/// AI 口语对话中的一条消息。
library;

enum AiSpeakingRole { user, assistant }

enum AiSpeakingMessageStatus { streaming, done, error }

class AiSpeakingMessage {
  const AiSpeakingMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.status,
    required this.createdAt,
    this.audioPath,
  });

  final String id;
  final AiSpeakingRole role;
  final String content;
  final AiSpeakingMessageStatus status;
  final DateTime createdAt;
  final String? audioPath;

  AiSpeakingMessage copyWith({
    String? content,
    AiSpeakingMessageStatus? status,
    String? audioPath,
  }) {
    return AiSpeakingMessage(
      id: id,
      role: role,
      content: content ?? this.content,
      status: status ?? this.status,
      createdAt: createdAt,
      audioPath: audioPath ?? this.audioPath,
    );
  }
}
