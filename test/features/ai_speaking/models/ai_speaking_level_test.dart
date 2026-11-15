/// 口语档位模型与 Provider 单元测试。
///
/// 覆盖：默认值、未知值回退、四档能力位组合与 Provider 持久化。
library;

import 'package:echo_loop/features/ai_speaking/models/ai_speaking_level.dart';
import 'package:echo_loop/features/ai_speaking/providers/ai_speaking_level_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer makeContainer(AiSpeakingLevel level) {
    final container = ProviderContainer(
      overrides: [initialAiSpeakingLevelProvider.overrideWithValue(level)],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('AiSpeakingLevel', () {
    test('空 SharedPreferences 回退到初级', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      expect(AiSpeakingLevel.fromPrefsSync(prefs), AiSpeakingLevel.beginner);
    });

    test('未知值回退到初级，避免升级后改变既有练习方式', () async {
      SharedPreferences.setMockInitialValues({
        AiSpeakingLevelKeys.level: 'unknown',
      });
      final prefs = await SharedPreferences.getInstance();

      expect(AiSpeakingLevel.fromPrefsSync(prefs), AiSpeakingLevel.beginner);
    });

    test('读取已保存的档位', () async {
      SharedPreferences.setMockInitialValues({
        AiSpeakingLevelKeys.level: 'advanced',
      });
      final prefs = await SharedPreferences.getInstance();

      expect(AiSpeakingLevel.fromPrefsSync(prefs), AiSpeakingLevel.advanced);
    });

    test('初级：按键说话、无 VAD、不可插话、可本地引擎', () {
      const level = AiSpeakingLevel.beginner;

      expect(level.usesPushToTalk, isTrue);
      expect(level.usesVoiceActivityDetection, isFalse);
      expect(level.allowsBargeIn, isFalse);
      expect(level.requiresRealtimeAsr, isFalse);
      expect(level.requiresCloudTts, isFalse);
      expect(level.usesSpeechToSpeech, isFalse);
      expect(level.allowsLocalEngines, isTrue);
      expect(level.usesContinuousSession, isFalse);
    });

    test('中级：VAD 自动轮转、不可插话、可本地引擎', () {
      const level = AiSpeakingLevel.intermediate;

      expect(level.usesPushToTalk, isFalse);
      expect(level.usesVoiceActivityDetection, isTrue);
      expect(level.allowsBargeIn, isFalse);
      expect(level.requiresRealtimeAsr, isFalse);
      expect(level.requiresCloudTts, isFalse);
      expect(level.allowsLocalEngines, isTrue);
      expect(level.usesContinuousSession, isTrue);
    });

    test('高级：VAD + 插话打断，强制云端实时语音引擎', () {
      const level = AiSpeakingLevel.advanced;

      expect(level.usesVoiceActivityDetection, isTrue);
      expect(level.allowsBargeIn, isTrue);
      expect(level.requiresRealtimeAsr, isTrue);
      expect(level.requiresCloudTts, isTrue);
      expect(level.usesSpeechToSpeech, isFalse);
      expect(level.allowsLocalEngines, isFalse);
    });

    test('特级：端到端语音模型，服务端判停，无本地 VAD', () {
      const level = AiSpeakingLevel.expert;

      expect(level.usesSpeechToSpeech, isTrue);
      expect(level.usesVoiceActivityDetection, isFalse);
      expect(level.allowsBargeIn, isTrue);
      expect(level.allowsLocalEngines, isFalse);
      expect(level.usesContinuousSession, isTrue);
    });
  });

  group('AiSpeakingLevelNotifier', () {
    test('切换档位写入 SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({});
      final container = makeContainer(AiSpeakingLevel.beginner);

      await container
          .read(aiSpeakingLevelProvider.notifier)
          .setLevel(AiSpeakingLevel.intermediate);

      expect(
        container.read(aiSpeakingLevelProvider),
        AiSpeakingLevel.intermediate,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(AiSpeakingLevelKeys.level), 'intermediate');
    });

    test('切换到相同档位不重复写盘', () async {
      SharedPreferences.setMockInitialValues({});
      final container = makeContainer(AiSpeakingLevel.advanced);

      await container
          .read(aiSpeakingLevelProvider.notifier)
          .setLevel(AiSpeakingLevel.advanced);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(AiSpeakingLevelKeys.level), isNull);
    });
  });
}
