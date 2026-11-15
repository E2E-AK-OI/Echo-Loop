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
import 'realtime_socket.dart';

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

class AliyunRealtimeAsrClient implements RealtimeAsrClient {
  AliyunRealtimeAsrClient({WebSocketConnector? connector})
    : _connector = connector ?? _defaultConnector;

  final WebSocketConnector _connector;

  static Future<RealtimeSocket> _defaultConnector(
    String url, {
    Map<String, dynamic>? headers,
  }) => connectRealtimeSocket(url, headers: headers);

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

    RealtimeSocket socket;
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

  final RealtimeSocket socket;
  final AiSpeechConfig config;
  final _events = StreamController<AsrTranscriptEvent>.broadcast();
  final _started = Completer<void>();
  final _finished = Completer<void>();

  StreamSubscription<dynamic>? _subscription;
  String? _taskId;

  /// 已经收到 sentence_end 的完整句子，按顺序用空格拼接。
  String _confirmedText = '';

  /// 当前句最新文本：服务端可能返回整句覆盖，也可能只返回新增片段。
  String _currentSentenceText = '';
  String? _currentSentenceId;
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

  /// 返回本轮完整转写。
  ///
  /// 不能只依赖 sentence_end：本地 VAD 的尾静音判定与云端 max_sentence_silence
  /// 是两条独立的计时，收尾时服务端常常还没来得及给出最终结果。这里把已确认
  /// 句子与当前句的最新文本一起返回，避免只把最后一个中间片段交给大模型。
  String _finalText() => _joinText(_confirmedText, _currentSentenceText);

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
    final sentenceId = sentence['sentence_id']?.toString();
    final startsSentence = sentence['sentence_begin'] == true;
    final isFinal = sentence['sentence_end'] == true;
    final switchedSentence =
        sentenceId != null &&
        _currentSentenceId != null &&
        sentenceId != _currentSentenceId;
    if (startsSentence || switchedSentence) {
      _commitCurrentSentence();
      _currentSentenceId = sentenceId;
    } else {
      _currentSentenceId ??= sentenceId;
    }
    if (text.isNotEmpty) {
      // 最终结果携带整句文本，直接以它为准；中间结果才走合并，兼容
      // 「整句覆盖」与「增量片段」两种下发方式，避免同一句被重复拼接。
      _currentSentenceText = isFinal
          ? text
          : _mergeSentenceText(_currentSentenceText, text);
    }
    if (isFinal) {
      _commitCurrentSentence();
      _events.add(AsrTranscriptEvent(text: _finalText(), isFinal: true));
    } else {
      _events.add(
        AsrTranscriptEvent(
          text: _joinText(_confirmedText, _currentSentenceText),
          isFinal: false,
        ),
      );
    }
  }

  /// 把当前句并入已确认文本，并开始下一句。
  void _commitCurrentSentence() {
    final text = _currentSentenceText.trim();
    if (text.isNotEmpty) {
      _confirmedText = _joinText(_confirmedText, text);
    }
    _currentSentenceText = '';
    _currentSentenceId = null;
  }

  /// 合并同一句的两次结果，兼容「整句覆盖」与「增量片段」两种服务端行为。
  static String _mergeSentenceText(String current, String incoming) {
    final base = current.trim();
    final next = incoming.trim();
    if (base.isEmpty) return next;
    if (next == base || base.endsWith(next)) return base;
    if (next.startsWith(base) || next.contains(base)) return next;
    final overlap = _suffixPrefixOverlap(base, next);
    if (overlap >= 2) {
      return _joinText(base, next.substring(overlap));
    }
    return _joinText(base, next);
  }

  /// 返回 base 的后缀与 next 的前缀重合长度。
  static int _suffixPrefixOverlap(String base, String next) {
    final max = base.length < next.length ? base.length : next.length;
    for (var length = max; length > 0; length--) {
      if (base.substring(base.length - length) == next.substring(0, length)) {
        return length;
      }
    }
    return 0;
  }

  /// 拼接识别文本：中文与英文标点之间不加空格，英文单词之间加空格。
  static String _joinText(String left, String right) {
    final a = left.trim();
    final b = right.trim();
    if (a.isEmpty) return b;
    if (b.isEmpty) return a;
    final needsSpace =
        !_isCjk(a.codeUnitAt(a.length - 1)) &&
        !_isCjk(b.codeUnitAt(0)) &&
        !_noSpaceBefore.contains(b[0]);
    return needsSpace ? '$a $b' : '$a$b';
  }

  static const _noSpaceBefore = <String>{',', '.', '!', '?', ';', ':', ')'};

  static bool _isCjk(int codeUnit) {
    return (codeUnit >= 0x3400 && codeUnit <= 0x9FFF) ||
        (codeUnit >= 0xF900 && codeUnit <= 0xFAFF) ||
        (codeUnit >= 0x3040 && codeUnit <= 0x30FF) ||
        (codeUnit >= 0xAC00 && codeUnit <= 0xD7AF);
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
