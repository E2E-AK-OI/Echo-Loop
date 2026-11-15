/// 本地 VAD 轮次判定：把连续的输入电平样本转换为「开始说话 / 说完 / 长时间静默」事件。
///
/// 中级档位不允许插话打断，轮次切换完全依赖本地能量判停；高级档在 AI 朗读
/// 期间保持判定以支持插话，此时调用 `raiseThreshold` 抬高门限抑制外放回声。
/// 越过门限并持续 `minSpeech` 视为开始说话；尾静音达到 EOS 视为说完；
/// 长时间没有语音则退出会话。只做能量判断，不做语义判停，保证延迟可控。
library;

import 'dart:math' as math;

/// VAD 判定事件。
enum VadTurnEvent {
  /// 用户开始说话（已越过最小语音时长防抖）。
  speechStarted,

  /// 用户说完（尾静音达到 EOS 时长）。
  speechEnded,

  /// 长时间没有用户语音，需要退出会话。
  idleTimeout,
}

/// VAD 内部状态。
enum VadTurnPhase {
  /// 静音或尚未确认的短促噪声。
  silence,

  /// 已确认用户正在说话。
  speech,
}

/// 能量门限 VAD，输入为 16bit 单声道 PCM 的 RMS（0~1）。
///
/// 调用方按录音帧节奏喂入 `feed`，并用同一帧的时间戳驱动计时，
/// 便于在测试中用假时间戳验证 EOS 与空闲超时的边界。
class VadTurnDetector {
  VadTurnDetector({
    required this.endOfSpeech,
    required this.idleTimeout,
    this.speechThreshold = 0.02,
    this.minSpeech = const Duration(milliseconds: 180),
    this.noiseFloorFactor = 3.0,
    this.maxNoiseFloor = 0.02,
    this.hardLimit = const Duration(milliseconds: 2000),
  });

  /// 尾静音达到该时长即判定说完（由「口语引擎」设置页配置，上限 2000ms）。
  final Duration endOfSpeech;

  /// 静默达到该时长即退出会话。
  final Duration idleTimeout;

  /// 绝对门限：环境噪声再低也要越过该电平才算说话。
  final double speechThreshold;

  /// 最小语音时长，用于过滤咳嗽、敲击等短促噪声。
  final Duration minSpeech;

  /// 噪声底倍数：门限取绝对门限与「噪声底 × 倍数」中的较大值。
  final double noiseFloorFactor;

  /// 噪声底上限，避免环境嘈杂时门限被抬得过高。
  final double maxNoiseFloor;

  /// 持续高于门限、始终等不到静音帧时的强制断句兜底。
  ///
  /// 以本轮语音峰值的 70% 作为「仍有语音」的释放门限：电平长期
  /// 无法回到峰值附近，说明用户已经说完，只是环境噪声仍高于入门门限。
  /// 这时从最后一次接近峰值算起超过该时长就强制结束，避免一直卡在聆听。
  final Duration hardLimit;

  VadTurnPhase _phase = VadTurnPhase.silence;
  int? _speechOnsetMs;
  int? _lastVoicedMs;
  int? _silenceStartMs;
  int? _lastStrongMs;
  double _peakLevel = 0;
  double _noiseFloor = 0;
  bool _isMuted = false;
  double? _raisedThreshold;

  /// 当前是否已确认在说话。
  VadTurnPhase get phase => _phase;

  /// 当前生效的能量门限：绝对门限、临时抬高的门限与噪声底三者取最大。
  double get effectiveThreshold => math.max(
    math.max(speechThreshold, _raisedThreshold ?? 0),
    _noiseFloor * noiseFloorFactor,
  );

  /// 临时抬高判定门限；传 null 恢复默认。
  ///
  /// 高级档 AI 朗读期间仍要判定用户是否插话，而外放声音会被麦克风拾取，
  /// 因此用比平时更高的门限抵消残余回声，避免 AI 自己的声音触发打断。
  void raiseThreshold(double? threshold) {
    _raisedThreshold = threshold;
  }

  /// 静音期间暂停判定。
  ///
  /// AI 朗读期间必须静音：外放声音会被麦克风拾取，若继续判定会被误当成用户说话。
  void mute() {
    _isMuted = true;
    _phase = VadTurnPhase.silence;
    _speechOnsetMs = null;
    _lastVoicedMs = null;
    _lastStrongMs = null;
    _peakLevel = 0;
  }

  /// 恢复判定，并以当前时刻重新开始静默计时。
  void unmute({required int timestampMs}) {
    _isMuted = false;
    _phase = VadTurnPhase.silence;
    _speechOnsetMs = null;
    _lastVoicedMs = null;
    _lastStrongMs = null;
    _peakLevel = 0;
    _silenceStartMs = timestampMs;
  }

  /// 清空全部状态，用于新一轮会话。
  void reset() {
    _phase = VadTurnPhase.silence;
    _speechOnsetMs = null;
    _lastVoicedMs = null;
    _lastStrongMs = null;
    _peakLevel = 0;
    _silenceStartMs = null;
    _noiseFloor = 0;
    _isMuted = false;
  }

  /// 喂入一帧电平，返回本轮产生的判定事件。
  VadTurnEvent? feed({required double level, required int timestampMs}) {
    if (_isMuted) return null;
    _silenceStartMs ??= timestampMs;
    final isVoiced = level.isFinite && level >= effectiveThreshold;

    if (isVoiced) {
      _speechOnsetMs ??= timestampMs;
      _lastVoicedMs = timestampMs;
      if (_phase == VadTurnPhase.silence &&
          timestampMs - _speechOnsetMs! >= minSpeech.inMilliseconds) {
        _phase = VadTurnPhase.speech;
        _peakLevel = level;
        _lastStrongMs = timestampMs;
        return VadTurnEvent.speechStarted;
      }
      if (_phase == VadTurnPhase.speech) {
        if (level > _peakLevel) _peakLevel = level;
        // 只有接近本轮峰值的电平才算「仍在说话」。持续高于入门门限但
        // 明显低于峰值的底噪不会刷新计时，超时后由强制断句结束本轮。
        final strongThreshold = math.max(effectiveThreshold, _peakLevel * 0.7);
        if (level > strongThreshold) {
          _lastStrongMs = timestampMs;
        } else if (hardLimit > Duration.zero &&
            _lastStrongMs != null &&
            timestampMs - _lastStrongMs! >= hardLimit.inMilliseconds) {
          _phase = VadTurnPhase.silence;
          _speechOnsetMs = null;
          _silenceStartMs = timestampMs;
          _lastStrongMs = null;
          _peakLevel = 0;
          return VadTurnEvent.speechEnded;
        }
      }
      return null;
    }

    if (_phase == VadTurnPhase.speech) {
      if (timestampMs - _lastVoicedMs! >= endOfSpeech.inMilliseconds) {
        _phase = VadTurnPhase.silence;
        _speechOnsetMs = null;
        _silenceStartMs = timestampMs;
        _lastStrongMs = null;
        _peakLevel = 0;
        return VadTurnEvent.speechEnded;
      }
      return null;
    }

    // 未确认说话时的静音帧：重置起音计时并缓慢跟踪噪声底。
    _speechOnsetMs = null;
    if (level.isFinite && level > 0) {
      _noiseFloor = math.min(maxNoiseFloor, _noiseFloor * 0.98 + level * 0.02);
    }
    if (timestampMs - _silenceStartMs! >= idleTimeout.inMilliseconds) {
      _silenceStartMs = timestampMs;
      return VadTurnEvent.idleTimeout;
    }
    return null;
  }
}
