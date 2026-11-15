/// 阿里云 Qwen-Audio 实时语音到语音客户端。
///
/// 特级档位直接使用端到端语音模型：客户端只持续推送麦克风 PCM，
/// 服务端自带判停并回传 24kHz PCM 语音与双向转写，不需要独立的
/// ASR / LLM / TTS 链路。
/// 协议参考：https://help.aliyun.com/zh/model-studio/qwen-audio-realtime-user-guides
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../models/ai_speaking_settings.dart';
import 'realtime_socket.dart';

/// 语音到语音会话中需要 UI 与播放器感知的事件。
sealed class SpeechToSpeechEvent {
  const SpeechToSpeechEvent();
}

/// 用户语音转写；[isFinal] 为 false 时是流式增量结果。
class SpeechToSpeechUserTranscript extends SpeechToSpeechEvent {
  const SpeechToSpeechUserTranscript({
    required this.text,
    required this.isFinal,
  });

  final String text;
  final bool isFinal;
}

/// AI 语音对应的文字转写。
class SpeechToSpeechAssistantTranscript extends SpeechToSpeechEvent {
  const SpeechToSpeechAssistantTranscript({
    required this.text,
    required this.isFinal,
    this.responseId = '',
  });

  final String text;
  final bool isFinal;

  /// 所属回复 id；用于丢弃被插话打断后迟到的分片。
  final String responseId;
}

/// AI 语音分片，24kHz / 16bit / 单声道裸 PCM。
class SpeechToSpeechAudio extends SpeechToSpeechEvent {
  const SpeechToSpeechAudio(this.pcm, {this.responseId = ''});

  final Uint8List pcm;

  /// 所属回复 id；用于丢弃被插话打断后迟到的分片。
  final String responseId;
}

/// 服务端判定用户开始说话；AI 正在播报时应立即停播。
class SpeechToSpeechSpeechStarted extends SpeechToSpeechEvent {
  const SpeechToSpeechSpeechStarted();
}

class SpeechToSpeechSpeechStopped extends SpeechToSpeechEvent {
  const SpeechToSpeechSpeechStopped();
}

/// 服务端开始生成一轮回复；[responseId] 用于过滤迟到分片。
class SpeechToSpeechResponseStarted extends SpeechToSpeechEvent {
  const SpeechToSpeechResponseStarted(this.responseId);

  final String responseId;
}

/// 一轮回复结束；[cancelled] 表示被用户插话打断。
class SpeechToSpeechResponseDone extends SpeechToSpeechEvent {
  const SpeechToSpeechResponseDone({
    required this.cancelled,
    this.responseId = '',
  });

  final bool cancelled;
  final String responseId;
}

/// 会话内错误；连接可能仍然可用，调用方决定是否结束会话。
class SpeechToSpeechFailure extends SpeechToSpeechEvent {
  const SpeechToSpeechFailure(this.message);

  final String message;
}

class QwenAudioRealtimeException implements Exception {
  const QwenAudioRealtimeException(this.message);

  final String message;

  @override
  String toString() => 'QwenAudioRealtimeException: $message';
}

abstract class SpeechToSpeechSession {
  Stream<SpeechToSpeechEvent> get events;

  /// 追加 16kHz / 16bit / 单声道 PCM 麦克风数据。
  void appendPcm(Uint8List bytes);

  /// 请求服务端取消当前回复（插话打断的兜底手段）。
  Future<void> cancelResponse();

  Future<void> close();
}

abstract class SpeechToSpeechClient {
  Future<SpeechToSpeechSession> start({
    required AiSpeechConfig config,
    required String apiKey,
    String instructions = '',
  });
}

class QwenAudioRealtimeClient implements SpeechToSpeechClient {
  QwenAudioRealtimeClient({WebSocketConnector? connector})
    : _connector = connector ?? connectRealtimeSocket;

  final WebSocketConnector _connector;

  @override
  Future<SpeechToSpeechSession> start({
    required AiSpeechConfig config,
    required String apiKey,
    String instructions = '',
  }) async {
    final model = AiSpeechConfig.normalizeRealtimeModel(config.realtimeModel);
    final workspace = config.workspaceId.trim();
    // 配置了业务空间时走空间专属域名，否则回退到公共域名。
    final host = workspace.isEmpty
        ? 'dashscope.aliyuncs.com'
        : '$workspace.cn-beijing.maas.aliyuncs.com';
    final url = 'wss://$host/api-ws/v1/realtime?model=$model';
    final headers = <String, dynamic>{
      'Authorization': 'Bearer ${apiKey.trim()}',
    };
    if (workspace.isNotEmpty) {
      headers['X-DashScope-WorkSpace'] = workspace;
    }

    RealtimeSocket socket;
    try {
      socket = await _connector(
        url,
        headers: headers,
      ).timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw const QwenAudioRealtimeException('连接实时语音服务超时');
    } on WebSocketException catch (error) {
      throw QwenAudioRealtimeException('连接实时语音服务失败：${error.message}');
    }

    final session = _QwenAudioRealtimeSession(
      socket: socket,
      config: config,
      instructions: instructions,
    );
    try {
      await session.start();
      return session;
    } on Object {
      await session.close();
      rethrow;
    }
  }
}

class _QwenAudioRealtimeSession implements SpeechToSpeechSession {
  _QwenAudioRealtimeSession({
    required this.socket,
    required this.config,
    required this.instructions,
  }) {
    // start 失败时调用方不会走 close 的正常路径，提前吞掉未处理的异步错误。
    _closed.future.ignore();
  }

  final RealtimeSocket socket;
  final AiSpeechConfig config;
  final String instructions;

