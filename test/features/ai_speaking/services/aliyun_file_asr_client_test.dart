import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:echo_loop/features/ai_speaking/models/ai_speaking_settings.dart';
import 'package:echo_loop/features/ai_speaking/services/aliyun_file_asr_client.dart';
import 'package:echo_loop/features/ai_speaking/services/aliyun_tts_client.dart';
import 'package:flutter_test/flutter_test.dart';

class _SseAdapter implements HttpClientAdapter {
  _SseAdapter(this.body, {this.statusCode = 200});

  final String body;
  final int statusCode;
  RequestOptions? request;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    request = options;
    return ResponseBody(
      Stream.value(Uint8List.fromList(utf8.encode(body))),
      statusCode,
      headers: {
        'content-type': ['text/event-stream'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

AiSpeechConfig _config({String model = AiSpeechConfig.nonRealtimeAsrModel}) {
  return AiSpeechConfig(
    asrModel: model,
    ttsModel: AiSpeechConfig.plusTtsModel,
    ttsVoice: AiSpeechConfig.defaultTtsVoice,
    ttsRate: 1,
    autoPlay: true,
    workspaceId: '',
    realtimeModel: AiSpeechConfig.defaultRealtimeModel,
    realtimeVoice: AiSpeechConfig.defaultRealtimeVoice,
    realtimeTurnDetection: RealtimeTurnDetection.smartTurnV2,
  );
}

void main() {
  test('非实时识别上传 WAV 并用 SSE 逐段返回累积文本', () async {
    final adapter = _SseAdapter(
      'data: {"output":{"text":"Hello"}}\n\n'
      'data: {"output":{"text":"Hello there"}}\n\n'
      'data: [DONE]\n\n',
    );
    final client = AliyunFileAsrClient(dio: Dio()..httpClientAdapter = adapter);

    final results = await client
        .transcribe(
          pcm: Uint8List.fromList(
            List<int>.generate(320, (index) => index % 128),
          ),
          config: _config(),
          apiKey: 'sk-test',
        )
        .toList();

    expect(
      results.where((result) => !result.isFinal).map((result) => result.text),
      ['Hello', 'Hello there'],
    );
    expect(results.last.isFinal, isTrue);
    expect(results.last.text, 'Hello there');
    expect(
      adapter.request?.uri.toString(),
      contains('/multimodal-generation/generation'),
    );
    expect(adapter.request?.headers['X-DashScope-SSE'], 'enable');
    final body = adapter.request?.data as Map<String, dynamic>;
    expect(body['model'], AiSpeechConfig.nonRealtimeAsrModel);
    expect((body['parameters'] as Map)['format'], 'wav');
    final input = body['input'] as Map<String, dynamic>;
    final messages = input['messages'] as List;
    final content = (messages.single as Map)['content'] as List;
    final audio =
        ((content.single as Map)['input_audio'] as Map)['data'] as String;
    expect(audio, startsWith('data:audio/wav;base64,'));
    final wav = base64Decode(audio.substring('data:audio/wav;base64,'.length));
    expect(ascii.decode(wav.sublist(0, 4)), 'RIFF');
    expect(ascii.decode(wav.sublist(8, 12)), 'WAVE');
    expect(wav.length, 44 + 320);
    expect(ByteData.sublistView(wav).getUint32(24, Endian.little), 16000);
  });

  test('非实时识别鉴权失败映射为授权错误', () async {
    final client = AliyunFileAsrClient(
      dio: Dio()
        ..httpClientAdapter = _SseAdapter(
          '{"code":"InvalidApiKey","message":"Invalid API-key provided."}',
          statusCode: 401,
        ),
    );

    await expectLater(
      client.transcribe(
        pcm: Uint8List(4),
        config: _config(),
        apiKey: 'sk-test',
      ),
      emitsError(
        isA<AiTtsException>()
            .having((error) => error.kind, 'kind', AiTtsErrorKind.unauthorized)
            .having((error) => error.statusCode, 'statusCode', 401),
      ),
    );
  });

  test('非实时识别拒绝空音频与空密钥', () async {
    final client = AliyunFileAsrClient(dio: Dio());

    await expectLater(
      client.transcribe(
        pcm: Uint8List(0),
        config: _config(),
        apiKey: 'sk-test',
      ),
      emitsError(
        isA<AiTtsException>().having(
          (error) => error.kind,
          'kind',
          AiTtsErrorKind.badRequest,
        ),
      ),
    );
    await expectLater(
      client.transcribe(pcm: Uint8List(4), config: _config(), apiKey: '  '),
      emitsError(
        isA<AiTtsException>().having(
          (error) => error.kind,
          'kind',
          AiTtsErrorKind.unauthorized,
        ),
      ),
    );
  });
}
