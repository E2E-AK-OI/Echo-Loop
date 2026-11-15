/// 阿里云实时语音识别客户端协议测试。
///
/// 使用假 WebSocket 验证 run-task 参数、finish-task 的 streaming 字段、
/// 心跳包过滤与最终文本拼接，不依赖真实网络。
library;

import 'dart:async';
import 'dart:convert';

import 'package:echo_loop/features/ai_speaking/models/ai_speaking_settings.dart';
import 'package:echo_loop/features/ai_speaking/services/aliyun_realtime_asr_client.dart';
import 'package:echo_loop/features/ai_speaking/services/realtime_socket.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAsrSocket implements RealtimeSocket {
  final _controller = StreamController<dynamic>();
  final sent = <Map<String, dynamic>>[];
  var closed = false;

  @override
  Stream<dynamic> get messages => _controller.stream;

  @override
  void add(dynamic data) {
    sent.add(jsonDecode(data as String) as Map<String, dynamic>);
  }

  @override
  Future<void> close() async {
    closed = true;
    await _controller.close();
  }

  void emit(Map<String, dynamic> event) {
    _controller.add(jsonEncode(event));
  }
}

const _config = AiSpeechConfig(
  asrModel: 'qwen-audio-3.1-asr-flash-streaming',
  ttsModel: 'qwen-audio-3.1-tts-plus',
  ttsVoice: 'longanlingxin_v3.1',
  ttsRate: 1,
  autoPlay: true,
  workspaceId: 'ws-test',
  realtimeModel: AiSpeechConfig.defaultRealtimeModel,
  realtimeVoice: AiSpeechConfig.defaultRealtimeVoice,
  realtimeTurnDetection: RealtimeTurnDetection.smartTurnV2,
);

Map<String, dynamic> _event(String name, [Map<String, dynamic>? payload]) => {
  'header': {
    'task_id': 'task-1',
    'event': name,
    'attributes': <String, dynamic>{},
  },
  'payload': payload ?? <String, dynamic>{},
};

Map<String, dynamic> _sentence(
  String text, {
  required bool sentenceEnd,
  bool heartbeat = false,
  int sentenceId = 1,
  bool sentenceBegin = false,
}) => {
  'output': {
    'sentence': {
      'text': text,
      'sentence_end': sentenceEnd,
      'sentence_begin': sentenceBegin,
      'sentence_id': heartbeat ? 0 : sentenceId,
      'heartbeat': heartbeat,
    },
  },
};

Future<({RealtimeAsrSession session, _FakeAsrSocket socket})>
_startSession() async {
  final socket = _FakeAsrSocket();
  final client = AliyunRealtimeAsrClient(
    connector: (url, {headers}) async => socket,
  );
  final startFuture = client.start(config: _config, apiKey: 'asr-key');
  await pumpEventQueue();
  socket.emit(_event('task-started'));
  return (session: await startFuture, socket: socket);
}

