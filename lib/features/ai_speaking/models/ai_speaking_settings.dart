/// AI 口语练习的本地设置值对象。
///
/// 非敏感设置存 SharedPreferences；API Key 不进入这里，统一由
/// AiSpeakingCredentialStore 存 FlutterSecureStorage。
library;

import 'package:shared_preferences/shared_preferences.dart';

import 'ai_llm_provider.dart';

/// SharedPreferences 键名常量。
abstract final class AiSpeakingSettingsKeys {
  static const llmProvider = 'ai_speaking_llm_provider';
  static const llmBaseUrl = 'ai_speaking_llm_base_url';
  static const llmModel = 'ai_speaking_llm_model';
  static const llmTemperature = 'ai_speaking_llm_temperature';
  static const ttsModel = 'ai_speaking_tts_model';
  static const ttsVoice = 'ai_speaking_tts_voice';
  static const ttsRate = 'ai_speaking_tts_rate';
  static const ttsAutoPlay = 'ai_speaking_tts_auto_play';
  static const workspaceId = 'ai_speaking_workspace_id';
}

/// 大模型连接配置。
class AiLlmConfig {
  const AiLlmConfig({
    required this.provider,
    required this.baseUrl,
    required this.model,
    required this.temperature,
  });

  final AiLlmProvider provider;
  final String baseUrl;
  final String model;
  final double temperature;

  factory AiLlmConfig.defaultsFor(AiLlmProvider provider) {
    final preset = AiLlmPreset.of(provider);
    return AiLlmConfig(
      provider: provider,
      baseUrl: preset.baseUrl,
      model: preset.defaultModel,
      temperature: 0.7,
    );
  }

  AiLlmConfig copyWith({
    AiLlmProvider? provider,
    String? baseUrl,
    String? model,
    double? temperature,
  }) {
    return AiLlmConfig(
      provider: provider ?? this.provider,
      baseUrl: baseUrl ?? this.baseUrl,
      model: model ?? this.model,
      temperature: temperature ?? this.temperature,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is AiLlmConfig &&
        other.provider == provider &&
        other.baseUrl == baseUrl &&
        other.model == model &&
        other.temperature == temperature;
  }

  @override
  int get hashCode => Object.hash(provider, baseUrl, model, temperature);
}

/// 语音服务配置。
class AiSpeechConfig {
  const AiSpeechConfig({
    required this.asrModel,
    required this.ttsModel,
    required this.ttsVoice,
    required this.ttsRate,
    required this.autoPlay,
    required this.workspaceId,
  });

  static const defaultAsrModel = 'qwen-audio-3.1-asr-flash-streaming';
  static const defaultTtsModel = 'qwen-audio-3.1-tts-plus';
  static const defaultTtsVoice = 'longanlingxin_v3.1';

  final String asrModel;
  final String ttsModel;
  final String ttsVoice;
  final double ttsRate;
  final bool autoPlay;
  final String workspaceId;

  AiSpeechConfig copyWith({
    String? asrModel,
    String? ttsModel,
    String? ttsVoice,
    double? ttsRate,
    bool? autoPlay,
    String? workspaceId,
  }) {
    return AiSpeechConfig(
      asrModel: asrModel ?? this.asrModel,
      ttsModel: ttsModel ?? this.ttsModel,
      ttsVoice: ttsVoice ?? this.ttsVoice,
      ttsRate: ttsRate ?? this.ttsRate,
      autoPlay: autoPlay ?? this.autoPlay,
      workspaceId: workspaceId ?? this.workspaceId,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is AiSpeechConfig &&
        other.asrModel == asrModel &&
        other.ttsModel == ttsModel &&
        other.ttsVoice == ttsVoice &&
        other.ttsRate == ttsRate &&
        other.autoPlay == autoPlay &&
        other.workspaceId == workspaceId;
  }

  @override
  int get hashCode {
    return Object.hash(
      asrModel,
      ttsModel,
      ttsVoice,
      ttsRate,
      autoPlay,
      workspaceId,
    );
  }
}

/// AI 口语练习全部本地设置。
class AiSpeakingSettings {
  const AiSpeakingSettings({required this.llm, required this.speech});

