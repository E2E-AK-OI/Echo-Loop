import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:echo_loop/features/ai_speaking/models/ai_speaking_settings.dart';
import 'package:echo_loop/features/ai_speaking/services/qwen_audio_realtime_client.dart';
import 'package:echo_loop/features/ai_speaking/services/realtime_socket.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSocket implements RealtimeSocket {
  final _controller = StreamController<dynamic>.broadcast();
  final List<String> sent = <String>[];
  bool isClosed = false;

  @override
  Stream<dynamic> get messages => _controller.stream;

  @override
  void add(dynamic data) => sent.add(data as String);

  @override
  Future<void> close() async {
    isClosed = true;
    await _controller.close();
  }

  void emit(Map<String, dynamic> event) => _controller.add(jsonEncode(event));

  Map<String, dynamic> eventAt(int index) =>
      jsonDecode(sent[index]) as Map<String, dynamic>;
}

AiSpeechConfig _config({
  String workspaceId = 'ws-test',
  RealtimeTurnDetection turnDetection = RealtimeTurnDetection.smartTurnV2,
  String model = AiSpeechConfig.defaultRealtimeModel,
}) => AiSpeechConfig(
  asrModel: AiSpeechConfig.defaultAsrModel,
  ttsModel: AiSpeechConfig.plusTtsModel,
  ttsVoice: AiSpeechConfig.defaultTtsVoice,
  ttsRate: 1,
  autoPlay: true,
  workspaceId: workspaceId,
  realtimeModel: model,
  realtimeVoice: AiSpeechConfig.defaultRealtimeVoice,
  realtimeTurnDetection: turnDetection,
);

/// 启动会话并模拟服务端确认，返回会话与假连接。
Future<({SpeechToSpeechSession session, _FakeSocket socket})> _start({
  AiSpeechConfig? config,
  List<Object?>? sink,
  String instructions = '',
}) async {
  final socket = _FakeSocket();
  final client = QwenAudioRealtimeClient(
    connector: (url, {headers}) async {
      sink?.add(url);
      sink?.add(headers);
      return socket;
    },
  );
  final future = client.start(
    config: config ?? _config(),
    apiKey: ' dash-key ',
    instructions: instructions,
  );
  await Future<void>.delayed(Duration.zero);
  socket.emit({'type': 'session.created'});
  final session = await future;
  return (session: session, socket: socket);
}

