/// 阿里云 DashScope 实时语音识别客户端。
///
/// 使用 WebSocket 双工协议：run-task -> task-started -> 二进制 PCM ->
/// result-generated -> finish-task -> task-finished。协议细节集中在会话类中，
/// 便于用可控的 WebSocketConnector 做单元测试。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../models/ai_speaking_settings.dart';

class AsrTranscriptEvent {
  const AsrTranscriptEvent({required this.text, required this.isFinal});

  final String text;
  final bool isFinal;
}

class AliyunAsrException implements Exception {
  const AliyunAsrException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() {
    if (code == null) return 'AliyunAsrException: $message';
    return 'AliyunAsrException($code): $message';
  }
}

abstract class RealtimeAsrSession {
  Stream<AsrTranscriptEvent> get events;

  void appendPcm(Uint8List bytes);

  Future<String> finish();

  Future<void> cancel();
}

abstract class RealtimeAsrClient {
  Future<RealtimeAsrSession> start({
    required AiSpeechConfig config,
    required String apiKey,
  });
}

/// 实时识别使用的 WebSocket 抽象，隔离 dart:io 以便单元测试注入假连接。
abstract class AsrSocket {
  Stream<dynamic> get messages;

  void add(dynamic data);

  Future<void> close();
}

typedef WebSocketConnector = Future<AsrSocket> Function(
  String url, {
  Map<String, dynamic>? headers,
});

class AliyunRealtimeAsrClient implements RealtimeAsrClient {
  AliyunRealtimeAsrClient({WebSocketConnector? connector})
    : _connector = connector ?? _defaultConnector;

  final WebSocketConnector _connector;

  static Future<AsrSocket> _defaultConnector(
    String url, {
    Map<String, dynamic>? headers,
  }) async {
    final socket = await WebSocket.connect(url, headers: headers);
    return _WebSocketAsrSocket(socket);
  }

  @override
  Future<RealtimeAsrSession> start({
    required AiSpeechConfig config,
    required String apiKey,
  }) async {
    final workspace = config.workspaceId.trim();
    final endpoint = workspace.isEmpty
        ? 'wss://dashscope.aliyuncs.com/api-ws/v1/inference'
        : 'wss://$workspace.cn-beijing.maas.aliyuncs.com/api-ws/v1/inference';
    final headers = <String, dynamic>{
      'Authorization': 'Bearer ${apiKey.trim()}',
    };
    if (workspace.isNotEmpty) {
      headers['X-DashScope-WorkSpace'] = workspace;
    }

    AsrSocket socket;
    try {
      socket = await _connector(
        endpoint,
        headers: headers,
      ).timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw const AliyunAsrException('连接语音识别服务超时');
    } on WebSocketException catch (error) {
      throw AliyunAsrException('连接语音识别服务失败：${error.message}');
    }

    final session = _AliyunRealtimeAsrSession(socket: socket, config: config);
    try {
      await session.start();
      return session;
    } on Object {
      await session.cancel();
      rethrow;
    }
  }
}

class _AliyunRealtimeAsrSession implements RealtimeAsrSession {
  _AliyunRealtimeAsrSession({required this.socket, required this.config}) {
    // start 阶段失败时调用方不会执行 finish，提前挂一个监听避免未处理的异步错误。
    _finished.future.ignore();
  }

  final AsrSocket socket;
  final AiSpeechConfig config;
  final _events = StreamController<AsrTranscriptEvent>.broadcast();
  final _started = Completer<void>();
  final _finished = Completer<void>();

  StreamSubscription<dynamic>? _subscription;
  String? _taskId;
  String _finalBuffer = '';
  String _latestText = '';
  bool _closed = false;

  @override
  Stream<AsrTranscriptEvent> get events => _events.stream;

  Future<void> start() async {
    _subscription = socket.messages.listen(
      _handleMessage,
      onError: _handleSocketError,
      onDone: _handleSocketDone,
      cancelOnError: false,
    );
    _taskId = const Uuid().v4();
    _sendJson({
      'header': {
        'action': 'run-task',
        'task_id': _taskId,
        'streaming': 'duplex',
      },
      'payload': {
        'task_group': 'audio',
        'task': 'asr',
        'function': 'recognition',
        'model': config.asrModel,
        'parameters': {
          'format': 'pcm',
          'sample_rate': 16000,
          'language_hints': ['en'],
          'max_sentence_silence': 800,
          'vad_model': 'near_meeting_16k',
        },
        'input': <String, dynamic>{},
      },
    });
    try {
      await _started.future.timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw const AliyunAsrException('等待语音识别任务启动超时');
    }
  }

