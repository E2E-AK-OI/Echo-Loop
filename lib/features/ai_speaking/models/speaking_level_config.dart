/// 单个口语档位的语音引擎配置。
///
/// 四个档位各自保存一套语音识别、语音合成、实时语音与会话参数：初级可以继续用
/// 本地识别/合成，高级要求云端实时识别，特级换成端到端语音模型。大模型配置与
/// DashScope 工作空间属于账号级设置，仍由「AI 设置」统一维护，这里不重复保存。
///
/// 存储使用「基础键名_档位名」后缀（如 `speaking_engine_asr_source_advanced`）；
/// 读取未命中时回退到旧版全局键，老用户升级后原有配置不会丢失。
library;

import 'package:shared_preferences/shared_preferences.dart';

import 'ai_speaking_level.dart';
import 'ai_speaking_settings.dart';
import 'speaking_dialog_settings.dart';
import 'speaking_engine_settings.dart';

/// 档位配置的 SharedPreferences 键名。
abstract final class SpeakingLevelConfigKeys {
  /// 生成带档位后缀的键名。
  static String key(String base, AiSpeakingLevel level) =>
      '${base}_${level.name}';

  static String asrSource(AiSpeakingLevel level) =>
      key(SpeakingEngineSettingsKeys.asrSource, level);

  static String ttsSource(AiSpeakingLevel level) =>
      key(SpeakingEngineSettingsKeys.ttsSource, level);

  static String asrModel(AiSpeakingLevel level) =>
      key(AiSpeakingSettingsKeys.asrModel, level);

  static String ttsModel(AiSpeakingLevel level) =>
      key(AiSpeakingSettingsKeys.ttsModel, level);

  static String ttsVoice(AiSpeakingLevel level) =>
      key(AiSpeakingSettingsKeys.ttsVoice, level);

  static String ttsRate(AiSpeakingLevel level) =>
      key(AiSpeakingSettingsKeys.ttsRate, level);

  static String autoPlay(AiSpeakingLevel level) =>
      key(AiSpeakingSettingsKeys.ttsAutoPlay, level);

  static String realtimeModel(AiSpeakingLevel level) =>
      key(AiSpeakingSettingsKeys.realtimeModel, level);

  static String realtimeVoice(AiSpeakingLevel level) =>
      key(AiSpeakingSettingsKeys.realtimeVoice, level);

  static String realtimeTurnDetection(AiSpeakingLevel level) =>
      key(AiSpeakingSettingsKeys.realtimeTurnDetection, level);

  static String endOfSpeechMs(AiSpeakingLevel level) =>
      key(SpeakingDialogSettingsKeys.endOfSpeechMs, level);

  static String idleExitSeconds(AiSpeakingLevel level) =>
      key(SpeakingDialogSettingsKeys.idleExitSeconds, level);

  static String bargeInSensitivity(AiSpeakingLevel level) =>
      key(SpeakingDialogSettingsKeys.bargeInSensitivity, level);
}

/// 一个档位的完整语音引擎配置。
class SpeakingLevelConfig {
  const SpeakingLevelConfig({
    required this.engine,
    required this.speech,
    required this.dialog,
  });

  /// 该档位默认配置：全部走 AI 服务、低延迟 flash 音色、800ms 尾静音与 30 秒空闲退出。
  factory SpeakingLevelConfig.defaultsFor(AiSpeakingLevel level) {
    return SpeakingLevelConfig(
      engine: SpeakingEngineSettings.defaults,
      speech: AiSpeakingSettings.defaults.speech.copyWith(
        ttsModel: recommendedTtsModelFor(level),
        ttsVoice: AiSpeechConfig.defaultFlashTtsVoice,
      ),
      dialog: SpeakingDialogSettings.defaults,
    );
  }

  /// 各档位统一推荐低延迟的 flash 模型；plus 仍可在设置页手动选择。
  static String recommendedTtsModelFor(AiSpeakingLevel level) {
    return AiSpeechConfig.flashTtsModel;
  }

  /// 语音识别与语音合成的来源。
  final SpeakingEngineSettings engine;

  /// 语音模型、音色、语速、自动播放与实时语音参数。
  ///
  /// `workspaceId` 在这里始终为空，运行时会与「AI 设置」中的工作空间合并，
  /// 避免两个页面各存一份账号级配置。
  final AiSpeechConfig speech;

  /// 免提会话的尾静音、空闲退出与打断灵敏度。
  final SpeakingDialogSettings dialog;