  final _events = StreamController<SpeechToSpeechEvent>.broadcast();
  final _ready = Completer<void>();
  final _closed = Completer<void>();

  StreamSubscription<dynamic>? _subscription;
  bool _isClosed = false;

  @override
  Stream<SpeechToSpeechEvent> get events => _events.stream;

  Future<void> start() async {
    _subscription = socket.messages.listen(
      _handleMessage,
      onError: _handleSocketError,
      onDone: _handleSocketDone,
      cancelOnError: false,
    );
    _sendJson({'type': 'session.update', 'session': _sessionPayload()});
    try {
      await _ready.future.timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw const QwenAudioRealtimeException('实时语音服务未确认会话配置');
    }
  }

  Map<String, dynamic> _sessionPayload() {
    // server_vad 只按静音时长判停；smart_turn_v2 由服务端融合语义判断。
    final turnDetection =
        config.realtimeTurnDetection == RealtimeTurnDetection.serverVad
        ? <String, dynamic>{
            'type': 'server_vad',
            'threshold': 0.5,
            'silence_duration_ms': 800,
          }
        : <String, dynamic>{'type': 'smart_turn_v2'};
    return <String, dynamic>{
      'modalities': const ['text', 'audio'],
      'voice': config.realtimeVoice,
      'input_audio_format': 'pcm',
      'output_audio_format': 'pcm',
      if (instructions.isNotEmpty) 'instructions': instructions,
      'turn_detection': turnDetection,
    };
  }

  @override
  void appendPcm(Uint8List bytes) {
    if (_isClosed || bytes.isEmpty) return;
    _sendJson({
      'type': 'input_audio_buffer.append',
      'audio': base64Encode(bytes),
    });
  }

  @override
  Future<void> cancelResponse() async {
    if (_isClosed) return;
    _sendJson({'type': 'response.cancel'});
  }

  @override
  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;
    if (!_closed.isCompleted) _closed.complete();
    await _subscription?.cancel();
    _subscription = null;
    try {
      await socket.close();
    } on Object {
      // 关闭阶段的异常不覆盖已经产生的转写或错误事件。
    }
    await _events.close();
  }

  void _sendJson(Map<String, dynamic> payload) {
    try {
      socket.add(jsonEncode(payload));
    } on Object {
      // 连接已断开时丢弃发送，错误由 onDone/onError 统一上报。
    }
  }

  void _emit(SpeechToSpeechEvent event) {
    if (_isClosed || _events.isClosed) return;
    _events.add(event);
  }

  void _markReady() {
    if (!_ready.isCompleted) _ready.complete();
  }

  void _handleMessage(dynamic raw) {
    if (raw is! String) return; // 实时语音协议只使用文本帧。
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, dynamic>) return;
    final type = decoded['type'];
    switch (type) {
      case 'session.created':
      case 'session.updated':
        _markReady();
      case 'input_audio_buffer.speech_started':
        _emit(const SpeechToSpeechSpeechStarted());
      case 'input_audio_buffer.speech_stopped':
        _emit(const SpeechToSpeechSpeechStopped());
      case 'conversation.item.input_audio_transcription.delta':
        final text = decoded['text'];
        if (text is String && text.isNotEmpty) {
          _emit(SpeechToSpeechUserTranscript(text: text, isFinal: false));
        }
      case 'conversation.item.input_audio_transcription.completed':
        final text = decoded['transcript'];
        if (text is String) {
          _emit(SpeechToSpeechUserTranscript(text: text, isFinal: true));
        }
      case 'response.created':
        final response = decoded['response'];
        final responseId = response is Map<String, dynamic>
            ? response['id']
            : null;
        _emit(
          SpeechToSpeechResponseStarted(responseId is String ? responseId : ''),
        );
      case 'response.audio_transcript.delta':
        final delta = decoded['delta'];
        if (delta is String && delta.isNotEmpty) {
          _emit(
            SpeechToSpeechAssistantTranscript(
              text: delta,
              isFinal: false,
              responseId: _responseIdOf(decoded),
            ),
          );
        }
      case 'response.audio_transcript.done':
        final text = decoded['transcript'];
        if (text is String) {
          _emit(
            SpeechToSpeechAssistantTranscript(
              text: text,
              isFinal: true,
              responseId: _responseIdOf(decoded),
            ),
          );
        }
      case 'response.audio.delta':
        final delta = decoded['delta'];
        if (delta is String && delta.isNotEmpty) {
          _emit(
            SpeechToSpeechAudio(
              base64Decode(delta),
              responseId: _responseIdOf(decoded),
            ),
          );
        }
      case 'response.done':
        final response = decoded['response'];
        final status = response is Map<String, dynamic>
            ? response['status']
            : null;
        final responseId = response is Map<String, dynamic>
            ? response['id']
            : null;
        _emit(
          SpeechToSpeechResponseDone(
            cancelled: status == 'cancelled',
            responseId: responseId is String ? responseId : '',
          ),
        );
      case 'error':
        _emit(SpeechToSpeechFailure(_errorMessage(decoded)));
    }
  }

  String _responseIdOf(Map<String, dynamic> event) {
    final responseId = event['response_id'];
    return responseId is String ? responseId : '';
  }

  String _errorMessage(Map<String, dynamic> event) {
    final error = event['error'];
    if (error is Map<String, dynamic>) {
      final message = error['message'];
      if (message is String && message.isNotEmpty) return message;
    }
    return '实时语音服务返回错误';
  }

  void _handleSocketError(Object error) {
    _emit(SpeechToSpeechFailure('实时语音连接异常：$error'));
    _markReady();
  }

  void _handleSocketDone() {
    if (_isClosed) return;
    _emit(const SpeechToSpeechFailure('实时语音连接已断开'));
    _markReady();
  }
}
