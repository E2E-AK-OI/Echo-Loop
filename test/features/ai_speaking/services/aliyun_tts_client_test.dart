/// 阿里云 DashScope TTS 客户端测试。
///
/// 覆盖请求体、音频下载、30 秒缓存复用与错误响应。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:echo_loop/features/ai_speaking/models/ai_speaking_settings.dart';
import 'package:echo_loop/features/ai_speaking/services/aliyun_tts_client.dart';
import 'package:flutter_test/flutter_test.dart';

class _TtsAdapter implements HttpClientAdapter {
  _TtsAdapter({this.audioUrl = 'https://cdn.example/audio.mp3'});

  final String? audioUrl;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (options.uri.host == 'cdn.example') {
      return ResponseBody(
        Stream.value(Uint8List.fromList([1, 2, 3, 4])),
        200,
        headers: {
          'content-type': ['audio/mpeg'],
        },
      );
    }
    final body = audioUrl == null
        ? <String, dynamic>{'output': <String, dynamic>{}}
        : <String, dynamic>{
            'output': {
              'audio': {'url': audioUrl},
            },
          };
    return ResponseBody(
      Stream.value(Uint8List.fromList(utf8.encode(jsonEncode(body)))),
      200,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

AiSpeechConfig _speech() => const AiSpeechConfig(
  asrModel: AiSpeechConfig.defaultAsrModel,
  ttsModel: AiSpeechConfig.defaultTtsModel,
  ttsVoice: AiSpeechConfig.defaultTtsVoice,
  ttsRate: 1.0,
  autoPlay: true,
  workspaceId: '',
);

void main() {
  test('请求体包含文本、音色与语速，并下载音频到临时缓存', () async {
    final adapter = _TtsAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final tempDir = await Directory.systemTemp.createTemp('ai_tts_test_');
    addTearDown(() => tempDir.delete(recursive: true));
    final client = AliyunTtsClient(
      dio: dio,
      tempDirProvider: () async => tempDir,
    );

    final path = await client.synthesizeToFile(
      text: 'Hello there',
      config: _speech(),
      apiKey: 'dash-key',
    );

    expect(File(path).existsSync(), isTrue);
    expect(adapter.requests.length, 2);
    final synthesisRequest = adapter.requests.first;
    expect(
      synthesisRequest.uri.toString(),
      'https://dashscope.aliyuncs.com/api/v1/services/audio/tts/SpeechSynthesizer',
    );
    expect(synthesisRequest.headers['Authorization'], 'Bearer dash-key');
    final body = synthesisRequest.data as Map<String, dynamic>;
    expect(body['model'], AiSpeechConfig.defaultTtsModel);
    final input = body['input'] as Map<String, dynamic>;
    expect(input['text'], 'Hello there');
    expect(input['voice'], AiSpeechConfig.defaultTtsVoice);
    expect(input['format'], 'mp3');
    expect(input['rate'], 1.0);
  });

  test('相同文本与音色第二次调用命中本地缓存', () async {
    final adapter = _TtsAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final tempDir = await Directory.systemTemp.createTemp('ai_tts_cache_test_');
    addTearDown(() => tempDir.delete(recursive: true));
    final client = AliyunTtsClient(
      dio: dio,
      tempDirProvider: () async => tempDir,
    );

    final first = await client.synthesizeToFile(
      text: 'Repeat me',
      config: _speech(),
      apiKey: 'dash-key',
    );
    final second = await client.synthesizeToFile(
      text: 'Repeat me',
      config: _speech(),
      apiKey: 'dash-key',
    );

    expect(second, first);
    expect(adapter.requests.length, 2);
  });

  test('响应缺少音频地址时抛 invalidResponse', () async {
    final adapter = _TtsAdapter(audioUrl: null);
    final dio = Dio()..httpClientAdapter = adapter;
    final tempDir = await Directory.systemTemp.createTemp('ai_tts_bad_test_');
    addTearDown(() => tempDir.delete(recursive: true));
    final client = AliyunTtsClient(
      dio: dio,
      tempDirProvider: () async => tempDir,
    );

    expect(
      client.synthesizeToFile(
        text: 'Hello',
        config: _speech(),
        apiKey: 'dash-key',
      ),
      throwsA(
        isA<AiTtsException>().having(
          (error) => error.kind,
          'kind',
          AiTtsErrorKind.invalidResponse,
        ),
      ),
    );
  });

  test('超过 1000 字符直接 badRequest，不发起网络请求', () async {
    final adapter = _TtsAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final tempDir = await Directory.systemTemp.createTemp('ai_tts_long_test_');
    addTearDown(() => tempDir.delete(recursive: true));
    final client = AliyunTtsClient(
      dio: dio,
      tempDirProvider: () async => tempDir,
    );

    expect(
      client.synthesizeToFile(
        text: 'a' * 1001,
        config: _speech(),
        apiKey: 'dash-key',
      ),
      throwsA(
        isA<AiTtsException>().having(
          (error) => error.kind,
          'kind',
          AiTtsErrorKind.badRequest,
        ),
      ),
    );
    expect(adapter.requests, isEmpty);
  });
}