  @override
  void appendPcm(Uint8List bytes) {
    if (_closed || bytes.isEmpty) return;
    try {
      socket.add(bytes);
    } on Object {
      _completeWithError(const AliyunAsrException('发送录音数据失败'));
    }
  }

  @override
  Future<String> finish() async {
    if (_closed && _finished.isCompleted) {
      return _finalText();
    }
    _sendJson({
      'header': {
        'action': 'finish-task',
        'task_id': _taskId,
        'streaming': 'duplex',
      },
      'payload': {'input': <String, dynamic>{}},
    });
    try {
      await _finished.future.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      throw const AliyunAsrException('等待语音识别结果超时');
    }
    await _close();
    return _finalText();
  }

  @override
  Future<void> cancel() async {
    if (_closed) return;
    await _close();
  }

  String _finalText() {
    if (_finalBuffer.trim().isEmpty && _latestText.trim().isNotEmpty) {
      _finalBuffer = _latestText.trim();
    }
    return _finalBuffer.trim();
  }

  void _handleMessage(dynamic message) {
    if (message is! String) return;
    final Map<String, dynamic> decoded;
    try {
      final raw = jsonDecode(message);
      if (raw is! Map) return;
      decoded = <String, dynamic>{
        for (final entry in raw.entries) entry.key.toString(): entry.value,
      };
    } on FormatException {
      return;
    }

    final header = decoded['header'];
    final event = header is Map ? header['event']?.toString() : null;
    switch (event) {
      case 'task-started':
        if (!_started.isCompleted) _started.complete();
      case 'result-generated':
        _handleResult(decoded['payload']);
      case 'task-finished':
        if (!_started.isCompleted) _started.complete();
        if (!_finished.isCompleted) _finished.complete();
      case 'task-failed':
        final code = header is Map ? header['error_code']?.toString() : null;
        final message = header is Map
            ? (header['error_message']?.toString() ?? '语音识别任务失败')
            : '语音识别任务失败';
        _completeWithError(AliyunAsrException(message, code: code));
    }
  }

  void _handleResult(Object? payload) {
    if (payload is! Map) return;
    final output = payload['output'];
    if (output is! Map) return;
    final sentence = output['sentence'];
    if (sentence is! Map) return;
    // 心跳包只用于保活，不携带有效识别文本，直接跳过。
    if (sentence['heartbeat'] == true) return;
    final text = sentence['text']?.toString().trim() ?? '';
    if (text.isEmpty) return;
    final isFinal = sentence['sentence_end'] == true;
    _latestText = text;
    if (isFinal) {
      _finalBuffer = _finalBuffer.isEmpty ? text : '$_finalBuffer $text';
      _events.add(AsrTranscriptEvent(text: text, isFinal: true));
    } else {
      _events.add(AsrTranscriptEvent(text: text, isFinal: false));
    }
  }

  void _handleSocketError(Object error) {
    _completeWithError(AliyunAsrException('语音识别连接异常：$error'));
  }

  void _handleSocketDone() {
    if (_finished.isCompleted) return;
    _completeWithError(const AliyunAsrException('语音识别连接提前关闭'));
  }

  void _completeWithError(AliyunAsrException error) {
    if (!_started.isCompleted) _started.completeError(error);
    if (!_finished.isCompleted) _finished.completeError(error);
    if (!_events.isClosed) _events.addError(error);
  }

  void _sendJson(Map<String, dynamic> payload) {
    try {
      socket.add(jsonEncode(payload));
    } on Object {
      _completeWithError(const AliyunAsrException('发送语音识别指令失败'));
    }
  }

  Future<void> _close() async {
    if (_closed) return;
    _closed = true;
    await _subscription?.cancel();
    _subscription = null;
    try {
      await socket.close();
    } on Object {
      // 关闭阶段的异常不覆盖已经产生的识别结果或错误。
    }
    await _events.close();
  }
}

class _WebSocketAsrSocket implements AsrSocket {
  _WebSocketAsrSocket(this._socket);

  final WebSocket _socket;

  @override
  Stream<dynamic> get messages => _socket;

  @override
  void add(dynamic data) => _socket.add(data);

  @override
  Future<void> close() => _socket.close();
}
