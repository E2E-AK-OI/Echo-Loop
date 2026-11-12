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
  static const llmReasoningEffort = 'ai_speaking_llm_reasoning_effort';
  static const ttsModel = 'ai_speaking_tts_model';
  static const ttsVoice = 'ai_speaking_tts_voice';
  static const ttsRate = 'ai_speaking_tts_rate';
  static const ttsAutoPlay = 'ai_speaking_tts_auto_play';
  static const workspaceId = 'ai_speaking_workspace_id';
}

/// 推理强度档位，按 OpenAI 兼容接口的 `reasoning_effort` 取值排序。
///
/// `none` 表示不发送该参数，保持与旧版本一致；其余档位是否被供应商支持
/// 由服务端决定，设置页的测试按钮用于实际验证。
enum AiReasoningEffort {
  none('none'),
  minimal('minimal'),
  low('low'),
  medium('medium'),
  high('high'),
  xhigh('xhigh'),
  max('max');

  const AiReasoningEffort(this.wireValue);

  /// 请求体中 `reasoning_effort` 的取值。
  final String wireValue;

  /// 需要随请求发送的参数值；`none` 不发送。
  String? get requestValue => this == AiReasoningEffort.none ? null : wireValue;

  /// 读取持久化值，未知或缺失时回退到 `none`。
  static AiReasoningEffort fromStorage(String? value) {
    for (final effort in values) {
      if (effort.wireValue == value) return effort;
    }
    return none;
  }
}

/// 大模型连接配置。
class AiLlmConfig {
  const AiLlmConfig({
    required this.provider,
    required this.baseUrl,
    required this.model,
    required this.temperature,
    this.reasoningEffort = AiReasoningEffort.none,
  });

  final AiLlmProvider provider;
  final String baseUrl;
  final String model;
  final double temperature;

  /// 推理强度；默认不向服务端发送该参数。
  final AiReasoningEffort reasoningEffort;

  factory AiLlmConfig.defaultsFor(AiLlmProvider provider) {
    final preset = AiLlmPreset.of(provider);
    return AiLlmConfig(
      provider: provider,
      baseUrl: preset.baseUrl,
      model: preset.defaultModel,
      temperature: 0.7,
      reasoningEffort: AiReasoningEffort.none,
    );
  }

  AiLlmConfig copyWith({
    AiLlmProvider? provider,
    String? baseUrl,
    String? model,
    double? temperature,
    AiReasoningEffort? reasoningEffort,
  }) {
    return AiLlmConfig(
      provider: provider ?? this.provider,
      baseUrl: baseUrl ?? this.baseUrl,
      model: model ?? this.model,
      temperature: temperature ?? this.temperature,
      reasoningEffort: reasoningEffort ?? this.reasoningEffort,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is AiLlmConfig &&
        other.provider == provider &&
        other.baseUrl == baseUrl &&
        other.model == model &&
        other.temperature == temperature &&
        other.reasoningEffort == reasoningEffort;
  }

  @override
  int get hashCode =>
      Object.hash(provider, baseUrl, model, temperature, reasoningEffort);
}

/// TTS 音色选项：label 用于界面展示，value 是 DashScope 的 voice 参数。
class AiTtsVoice {
  const AiTtsVoice({required this.label, required this.value, this.accent});

  final String label;
  final String value;

  /// 官方口音描述，例如「英式女声」「美式男声」；plus 音色暂无此字段。
  final String? accent;

  /// 下拉框展示文案：有口音时追加官方描述，并保留 voice 参数便于核对。
  String get displayLabel {
    final accentText = accent == null ? '' : ' · $accent';
    return '$label$accentText ($value)';
  }
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
  static const flashTtsModel = 'qwen-audio-3.1-tts-flash';
  static const defaultTtsVoice = 'longanlingxin_v3.1';
  static const defaultFlashTtsVoice = 'Emily_v3.1';

  /// 音色必须与模型匹配，跨模型使用会被 DashScope 拒绝。
  /// 来源：https://help.aliyun.com/zh/model-studio/qwen-audio-tts-voice-list
  static const _plusVoices = <AiTtsVoice>[
    AiTtsVoice(label: '龙安灵心', value: defaultTtsVoice),
    AiTtsVoice(label: '许南川', value: 'xunanchuan_v3.1'),
    AiTtsVoice(label: '龙安欢', value: 'longanhuan_v3.1'),
    AiTtsVoice(label: '龙安风悦', value: 'longanfengyue_v3.1'),
  ];

