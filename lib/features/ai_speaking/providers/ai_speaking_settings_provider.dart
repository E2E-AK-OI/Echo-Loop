/// AI 设置的状态管理与持久化。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/ai_speaking_credential_store.dart';
import '../models/ai_llm_provider.dart';
import '../models/ai_speaking_settings.dart';

/// 应用启动时由 main.dart 用 SharedPreferences 预读的初始值覆盖。
final initialAiSpeakingSettingsProvider = Provider<AiSpeakingSettings>(
  (ref) => AiSpeakingSettings.defaults,
);

class AiSpeakingSettingsNotifier extends Notifier<AiSpeakingSettings> {
  @override
  AiSpeakingSettings build() => ref.read(initialAiSpeakingSettingsProvider);

  Future<void> setProvider(AiLlmProvider provider) async {
    final current = state.llm;
    final oldPreset = AiLlmPreset.of(current.provider);
    final newPreset = AiLlmPreset.of(provider);
    // 只有仍停留在旧预设默认值时才跟随切换，保留用户手动填写的自定义端点与模型。
    final baseUrl = current.baseUrl == oldPreset.baseUrl
        ? newPreset.baseUrl
        : current.baseUrl;
    final model = current.model == oldPreset.defaultModel
        ? newPreset.defaultModel
        : current.model;
    state = state.copyWith(
      llm: current.copyWith(provider: provider, baseUrl: baseUrl, model: model),
    );
    await _persistString(
      AiSpeakingSettingsKeys.llmProvider,
      provider.storageValue,
    );
    await _persistString(AiSpeakingSettingsKeys.llmBaseUrl, baseUrl);
    await _persistString(AiSpeakingSettingsKeys.llmModel, model);
  }

  Future<void> setBaseUrl(String baseUrl) async {
    final normalized = baseUrl.trim();
    state = state.copyWith(llm: state.llm.copyWith(baseUrl: normalized));
    await _persistString(AiSpeakingSettingsKeys.llmBaseUrl, normalized);
  }

  Future<void> setModel(String model) async {
    final normalized = model.trim();
    state = state.copyWith(llm: state.llm.copyWith(model: normalized));
    await _persistString(AiSpeakingSettingsKeys.llmModel, normalized);
  }

  Future<void> setTemperature(double temperature) async {
    final value = temperature.clamp(0.0, 2.0).toDouble();
    state = state.copyWith(llm: state.llm.copyWith(temperature: value));
    await _persistDouble(AiSpeakingSettingsKeys.llmTemperature, value);
  }

  Future<void> setReasoningEffort(AiReasoningEffort effort) async {
    state = state.copyWith(llm: state.llm.copyWith(reasoningEffort: effort));
    await _persistString(
      AiSpeakingSettingsKeys.llmReasoningEffort,
      effort.wireValue,
    );
  }

  Future<void> setTtsModel(String model) async {
    final normalizedModel = AiSpeechConfig.normalizeTtsModel(model.trim());
    final previousVoice = state.speech.ttsVoice;
    final resolvedVoice = AiSpeechConfig.resolveTtsVoice(
      model: normalizedModel,
      voice: previousVoice,
    );
    state = state.copyWith(
      speech: state.speech.copyWith(
        ttsModel: normalizedModel,
        ttsVoice: resolvedVoice,
      ),
    );
    await _persistString(AiSpeakingSettingsKeys.ttsModel, normalizedModel);
    if (resolvedVoice != previousVoice) {
      await _persistString(AiSpeakingSettingsKeys.ttsVoice, resolvedVoice);
    }
  }

  Future<void> setTtsVoice(String voice) async {
    final resolvedVoice = AiSpeechConfig.resolveTtsVoice(
      model: state.speech.ttsModel,
      voice: voice.trim(),
    );
    state = state.copyWith(
      speech: state.speech.copyWith(ttsVoice: resolvedVoice),
    );
    await _persistString(AiSpeakingSettingsKeys.ttsVoice, resolvedVoice);
  }

  Future<void> setTtsRate(double rate) async {
    final value = rate.clamp(0.5, 2.0).toDouble();
    state = state.copyWith(speech: state.speech.copyWith(ttsRate: value));
    await _persistDouble(AiSpeakingSettingsKeys.ttsRate, value);
  }

  Future<void> setAutoPlay(bool autoPlay) async {
    state = state.copyWith(speech: state.speech.copyWith(autoPlay: autoPlay));
    await _persistBool(AiSpeakingSettingsKeys.ttsAutoPlay, autoPlay);
  }

  Future<void> setWorkspaceId(String workspaceId) async {
    final normalized = workspaceId.trim();
    state = state.copyWith(
      speech: state.speech.copyWith(workspaceId: normalized),
    );
    await _persistString(AiSpeakingSettingsKeys.workspaceId, normalized);
  }

  /// 切换特级档位实时模型；音色在新模型下不合法时自动回退默认音色。
  Future<void> setRealtimeModel(String model) async {
    final normalized = AiSpeechConfig.normalizeRealtimeModel(model.trim());
    final previousVoice = state.speech.realtimeVoice;
    final resolvedVoice = AiSpeechConfig.resolveRealtimeVoice(previousVoice);
    state = state.copyWith(
      speech: state.speech.copyWith(
        realtimeModel: normalized,
        realtimeVoice: resolvedVoice,
      ),
    );
    await _persistString(AiSpeakingSettingsKeys.realtimeModel, normalized);
    if (resolvedVoice != previousVoice) {
      await _persistString(AiSpeakingSettingsKeys.realtimeVoice, resolvedVoice);
    }
  }

  Future<void> setRealtimeVoice(String voice) async {
    final resolved = AiSpeechConfig.resolveRealtimeVoice(voice.trim());
    state = state.copyWith(
      speech: state.speech.copyWith(realtimeVoice: resolved),
    );
    await _persistString(AiSpeakingSettingsKeys.realtimeVoice, resolved);
  }

  Future<void> setRealtimeTurnDetection(
    RealtimeTurnDetection turnDetection,
  ) async {
    state = state.copyWith(
      speech: state.speech.copyWith(realtimeTurnDetection: turnDetection),
    );
    await _persistString(
      AiSpeakingSettingsKeys.realtimeTurnDetection,
      turnDetection.wireValue,
    );
  }

  Future<void> _persistString(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, value);
  }

  Future<void> _persistDouble(String key, double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(key, value);
  }

  Future<void> _persistBool(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }
}

final aiSpeakingSettingsProvider =
    NotifierProvider<AiSpeakingSettingsNotifier, AiSpeakingSettings>(
      AiSpeakingSettingsNotifier.new,
    );

final aiSpeakingCredentialStoreProvider = Provider<AiSpeakingCredentialStore>(
  (ref) => AiSpeakingCredentialStore(),
);

/// 设置页密钥状态；切换供应商或保存密钥后由页面主动 invalidate 刷新。
final aiSpeakingSecretStatusProvider = FutureProvider<AiSpeakingSecretStatus>((
  ref,
) async {
  final settings = ref.watch(aiSpeakingSettingsProvider);
  final store = ref.watch(aiSpeakingCredentialStoreProvider);
  return store.readStatus(settings.llm.provider);
});
