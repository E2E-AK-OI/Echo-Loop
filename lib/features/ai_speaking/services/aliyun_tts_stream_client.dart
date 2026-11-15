/// 阿里云 DashScope 流式语音合成客户端。
///
/// 与 `AliyunTtsClient` 的非实时 HTTP 接口不同，这里通过 WebSocket 的
/// run-task / continue-task / finish-task 协议边合成边接收 24kHz PCM，
/// 首包到达即可交给 `PcmStreamPlayer` 播放，降低整段等待时间。
/// 协议参考：https://help.aliyun.com/zh/model-studio/websocket-for-tts
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../models/ai_speaking_settings.dart';
import 'aliyun_tts_client.dart';
import 'realtime_socket.dart';

/// 流式语音合成的下行数据：24kHz / 16bit / 单声道裸 PCM。
abstract class AiTtsStreamClient {
  Stream<Uint8List> synthesizeStream({
    required String text,
    required AiSpeechConfig config,
    required String apiKey,
    CancelToken? cancelToken,
  });

  /// 边接收文本边合成；实现方应在文本流结束前持续发送 continue-task，
  /// 让音频尽早返回。默认实现会先攒全文，仅用于不支持分段合成的实现。
  Stream<Uint8List> synthesizeChunks({
    required Stream<String> textChunks,
    required AiSpeechConfig config,
    required String apiKey,
    CancelToken? cancelToken,
  }) async* {
    final buffer = StringBuffer();
    await for (final chunk in textChunks) {
      buffer.write(chunk);
    }
    yield* synthesizeStream(
      text: buffer.toString(),
      config: config,
      apiKey: apiKey,
      cancelToken: cancelToken,
    );
  }
}

class AliyunTtsStreamClient implements AiTtsStreamClient {
  AliyunTtsStreamClient({WebSocketConnector? connector})
    : _connector = connector ?? connectRealtimeSocket;

  static const sampleRate = 24000;

  final WebSocketConnector _connector;

  @override
  Stream<Uint8List> synthesizeStream({
    required String text,
    required AiSpeechConfig config,
    required String apiKey,
    CancelToken? cancelToken,
  }) async* {
    final normalized = text.trim();
    if (normalized.isEmpty) {
      throw const AiTtsException(AiTtsErrorKind.badRequest, '朗读文本不能为空');
    }
    if (normalized.runes.length > AliyunTtsClient.maxTextLength) {
      throw const AiTtsException(AiTtsErrorKind.badRequest, '朗读文本超过 1000 字符');
    }
    yield* synthesizeChunks(
      textChunks: Stream<String>.value(normalized),
      config: config,
      apiKey: apiKey,
      cancelToken: cancelToken,
    );
  }

