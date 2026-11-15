import 'dart:math' as math;

/// 外放插话动作：降低 TTS 音量、静音 TTS 复核、确认插话、恢复 TTS 音量。
enum VoiceBargeInActionType { duck, listen, confirm, resume }

class VoiceBargeInAction {
  const VoiceBargeInAction(this.type, {this.volume});

  final VoiceBargeInActionType type;
  final double? volume;
}

/// 外放插话判别器。
///
/// 平台 AEC 只能削弱回声，不能保证完全消除。这里固定走三段式
/// （duck → listen → confirm/resume）：
/// 1. TTS 播放一段时间后检测到持续人声，先把 TTS 音量 duck 到 12%，给
///    AEC 留出收敛时间；
/// 2. duck 收敛后不再根据“残留是否接近 duck 前峰值”决定是否复核，而是
///    一律把 TTS 静音一小段，彻底去掉回声后再判断。用户持续说话时，duck
///    只降低 TTS，用户自己的声音不会下降；用残留比例判断会把正常音量的
///    用户误判成回声。
///
/// 静音复核阶段按滑动窗口统计有声时长，而不是要求连续越过门限：真实语音
/// 有音节间隙，连续 250ms 的条件很容易被短暂停顿清零。
///
/// 该判别器只处理 PCM 电平，不依赖 [VadTurnDetector]；后者在播放期间被
/// mute，避免能量门限被 TTS 自身触发。
class VoiceBargeInGuard {
  VoiceBargeInGuard({
    DateTime Function()? now,
    this.duckVolume = 0.12,
    this.listenVolume = 0,
    this.minPlaybackBeforeCandidate = const Duration(milliseconds: 400),
    this.candidateHold = const Duration(milliseconds: 100),
    this.candidateTimeout = const Duration(milliseconds: 900),
    this.confirmHold = const Duration(milliseconds: 250),
    this.confirmWindow = const Duration(milliseconds: 700),
    this.resumeHold = const Duration(milliseconds: 450),
    this.maxDuckDuration = const Duration(milliseconds: 1600),
    this.resumeCooldown = const Duration(milliseconds: 1200),
    this.duckVoiceFloor = 0.03,
    this.duckSettleDuration = const Duration(milliseconds: 200),
    this.listenSettleDuration = const Duration(milliseconds: 180),
  }) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final double duckVolume;
  final double listenVolume;
  final Duration minPlaybackBeforeCandidate;
  final Duration candidateHold;
  final Duration candidateTimeout;
  final Duration confirmHold;
  final Duration confirmWindow;
  final Duration resumeHold;
  final Duration maxDuckDuration;
  final Duration resumeCooldown;
  final double duckVoiceFloor;
  final Duration duckSettleDuration;
  final Duration listenSettleDuration;

  bool _active = false;
  bool _isDucking = false;
  bool _isListening = false;
  bool _confirmed = false;
  bool _hasCandidate = false;
  DateTime? _startedAt;
  DateTime? _candidateAt;
  DateTime? _candidateVoiceSince;
  DateTime? _candidateQuietSince;
  DateTime? _duckAt;
  DateTime? _listenAt;
  DateTime? _cooldownUntil;
  DateTime? _lastFrameAt;
  DateTime? _lastVoicedAt;
  double _candidateThreshold = 0.04;
  double _duckVoiceThreshold = 0.03;
  double _duckResidualPeak = 0;
  bool _duckSettled = false;
  bool _listenSettled = false;
  final List<_VoiceSample> _voiceSamples = <_VoiceSample>[];
  double _voicedMsInWindow = 0;

  bool get isDucking => _isDucking;
  bool get isListening => _isListening;
  bool get isConfirmed => _confirmed;

  /// 供日志定位真机问题：残留峰值、当前门限、窗口内有声时长与静音时长。
  String get debugSummary {
    final quietMs = _quietMs(_now());
    return 'residual=${_duckResidualPeak.toStringAsFixed(3)}, '
        'threshold=${_duckVoiceThreshold.toStringAsFixed(3)}, '
        'voiced=${_voicedMsInWindow.toStringAsFixed(0)}ms, '
        'quiet=${quietMs.toStringAsFixed(0)}ms';
  }

