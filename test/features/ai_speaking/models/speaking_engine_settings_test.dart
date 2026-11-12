/// 口语引擎来源设置单元测试。
///
/// 覆盖：默认值、SharedPreferences 预读、未知值回退与 Provider 持久化。
library;

import 'package:echo_loop/features/ai_speaking/models/speaking_engine_settings.dart';
import 'package:echo_loop/features/ai_speaking/providers/speaking_engine_settings_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer makeContainer(SpeakingEngineSettings settings) {
    final container = ProviderContainer(
      overrides: [
        initialSpeakingEngineSettingsProvider.overrideWithValue(settings),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('SpeakingEngineSettings', () {
    test('默认全部使用 AI 服务', () {
      expect(SpeakingEngineSettings.defaults.asrSource, SpeakingAsrSource.ai);
      expect(SpeakingEngineSettings.defaults.ttsSource, SpeakingTtsSource.ai);
      expect(SpeakingEngineSettings.defaults.usesLocalAsr, isFalse);
      expect(SpeakingEngineSettings.defaults.usesLocalTts, isFalse);
    });

    test('空 SharedPreferences 回退到默认值', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      final settings = SpeakingEngineSettings.fromPrefsSync(prefs);

      expect(settings, SpeakingEngineSettings.defaults);
    });

    test('读取已保存的本地引擎来源', () async {
      SharedPreferences.setMockInitialValues({
        SpeakingEngineSettingsKeys.asrSource: 'local',
        SpeakingEngineSettingsKeys.ttsSource: 'local',
      });
      final prefs = await SharedPreferences.getInstance();

      final settings = SpeakingEngineSettings.fromPrefsSync(prefs);

      expect(settings.asrSource, SpeakingAsrSource.local);
      expect(settings.ttsSource, SpeakingTtsSource.local);
      expect(settings.usesLocalAsr, isTrue);
      expect(settings.usesLocalTts, isTrue);
    });

    test('未知值回退到 AI 服务', () async {
      SharedPreferences.setMockInitialValues({
        SpeakingEngineSettingsKeys.asrSource: 'unknown',
        SpeakingEngineSettingsKeys.ttsSource: 'offline',
      });
      final prefs = await SharedPreferences.getInstance();

      final settings = SpeakingEngineSettings.fromPrefsSync(prefs);

      expect(settings.asrSource, SpeakingAsrSource.ai);
      expect(settings.ttsSource, SpeakingTtsSource.ai);
    });
  });

  group('SpeakingEngineSettingsNotifier', () {
    test('切换来源后持久化到 SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({});
      final container = makeContainer(SpeakingEngineSettings.defaults);
      final notifier = container.read(speakingEngineSettingsProvider.notifier);

      await notifier.setAsrSource(SpeakingAsrSource.local);
      await notifier.setTtsSource(SpeakingTtsSource.local);

      expect(
        container.read(speakingEngineSettingsProvider),
        const SpeakingEngineSettings(
          asrSource: SpeakingAsrSource.local,
          ttsSource: SpeakingTtsSource.local,
        ),
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(SpeakingEngineSettingsKeys.asrSource), 'local');
      expect(prefs.getString(SpeakingEngineSettingsKeys.ttsSource), 'local');
    });
  });
}
