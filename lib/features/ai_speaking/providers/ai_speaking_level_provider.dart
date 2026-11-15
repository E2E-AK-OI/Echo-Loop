/// 口语练习档位的状态管理与持久化。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/ai_speaking_level.dart';

/// 应用启动时由 main.dart 用 SharedPreferences 预读的初始值覆盖。
final initialAiSpeakingLevelProvider = Provider<AiSpeakingLevel>(
  (ref) => AiSpeakingLevel.beginner,
);

class AiSpeakingLevelNotifier extends Notifier<AiSpeakingLevel> {
  @override
  AiSpeakingLevel build() => ref.read(initialAiSpeakingLevelProvider);

  Future<void> setLevel(AiSpeakingLevel level) async {
    if (state == level) return;
    state = level;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AiSpeakingLevelKeys.level, level.name);
  }
}

final aiSpeakingLevelProvider =
    NotifierProvider<AiSpeakingLevelNotifier, AiSpeakingLevel>(
      AiSpeakingLevelNotifier.new,
    );