  @override
  Stream<Uint8List> synthesizeChunks({
    required Stream<String> textChunks,
    required AiSpeechConfig config,
    required String apiKey,
    CancelToken? cancelToken,
  }) async* {
    // 先拿到第一段有效文本再建连：空文本直接报参数错误，避免白白握手。
    final iterator = StreamIterator<String>(textChunks);
    String? firstChunk;
    while (await iterator.moveNext()) {
      final normalized = iterator.current.trim();
      if (normalized.isEmpty) continue;
      if (normalized.runes.length > AliyunTtsClient.maxTextLength) {
        await iterator.cancel();
        throw const AiTtsException(AiTtsErrorKind.badRequest, '朗读文本超过 1000 字符');
      }
      firstChunk = normalized;
      break;
    }
    if (firstChunk == null) {
      await iterator.cancel();
      throw const AiTtsException(AiTtsErrorKind.badRequest, '朗读文本不能为空');
    }
    if (apiKey.trim().isEmpty) {
      await iterator.cancel();
      throw const AiTtsException(
        AiTtsErrorKind.unauthorized,
        'DashScope API Key 未配置',
      );
    }

    final workspace = config.workspaceId.trim();
    final host = workspace.isEmpty
        ? 'dashscope.aliyuncs.com'
        : '$workspace.cn-beijing.maas.aliyuncs.com';
    final headers = <String, dynamic>{
      'Authorization': 'Bearer ${apiKey.trim()}',
    };
    if (workspace.isNotEmpty) {
      headers['X-DashScope-WorkSpace'] = workspace;
    }

    RealtimeSocket socket;
    try {
      socket = await _connector(
        'wss://$host/api-ws/v1/inference',
        headers: headers,
      ).timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw const AiTtsException(AiTtsErrorKind.network, '连接语音合成服务超时');
    } on Object catch (error) {
      throw AiTtsException(AiTtsErrorKind.network, '连接语音合成服务失败：$error');
    }

    final taskId = 'tts-${DateTime.now().microsecondsSinceEpoch}';
    final audio = StreamController<Uint8List>();
    final started = Completer<void>();
    var isClosed = false;

    void closeAudio() {
      if (isClosed) return;
      isClosed = true;
      unawaited(audio.close());
    }

    void fail(AiTtsException error) {
      if (!started.isCompleted) {
        started.completeError(error);
        return;
      }
      if (!isClosed) {
        isClosed = true;
        audio.addError(error);
        unawaited(audio.close());
      }
    }

    final subscription = socket.messages.listen(
      (message) {
        if (message is List<int>) {
          if (started.isCompleted && !isClosed) {
            audio.add(Uint8List.fromList(message));
          }
          return;
        }
        final data = _decodeMessage(message);
        if (data == null) return;
        final header = data['header'];
        final event = header is Map ? header['event'] : null;
        switch (event) {
          case 'task-started':
            if (!started.isCompleted) started.complete();
          case 'task-finished':
            closeAudio();
          case 'task-failed':
            final code = header is Map ? header['error_code'] : null;
            final message = header is Map ? header['error_message'] : null;
            fail(
              AiTtsException(
                AiTtsErrorKind.server,
                '语音合成失败${code == null ? '' : '（$code）'}'
                '${message == null ? '' : '：$message'}',
              ),
            );
          default:
            break;
        }
      },
      onError: (Object error) {
        fail(AiTtsException(AiTtsErrorKind.network, '语音合成连接中断：$error'));
      },
      onDone: () {
        fail(const AiTtsException(AiTtsErrorKind.network, '语音合成连接已断开'));
      },
      cancelOnError: false,
    );

    cancelToken?.whenCancel.then((_) {
      if (isClosed) return;
      fail(const AiTtsException(AiTtsErrorKind.cancelled, '语音合成已取消'));
      unawaited(socket.close());
    });

    try {
      socket.add(
        jsonEncode({
          'header': {
            'action': 'run-task',
            'task_id': taskId,
            'streaming': 'duplex',
          },
          'payload': {
            'task_group': 'audio',
            'task': 'tts',
            'function': 'SpeechSynthesizer',
            'model': config.ttsModel,
            'parameters': {
              'text_type': 'PlainText',
              'voice': config.ttsVoice,
              'format': 'pcm',
              'sample_rate': sampleRate,
              'volume': 50,
              'rate': config.ttsRate,
              'pitch': 1.0,
              'language_hints': ['en'],
              'instruction': AliyunTtsClient.instruction,
              'enable_ssml': false,
            },
            'input': <String, dynamic>{},
          },
        }),
      );
      await started.future.timeout(const Duration(seconds: 15));
      final first = firstChunk;
      var senderCancelled = false;
      // 文本流与音频流同时推进：每收到一句就发一个 continue-task，
      // 不等待文本流结束，首句音频才能在 LLM 还在生成时就开始播放。
      final sender = () async {
        try {
          if (!isClosed) {
            socket.add(jsonEncode(_continueTask(taskId, first)));
          }
          while (!senderCancelled && await iterator.moveNext()) {
            if (isClosed) break;
            final normalized = iterator.current.trim();
            if (normalized.isEmpty) continue;
            if (normalized.runes.length > AliyunTtsClient.maxTextLength) {
              fail(
                const AiTtsException(
                  AiTtsErrorKind.badRequest,
                  '朗读文本超过 1000 字符',
                ),
              );
              break;
            }
            socket.add(jsonEncode(_continueTask(taskId, normalized)));
          }
          if (!isClosed && !senderCancelled) {
            socket.add(jsonEncode(_finishTask(taskId)));
          }
        } on Object catch (error) {
          fail(AiTtsException(AiTtsErrorKind.network, '发送朗读文本失败：$error'));
        }
      }();
      try {
        yield* audio.stream;
      } finally {
        senderCancelled = true;
        await iterator.cancel();
        await sender;
      }
    } on TimeoutException {
      throw const AiTtsException(AiTtsErrorKind.network, '语音合成服务未确认任务');
    } finally {
      await subscription.cancel();
      await socket.close();
    }
  }

  static Map<String, dynamic> _continueTask(String taskId, String text) {
    return {
      'header': {
        'action': 'continue-task',
        'task_id': taskId,
        'streaming': 'duplex',
      },
      'payload': {
        'input': {'text': text},
      },
    };
  }

  static Map<String, dynamic> _finishTask(String taskId) {
    return {
      'header': {
        'action': 'finish-task',
        'task_id': taskId,
        'streaming': 'duplex',
      },
      'payload': {'input': <String, dynamic>{}},
    };
  }

  static Map<String, dynamic>? _decodeMessage(Object? message) {
    if (message is! String) return null;
    try {
      final decoded = jsonDecode(message);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }
}
