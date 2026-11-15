/// 各档位语音引擎配置的状态管理与持久化。
///
/// 四个档位各存一套配置；同一时间只有一个档位在练习中使用，因此用一张
/// `档位 → 配置` 的映射统一管理，页面按当前标签读写其中一个档位。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/ai_speaking_level.dart';
import '../models/ai_speaking_settings.dart';
import '../models/speaking_dialog_settings.dart';
import '../models/speaking_engine_settings.dart';
import '../models/speaking_level_config.dart';

/// 应用启动时由 main.dart 用 SharedPreferences 预读的初始配置。
final initialSpeakingLevelConfigsProvider =
    Provider<Map<AiSpeakingLevel, SpeakingLevelConfig>>((ref) {
      return {
        for (final level in AiSpeakingLevel.values)
          level: SpeakingLevelConfig.defaultsFor(level),
      };
    });

/// 每个档位一份配置；缺省档位回退到默认配置，避免调用方到处判空。
class SpeakingLevelConfigsNotifier
    extends Notifier<Map<AiSpeakingLevel, SpeakingLevelConfig>> {
  @override
  Map<AiSpeakingLevel, SpeakingLevelConfig> build() {
    return Map<AiSpeakingLevel, SpeakingLevelConfig>.of(
      ref.read(initialSpeakingLevelConfigsProvider),
    );
  }

  /// 读取指定档位配置。
  SpeakingLevelConfig configFor(AiSpeakingLevel level) {
    return state[level] ?? SpeakingLevelConfig.defaultsFor(level);
  }

  Future<void> setAsrSource(
    AiSpeakingLevel level,
    SpeakingAsrSource source,
  ) async {
    await _update(
      level,
      (config) =>
          config.copyWith(engine: config.engine.copyWith(asrSource: source)),
    );
  }

  Future<void> setTtsSource(
    AiSpeakingLevel level,
    SpeakingTtsSource source,
  ) async {
    await _update(
      level,
      (config) =>
          config.copyWith(engine: config.engine.copyWith(ttsSource: source)),
    );
  }

  Future<void> setAsrModel(AiSpeakingLevel level, String model) async {
    final normalized = AiSpeechConfig.normalizeAsrModel(model);
    await _update(
      level,
      (config) =>
          config.copyWith(speech: config.speech.copyWith(asrModel: normalized)),
    );
  }

  Future<void> setTtsModel(AiSpeakingLevel level, String model) async {
    final normalized = AiSpeechConfig.normalizeTtsModel(model);
    await _update(level, (config) {
      return config.copyWith(
        speech: config.speech.copyWith(
          ttsModel: normalized,
          ttsVoice: AiSpeechConfig.resolveTtsVoice(
            model: normalized,
            voice: config.speech.ttsVoice,
          ),
        ),
      );
    });
  }

  Future<void> setTtsVoice(AiSpeakingLevel level, String voice) async {
    await _update(level, (config) {
      return config.copyWith(
        speech: config.speech.copyWith(
          ttsVoice: AiSpeechConfig.resolveTtsVoice(
            model: config.speech.ttsModel,
            voice: voice,
          ),
        ),
      );
    });
  }

  Future<void> setTtsRate(AiSpeakingLevel level, double rate) async {
    final clamped = rate.clamp(0.5, 2.0).toDouble();
    await _update(
      level,
      (config) =>
          config.copyWith(speech: config.speech.copyWith(ttsRate: clamped)),
    );
  }

  Future<void> setAutoPlay(AiSpeakingLevel level, bool value) async {
    await _update(
      level,
      (config) =>
          config.copyWith(speech: config.speech.copyWith(autoPlay: value)),
    );
  }

  Future<void> setRealtimeModel(AiSpeakingLevel level, String model) async {
    final normalized = AiSpeechConfig.normalizeRealtimeModel(model);
    await _update(level, (config) {
      return config.copyWith(
        speech: config.speech.copyWith(
          realtimeModel: normalized,
          realtimeVoice: AiSpeechConfig.resolveRealtimeVoice(
            config.speech.realtimeVoice,
          ),
        ),
      );
    });
  }

  Future<void> setRealtimeVoice(AiSpeakingLevel level, String voice) async {
    final resolved = AiSpeechConfig.resolveRealtimeVoice(voice);
    await _update(
      level,
      (config) => config.copyWith(
        speech: config.speech.copyWith(realtimeVoice: resolved),
      ),
    );
  }

  Future<void> setRealtimeTurnDetection(
    AiSpeakingLevel level,
    RealtimeTurnDetection mode,
  ) async {
    await _update(
      level,
      (config) => config.copyWith(
        speech: config.speech.copyWith(realtimeTurnDetection: mode),
      ),
    );
  }

  Future<void> setEndOfSpeechMs(AiSpeakingLevel level, int value) async {
    await _update(
      level,
      (config) =>
          config.copyWith(dialog: config.dialog.copyWith(endOfSpeechMs: value)),
    );
  }

  Future<void> setIdleExitSeconds(AiSpeakingLevel level, int value) async {
    await _update(
      level,
      (config) => config.copyWith(
        dialog: config.dialog.copyWith(idleExitSeconds: value),
      ),
    );
  }

  Future<void> setBargeInSensitivity(
    AiSpeakingLevel level,
    BargeInSensitivity value,
  ) async {
    await _update(
      level,
      (config) => config.copyWith(
        dialog: config.dialog.copyWith(bargeInSensitivity: value),
      ),
    );
  }

  Future<void> _update(
    AiSpeakingLevel level,
    SpeakingLevelConfig Function(SpeakingLevelConfig config) transform,
  ) async {
    final current = configFor(level);
    final next = transform(current);
    if (next == current) return;
    state = {...state, level: next};
    await _persist(level, next);
  }

  /// 写入整个档位配置；字段不多，整体落盘比分字段判断更不容易漏写。
  Future<void> _persist(
    AiSpeakingLevel level,
    SpeakingLevelConfig config,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      SpeakingLevelConfigKeys.asrSource(level),
      config.engine.asrSource.name,
    );
    await prefs.setString(
      SpeakingLevelConfigKeys.ttsSource(level),
      config.engine.ttsSource.name,
    );
    await prefs.setString(
      SpeakingLevelConfigKeys.asrModel(level),
      config.speech.asrModel,
    );
    await prefs.setString(
      SpeakingLevelConfigKeys.ttsModel(level),
      config.speech.ttsModel,
    );
    await prefs.setString(
      SpeakingLevelConfigKeys.ttsVoice(level),
      config.speech.ttsVoice,
    );
    await prefs.setDouble(
      SpeakingLevelConfigKeys.ttsRate(level),
      config.speech.ttsRate,
    );
    await prefs.setBool(
      SpeakingLevelConfigKeys.autoPlay(level),
      config.speech.autoPlay,
    );
    await prefs.setString(
      SpeakingLevelConfigKeys.realtimeModel(level),
      config.speech.realtimeModel,
    );
    await prefs.setString(
      SpeakingLevelConfigKeys.realtimeVoice(level),
      config.speech.realtimeVoice,
    );
    await prefs.setString(
      SpeakingLevelConfigKeys.realtimeTurnDetection(level),
      config.speech.realtimeTurnDetection.wireValue,
    );
    await prefs.setInt(
      SpeakingLevelConfigKeys.endOfSpeechMs(level),
      config.dialog.endOfSpeechMs,
    );
    await prefs.setInt(
      SpeakingLevelConfigKeys.idleExitSeconds(level),
      config.dialog.idleExitSeconds,
    );
    await prefs.setString(
      SpeakingLevelConfigKeys.bargeInSensitivity(level),
      config.dialog.bargeInSensitivity.name,
    );
  }
}

final speakingLevelConfigsProvider =
    NotifierProvider<
      SpeakingLevelConfigsNotifier,
      Map<AiSpeakingLevel, SpeakingLevelConfig>
    >(SpeakingLevelConfigsNotifier.new);
