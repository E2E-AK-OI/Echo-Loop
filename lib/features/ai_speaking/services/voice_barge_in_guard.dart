import 'dart:math' as math;

/// 外放插话动作：降低 TTS 音量、确认插话、恢复 TTS 音量、关闭插话。
enum VoiceBargeInActionType { duck, confirm, resume, disable }

class VoiceBargeInAction {
  const VoiceBargeInAction(this.type, {this.volume});

  final VoiceBargeInActionType type;
  final double? volume;
}

/// 外放插话判别器。
///
/// 平台 AEC 只能削弱回声，不能保证完全消除。这里用两段式策略：
/// 1. TTS 播放中检测到持续人声，先把 TTS 音量 duck 到 12%，给 AEC 留出
///    收敛时间；
/// 2. duck 后先等 180ms 让平台 AEC 收敛，再以收敛后的残留电平为基线：
///    持续高于基线的上升人声 250ms 才确认插话；若残留仍接近 duck 前峰值，
///    说明 AEC 没有压住外放，直接关闭插话，避免把 TTS 回声当用户输入。
///
/// 该判别器只处理 PCM 电平，不依赖 [VadTurnDetector]；后者在播放期间被
/// mute，避免能量门限被 TTS 自身触发。
class VoiceBargeInGuard {
  VoiceBargeInGuard({
    DateTime Function()? now,
    this.duckVolume = 0.12,
    this.minPlaybackBeforeCandidate = const Duration(milliseconds: 300),
    this.candidateHold = const Duration(milliseconds: 90),
    this.candidateTimeout = const Duration(milliseconds: 900),
    this.confirmHold = const Duration(milliseconds: 250),
    this.resumeHold = const Duration(milliseconds: 500),
    this.maxDuckDuration = const Duration(milliseconds: 1500),
    this.echoRatio = 0.38,
    this.duckVoiceFloor = 0.055,
    this.duckAmbientFloor = 0.02,
    this.duckSettleDuration = const Duration(milliseconds: 180),
    this.duckIneffectiveRatio = 0.7,
    this.duckRiseRatio = 1.5,
  }) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final double duckVolume;
  final Duration minPlaybackBeforeCandidate;
  final Duration candidateHold;
  final Duration candidateTimeout;
  final Duration confirmHold;
  final Duration resumeHold;
  final Duration maxDuckDuration;
  final double echoRatio;
  final double duckVoiceFloor;
  final double duckAmbientFloor;
  final Duration duckSettleDuration;
  final double duckIneffectiveRatio;
  final double duckRiseRatio;

  bool _active = false;
  bool _isDucking = false;
  bool _confirmed = false;
  bool _hasCandidate = false;
  DateTime? _startedAt;
  DateTime? _candidateAt;
  DateTime? _candidateVoiceSince;
  DateTime? _candidateQuietSince;
  DateTime? _duckAt;
  DateTime? _duckVoiceSince;
  DateTime? _duckQuietSince;
  double _candidateThreshold = 0.05;
  double _duckVoiceThreshold = 0.055;
  double _duckAmbientThreshold = 0.02;
  double _recentPeak = 0;
  double _duckReference = 0;
  double _duckResidualPeak = 0;
  bool _duckSettled = false;

  bool get isDucking => _isDucking;
  bool get isConfirmed => _confirmed;

  void onPlaybackStarted({double candidateThreshold = 0.05}) {
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
    _recentPeak = math.max(level, _recentPeak * 0.97);

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
    if (!_duckSettled) {
      _duckResidualPeak = math.max(_duckResidualPeak, level);
      if (now.difference(_duckAt!) < duckSettleDuration) {
        return const <VoiceBargeInAction>[];
      }
      _duckSettled = true;
      // duck 后残留没有明显下降，说明 AEC 没把外放声音消掉；继续按
      // 能量确认只会把 TTS 回声当用户，必须关闭插话而不是误打断。
      if (_duckResidualPeak >= _duckReference * duckIneffectiveRatio) {
        return _disable();
      }
      _duckVoiceThreshold = math.max(
        duckVoiceFloor,
        math.max(_duckResidualPeak * duckRiseRatio, _duckReference * echoRatio),
      );
      _duckAmbientThreshold = math.max(
        duckAmbientFloor,
        _duckReference * echoRatio * 0.45,
      );
      _duckVoiceSince = null;
      _duckQuietSince = null;
    }
    if (level >= _duckVoiceThreshold) {
      _duckQuietSince = null;
      _duckVoiceSince ??= now;
      if (now.difference(_duckVoiceSince!) >= confirmHold) {
        return _confirm();
      }
    } else if (level <= _duckAmbientThreshold) {
      _duckVoiceSince = null;
      _duckQuietSince ??= now;
      if (now.difference(_duckQuietSince!) >= resumeHold) {
        return _resume();
      }
    } else {
      _duckVoiceSince = null;
      _duckQuietSince = null;
    }
    if (now.difference(_duckAt!) >= maxDuckDuration) {
      return _resume();
    }
    return const <VoiceBargeInAction>[];
  }

  List<VoiceBargeInAction> _startDuck(DateTime now) {
    _isDucking = true;
    _duckSettled = false;
    _duckAt = now;
    _duckVoiceSince = null;
    _duckQuietSince = null;
    _duckResidualPeak = 0;
    _duckReference = math.max(_recentPeak, _candidateThreshold);
    _duckVoiceThreshold = math.max(duckVoiceFloor, _duckReference * echoRatio);
    _duckAmbientThreshold = math.max(
      duckAmbientFloor,
      _duckReference * echoRatio * 0.45,
    );
    return [
      VoiceBargeInAction(VoiceBargeInActionType.duck, volume: duckVolume),
    ];
  }

  List<VoiceBargeInAction> _confirm() {
    _confirmed = true;
    _isDucking = false;
    _duckSettled = false;
    return const [VoiceBargeInAction(VoiceBargeInActionType.confirm)];
  }

  List<VoiceBargeInAction> _resume() {
    _isDucking = false;
    _duckSettled = false;
    _duckVoiceSince = null;
    _duckQuietSince = null;
    _hasCandidate = false;
    _recentPeak = 0;
    _duckReference = 0;
    _duckResidualPeak = 0;
    return const [VoiceBargeInAction(VoiceBargeInActionType.resume)];
  }

  List<VoiceBargeInAction> _disable() {
    _active = false;
    _confirmed = false;
    _isDucking = false;
    _duckSettled = false;
    _duckReference = 0;
    _duckResidualPeak = 0;
    _clearCandidate();
    return const [VoiceBargeInAction(VoiceBargeInActionType.disable)];
  }

  /// TTS 播放停止时恢复可能处于 duck 状态的音量。
  List<VoiceBargeInAction> onPlaybackStopped() {
    final wasDucking = _isDucking;
    _active = false;
    _isDucking = false;
    _clearCandidate();
    if (!wasDucking) return const <VoiceBargeInAction>[];
    return const [VoiceBargeInAction(VoiceBargeInActionType.resume)];
  }

  void reset() {
    _active = false;
    _isDucking = false;
    _confirmed = false;
    _startedAt = null;
    _duckAt = null;
    _recentPeak = 0;
    _duckReference = 0;
    _duckResidualPeak = 0;
    _duckSettled = false;
    _clearCandidate();
  }

  void _clearCandidate() {
    _hasCandidate = false;
    _candidateAt = null;
    _candidateVoiceSince = null;
    _candidateQuietSince = null;
  }
}