  final AiLlmConfig llm;
  final AiSpeechConfig speech;

  static const defaults = AiSpeakingSettings(
    llm: AiLlmConfig(
      provider: AiLlmProvider.deepSeek,
      baseUrl: 'https://api.deepseek.com/v1',
      model: 'deepseek-chat',
      temperature: 0.7,
    ),
    speech: AiSpeechConfig(
      asrModel: AiSpeechConfig.defaultAsrModel,
      ttsModel: AiSpeechConfig.defaultTtsModel,
      ttsVoice: AiSpeechConfig.defaultTtsVoice,
      ttsRate: 1.0,
      autoPlay: true,
      workspaceId: '',
    ),
  );

  /// 从 SharedPreferences 同步构造首帧设置，避免设置页与主页读到不同快照。
  factory AiSpeakingSettings.fromPrefsSync(SharedPreferences prefs) {
    final provider = _readProvider(prefs);
    final preset = AiLlmPreset.of(provider);
    final storedBaseUrl =
        prefs.getString(AiSpeakingSettingsKeys.llmBaseUrl)?.trim() ?? '';
    final storedModel =
        prefs.getString(AiSpeakingSettingsKeys.llmModel)?.trim() ?? '';
    final rawTemperature =
        prefs.getDouble(AiSpeakingSettingsKeys.llmTemperature) ?? 0.7;
    final rawTtsRate = prefs.getDouble(AiSpeakingSettingsKeys.ttsRate) ?? 1.0;
    final storedTtsModel =
        prefs.getString(AiSpeakingSettingsKeys.ttsModel)?.trim() ?? '';
    final storedTtsVoice =
        prefs.getString(AiSpeakingSettingsKeys.ttsVoice)?.trim() ?? '';

    return AiSpeakingSettings(
      llm: AiLlmConfig(
        provider: provider,
        baseUrl: storedBaseUrl.isEmpty ? preset.baseUrl : storedBaseUrl,
        model: storedModel.isEmpty ? preset.defaultModel : storedModel,
        temperature: rawTemperature.clamp(0.0, 2.0).toDouble(),
      ),
      speech: AiSpeechConfig(
        asrModel: AiSpeechConfig.defaultAsrModel,
        ttsModel: storedTtsModel.isEmpty
            ? AiSpeechConfig.defaultTtsModel
            : storedTtsModel,
        ttsVoice: storedTtsVoice.isEmpty
            ? AiSpeechConfig.defaultTtsVoice
            : storedTtsVoice,
        ttsRate: rawTtsRate.clamp(0.5, 2.0).toDouble(),
        autoPlay: prefs.getBool(AiSpeakingSettingsKeys.ttsAutoPlay) ?? true,
        workspaceId:
            prefs.getString(AiSpeakingSettingsKeys.workspaceId)?.trim() ?? '',
      ),
    );
  }

  static AiLlmProvider _readProvider(SharedPreferences prefs) {
    final value = prefs.getString(AiSpeakingSettingsKeys.llmProvider);
    if (value == null) return AiLlmProvider.deepSeek;
    for (final provider in AiLlmProvider.values) {
      if (provider.storageValue == value) return provider;
    }
    return AiLlmProvider.deepSeek;
  }

  AiSpeakingSettings copyWith({AiLlmConfig? llm, AiSpeechConfig? speech}) {
    return AiSpeakingSettings(
      llm: llm ?? this.llm,
      speech: speech ?? this.speech,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is AiSpeakingSettings &&
        other.llm == llm &&
        other.speech == speech;
  }

  @override
  int get hashCode => Object.hash(llm, speech);
}
