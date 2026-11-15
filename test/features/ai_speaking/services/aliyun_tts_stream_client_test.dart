/// 阿里云 DashScope 流式语音合成客户端测试。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:echo_loop/features/ai_speaking/models/ai_speaking_settings.dart';
import 'package:echo_loop/features/ai_speaking/services/aliyun_tts_client.dart';
import 'package:echo_loop/features/ai_speaking/services/aliyun_tts_stream_client.dart';
import 'package:echo_loop/features/ai_speaking/services/realtime_socket.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeTtsSocket implements RealtimeSocket {
  final _messages = StreamController<dynamic>();
  final sent = <Map<String, dynamic>>[];

  @override
  Stream<dynamic> get messages => _messages.stream;

  @override
  void add(dynamic data) {
    final decoded = jsonDecode(data as String) as Map<String, dynamic>;
    sent.add(decoded);
    final action = (decoded['header'] as Map)['action'];
    switch (action) {
      case 'run-task':
        _messages.add(
          jsonEncode({
            'header': {'event': 'task-started', 'task_id': 'task-1'},
          }),
        );
      case 'continue-task':
        _messages.add(Uint8List.fromList([1, 2]));
        _messages.add(
          jsonEncode({
            'header': {'event': 'result-generated'},
            'payload': {
              'output': {'type': 'sentence-synthesis'},
            },
          }),
        );
        _messages.add(Uint8List.fromList([3, 4]));
      case 'finish-task':
        _messages.add(
          jsonEncode({
            'header': {'event': 'task-finished', 'task_id': 'task-1'},
          }),
        );
        unawaited(_messages.close());
    }
  }

  @override
  Future<void> close() async {
    if (!_messages.isClosed) await _messages.close();
  }
}

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('等待测试条件超时');
    await Future<void>.delayed(Duration.zero);
  }
}

AiSpeechConfig _speech({String workspaceId = ''}) => AiSpeechConfig(
  asrModel: AiSpeechConfig.defaultAsrModel,
  ttsModel: AiSpeechConfig.plusTtsModel,
  ttsVoice: AiSpeechConfig.defaultTtsVoice,
  ttsRate: 1.1,
  autoPlay: true,
  workspaceId: workspaceId,
  realtimeModel: AiSpeechConfig.defaultRealtimeModel,
  realtimeVoice: AiSpeechConfig.defaultRealtimeVoice,
  realtimeTurnDetection: RealtimeTurnDetection.smartTurnV2,
);