  /// flash 的“精品英文音色”共 15 个，是英语口语练习的主要候选。
  static const _flashEnglishVoices = <AiTtsVoice>[
    AiTtsVoice(label: 'Emily', value: defaultFlashTtsVoice, accent: '英式女声'),
    AiTtsVoice(label: 'Luna', value: 'Luna_v3.1', accent: '英式女声'),
    AiTtsVoice(label: 'Eric', value: 'Eric_v3.1', accent: '英式男声'),
    AiTtsVoice(label: 'Luca', value: 'Luca_v3.1', accent: '英式男声'),
    AiTtsVoice(label: 'Abby', value: 'Abby_v3.1', accent: '美式女声'),
    AiTtsVoice(label: 'Annie', value: 'Annie_v3.1', accent: '美式女声'),
    AiTtsVoice(label: 'Ava', value: 'Ava_v3.1', accent: '美式女声'),
    AiTtsVoice(label: 'Beth', value: 'Beth_v3.1', accent: '美式女声'),
    AiTtsVoice(label: 'Betty', value: 'Betty_v3.1', accent: '美式女声'),
    AiTtsVoice(label: 'Cally', value: 'Cally_v3.1', accent: '美式女声'),
    AiTtsVoice(label: 'Cindy', value: 'Cindy_v3.1', accent: '美式女声'),
    AiTtsVoice(label: 'Donna', value: 'Donna_v3.1', accent: '美式女声'),
    AiTtsVoice(label: 'Andy', value: 'Andy_v3.1', accent: '美式男声'),
    AiTtsVoice(label: 'Brian', value: 'Brian_v3.1', accent: '美式男声'),
    AiTtsVoice(label: 'David', value: 'David_v3.1', accent: '美式男声'),
  ];

  /// 当前支持的 TTS 模型，未知模型统一回退到 plus。
  static String normalizeTtsModel(String model) {
    return model == flashTtsModel ? flashTtsModel : defaultTtsModel;
  }

  /// 返回模型可用的音色；未知模型按 plus 处理，保证下拉始终有选项。
  static List<AiTtsVoice> voicesForModel(String model) {
    return normalizeTtsModel(model) == flashTtsModel
        ? _flashEnglishVoices
        : _plusVoices;
  }

  /// 将历史设置中跨模型或旧版本遗留的非法音色修正为当前模型的默认音色。
  static String resolveTtsVoice({
    required String model,
    required String voice,
  }) {
    final voices = voicesForModel(model);
    for (final option in voices) {
      if (option.value == voice) return voice;
    }
    return voices.first.value;
  }

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
    final reasoningEffort = AiReasoningEffort.fromStorage(
      prefs.getString(AiSpeakingSettingsKeys.llmReasoningEffort),
    );
    final rawTtsRate = prefs.getDouble(AiSpeakingSettingsKeys.ttsRate) ?? 1.0;
    final storedTtsModel =
        prefs.getString(AiSpeakingSettingsKeys.ttsModel)?.trim() ?? '';
    final storedTtsVoice =
        prefs.getString(AiSpeakingSettingsKeys.ttsVoice)?.trim() ?? '';
    final ttsModel = AiSpeechConfig.normalizeTtsModel(
      storedTtsModel.isEmpty ? AiSpeechConfig.defaultTtsModel : storedTtsModel,
    );
    final ttsVoice = AiSpeechConfig.resolveTtsVoice(
      model: ttsModel,
      voice: storedTtsVoice.isEmpty
          ? AiSpeechConfig.defaultTtsVoice
          : storedTtsVoice,
    );

    return AiSpeakingSettings(
      llm: AiLlmConfig(
        provider: provider,
        baseUrl: storedBaseUrl.isEmpty ? preset.baseUrl : storedBaseUrl,
        model: storedModel.isEmpty ? preset.defaultModel : storedModel,
        temperature: rawTemperature.clamp(0.0, 2.0).toDouble(),
        reasoningEffort: reasoningEffort,
      ),
      speech: AiSpeechConfig(
        asrModel: AiSpeechConfig.defaultAsrModel,
        ttsModel: ttsModel,
        ttsVoice: ttsVoice,
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
