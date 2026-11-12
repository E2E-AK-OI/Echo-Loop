/// AI 口语会话页面的状态模型。
library;

import 'ai_speaking_message.dart';

enum AiSpeakingPhase { idle, listening, finalizing, thinking, speaking, error }

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
  });

  final List<AiSpeakingMessage> messages;
  final AiSpeakingPhase phase;
  final String partialTranscript;

  /// 录音输入电平，0~1；用于驱动话筒动画。
  final double inputLevel;
  final String? errorMessage;
  final AiSpeakingErrorKind? errorKind;

  AiSpeakingSessionState copyWith({
    List<AiSpeakingMessage>? messages,
    AiSpeakingPhase? phase,
    String? partialTranscript,
    double? inputLevel,
    String? errorMessage,
    AiSpeakingErrorKind? errorKind,
    bool clearError = false,
  }) {
    return AiSpeakingSessionState(
      messages: messages ?? this.messages,
      phase: phase ?? this.phase,
      partialTranscript: partialTranscript ?? this.partialTranscript,
      inputLevel: inputLevel ?? this.inputLevel,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      errorKind: clearError ? null : (errorKind ?? this.errorKind),
    );
  }
}