  /// 从本地偏好读取指定档位的配置。
  ///
  /// 优先读取带档位后缀的键；没有写过时回退到旧版全局键，保证升级平滑。
  factory SpeakingLevelConfig.fromPrefsSync(
    SharedPreferences prefs,
    AiSpeakingLevel level,
  ) {
    final legacyEngine = SpeakingEngineSettings.fromPrefsSync(prefs);
    final legacyDialog = SpeakingDialogSettings.fromPrefsSync(prefs);
    final legacySpeech = AiSpeakingSettings.fromPrefsSync(prefs).speech;

    final asrSource =
        _readEnum(
          prefs,
          SpeakingLevelConfigKeys.asrSource(level),
          SpeakingEngineSettings.parseAsrSource,
        ) ??
        legacyEngine.asrSource;
    final ttsSource =
        _readEnum(
          prefs,
          SpeakingLevelConfigKeys.ttsSource(level),
          SpeakingEngineSettings.parseTtsSource,
        ) ??
        legacyEngine.ttsSource;

    final asrModel = AiSpeechConfig.normalizeAsrModel(
      _readString(prefs, SpeakingLevelConfigKeys.asrModel(level)) ??
          legacySpeech.asrModel,
    );
    final ttsModel = AiSpeechConfig.normalizeTtsModel(
      _readString(prefs, SpeakingLevelConfigKeys.ttsModel(level)) ??
          legacySpeech.ttsModel,
    );
    final ttsVoice = AiSpeechConfig.resolveTtsVoice(
      model: ttsModel,
      voice:
          _readString(prefs, SpeakingLevelConfigKeys.ttsVoice(level)) ??
          legacySpeech.ttsVoice,
    );
    final ttsRate =
        (prefs.getDouble(SpeakingLevelConfigKeys.ttsRate(level)) ??
                legacySpeech.ttsRate)
            .clamp(0.5, 2.0)
            .toDouble();
    final autoPlay =
        prefs.getBool(SpeakingLevelConfigKeys.autoPlay(level)) ??
        legacySpeech.autoPlay;
    final realtimeModel = AiSpeechConfig.normalizeRealtimeModel(
      _readString(prefs, SpeakingLevelConfigKeys.realtimeModel(level)) ??
          legacySpeech.realtimeModel,
    );
    final realtimeVoice = AiSpeechConfig.resolveRealtimeVoice(
      _readString(prefs, SpeakingLevelConfigKeys.realtimeVoice(level)) ??
          legacySpeech.realtimeVoice,
    );
    final realtimeTurnDetection =
        _readEnum(
          prefs,
          SpeakingLevelConfigKeys.realtimeTurnDetection(level),
          RealtimeTurnDetection.fromStorage,
        ) ??
        legacySpeech.realtimeTurnDetection;

    final endOfSpeechMs =
        prefs.getInt(SpeakingLevelConfigKeys.endOfSpeechMs(level)) ??
        legacyDialog.endOfSpeechMs;
    final idleExitSeconds =
        prefs.getInt(SpeakingLevelConfigKeys.idleExitSeconds(level)) ??
        legacyDialog.idleExitSeconds;
    final bargeInSensitivity =
        _readEnum(
          prefs,
          SpeakingLevelConfigKeys.bargeInSensitivity(level),
          BargeInSensitivity.fromStorage,
        ) ??
        legacyDialog.bargeInSensitivity;

    return SpeakingLevelConfig(
      engine: SpeakingEngineSettings(
        asrSource: asrSource,
        ttsSource: ttsSource,
      ),
      speech: AiSpeechConfig(
        asrModel: asrModel,
        ttsModel: ttsModel,
        ttsVoice: ttsVoice,
        ttsRate: ttsRate,
        autoPlay: autoPlay,
        workspaceId: '',
        realtimeModel: realtimeModel,
        realtimeVoice: realtimeVoice,
        realtimeTurnDetection: realtimeTurnDetection,
      ),
      dialog: SpeakingDialogSettings(
        endOfSpeechMs: endOfSpeechMs,
        idleExitSeconds: idleExitSeconds,
        bargeInSensitivity: bargeInSensitivity,
      ),
    );
  }

  static String? _readString(SharedPreferences prefs, String key) {
    final value = prefs.getString(key)?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  static T? _readEnum<T>(
    SharedPreferences prefs,
    String key,
    T Function(String? value) parse,
  ) {
    final raw = prefs.getString(key);
    if (raw == null || raw.trim().isEmpty) return null;
    return parse(raw);
  }

  SpeakingLevelConfig copyWith({
    SpeakingEngineSettings? engine,
    AiSpeechConfig? speech,
    SpeakingDialogSettings? dialog,
  }) {
    return SpeakingLevelConfig(
      engine: engine ?? this.engine,
      speech: speech ?? this.speech,
      dialog: dialog ?? this.dialog,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is SpeakingLevelConfig &&
        other.engine == engine &&
        other.speech == speech &&
        other.dialog == dialog;
  }

  @override
  int get hashCode => Object.hash(engine, speech, dialog);
}