  void onPlaybackStarted({double candidateThreshold = 0.04}) {
    reset();
    _active = true;
    _candidateThreshold = candidateThreshold;
    _startedAt = _now();
  }

  List<VoiceBargeInAction> onInputFrame(double level) {
    if (!_active || _confirmed || _startedAt == null) {
      return const <VoiceBargeInAction>[];
    }
    final now = _now();
    if (_cooldownUntil != null && now.isBefore(_cooldownUntil!)) {
      return const <VoiceBargeInAction>[];
    }

    if (!_isDucking) {
      return _handleCandidate(level, now);
    }
    return _handleDucking(level, now);
  }

  List<VoiceBargeInAction> _handleCandidate(double level, DateTime now) {
    if (!_hasCandidate) {
      if (level < _candidateThreshold) return const <VoiceBargeInAction>[];
      _hasCandidate = true;
      _candidateAt = now;
      _candidateVoiceSince = now;
      _candidateQuietSince = null;
    }
    if (now.difference(_startedAt!) < minPlaybackBeforeCandidate) {
      return const <VoiceBargeInAction>[];
    }
    if (now.difference(_candidateAt!) > candidateTimeout) {
      _clearCandidate();
      return const <VoiceBargeInAction>[];
    }
    if (level >= _candidateThreshold) {
      _candidateQuietSince = null;
      if (now.difference(_candidateVoiceSince!) >= candidateHold) {
        return _startDuck(now);
      }
      return const <VoiceBargeInAction>[];
    }
    if (level < _candidateThreshold * 0.6) {
      _candidateQuietSince ??= now;
      if (now.difference(_candidateQuietSince!) >=
          const Duration(milliseconds: 120)) {
        _clearCandidate();
      }
    }
    return const <VoiceBargeInAction>[];
  }

  List<VoiceBargeInAction> _handleDucking(double level, DateTime now) {
    if (_isListening) {
      return _handleListening(level, now);
    }
    if (!_duckSettled) {
      _duckResidualPeak = math.max(_duckResidualPeak, level);
      if (now.difference(_duckAt!) < duckSettleDuration) {
        return const <VoiceBargeInAction>[];
      }
      _duckSettled = true;
      _isListening = true;
      _listenAt = now;
      _listenSettled = false;
      _duckVoiceThreshold = math.max(
        duckVoiceFloor,
        _candidateThreshold * 0.75,
      );
      _resetVoiceWindow(now);
      return [
        VoiceBargeInAction(VoiceBargeInActionType.listen, volume: listenVolume),
      ];
    }
    return const <VoiceBargeInAction>[];
  }

  /// TTS 已静音后的复核：等播放管线把尾音放完，再按滑动窗口判断人声。
  List<VoiceBargeInAction> _handleListening(double level, DateTime now) {
    if (!_listenSettled) {
      _lastFrameAt = now;
      if (now.difference(_listenAt!) < listenSettleDuration) {
        return const <VoiceBargeInAction>[];
      }
      _listenSettled = true;
      _lastFrameAt = now;
      _lastVoicedAt = now;
      _duckVoiceThreshold = math.max(
        duckVoiceFloor,
        _candidateThreshold * 0.75,
      );
      _resetVoiceWindow(now);
      // 收敛帧本身不参与判断，避免播放管线最后一小段尾音被当成人声。
      return const <VoiceBargeInAction>[];
    }

    final deltaMs = _frameDeltaMs(now);
    final voiced = level >= _duckVoiceThreshold;
    if (voiced) {
      _lastVoicedAt = now;
    }
    _addVoiceSample(now, deltaMs, voiced);

    final voicedFrames = _voiceSamples.where((sample) => sample.voiced).length;
    if (_voicedMsInWindow >= confirmHold.inMilliseconds && voicedFrames >= 3) {
      return _confirm();
    }
    if (_quietMs(now) >= resumeHold.inMilliseconds) {
      return _resume(now);
    }
    if (now.difference(_duckAt!) >= maxDuckDuration) {
      return _resume(now);
    }
    return const <VoiceBargeInAction>[];
  }

