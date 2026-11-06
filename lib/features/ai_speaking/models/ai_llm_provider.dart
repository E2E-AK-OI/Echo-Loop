/// AI 口语练习支持的大模型供应商。
///
/// v1 只支持四类：DeepSeek、阿里云百炼、OpenAI，以及任意 OpenAI 兼容的自定义端点。
/// 语音服务固定为阿里云 DashScope，因此这里不包含语音供应商。
library;

enum AiLlmProvider { deepSeek, aliyunBailian, openAi, custom }

extension AiLlmProviderX on AiLlmProvider {
  /// SharedPreferences 与 SecureStorage 中使用的稳定值，避免依赖枚举顺序。
  String get storageValue => name;

  bool get isCustom => this == AiLlmProvider.custom;
}

/// 供应商预设：默认 Base URL、默认模型与可选模型列表。
class AiLlmPreset {
  const AiLlmPreset({
    required this.provider,
    required this.baseUrl,
    required this.defaultModel,
    required this.models,
  });

  final AiLlmProvider provider;
  final String baseUrl;
  final String defaultModel;
  final List<String> models;

  static const deepSeek = AiLlmPreset(
    provider: AiLlmProvider.deepSeek,
    baseUrl: 'https://api.deepseek.com/v1',
    defaultModel: 'deepseek-chat',
    models: ['deepseek-chat', 'deepseek-reasoner'],
  );

  static const aliyunBailian = AiLlmPreset(
    provider: AiLlmProvider.aliyunBailian,
    baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    defaultModel: 'qwen-plus',
    models: ['qwen-plus', 'qwen-max', 'qwen-turbo', 'qwen3-max'],
  );

  static const openAi = AiLlmPreset(
    provider: AiLlmProvider.openAi,
    baseUrl: 'https://api.openai.com/v1',
    defaultModel: 'gpt-4o-mini',
    models: ['gpt-4o-mini', 'gpt-4.1-mini', 'gpt-4o'],
  );

  static const custom = AiLlmPreset(
    provider: AiLlmProvider.custom,
    baseUrl: '',
    defaultModel: '',
    models: [],
  );

  static const values = [deepSeek, aliyunBailian, openAi, custom];

  static AiLlmPreset of(AiLlmProvider provider) {
    return switch (provider) {
      AiLlmProvider.deepSeek => deepSeek,
      AiLlmProvider.aliyunBailian => aliyunBailian,
      AiLlmProvider.openAi => openAi,
      AiLlmProvider.custom => custom,
    };
  }
}
