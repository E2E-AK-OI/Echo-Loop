/// AI 口语练习的引擎来源设置。
///
/// 语音识别与语音合成各自可以在「AI 服务」和「本地引擎」之间选择；
/// 大模型始终来自 AI 设置。默认全部使用 AI 服务，保持既有行为不变。
library;

import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences 键名常量。
abstract final class SpeakingEngineSettingsKeys {
  static const asrSource = 'speaking_engine_asr_source';
  static const ttsSource = 'speaking_engine_tts_source';
}

/// 语音识别来源。
enum SpeakingAsrSource {
  /// AI 设置中的 DashScope 实时语音识别。
  ai,

  /// 语音识别设置中的本地离线模型。
  local,
}

/// 语音合成来源。
enum SpeakingTtsSource {
  /// AI 设置中的 DashScope 语音合成。
  ai,

  /// 语音合成设置中的本地/系统引擎。
  local,
}

/// 口语引擎来源设置值对象。
class SpeakingEngineSettings {
  const SpeakingEngineSettings({
    required this.asrSource,
    required this.ttsSource,
  });

  /// 默认沿用 AI 服务，避免升级后改变用户已有的练习链路。
  static const defaults = SpeakingEngineSettings(
    asrSource: SpeakingAsrSource.ai,
    ttsSource: SpeakingTtsSource.ai,
  );

  final SpeakingAsrSource asrSource;
  final SpeakingTtsSource ttsSource;

  bool get usesLocalAsr => asrSource == SpeakingAsrSource.local;

  bool get usesLocalTts => ttsSource == SpeakingTtsSource.local;

  SpeakingEngineSettings copyWith({
    SpeakingAsrSource? asrSource,
    SpeakingTtsSource? ttsSource,
  }) {
    return SpeakingEngineSettings(
      asrSource: asrSource ?? this.asrSource,
      ttsSource: ttsSource ?? this.ttsSource,
    );
  }

  /// 从本地偏好同步读取；未知值回退到 AI 服务。
  factory SpeakingEngineSettings.fromPrefsSync(SharedPreferences prefs) {
    return SpeakingEngineSettings(
      asrSource: parseAsrSource(
        prefs.getString(SpeakingEngineSettingsKeys.asrSource),
      ),
      ttsSource: parseTtsSource(
        prefs.getString(SpeakingEngineSettingsKeys.ttsSource),
      ),
    );
  }

  /// 解析语音识别来源；未知值回退到 AI 服务。
  static SpeakingAsrSource parseAsrSource(String? value) {
    return SpeakingAsrSource.values.firstWhere(
      (source) => source.name == value,
      orElse: () => SpeakingAsrSource.ai,
    );
  }

  /// 解析语音合成来源；未知值回退到 AI 服务。
  static SpeakingTtsSource parseTtsSource(String? value) {
    return SpeakingTtsSource.values.firstWhere(
      (source) => source.name == value,
      orElse: () => SpeakingTtsSource.ai,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is SpeakingEngineSettings &&
        other.asrSource == asrSource &&
        other.ttsSource == ttsSource;
  }

  @override
  int get hashCode => Object.hash(asrSource, ttsSource);
}