void main() {
  test('按 run-task/continue-task/finish-task 顺序合成并透传 PCM 分片', () async {
    final socket = _FakeTtsSocket();
    String? connectedUrl;
    Map<String, dynamic>? connectedHeaders;
    final client = AliyunTtsStreamClient(
      connector: (url, {headers}) async {
        connectedUrl = url;
        connectedHeaders = headers;
        return socket;
      },
    );

    final chunks = await client
        .synthesizeStream(
          text: ' Hello there ',
          config: _speech(),
          apiKey: ' dash-key ',
        )
        .toList();

    expect(connectedUrl, 'wss://dashscope.aliyuncs.com/api-ws/v1/inference');
    expect(connectedHeaders?['Authorization'], 'Bearer dash-key');
    expect(socket.sent.map((message) => (message['header'] as Map)['action']), [
      'run-task',
      'continue-task',
      'finish-task',
    ]);

    final runTask = socket.sent.first['payload'] as Map<String, dynamic>;
    expect(runTask['model'], AiSpeechConfig.plusTtsModel);
    expect(runTask['task'], 'tts');
    final parameters = runTask['parameters'] as Map<String, dynamic>;
    expect(parameters['format'], 'pcm');
    expect(parameters['sample_rate'], 24000);
    expect(parameters['voice'], AiSpeechConfig.defaultTtsVoice);
    expect(parameters['rate'], 1.1);

    final continueTask = socket.sent[1]['payload'] as Map<String, dynamic>;
    expect((continueTask['input'] as Map)['text'], 'Hello there');

    expect(chunks.map((chunk) => chunk.toList()), [
      [1, 2],
      [3, 4],
    ]);
  });

  test('文本流未结束时就发送首句 continue-task，后续句子继续送入', () async {
    final socket = _FakeTtsSocket();
    final input = StreamController<String>();
    final client = AliyunTtsStreamClient(
      connector: (url, {headers}) async => socket,
    );

    final future = client
        .synthesizeChunks(
          textChunks: input.stream,
          config: _speech(),
          apiKey: 'dash-key',
        )
        .toList();
    input.add('First.');
    // 首句发送后文本流仍保持打开，证明合成没有等待完整回复。
    await _waitUntil(() => socket.sent.length >= 2);
    expect(input.isClosed, isFalse);
    input.add('Second.');
    await input.close();

    final chunks = await future;
    expect(socket.sent.map((message) => (message['header'] as Map)['action']), [
      'run-task',
      'continue-task',
      'continue-task',
      'finish-task',
    ]);
    final texts = socket.sent
        .where(
          (message) => (message['header'] as Map)['action'] == 'continue-task',
        )
        .map(
          (message) => ((message['payload'] as Map)['input'] as Map)['text'],
        );
    expect(texts, <String>['First.', 'Second.']);
    expect(chunks.map((chunk) => chunk.toList()), [
      [1, 2],
      [3, 4],
      [1, 2],
      [3, 4],
    ]);
  });

  test('文本流未结束时取消会立即结束合成而不是等待下一句', () async {
    final socket = _FakeTtsSocket();
    final input = StreamController<String>();
    final cancelToken = CancelToken();
    final client = AliyunTtsStreamClient(
      connector: (url, {headers}) async => socket,
    );

    final result = client
        .synthesizeChunks(
          textChunks: input.stream,
          config: _speech(),
          apiKey: 'dash-key',
          cancelToken: cancelToken,
        )
        .toList();
    final expectation = expectLater(
      result,
      throwsA(
        isA<AiTtsException>().having(
          (error) => error.kind,
          'kind',
          AiTtsErrorKind.cancelled,
        ),
      ),
    );
    input.add('First.');
    await _waitUntil(() => socket.sent.length >= 2);

    cancelToken.cancel();
    await expectation;
    await input.close();
  });

  test('配置工作空间时使用空间域名并带 X-DashScope-WorkSpace', () async {
    final socket = _FakeTtsSocket();
    String? connectedUrl;
    Map<String, dynamic>? connectedHeaders;
    final client = AliyunTtsStreamClient(
      connector: (url, {headers}) async {
        connectedUrl = url;
        connectedHeaders = headers;
        return socket;
      },
    );

    await client
        .synthesizeStream(
          text: 'Hello',
          config: _speech(workspaceId: 'ws-123'),
          apiKey: 'dash-key',
        )
        .toList();

    expect(
      connectedUrl,
      'wss://ws-123.cn-beijing.maas.aliyuncs.com/api-ws/v1/inference',
    );
    expect(connectedHeaders?['X-DashScope-WorkSpace'], 'ws-123');
  });

  test('服务端 task-failed 时抛出带错误码的 AiTtsException', () async {
    final socket = _FakeTtsSocket();
    // 覆盖 run-task 的默认回包，直接返回失败事件。
    final failing = _FailingTtsSocket(socket);
    final client = AliyunTtsStreamClient(
      connector: (url, {headers}) async => failing,
    );

    await expectLater(
      client
          .synthesizeStream(
            text: 'Hello',
            config: _speech(),
            apiKey: 'dash-key',
          )
          .toList(),
      throwsA(
        isA<AiTtsException>()
            .having((error) => error.kind, 'kind', AiTtsErrorKind.server)
            .having((error) => error.message, 'message', contains('BadVoice')),
      ),
    );
  });

  test('请求前校验空文本与缺失 API Key', () async {
    final client = AliyunTtsStreamClient(
      connector: (url, {headers}) async => _FakeTtsSocket(),
    );

    await expectLater(
      client
          .synthesizeStream(text: '  ', config: _speech(), apiKey: 'x')
          .toList(),
      throwsA(isA<AiTtsException>()),
    );
    await expectLater(
      client
          .synthesizeStream(text: 'Hello', config: _speech(), apiKey: ' ')
          .toList(),
      throwsA(isA<AiTtsException>()),
    );
  });
}

class _FailingTtsSocket implements RealtimeSocket {
  _FailingTtsSocket(this._delegate);

  final _FakeTtsSocket _delegate;
  final _messages = StreamController<dynamic>();

  @override
  Stream<dynamic> get messages => _messages.stream;

  @override
  void add(dynamic data) {
    _delegate.add(data);
    _messages.add(
      jsonEncode({
        'header': {
          'event': 'task-failed',
          'error_code': 'BadVoice',
          'error_message': 'voice is not supported',
        },
      }),
    );
  }

  @override
  Future<void> close() async {
    if (!_messages.isClosed) await _messages.close();
  }
}
