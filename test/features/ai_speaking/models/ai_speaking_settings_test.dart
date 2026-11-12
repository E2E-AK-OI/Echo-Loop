/// AI 设置模型与 Provider 单元测试。
///
/// 覆盖：默认值、SharedPreferences 同步预读、边界值夹紧、供应商切换与持久化。
library;

import 'package:echo_loop/features/ai_speaking/models/ai_llm_provider.dart';
import 'package:echo_loop/features/ai_speaking/models/ai_speaking_settings.dart';
import 'package:echo_loop/features/ai_speaking/providers/ai_speaking_settings_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer makeContainer(AiSpeakingSettings settings) {
    final container = ProviderContainer(
      overrides: [
        initialAiSpeakingSettingsProvider.overrideWithValue(settings),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('AiSpeakingSettings.fromPrefsSync', () {
    test('空 SharedPreferences 返回默认 DeepSeek + 阿里云 TTS', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      final settings = AiSpeakingSettings.fromPrefsSync(prefs);

      expect(settings.llm.provider, AiLlmProvider.deepSeek);
      expect(settings.llm.baseUrl, 'https://api.deepseek.com/v1');
      expect(settings.llm.model, 'deepseek-chat');
      expect(settings.llm.temperature, 0.7);
      expect(settings.speech.asrModel, AiSpeechConfig.defaultAsrModel);
      expect(settings.speech.ttsModel, AiSpeechConfig.defaultTtsModel);
      expect(settings.speech.ttsVoice, AiSpeechConfig.defaultTtsVoice);
      expect(settings.speech.ttsRate, 1.0);
      expect(settings.speech.autoPlay, isTrue);
      expect(settings.speech.workspaceId, isEmpty);
    });

    test('读取已保存值并修正不匹配的 flash 音色', () async {
      SharedPreferences.setMockInitialValues({
        AiSpeakingSettingsKeys.llmProvider: 'openAi',
        AiSpeakingSettingsKeys.llmBaseUrl: 'https://proxy.example/v1',
        AiSpeakingSettingsKeys.llmModel: 'gpt-4.1-mini',
        AiSpeakingSettingsKeys.llmTemperature: 1.35,
        AiSpeakingSettingsKeys.ttsModel: 'qwen-audio-3.1-tts-flash',
        AiSpeakingSettingsKeys.ttsVoice: 'Bella',
        AiSpeakingSettingsKeys.ttsRate: 1.6,
        AiSpeakingSettingsKeys.ttsAutoPlay: false,
        AiSpeakingSettingsKeys.workspaceId: 'ws-test',
      });
      final prefs = await SharedPreferences.getInstance();

      final settings = AiSpeakingSettings.fromPrefsSync(prefs);

      expect(settings.llm.provider, AiLlmProvider.openAi);
      expect(settings.llm.baseUrl, 'https://proxy.example/v1');
      expect(settings.llm.model, 'gpt-4.1-mini');
      expect(settings.llm.temperature, 1.35);
      expect(settings.speech.ttsModel, AiSpeechConfig.flashTtsModel);
      expect(settings.speech.ttsVoice, AiSpeechConfig.defaultFlashTtsVoice);
      expect(settings.speech.ttsRate, 1.6);
      expect(settings.speech.autoPlay, isFalse);
      expect(settings.speech.workspaceId, 'ws-test');
    });

    test('非法供应商回退 DeepSeek，温度与语速夹紧', () async {
      SharedPreferences.setMockInitialValues({
        AiSpeakingSettingsKeys.llmProvider: 'not-a-provider',
        AiSpeakingSettingsKeys.llmTemperature: 9.0,
        AiSpeakingSettingsKeys.ttsRate: 0.1,
      });
      final prefs = await SharedPreferences.getInstance();

      final settings = AiSpeakingSettings.fromPrefsSync(prefs);

      expect(settings.llm.provider, AiLlmProvider.deepSeek);
      expect(settings.llm.temperature, 2.0);
      expect(settings.speech.ttsRate, 0.5);
    });

    test('空字符串的端点与模型回退到预设默认值', () async {
      SharedPreferences.setMockInitialValues({
        AiSpeakingSettingsKeys.llmProvider: 'aliyunBailian',
        AiSpeakingSettingsKeys.llmBaseUrl: '   ',
        AiSpeakingSettingsKeys.llmModel: '',
      });
      final prefs = await SharedPreferences.getInstance();

      final settings = AiSpeakingSettings.fromPrefsSync(prefs);

      expect(
        settings.llm.baseUrl,
        'https://dashscope.aliyuncs.com/compatible-mode/v1',
      );
      expect(settings.llm.model, 'qwen-plus');
    });
  });

  group('AiSpeechConfig 音色目录', () {
    test('plus 提供官方四个旗舰音色', () {
      final voices = AiSpeechConfig.voicesForModel(
        AiSpeechConfig.defaultTtsModel,
      );

      expect(voices.map((voice) => voice.value), <String>[
        'longanlingxin_v3.1',
        'xunanchuan_v3.1',
        'longanhuan_v3.1',
        'longanfengyue_v3.1',
      ]);
    });

    test('flash 提供官方十五个精品英文音色且不含 Bella', () {
      final voices = AiSpeechConfig.voicesForModel(
        AiSpeechConfig.flashTtsModel,
      );
      final values = voices.map((voice) => voice.value);

      expect(voices, hasLength(15));
      expect(values.first, AiSpeechConfig.defaultFlashTtsVoice);
      expect(
        values,
        containsAll(<String>[
          'Emily_v3.1',
          'Luna_v3.1',
          'Eric_v3.1',
          'Luca_v3.1',
          'Abby_v3.1',
          'Annie_v3.1',
          'Ava_v3.1',
          'Beth_v3.1',
          'Betty_v3.1',
          'Cally_v3.1',
          'Cindy_v3.1',
          'Donna_v3.1',
          'Andy_v3.1',
          'Brian_v3.1',
          'David_v3.1',
        ]),
      );
      expect(values, isNot(contains('Bella')));
    });

    test('跨模型音色回退到目标模型默认音色', () {
      expect(
        AiSpeechConfig.resolveTtsVoice(
          model: AiSpeechConfig.flashTtsModel,
          voice: AiSpeechConfig.defaultTtsVoice,
        ),
        AiSpeechConfig.defaultFlashTtsVoice,
      );
      expect(
        AiSpeechConfig.resolveTtsVoice(
          model: AiSpeechConfig.defaultTtsModel,
          voice: AiSpeechConfig.defaultFlashTtsVoice,
        ),
        AiSpeechConfig.defaultTtsVoice,
      );
      expect(
        AiSpeechConfig.resolveTtsVoice(
          model: AiSpeechConfig.flashTtsModel,
          voice: 'Bella',
        ),
        AiSpeechConfig.defaultFlashTtsVoice,
      );
    });
  });

  group('AiSpeakingSettingsNotifier', () {
    test('默认供应商切换时同步切换预设端点与模型', () async {
      SharedPreferences.setMockInitialValues({});
      final container = makeContainer(AiSpeakingSettings.defaults);

      await container
          .read(aiSpeakingSettingsProvider.notifier)
          .setProvider(AiLlmProvider.aliyunBailian);

      final llm = container.read(aiSpeakingSettingsProvider).llm;
      expect(llm.provider, AiLlmProvider.aliyunBailian);
      expect(llm.baseUrl, 'https://dashscope.aliyuncs.com/compatible-mode/v1');
      expect(llm.model, 'qwen-plus');
    });

    test('自定义端点与模型在切换供应商时保留', () async {
      SharedPreferences.setMockInitialValues({});
      final container = makeContainer(
        AiSpeakingSettings.defaults.copyWith(
          llm: AiSpeakingSettings.defaults.llm.copyWith(
            baseUrl: 'https://my-proxy.example/v1',
            model: 'my-model',
          ),
        ),
      );

      await container
          .read(aiSpeakingSettingsProvider.notifier)
          .setProvider(AiLlmProvider.openAi);

      final llm = container.read(aiSpeakingSettingsProvider).llm;
      expect(llm.provider, AiLlmProvider.openAi);
      expect(llm.baseUrl, 'https://my-proxy.example/v1');
      expect(llm.model, 'my-model');
    });

    test('设置项写入内存并持久化到 SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({});
      final container = makeContainer(AiSpeakingSettings.defaults);
      final notifier = container.read(aiSpeakingSettingsProvider.notifier);

      await notifier.setTemperature(1.2);
      await notifier.setTtsModel(AiSpeechConfig.flashTtsModel);
      await notifier.setTtsVoice(AiSpeechConfig.defaultFlashTtsVoice);
      await notifier.setTtsRate(1.4);
      await notifier.setAutoPlay(false);
      await notifier.setWorkspaceId(' ws-1 ');

      final state = container.read(aiSpeakingSettingsProvider);
      expect(state.llm.temperature, 1.2);
      expect(state.speech.ttsModel, AiSpeechConfig.flashTtsModel);
      expect(state.speech.ttsVoice, AiSpeechConfig.defaultFlashTtsVoice);
      expect(state.speech.ttsRate, 1.4);
      expect(state.speech.autoPlay, isFalse);
      expect(state.speech.workspaceId, 'ws-1');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble(AiSpeakingSettingsKeys.llmTemperature), 1.2);
      expect(
        prefs.getString(AiSpeakingSettingsKeys.ttsModel),
        AiSpeechConfig.flashTtsModel,
      );
      expect(
        prefs.getString(AiSpeakingSettingsKeys.ttsVoice),
        AiSpeechConfig.defaultFlashTtsVoice,
      );
      expect(prefs.getDouble(AiSpeakingSettingsKeys.ttsRate), 1.4);
      expect(prefs.getBool(AiSpeakingSettingsKeys.ttsAutoPlay), isFalse);
      expect(prefs.getString(AiSpeakingSettingsKeys.workspaceId), 'ws-1');
    });

    test('切换到 flash 时自动替换不匹配音色并持久化', () async {
      SharedPreferences.setMockInitialValues({});
      final container = makeContainer(AiSpeakingSettings.defaults);
      final notifier = container.read(aiSpeakingSettingsProvider.notifier);

      await notifier.setTtsModel(AiSpeechConfig.flashTtsModel);

      expect(
        container.read(aiSpeakingSettingsProvider).speech.ttsVoice,
        AiSpeechConfig.defaultFlashTtsVoice,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(AiSpeakingSettingsKeys.ttsVoice),
        AiSpeechConfig.defaultFlashTtsVoice,
      );

      await notifier.setTtsVoice('Bella');

      expect(
        container.read(aiSpeakingSettingsProvider).speech.ttsVoice,
        AiSpeechConfig.defaultFlashTtsVoice,
      );
    });

    test('温度与语速越过边界时夹紧后持久化', () async {
      SharedPreferences.setMockInitialValues({});
      final container = makeContainer(AiSpeakingSettings.defaults);
      final notifier = container.read(aiSpeakingSettingsProvider.notifier);

      await notifier.setTemperature(3.0);
      await notifier.setTtsRate(0.2);

      expect(container.read(aiSpeakingSettingsProvider).llm.temperature, 2.0);
      expect(container.read(aiSpeakingSettingsProvider).speech.ttsRate, 0.5);
    });
  });
}
