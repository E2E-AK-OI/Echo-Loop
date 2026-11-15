/// 档位语音引擎配置的模型与 Provider 单元测试。
///
/// 覆盖：默认值、旧全局键回退、档位后缀优先、非法值修正与持久化隔离。
library;

import 'package:echo_loop/features/ai_speaking/models/ai_speaking_level.dart';
import 'package:echo_loop/features/ai_speaking/models/ai_speaking_settings.dart';
import 'package:echo_loop/features/ai_speaking/models/speaking_dialog_settings.dart';
import 'package:echo_loop/features/ai_speaking/models/speaking_engine_settings.dart';
import 'package:echo_loop/features/ai_speaking/models/speaking_level_config.dart';
import 'package:echo_loop/features/ai_speaking/providers/speaking_level_configs_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [
        initialSpeakingLevelConfigsProvider.overrideWithValue({
          for (final level in AiSpeakingLevel.values)
            level: SpeakingLevelConfig.defaultsFor(level),
        }),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('SpeakingLevelConfig', () {
    test('四档默认配置一致且不绑定工作空间', () {
      for (final level in AiSpeakingLevel.values) {
        final config = SpeakingLevelConfig.defaultsFor(level);
        expect(config.engine.asrSource, SpeakingAsrSource.ai);
        expect(config.engine.ttsSource, SpeakingTtsSource.ai);
        expect(config.speech.asrModel, AiSpeechConfig.defaultAsrModel);
        expect(config.speech.ttsModel, AiSpeechConfig.defaultTtsModel);
        expect(
          SpeakingLevelConfig.recommendedTtsModelFor(level),
          AiSpeechConfig.flashTtsModel,
        );
        expect(config.speech.ttsVoice, AiSpeechConfig.defaultFlashTtsVoice);
        expect(config.speech.autoPlay, isTrue);
        expect(config.speech.workspaceId, isEmpty);
        expect(config.dialog, SpeakingDialogSettings.defaults);
      }
    });

    test('空 SharedPreferences 回退到默认值', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      final config = SpeakingLevelConfig.fromPrefsSync(
        prefs,
        AiSpeakingLevel.intermediate,
      );

      expect(
        config,
        SpeakingLevelConfig.defaultsFor(AiSpeakingLevel.intermediate),
      );
    });

    test('未写过档位键时继承旧版全局配置', () async {
      SharedPreferences.setMockInitialValues({
        SpeakingEngineSettingsKeys.asrSource: 'local',
        AiSpeakingSettingsKeys.ttsModel: AiSpeechConfig.flashTtsModel,
        AiSpeakingSettingsKeys.ttsRate: 1.4,
        SpeakingDialogSettingsKeys.endOfSpeechMs: 1200,
      });
      final prefs = await SharedPreferences.getInstance();

      final config = SpeakingLevelConfig.fromPrefsSync(
        prefs,
        AiSpeakingLevel.advanced,
      );

      expect(config.engine.asrSource, SpeakingAsrSource.local);
      expect(config.speech.ttsModel, AiSpeechConfig.flashTtsModel);
      // 旧音色不属于 flash 时自动修正为 flash 默认音色。
      expect(config.speech.ttsVoice, AiSpeechConfig.defaultFlashTtsVoice);
      expect(config.speech.ttsRate, 1.4);
      expect(config.dialog.endOfSpeechMs, 1200);
    });

    test('档位后缀优先于全局键，且档位之间互不影响', () async {
      SharedPreferences.setMockInitialValues({
        SpeakingEngineSettingsKeys.asrSource: 'ai',
        SpeakingLevelConfigKeys.asrSource(AiSpeakingLevel.beginner): 'local',
      });
      final prefs = await SharedPreferences.getInstance();

      final beginner = SpeakingLevelConfig.fromPrefsSync(
        prefs,
        AiSpeakingLevel.beginner,
      );
      final intermediate = SpeakingLevelConfig.fromPrefsSync(
        prefs,
        AiSpeakingLevel.intermediate,
      );

      expect(beginner.engine.asrSource, SpeakingAsrSource.local);
      expect(intermediate.engine.asrSource, SpeakingAsrSource.ai);
    });

    test('识别模型按档位保存，非法模型回退默认', () async {
      SharedPreferences.setMockInitialValues({
        SpeakingLevelConfigKeys.asrModel(AiSpeakingLevel.intermediate):
            'qwen-audio-3.0-asr-flash-streaming',
        SpeakingLevelConfigKeys.asrModel(AiSpeakingLevel.advanced): 'unknown',
      });
      final prefs = await SharedPreferences.getInstance();

      final intermediate = SpeakingLevelConfig.fromPrefsSync(
        prefs,
        AiSpeakingLevel.intermediate,
      );
      final advanced = SpeakingLevelConfig.fromPrefsSync(
        prefs,
        AiSpeakingLevel.advanced,
      );

      expect(
        intermediate.speech.asrModel,
        'qwen-audio-3.0-asr-flash-streaming',
      );
      expect(advanced.speech.asrModel, AiSpeechConfig.defaultAsrModel);
    });

    test('非法数值按合法范围钳制', () async {
      SharedPreferences.setMockInitialValues({
        SpeakingLevelConfigKeys.ttsRate(AiSpeakingLevel.expert): 9.0,
        SpeakingLevelConfigKeys.endOfSpeechMs(AiSpeakingLevel.expert): 50,
        SpeakingLevelConfigKeys.idleExitSeconds(AiSpeakingLevel.expert): 600,
        SpeakingLevelConfigKeys.realtimeTurnDetection(AiSpeakingLevel.expert):
            'unknown',
      });
      final prefs = await SharedPreferences.getInstance();

      final config = SpeakingLevelConfig.fromPrefsSync(
        prefs,
        AiSpeakingLevel.expert,
      );

      expect(config.speech.ttsRate, 2.0);
      expect(
        config.dialog.endOfSpeechMs,
        SpeakingDialogSettings.minEndOfSpeechMs,
      );
      expect(
        config.dialog.idleExitSeconds,
        SpeakingDialogSettings.maxIdleExitSeconds,
      );
      expect(
        config.speech.realtimeTurnDetection,
        RealtimeTurnDetection.smartTurnV2,
      );
    });
  });

  group('SpeakingLevelConfigsNotifier', () {
    test('修改档位来源只写入该档位后缀键', () async {
      SharedPreferences.setMockInitialValues({});
      final container = makeContainer();
      final notifier = container.read(speakingLevelConfigsProvider.notifier);

      await notifier.setAsrSource(
        AiSpeakingLevel.advanced,
        SpeakingAsrSource.local,
      );

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(
          SpeakingLevelConfigKeys.asrSource(AiSpeakingLevel.advanced),
        ),
        'local',
      );
      expect(
        prefs.getString(
          SpeakingLevelConfigKeys.asrSource(AiSpeakingLevel.beginner),
        ),
        isNull,
      );
      expect(
        notifier.configFor(AiSpeakingLevel.advanced).engine.asrSource,
        SpeakingAsrSource.local,
      );
      expect(
        notifier.configFor(AiSpeakingLevel.beginner).engine.asrSource,
        SpeakingAsrSource.ai,
      );
    });

    test('切换识别模型只写入该档位后缀键', () async {
      SharedPreferences.setMockInitialValues({});
      final container = makeContainer();
      final notifier = container.read(speakingLevelConfigsProvider.notifier);

      await notifier.setAsrModel(
        AiSpeakingLevel.advanced,
        'qwen-audio-3.0-asr-flash-streaming',
      );

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(
          SpeakingLevelConfigKeys.asrModel(AiSpeakingLevel.advanced),
        ),
        'qwen-audio-3.0-asr-flash-streaming',
      );
      expect(
        prefs.getString(
          SpeakingLevelConfigKeys.asrModel(AiSpeakingLevel.beginner),
        ),
        isNull,
      );
      expect(
        notifier.configFor(AiSpeakingLevel.advanced).speech.asrModel,
        'qwen-audio-3.0-asr-flash-streaming',
      );
      expect(
        notifier.configFor(AiSpeakingLevel.beginner).speech.asrModel,
        AiSpeechConfig.defaultAsrModel,
      );
    });

    test('切换 TTS 模型时自动修正音色并落盘', () async {
      SharedPreferences.setMockInitialValues({});
      final container = makeContainer();
      final notifier = container.read(speakingLevelConfigsProvider.notifier);

      await notifier.setTtsModel(
        AiSpeakingLevel.beginner,
        AiSpeechConfig.plusTtsModel,
      );
      await notifier.setTtsModel(
        AiSpeakingLevel.beginner,
        AiSpeechConfig.flashTtsModel,
      );

      final config = notifier.configFor(AiSpeakingLevel.beginner);
      expect(config.speech.ttsModel, AiSpeechConfig.flashTtsModel);
      expect(config.speech.ttsVoice, AiSpeechConfig.defaultFlashTtsVoice);

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(
          SpeakingLevelConfigKeys.ttsModel(AiSpeakingLevel.beginner),
        ),
        AiSpeechConfig.flashTtsModel,
      );
      expect(
        prefs.getString(
          SpeakingLevelConfigKeys.ttsVoice(AiSpeakingLevel.beginner),
        ),
        AiSpeechConfig.defaultFlashTtsVoice,
      );
    });

    test('对话参数越界写入按钳制后的值持久化', () async {
      SharedPreferences.setMockInitialValues({});
      final container = makeContainer();
      final notifier = container.read(speakingLevelConfigsProvider.notifier);

      await notifier.setEndOfSpeechMs(AiSpeakingLevel.intermediate, 100);
      await notifier.setIdleExitSeconds(AiSpeakingLevel.intermediate, 5);
      await notifier.setBargeInSensitivity(
        AiSpeakingLevel.advanced,
        BargeInSensitivity.high,
      );

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getInt(
          SpeakingLevelConfigKeys.endOfSpeechMs(AiSpeakingLevel.intermediate),
        ),
        SpeakingDialogSettings.minEndOfSpeechMs,
      );
      expect(
        prefs.getInt(
          SpeakingLevelConfigKeys.idleExitSeconds(AiSpeakingLevel.intermediate),
        ),
        SpeakingDialogSettings.minIdleExitSeconds,
      );
      expect(
        prefs.getString(
          SpeakingLevelConfigKeys.bargeInSensitivity(AiSpeakingLevel.advanced),
        ),
        'high',
      );
    });

    test('实时语音判停按 wireValue 持久化', () async {
      SharedPreferences.setMockInitialValues({});
      final container = makeContainer();
      final notifier = container.read(speakingLevelConfigsProvider.notifier);

      await notifier.setRealtimeTurnDetection(
        AiSpeakingLevel.expert,
        RealtimeTurnDetection.serverVad,
      );

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(
          SpeakingLevelConfigKeys.realtimeTurnDetection(AiSpeakingLevel.expert),
        ),
        'server_vad',
      );
      expect(
        notifier.configFor(AiSpeakingLevel.expert).speech.realtimeTurnDetection,
        RealtimeTurnDetection.serverVad,
      );
    });
  });
}
