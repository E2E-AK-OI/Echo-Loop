/// 对话与会话设置模型与 Provider 单元测试。
///
/// 覆盖：默认值、越界钳制、SharedPreferences 预读与插话门限。
library;

import 'package:echo_loop/features/ai_speaking/models/speaking_dialog_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SpeakingDialogSettings', () {
    test('默认：800ms 尾静音、30 秒空闲退出、中档灵敏度', () {
      const settings = SpeakingDialogSettings.defaults;

      expect(settings.endOfSpeechMs, 800);
      expect(settings.idleExitSeconds, 30);
      expect(settings.bargeInSensitivity, BargeInSensitivity.medium);
      expect(settings.endOfSpeech, const Duration(milliseconds: 800));
      expect(settings.idleExit, const Duration(seconds: 30));
    });

    test('尾静音越界被钳制到 400–2000ms', () {
      expect(
        SpeakingDialogSettings(
          endOfSpeechMs: 300,
          idleExitSeconds: 30,
        ).endOfSpeechMs,
        SpeakingDialogSettings.minEndOfSpeechMs,
      );
      expect(
        SpeakingDialogSettings(
          endOfSpeechMs: 5000,
          idleExitSeconds: 30,
        ).endOfSpeechMs,
        SpeakingDialogSettings.maxEndOfSpeechMs,
      );
    });

    test('空闲退出越界被钳制到 10–60 秒', () {
      expect(
        SpeakingDialogSettings(
          endOfSpeechMs: 800,
          idleExitSeconds: 5,
        ).idleExitSeconds,
        SpeakingDialogSettings.minIdleExitSeconds,
      );
      expect(
        SpeakingDialogSettings(
          endOfSpeechMs: 800,
          idleExitSeconds: 120,
        ).idleExitSeconds,
        SpeakingDialogSettings.maxIdleExitSeconds,
      );
    });

    test('强制断句兜底为尾静音上限 2000ms', () {
      expect(SpeakingDialogSettings.hardLimitEndOfSpeechMs, 2000);
      expect(
        SpeakingDialogSettings.hardLimitEndOfSpeechMs,
        SpeakingDialogSettings.maxEndOfSpeechMs,
      );
    });

    test('设置页档位都落在合法范围内', () {
      for (final option in SpeakingDialogSettings.endOfSpeechOptions) {
        expect(
          option,
          greaterThanOrEqualTo(SpeakingDialogSettings.minEndOfSpeechMs),
        );
        expect(
          option,
          lessThanOrEqualTo(SpeakingDialogSettings.maxEndOfSpeechMs),
        );
      }
      for (final option in SpeakingDialogSettings.idleExitOptions) {
        expect(
          option,
          greaterThanOrEqualTo(SpeakingDialogSettings.minIdleExitSeconds),
        );
        expect(
          option,
          lessThanOrEqualTo(SpeakingDialogSettings.maxIdleExitSeconds),
        );
      }
      expect(
        SpeakingDialogSettings.endOfSpeechOptions,
        contains(SpeakingDialogSettings.defaultEndOfSpeechMs),
      );
      expect(
        SpeakingDialogSettings.idleExitOptions,
        contains(SpeakingDialogSettings.defaultIdleExitSeconds),
      );
    });

    test('空 SharedPreferences 回退默认值', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      expect(
        SpeakingDialogSettings.fromPrefsSync(prefs),
        SpeakingDialogSettings.defaults,
      );
    });

    test('读取已保存值并钳制历史越界数据', () async {
      SharedPreferences.setMockInitialValues({
        SpeakingDialogSettingsKeys.endOfSpeechMs: 5000,
        SpeakingDialogSettingsKeys.idleExitSeconds: 5,
        SpeakingDialogSettingsKeys.bargeInSensitivity: 'high',
      });
      final prefs = await SharedPreferences.getInstance();

      final settings = SpeakingDialogSettings.fromPrefsSync(prefs);

      expect(settings.endOfSpeechMs, 2000);
      expect(settings.idleExitSeconds, 10);
      expect(settings.bargeInSensitivity, BargeInSensitivity.high);
    });

    test('未知灵敏度回退到中档', () {
      expect(
        BargeInSensitivity.fromStorage('unknown'),
        BargeInSensitivity.medium,
      );
      expect(BargeInSensitivity.fromStorage(null), BargeInSensitivity.medium);
    });

    test('朗读期间的插话门限随灵敏度升高而降低', () {
      expect(
        BargeInSensitivity.low.bargeInThreshold,
        greaterThan(BargeInSensitivity.medium.bargeInThreshold),
      );
      expect(
        BargeInSensitivity.medium.bargeInThreshold,
        greaterThan(BargeInSensitivity.high.bargeInThreshold),
      );
    });

    test('灵敏度门限随档位递减（越高越易打断）', () {
      expect(
        BargeInSensitivity.low.vadThreshold,
        greaterThan(BargeInSensitivity.medium.vadThreshold),
      );
      expect(
        BargeInSensitivity.medium.vadThreshold,
        greaterThan(BargeInSensitivity.high.vadThreshold),
      );
    });

    test('copyWith 与相等性', () {
      const base = SpeakingDialogSettings.defaults;
      final changed = base.copyWith(endOfSpeechMs: 1200);

      expect(changed.endOfSpeechMs, 1200);
      expect(changed.idleExitSeconds, base.idleExitSeconds);
      expect(changed == base, isFalse);
      expect(changed == base.copyWith(endOfSpeechMs: 1200), isTrue);
    });
  });
}
