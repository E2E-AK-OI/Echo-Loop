/// 口语引擎来源设置单元测试。
///
/// 覆盖：默认值、SharedPreferences 预读与未知值回退。
library;

import 'package:echo_loop/features/ai_speaking/models/speaking_engine_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
}
