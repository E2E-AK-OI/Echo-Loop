/// OpenAI 兼容流式聊天客户端测试。
///
/// 覆盖 SSE 解析、请求体、错误状态映射与提前断流。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:echo_loop/features/ai_speaking/models/ai_llm_provider.dart';
import 'package:echo_loop/features/ai_speaking/models/ai_speaking_message.dart';
import 'package:echo_loop/features/ai_speaking/models/ai_speaking_settings.dart';
import 'package:echo_loop/features/ai_speaking/services/ai_chat_client.dart';
import 'package:flutter_test/flutter_test.dart';

class _SseAdapter implements HttpClientAdapter {
  _SseAdapter({required this.body, this.statusCode = 200});

  final String body;
  final int statusCode;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
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

AiLlmConfig _config() => const AiLlmConfig(
  provider: AiLlmProvider.deepSeek,
  baseUrl: 'https://api.deepseek.com/v1/',
  model: 'deepseek-chat',
  temperature: 0.6,
);

AiSpeakingMessage _message(
  String id,
  AiSpeakingRole role,
  String content, {
  AiSpeakingMessageStatus status = AiSpeakingMessageStatus.done,
}) {
  return AiSpeakingMessage(
    id: id,
    role: role,
    content: content,
    status: status,
    createdAt: DateTime.utc(2026, 11, 5),
  );
}

void main() {
  test('解析 SSE 增量并在 DONE 后结束', () async {
    final adapter = _SseAdapter(
      body: [
        'data: {"choices":[{"delta":{"content":"Hello"}}]}',
        '',
        'data: {"choices":[{"delta":{"content":" there"}}]}',
        '',
        'data: {"choices":[{"delta":{"content":"!"}}]}',
        '',
        'data: [DONE]',
        '',
      ].join('\n'),
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final client = HttpOpenAiCompatibleChatClient(dio: dio);

    final chunks = await client
        .streamReply(
          config: _config(),
          apiKey: 'key',
          history: [
            _message('u1', AiSpeakingRole.user, 'Hi'),
            _message('a1', AiSpeakingRole.assistant, 'Hello!'),
          ],
        )
        .toList();

    expect(chunks, ['Hello', ' there', '!']);
    final request = adapter.requests.single;
    expect(
      request.uri.toString(),
      'https://api.deepseek.com/v1/chat/completions',
    );
    expect(request.headers['Authorization'], 'Bearer key');
    final body = request.data as Map<String, dynamic>;
    expect(body['model'], 'deepseek-chat');
    expect(body['temperature'], 0.6);
    expect(body['stream'], isTrue);
    expect(body.containsKey('reasoning_effort'), isFalse);
    final messages = body['messages'] as List<dynamic>;
    expect(messages.first['role'], 'system');
    expect(messages.where((item) => item['role'] == 'user').length, 1);
  });

  test('推理强度非 none 时写入 reasoning_effort', () async {
    final adapter = _SseAdapter(body: 'data: [DONE]\n');
    final dio = Dio()..httpClientAdapter = adapter;
    final client = HttpOpenAiCompatibleChatClient(dio: dio);

    await client
        .streamReply(
          config: _config().copyWith(reasoningEffort: AiReasoningEffort.xhigh),
          apiKey: 'key',
          history: [_message('u1', AiSpeakingRole.user, 'Hi')],
        )
        .toList();

    expect(
      (adapter.requests.single.data
          as Map<String, dynamic>)['reasoning_effort'],
      'xhigh',
    );
  });

  test('错误消息与非空校验：error 消息不发送给大模型', () async {
    final adapter = _SseAdapter(body: 'data: [DONE]\n');
    final dio = Dio()..httpClientAdapter = adapter;
    final client = HttpOpenAiCompatibleChatClient(dio: dio);

    await client
        .streamReply(
          config: _config(),
          apiKey: 'key',
          history: [
            _message('u1', AiSpeakingRole.user, 'Question'),
            _message(
              'a1',
              AiSpeakingRole.assistant,
              'failed',
              status: AiSpeakingMessageStatus.error,
            ),
          ],
        )
        .toList();

    final messages =
        (adapter.requests.single.data as Map<String, dynamic>)['messages']
            as List<dynamic>;
    expect(messages.length, 2);
    expect(messages.last['content'], 'Question');
  });

  test('401 映射为 unauthorized', () async {
    final adapter = _SseAdapter(body: '{"error":"bad key"}', statusCode: 401);
    final dio = Dio()..httpClientAdapter = adapter;
    final client = HttpOpenAiCompatibleChatClient(dio: dio);

    expect(
      client
          .streamReply(
            config: _config(),
            apiKey: 'bad',
            history: [_message('u1', AiSpeakingRole.user, 'Hi')],
          )
          .toList(),
      throwsA(
        isA<AiChatException>().having(
          (error) => error.kind,
          'kind',
          AiChatErrorKind.unauthorized,
        ),
      ),
    );
  });

  test('缺少 DONE 时抛 invalidResponse', () async {
    final adapter = _SseAdapter(
      body: 'data: {"choices":[{"delta":{"content":"partial"}}]}\n',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final client = HttpOpenAiCompatibleChatClient(dio: dio);

    expect(
      client
          .streamReply(
            config: _config(),
            apiKey: 'key',
            history: [_message('u1', AiSpeakingRole.user, 'Hi')],
          )
          .toList(),
      throwsA(
        isA<AiChatException>().having(
          (error) => error.kind,
          'kind',
          AiChatErrorKind.invalidResponse,
        ),
      ),
    );
  });

  test('空 Base URL 在发请求前直接报 badRequest', () async {
    final client = HttpOpenAiCompatibleChatClient(dio: Dio());

    expect(
      client
          .streamReply(
            config: const AiLlmConfig(
              provider: AiLlmProvider.custom,
              baseUrl: '   ',
              model: 'm',
              temperature: 0.7,
            ),
            apiKey: 'key',
            history: const [],
          )
          .toList(),
      throwsA(
        isA<AiChatException>().having(
          (error) => error.kind,
          'kind',
          AiChatErrorKind.badRequest,
        ),
      ),
    );
  });
}