void main() {
  test('配置业务空间时使用空间域名并下发语义判停会话参数', () async {
    final captured = <Object?>[];
    final started = await _start(sink: captured, instructions: 'Be my tutor');

    expect(
      captured[0],
      'wss://ws-test.cn-beijing.maas.aliyuncs.com/api-ws/v1/realtime'
      '?model=qwen-audio-3.1-realtime-flash',
    );
    expect(captured[1], {
      'Authorization': 'Bearer dash-key',
      'X-DashScope-WorkSpace': 'ws-test',
    });
    final update = started.socket.eventAt(0);
    expect(update['type'], 'session.update');
    final session = update['session'] as Map<String, dynamic>;
    expect(session['modalities'], ['text', 'audio']);
    expect(session['voice'], AiSpeechConfig.defaultRealtimeVoice);
    expect(session['input_audio_format'], 'pcm');
    expect(session['output_audio_format'], 'pcm');
    expect(session['instructions'], 'Be my tutor');
    expect(session['turn_detection'], {'type': 'smart_turn_v2'});

    await started.session.close();
  });

  test('未配置业务空间时回退公共域名且 server_vad 使用 800ms 静音', () async {
    final captured = <Object?>[];
    final started = await _start(
      config: _config(
        workspaceId: '  ',
        turnDetection: RealtimeTurnDetection.serverVad,
      ),
      sink: captured,
    );

    expect(
      captured[0],
      'wss://dashscope.aliyuncs.com/api-ws/v1/realtime'
      '?model=qwen-audio-3.1-realtime-flash',
    );
    expect(
      (captured[1] as Map<String, dynamic>).containsKey(
        'X-DashScope-WorkSpace',
      ),
      isFalse,
    );
    final session =
        started.socket.eventAt(0)['session'] as Map<String, dynamic>;
    expect(session['turn_detection'], {
      'type': 'server_vad',
      'threshold': 0.5,
      'silence_duration_ms': 800,
    });

    await started.session.close();
  });

  test('appendPcm 以 base64 帧持续推送麦克风数据', () async {
    final started = await _start();
    final pcm = Uint8List.fromList([1, 2, 3, 4]);

    started.session.appendPcm(pcm);
    started.session.appendPcm(Uint8List(0));

    // 空帧不发送，避免无效事件。
    expect(started.socket.sent.length, 2);
    final append = started.socket.eventAt(1);
    expect(append['type'], 'input_audio_buffer.append');
    expect(base64Decode(append['audio'] as String), pcm);

    await started.session.close();
  });

  test('服务端事件映射为语音到语音事件', () async {
    final started = await _start();
    final events = <SpeechToSpeechEvent>[];
    final subscription = started.session.events.listen(events.add);
    await Future<void>.delayed(Duration.zero);

    started.socket.emit({'type': 'input_audio_buffer.speech_started'});
    started.socket.emit({
      'type': 'conversation.item.input_audio_transcription.delta',
      'text': 'Hel',
    });
    started.socket.emit({
      'type': 'conversation.item.input_audio_transcription.completed',
      'transcript': 'Hello',
    });
    started.socket.emit({
      'type': 'response.audio_transcript.done',
      'transcript': 'Hi there',
    });
    started.socket.emit({
      'type': 'response.audio.delta',
      'delta': base64Encode([9, 8, 7]),
    });
    started.socket.emit({
      'type': 'response.done',
      'response': {'status': 'cancelled'},
    });
    await Future<void>.delayed(Duration.zero);

    expect(events.length, 6);
    expect(events[0], isA<SpeechToSpeechSpeechStarted>());
    expect((events[1] as SpeechToSpeechUserTranscript).text, 'Hel');
    expect((events[1] as SpeechToSpeechUserTranscript).isFinal, isFalse);
    expect((events[2] as SpeechToSpeechUserTranscript).text, 'Hello');
    expect((events[2] as SpeechToSpeechUserTranscript).isFinal, isTrue);
    expect((events[3] as SpeechToSpeechAssistantTranscript).text, 'Hi there');
    expect((events[4] as SpeechToSpeechAudio).pcm, [9, 8, 7]);
    expect((events[5] as SpeechToSpeechResponseDone).cancelled, isTrue);

    await subscription.cancel();
    await started.session.close();
  });

  test('response.created 提供回复 id，音频与文本分片携带同一 id', () async {
    final started = await _start();
    final events = <SpeechToSpeechEvent>[];
    final subscription = started.session.events.listen(events.add);
    await Future<void>.delayed(Duration.zero);

    started.socket.emit({
      'type': 'response.created',
      'response': {'id': 'resp-1'},
    });
    started.socket.emit({
      'type': 'response.audio.delta',
      'response_id': 'resp-1',
      'delta': base64Encode([1, 2]),
    });
    started.socket.emit({
      'type': 'response.audio_transcript.delta',
      'response_id': 'resp-1',
      'delta': 'Hi',
    });
    started.socket.emit({
      'type': 'response.done',
      'response': {'id': 'resp-1', 'status': 'completed'},
    });
    await Future<void>.delayed(Duration.zero);

    expect((events[0] as SpeechToSpeechResponseStarted).responseId, 'resp-1');
    expect((events[1] as SpeechToSpeechAudio).responseId, 'resp-1');
    final transcript = events[2] as SpeechToSpeechAssistantTranscript;
    expect(transcript.responseId, 'resp-1');
    expect(transcript.isFinal, isFalse);
    final done = events[3] as SpeechToSpeechResponseDone;
    expect(done.responseId, 'resp-1');
    expect(done.cancelled, isFalse);

    await subscription.cancel();
    await started.session.close();
  });

  test('cancelResponse 发送取消指令，close 关闭连接', () async {
    final started = await _start();

    await started.session.cancelResponse();
    expect(started.socket.eventAt(1), {'type': 'response.cancel'});

    await started.session.close();
    expect(started.socket.isClosed, isTrue);
  });

  test('服务端 error 事件映射为失败事件并保留原文', () async {
    final started = await _start();
    final events = <SpeechToSpeechEvent>[];
    final subscription = started.session.events.listen(events.add);
    await Future<void>.delayed(Duration.zero);

    started.socket.emit({
      'type': 'error',
      'error': {'message': 'voice not supported'},
    });
    await Future<void>.delayed(Duration.zero);

    expect(
      (events.single as SpeechToSpeechFailure).message,
      'voice not supported',
    );

    await subscription.cancel();
    await started.session.close();
  });
}
