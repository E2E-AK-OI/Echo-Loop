/// AI 口语练习的对话档位。
///
/// 四档共用同一份会话、消息与「AI 设置」中的大模型配置，差异集中在语音输入、
/// 语音输出与轮次控制上：初级按键说话；中级由本地 VAD 自动轮转但不允许插话；
/// 高级允许用户在 AI 朗读时打断；特级直接交给端到端语音模型。
library;

import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences 键名常量。
abstract final class AiSpeakingLevelKeys {
  static const level = 'ai_speaking_level';
}

/// 口语练习档位。
enum AiSpeakingLevel {
  /// 初级：按键说话、按键提交。
  beginner,

  /// 中级：点话筒开始会话，由 VAD 自动判断轮次，不允许插话打断。
  intermediate,

  /// 高级：在中级基础上允许用户打断 AI，语音链路使用云端实时模型。
  advanced,

  /// 特级：端到端语音到语音模型，不使用 ASR/LLM/TTS 三段链路。
  expert;

  /// 是否需要用户手动开始和结束本轮（按键说话）。
  bool get usesPushToTalk => this == AiSpeakingLevel.beginner;

  /// 是否由本地 VAD 决定用户说话的起止。
  ///
  /// 特级由服务端模型判停，不需要本地 VAD。
  bool get usesVoiceActivityDetection =>
      this == AiSpeakingLevel.intermediate || this == AiSpeakingLevel.advanced;

  /// 是否允许用户在 AI 朗读期间插话打断。
  bool get allowsBargeIn =>
      this == AiSpeakingLevel.advanced || this == AiSpeakingLevel.expert;

  /// 是否强制使用云端实时语音识别（高级对延迟敏感，不允许本地或平台识别）。
  bool get requiresRealtimeAsr => this == AiSpeakingLevel.advanced;

  /// 是否强制使用云端语音合成（中级允许本地 TTS，高级不允许）。
  bool get requiresCloudTts => this == AiSpeakingLevel.advanced;

  /// 是否使用端到端语音到语音模型，绕过 ASR / LLM / TTS 三段链路。
  bool get usesSpeechToSpeech => this == AiSpeakingLevel.expert;

  /// 是否仍允许选择本地/平台语音引擎。
  ///
  /// 特级走端到端语音模型，整条链路由服务端决定，本地引擎无从接入。
  bool get allowsLocalEngines =>
      !usesSpeechToSpeech && !requiresRealtimeAsr && !requiresCloudTts;

  /// 对话轮次是否需要「会话中」状态（点话筒开始、再点停止）。
  bool get usesContinuousSession => !usesPushToTalk;

  /// 从本地偏好读取，未知值回退到初级，避免升级后改变既有练习方式。
  static AiSpeakingLevel fromStorage(String? value) {
    return AiSpeakingLevel.values.firstWhere(
      (level) => level.name == value,
      orElse: () => AiSpeakingLevel.beginner,
    );
  }

  /// 从 SharedPreferences 同步读取。
  static AiSpeakingLevel fromPrefsSync(SharedPreferences prefs) {
    return fromStorage(prefs.getString(AiSpeakingLevelKeys.level));
  }
}
