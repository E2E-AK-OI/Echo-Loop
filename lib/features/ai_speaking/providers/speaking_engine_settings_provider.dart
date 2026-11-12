/// 口语引擎来源设置的状态管理与持久化。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/speaking_engine_settings.dart';

/// 应用启动时由 main.dart 用 SharedPreferences 预读的初始值覆盖。
final initialSpeakingEngineSettingsProvider = Provider<SpeakingEngineSettings>(
  (ref) => SpeakingEngineSettings.defaults,
);

class SpeakingEngineSettingsNotifier extends Notifier<SpeakingEngineSettings> {
  @override
  SpeakingEngineSettings build() =>
      ref.read(initialSpeakingEngineSettingsProvider);

  Future<void> setAsrSource(SpeakingAsrSource source) async {
    if (state.asrSource == source) return;
    state = state.copyWith(asrSource: source);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(SpeakingEngineSettingsKeys.asrSource, source.name);
  }

  Future<void> setTtsSource(SpeakingTtsSource source) async {
    if (state.ttsSource == source) return;
    state = state.copyWith(ttsSource: source);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(SpeakingEngineSettingsKeys.ttsSource, source.name);
  }
}

final speakingEngineSettingsProvider =
    NotifierProvider<SpeakingEngineSettingsNotifier, SpeakingEngineSettings>(
      SpeakingEngineSettingsNotifier.new,
    );
