/// AI 口语练习的对话与会话设置。
///
/// 这些参数只影响「中级及以上」的自由对话：尾静音多久算说完、长时间不说话多久
/// 退出会话、以及高级档打断 AI 时的语音活动灵敏度。所有取值在构造时钳制，
/// 历史数据或越界输入不会让引擎进入非法状态。
///
/// 中级档 AI 朗读期间 VAD 静音（不允许插话）；高级档保持判定，并用
/// `bargeInThreshold` 抬高门限抵消外放回声。
library;

import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences 键名常量。
abstract final class SpeakingDialogSettingsKeys {
  static const endOfSpeechMs = 'speaking_dialog_end_of_speech_ms';
  static const idleExitSeconds = 'speaking_dialog_idle_exit_seconds';
  static const bargeInSensitivity = 'speaking_dialog_barge_in_sensitivity';
}

/// 打断灵敏度：映射为 VAD 判定用户开口所需的语音概率/能量门限。
///
/// 门限越高越不容易被 AI 自己的外放声音误触发，但也越难打断；
/// 外放环境建议用「低」，耳机环境可用「高」。
enum BargeInSensitivity {
  /// 低：门限最高，最不容易误触发。
  low(0.22),

  /// 中：默认档位。
  medium(0.16),

  /// 高：门限最低，最容易打断。
  high(0.12);

  const BargeInSensitivity(this.vadThreshold);

  /// 交 VoiceActivityDetector 的能量门限（0~1）。
  final double vadThreshold;

  /// AI 朗读期间判定插话所用的 RMS 门限（0~1）。
  ///
  /// 外放时残余回声会抬高底噪，因此比平时的能量门限更高；
  /// 灵敏度越高门限越低，越容易打断。
  double get bargeInThreshold => switch (this) {
    BargeInSensitivity.low => 0.06,
    BargeInSensitivity.medium => 0.045,
    BargeInSensitivity.high => 0.03,
  };

  /// 从本地偏好读取，未知值回退到中档。
  static BargeInSensitivity fromStorage(String? value) {
    return BargeInSensitivity.values.firstWhere(
      (sensitivity) => sensitivity.name == value,
      orElse: () => BargeInSensitivity.medium,
    );
  }
}

/// 对话与会话设置值对象。
class SpeakingDialogSettings {
  const SpeakingDialogSettings._({
    required this.endOfSpeechMs,
    required this.idleExitSeconds,
    required this.bargeInSensitivity,
  });

  /// 默认值：800ms 尾静音、30 秒空闲退出、中档打断灵敏度。
  static const defaults = SpeakingDialogSettings._(
    endOfSpeechMs: defaultEndOfSpeechMs,
    idleExitSeconds: defaultIdleExitSeconds,
    bargeInSensitivity: BargeInSensitivity.medium,
  );

  /// 尾静音下限：低于 400ms 会把正常换气误判成说完。
  static const minEndOfSpeechMs = 400;

  /// 尾静音上限：也是「始终没有确认静音」时的强制断句兜底。
  static const maxEndOfSpeechMs = 2000;

  /// 尾静音默认值。
  static const defaultEndOfSpeechMs = 800;

  /// 空闲退出下限。
  static const minIdleExitSeconds = 10;

  /// 空闲退出上限。
  static const maxIdleExitSeconds = 60;

  /// 空闲退出默认值。
  static const defaultIdleExitSeconds = 30;

  /// 设置页可选的尾静音档位。
  static const endOfSpeechOptions = <int>[400, 600, 800, 1000, 1500, 2000];

  /// 设置页可选的空闲退出档位。
  static const idleExitOptions = <int>[10, 15, 20, 30, 45, 60];

  /// 用户说话结束的尾静音阈值。
  final int endOfSpeechMs;

  /// 长时间没有用户语音时自动结束会话的秒数。
  final int idleExitSeconds;

  /// 打断灵敏度（仅高级档使用）。
  final BargeInSensitivity bargeInSensitivity;

  /// 强制断句兜底：超过该时长仍未确认静音时也要结束本轮，避免一直卡在聆听。
  static const int hardLimitEndOfSpeechMs = maxEndOfSpeechMs;

  /// 构造时钳制到合法范围；越界不抛异常，保证设置页与历史数据都能安全落地。
  factory SpeakingDialogSettings({
    required int endOfSpeechMs,
    required int idleExitSeconds,
    BargeInSensitivity bargeInSensitivity = BargeInSensitivity.medium,
  }) {
    return SpeakingDialogSettings._(
      endOfSpeechMs: endOfSpeechMs.clamp(minEndOfSpeechMs, maxEndOfSpeechMs),
      idleExitSeconds: idleExitSeconds.clamp(
        minIdleExitSeconds,
        maxIdleExitSeconds,
      ),
      bargeInSensitivity: bargeInSensitivity,
    );
  }

  Duration get endOfSpeech => Duration(milliseconds: endOfSpeechMs);

  Duration get idleExit => Duration(seconds: idleExitSeconds);

  SpeakingDialogSettings copyWith({
    int? endOfSpeechMs,
    int? idleExitSeconds,
    BargeInSensitivity? bargeInSensitivity,
  }) {
    return SpeakingDialogSettings(
      endOfSpeechMs: endOfSpeechMs ?? this.endOfSpeechMs,
      idleExitSeconds: idleExitSeconds ?? this.idleExitSeconds,
      bargeInSensitivity: bargeInSensitivity ?? this.bargeInSensitivity,
    );
  }

  /// 从本地偏好同步读取；缺失项回退默认值，越界值自动钳制。
  factory SpeakingDialogSettings.fromPrefsSync(SharedPreferences prefs) {
    return SpeakingDialogSettings(
      endOfSpeechMs:
          prefs.getInt(SpeakingDialogSettingsKeys.endOfSpeechMs) ??
          defaultEndOfSpeechMs,
      idleExitSeconds:
          prefs.getInt(SpeakingDialogSettingsKeys.idleExitSeconds) ??
          defaultIdleExitSeconds,
      bargeInSensitivity: BargeInSensitivity.fromStorage(
        prefs.getString(SpeakingDialogSettingsKeys.bargeInSensitivity),
      ),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is SpeakingDialogSettings &&
        other.endOfSpeechMs == endOfSpeechMs &&
        other.idleExitSeconds == idleExitSeconds &&
        other.bargeInSensitivity == bargeInSensitivity;
  }

  @override
  int get hashCode =>
      Object.hash(endOfSpeechMs, idleExitSeconds, bargeInSensitivity);
}
