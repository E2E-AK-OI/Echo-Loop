/// 通用聊天流式客户端（纯端侧 BYOK 版）。
///
/// 不再访问自建后端；直接把聊天历史发给用户配置的 OpenAI 兼容接口。
/// [ChatApi] 抽象保持不变，便于 [FakeChatApiClient] 与测试替换。
library;

import 'dart:async';

import 'package:dio/dio.dart';

import '../../../services/byok_ai_service.dart';
import '../models/chat_message.dart';
import 'ndjson_text_stream.dart';

/// 请求聊天但未登录 / token 失效（保留类型以兼容旧 UI 分支）。
class ChatAuthRequiredException implements Exception {
  const ChatAuthRequiredException();

  @override
  String toString() => 'ChatAuthRequiredException';
}

/// 聊天流式 API 抽象。
abstract interface class ChatApi {
  /// 发起一轮聊天，逐帧 yield 累计全文。
  Stream<ChatTextFrame> streamChat({
    required String endpoint,
    required List<ChatMessage> history,
    required Map<String, Object?> context,
    required String followUpInstruction,
    String? targetLanguage,
    required String accessToken,
    CancelToken? cancelToken,
  });

  /// 释放资源。
  void dispose();
}

/// 通用聊天客户端，使用用户配置的 BYOK 模型。
class ChatApiClient implements ChatApi {
  final ByokAiService? _service;

  ChatApiClient({required ByokAiService byokService}) : _service = byokService;

  /// 测试用：仅保留构造签名，不注入 BYOK 服务时无法发起真实请求。
  ChatApiClient.withDio(
    Dio dio, {
    void Function(String message)? streamLogPrint,
  }) : _service = null;

  @override
  Stream<ChatTextFrame> streamChat({
    required String endpoint,
    required List<ChatMessage> history,
    required Map<String, Object?> context,
    required String followUpInstruction,
    String? targetLanguage,
    required String accessToken,
    CancelToken? cancelToken,
  }) async* {
    final service = _service;
    if (service == null) {
      throw const ByokAiException(ByokAiErrorKind.missingConfig, '聊天客户端未配置');
    }

    final messages = <Map<String, String>>[
      {'role': 'system', 'content': _systemPrompt(context)},
      ...history.map((message) {
        final wire = message.toWire(instruction: followUpInstruction);
        return <String, String>{
          'role': (wire['role'] as String?) ?? 'user',
          'content': (wire['content'] as String?) ?? '',
        };
      }),
    ];

    final buffer = StringBuffer();
    await for (final delta in service.streamText(
      messages: messages,
      cancelToken: cancelToken,
    )) {
      buffer.write(delta);
      yield ChatTextFrame(text: buffer.toString(), isFinal: false);
    }
    yield ChatTextFrame(text: buffer.toString(), isFinal: true);
  }

  String _systemPrompt(Map<String, Object?> context) {
    final sentence = context['sentence'];
    final passage = context['passage'];
    final buffer = StringBuffer(
      '你是英语学习助手，正在帮助用户理解并练习英语句子。'
      '请用简体中文简洁回答，必要时给出英文例句。',
    );
    if (sentence is String && sentence.trim().isNotEmpty) {
      buffer.write('\n当前句子：${sentence.trim()}');
    }
    if (passage is String && passage.trim().isNotEmpty) {
      buffer.write('\n上下文段落：${passage.trim()}');
    }
    return buffer.toString();
  }

  @override
  void dispose() {}
}