void main() {
  test('run-task 携带工作空间地址、鉴权头与识别参数', () async {
    final socket = _FakeAsrSocket();
    String? connectedUrl;
    Map<String, dynamic>? connectedHeaders;
    final client = AliyunRealtimeAsrClient(
      connector: (url, {headers}) async {
        connectedUrl = url;
        connectedHeaders = headers;
        return socket;
      },
    );

    final startFuture = client.start(config: _config, apiKey: ' asr-key ');
    await pumpEventQueue();
    socket.emit(_event('task-started'));
    final session = await startFuture;

    expect(
      connectedUrl,
      'wss://ws-test.cn-beijing.maas.aliyuncs.com/api-ws/v1/inference',
    );
    expect(connectedHeaders?['Authorization'], 'Bearer asr-key');
    expect(connectedHeaders?['X-DashScope-WorkSpace'], 'ws-test');
    final runTask = socket.sent.single;
    expect(runTask['header']['action'], 'run-task');
    expect(runTask['header']['streaming'], 'duplex');
    expect(runTask['payload']['parameters']['format'], 'pcm');
    expect(runTask['payload']['parameters']['sample_rate'], 16000);

    await session.cancel();
    expect(socket.closed, isTrue);
  });

  test('finish-task 携带 streaming 并过滤心跳包', () async {
    final socket = _FakeAsrSocket();
    final client = AliyunRealtimeAsrClient(
      connector: (url, {headers}) async => socket,
    );

    final startFuture = client.start(config: _config, apiKey: 'asr-key');
    await pumpEventQueue();
    socket.emit(_event('task-started'));
    final session = await startFuture;
    final events = <AsrTranscriptEvent>[];
    session.events.listen(events.add);

    socket.emit(
      _event(
        'result-generated',
        _sentence('心跳文本', sentenceEnd: true, heartbeat: true),
      ),
    );
    socket.emit(
      _event('result-generated', _sentence('Hello', sentenceEnd: false)),
    );
    socket.emit(
      _event('result-generated', _sentence('Hello world', sentenceEnd: true)),
    );
    await pumpEventQueue();
    expect(events.map((event) => event.text).toList(), [
      'Hello',
      'Hello world',
    ]);
    expect(events.last.isFinal, isTrue);

    final finishFuture = session.finish();
    socket.emit(_event('task-finished'));
    final text = await finishFuture;

    expect(text, 'Hello world');
    final finishTask = socket.sent.last;
    expect(finishTask['header']['action'], 'finish-task');
    expect(finishTask['header']['streaming'], 'duplex');
    expect(finishTask['payload']['input'], isEmpty);
    expect(socket.closed, isTrue);
  });

  test('中间结果按增量下发且没有最终包时保留整句前文', () async {
    final (:session, :socket) = await _startSession();

    socket.emit(_event('result-generated', _sentence('你', sentenceEnd: false)));
    socket.emit(_event('result-generated', _sentence('好', sentenceEnd: false)));
    await pumpEventQueue();

    final finishFuture = session.finish();
    socket.emit(_event('task-finished'));

    expect(await finishFuture, '你好');
  });

  test('最终结果按整句覆盖，不重复拼接中间增量片段', () async {
    final (:session, :socket) = await _startSession();

    socket.emit(
      _event('result-generated', _sentence('Hel', sentenceEnd: false)),
    );
    socket.emit(
      _event('result-generated', _sentence('lo', sentenceEnd: false)),
    );
    socket.emit(
      _event('result-generated', _sentence('Hello', sentenceEnd: true)),
    );
    await pumpEventQueue();

    final finishFuture = session.finish();
    socket.emit(_event('task-finished'));

    expect(await finishFuture, 'Hello');
  });

  test('跨句按 sentence_id 切换并把前句并入完整转写', () async {
    final (:session, :socket) = await _startSession();

    socket.emit(
      _event(
        'result-generated',
        _sentence('Hello', sentenceEnd: true, sentenceId: 1),
      ),
    );
    socket.emit(
      _event(
        'result-generated',
        _sentence(
          'World',
          sentenceEnd: false,
          sentenceId: 2,
          sentenceBegin: true,
        ),
      ),
    );
    await pumpEventQueue();

    final finishFuture = session.finish();
    socket.emit(_event('task-finished'));

    expect(await finishFuture, 'Hello World');
  });

  test('task-failed 将错误传给调用方', () async {
    final socket = _FakeAsrSocket();
    final client = AliyunRealtimeAsrClient(
      connector: (url, {headers}) async => socket,
    );

    final startFuture = client.start(config: _config, apiKey: 'bad-key');
    await pumpEventQueue();
    socket.emit({
      'header': {
        'task_id': 'task-1',
        'event': 'task-failed',
        'error_code': 'CLIENT_ERROR',
        'error_message': 'request timeout',
        'attributes': <String, dynamic>{},
      },
      'payload': <String, dynamic>{},
    });

    await expectLater(
      startFuture,
      throwsA(
        isA<AliyunAsrException>()
            .having((error) => error.code, 'code', 'CLIENT_ERROR')
            .having((error) => error.message, 'message', 'request timeout'),
      ),
    );
  });
}
