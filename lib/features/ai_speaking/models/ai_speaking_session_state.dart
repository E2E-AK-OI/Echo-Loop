/// AI 口语会话页面的状态模型。
library;

import 'ai_speaking_message.dart';

enum AiSpeakingPhase {
  idle,
  preparing,
  listening,
  finalizing,
  thinking,
  speaking,
  error,
}

enum AiSpeakingErrorKind {
  missingConfig,
  permissionDenied,
  unsupportedPlatform,
  noSpeech,
  asrFailed,
  llmFailed,
  ttsFailed,
}

class AiSpeakingSessionState {
  const AiSpeakingSessionState({
    this.messages = const [],
    this.phase = AiSpeakingPhase.idle,
    this.partialTranscript = '',
    this.inputLevel = 0,
    this.errorMessage,
    this.errorKind,
    this.isSessionActive = false,
    this.isVoiceBargeInAvailable = true,
  });

  final List<AiSpeakingMessage> messages;
  final AiSpeakingPhase phase;
  final String partialTranscript;

  /// 录音输入电平，0~1；用于驱动话筒动画。
  final double inputLevel;
  final String? errorMessage;
  final AiSpeakingErrorKind? errorKind;

  /// 是否处于免提会话中（中级及以上点话筒开始、再点停止）。
  final bool isSessionActive;

  /// 当前是否允许用语音打断朗读。
  ///
  /// 高级档在检测到 TTS 从内置扬声器外放时会临时关闭该能力：麦克风会
  /// 拾取 AI 自己的声音，仅靠能量阈值无法可靠区分回声和用户插话。
  final bool isVoiceBargeInAvailable;

  AiSpeakingSessionState copyWith({
    List<AiSpeakingMessage>? messages,
    AiSpeakingPhase? phase,
    String? partialTranscript,
    double? inputLevel,
    String? errorMessage,
    AiSpeakingErrorKind? errorKind,
    bool? isSessionActive,
    bool? isVoiceBargeInAvailable,
    bool clearError = false,
  }) {
    return AiSpeakingSessionState(
      messages: messages ?? this.messages,
      phase: phase ?? this.phase,
      partialTranscript: partialTranscript ?? this.partialTranscript,
      inputLevel: inputLevel ?? this.inputLevel,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      errorKind: clearError ? null : (errorKind ?? this.errorKind),
      isSessionActive: isSessionActive ?? this.isSessionActive,
      isVoiceBargeInAvailable:
          isVoiceBargeInAvailable ?? this.isVoiceBargeInAvailable,
    );
  }
}
