/// BYOK 服务模型列表测试。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:echo_loop/features/ai_speaking/data/ai_speaking_credential_store.dart';
import 'package:echo_loop/features/ai_speaking/models/ai_llm_provider.dart';
import 'package:echo_loop/features/ai_speaking/models/ai_speaking_settings.dart';
import 'package:echo_loop/services/byok_ai_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this.response);

  final ResponseBody response;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return response;
  }

  @override
  void close({bool force = false}) {}
}

class _FakeCredentialStore extends AiSpeakingCredentialStore {
  _FakeCredentialStore(this.apiKey);

  final String? apiKey;

  @override
  Future<String?> readLlmApiKey(AiLlmProvider provider) async => apiKey;
}

ResponseBody _jsonResponse(Map<String, Object?> body) =>
    ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

void main() {
  test('自定义供应商未选择模型时也能拉取模型列表并按名称排序', () async {
    final adapter = _ScriptedAdapter(
      _jsonResponse({
        'data': [
          {'id': 'qwen-max'},
          {'id': 'qwen-plus'},
          'qwen-turbo',
        ],
      }),
    );
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test'))
      ..httpClientAdapter = adapter;
    addTearDown(() => dio.close(force: true));
    final settings = AiSpeakingSettings.defaults.copyWith(
      llm: const AiLlmConfig(
        provider: AiLlmProvider.custom,
        baseUrl: 'https://example.test/v1',
        model: '',
        temperature: 0.7,
      ),
    );
    final service = ByokAiService(
      readSettings: () => settings,
      credentialStore: _FakeCredentialStore('sk-test'),
      dio: dio,
    );

    final models = await service.listModels();

    expect(models, ['qwen-max', 'qwen-plus', 'qwen-turbo']);
    expect(adapter.requests, hasLength(1));
    expect(
      adapter.requests.single.uri.toString(),
      'https://example.test/v1/models',
    );
    expect(adapter.requests.single.headers['Authorization'], 'Bearer sk-test');
  });

  test('推理强度非 none 时请求体包含 reasoning_effort', () async {
    final adapter = _ScriptedAdapter(
      _jsonResponse({
        'choices': [
          {
            'message': {'content': 'OK'},
          },
        ],
      }),
    );
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test'))
      ..httpClientAdapter = adapter;
    addTearDown(() => dio.close(force: true));
    final settings = AiSpeakingSettings.defaults.copyWith(
      llm: const AiLlmConfig(
        provider: AiLlmProvider.deepSeek,
        baseUrl: 'https://example.test/v1',
        model: 'deepseek-chat',
        temperature: 0.7,
        reasoningEffort: AiReasoningEffort.high,
      ),
    );
    final service = ByokAiService(
      readSettings: () => settings,
      credentialStore: _FakeCredentialStore('sk-test'),
      dio: dio,
    );

    final text = await service.completeText(
      messages: const [
        {'role': 'user', 'content': 'Hi'},
      ],
    );

    expect(text, 'OK');
    final body = adapter.requests.single.data as Map<String, dynamic>;
    expect(body['reasoning_effort'], 'high');
  });

  test('推理强度为 none 时不发送 reasoning_effort', () async {
    final adapter = _ScriptedAdapter(
      _jsonResponse({
        'choices': [
          {
            'message': {'content': 'OK'},
          },
        ],
      }),
    );
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test'))
      ..httpClientAdapter = adapter;
    addTearDown(() => dio.close(force: true));
    final service = ByokAiService(
      readSettings: () => AiSpeakingSettings.defaults,
      credentialStore: _FakeCredentialStore('sk-test'),
      dio: dio,
    );

    await service.completeText(
      messages: const [
        {'role': 'user', 'content': 'Hi'},
      ],
    );

    final body = adapter.requests.single.data as Map<String, dynamic>;
    expect(body.containsKey('reasoning_effort'), isFalse);
  });
}