  double _frameDeltaMs(DateTime now) {
    final last = _lastFrameAt;
    _lastFrameAt = now;
    if (last == null) return 0;
    return now.difference(last).inMilliseconds.clamp(0, 200).toDouble();
  }

  void _addVoiceSample(DateTime now, double durationMs, bool voiced) {
    if (durationMs <= 0) return;
    _voiceSamples.add(_VoiceSample(now, durationMs, voiced));
    if (voiced) {
      _voicedMsInWindow += durationMs;
    }
    final cutoff = now.subtract(confirmWindow);
    while (_voiceSamples.isNotEmpty &&
        _voiceSamples.first.at.isBefore(cutoff)) {
      final removed = _voiceSamples.removeAt(0);
      if (removed.voiced) {
        _voicedMsInWindow -= removed.durationMs;
      }
    }
  }

  double _quietMs(DateTime now) {
    final since = _lastVoicedAt ?? _listenAt;
    if (since == null) return 0;
    return math.max(0, now.difference(since).inMilliseconds.toDouble());
  }

  void _resetVoiceWindow(DateTime? referenceAt) {
    _voiceSamples.clear();
    _voicedMsInWindow = 0;
    _lastFrameAt = referenceAt;
    _lastVoicedAt = referenceAt;
  }

  List<VoiceBargeInAction> _startDuck(DateTime now) {
    _isDucking = true;
    _duckSettled = false;
    _isListening = false;
    _listenAt = null;
    _listenSettled = false;
    _duckAt = now;
    _duckResidualPeak = 0;
    _duckVoiceThreshold = math.max(duckVoiceFloor, _candidateThreshold * 0.75);
    _resetVoiceWindow(now);
    return [
      VoiceBargeInAction(VoiceBargeInActionType.duck, volume: duckVolume),
    ];
  }

  List<VoiceBargeInAction> _confirm() {
    _confirmed = true;
    _isDucking = false;
    _isListening = false;
    _duckSettled = false;
    _listenSettled = false;
    _resetVoiceWindow(null);
    return const [VoiceBargeInAction(VoiceBargeInActionType.confirm)];
  }

  List<VoiceBargeInAction> _resume(DateTime now) {
    _isDucking = false;
    _isListening = false;
    _duckSettled = false;
    _listenSettled = false;
    _duckAt = null;
    _listenAt = null;
    _hasCandidate = false;
    _duckResidualPeak = 0;
    _resetVoiceWindow(null);
    _cooldownUntil = now.add(resumeCooldown);
    return const [VoiceBargeInAction(VoiceBargeInActionType.resume)];
  }

  /// TTS 播放停止时恢复可能处于 duck/静音状态的音量。
  List<VoiceBargeInAction> onPlaybackStopped() {
    final wasDucking = _isDucking || _isListening;
    _active = false;
    _isDucking = false;
    _isListening = false;
    _duckSettled = false;
    _listenSettled = false;
    _resetVoiceWindow(null);
    _clearCandidate();
    if (!wasDucking) return const <VoiceBargeInAction>[];
    return const [VoiceBargeInAction(VoiceBargeInActionType.resume)];
  }

  void reset() {
    _active = false;
    _isDucking = false;
    _isListening = false;
    _confirmed = false;
    _startedAt = null;
    _duckAt = null;
    _listenAt = null;
    _duckResidualPeak = 0;
    _duckSettled = false;
    _listenSettled = false;
    _cooldownUntil = null;
    _resetVoiceWindow(null);
    _clearCandidate();
  }

  void _clearCandidate() {
    _hasCandidate = false;
    _candidateAt = null;
    _candidateVoiceSince = null;
    _candidateQuietSince = null;
  }
}

class _VoiceSample {
  const _VoiceSample(this.at, this.durationMs, this.voiced);

  final DateTime at;
  final double durationMs;
  final bool voiced;
}
