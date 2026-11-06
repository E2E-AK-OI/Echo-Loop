/// OpenAI 兼容的大模型流式聊天客户端。
///
/// 只依赖 /chat/completions + SSE，因此 DeepSeek、阿里云百炼、OpenAI 与自定义
/// OpenAI 兼容端点共用同一条实现。
library;

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/ai_speaking_message.dart';
import '../models/ai_speaking_settings.dart';
import 'ai_speaking_prompts.dart';

enum AiChatErrorKind {
  unauthorized,
  rateLimited,
  badRequest,
  network,
  server,
  invalidResponse,
  cancelled,
}

class AiChatException implements Exception {
  const AiChatException(this.kind, this.message, {this.statusCode});

  final AiChatErrorKind kind;
  final String message;
  final int? statusCode;

  @override
  String toString() => 'AiChatException($kind): $message';
}

abstract class AiChatClient {
  Stream<String> streamReply({
    required AiLlmConfig config,
    required String apiKey,
    required List<AiSpeakingMessage> history,
    CancelToken? cancelToken,
  });
}

class HttpOpenAiCompatibleChatClient implements AiChatClient {
  HttpOpenAiCompatibleChatClient({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 60),
            ),
          );

  final Dio _dio;

  @override
  Stream<String> streamReply({
    required AiLlmConfig config,
    required String apiKey,
    required List<AiSpeakingMessage> history,
    CancelToken? cancelToken,
  }) async* {
    final baseUrl = config.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (baseUrl.isEmpty) {
      throw const AiChatException(
        AiChatErrorKind.badRequest,
        '大模型 Base URL 未配置',
      );
    }
    if (apiKey.trim().isEmpty) {
      throw const AiChatException(
        AiChatErrorKind.unauthorized,
        '大模型 API Key 未配置',
      );
    }

    final messages = <Map<String, String>>[
      {'role': 'system', 'content': aiSpeakingSystemPrompt},
      ...history
          .where(
            (message) =>
                message.status != AiSpeakingMessageStatus.error &&
                message.content.trim().isNotEmpty,
          )
          .toList()
          .reversed
          .take(20)
          .toList()
          .reversed
          .map(
            (message) => {
              'role': message.role == AiSpeakingRole.user
                  ? 'user'
                  : 'assistant',
              'content': message.content,
            },
          ),
    ];

    Response<ResponseBody> response;
    try {
      response = await _dio.post<ResponseBody>(
        '$baseUrl/chat/completions',
        data: {
          'model': config.model,
          'messages': messages,
          'temperature': config.temperature,
          'stream': true,
        },
        options: Options(
          responseType: ResponseType.stream,
          headers: {
            'Authorization': 'Bearer ${apiKey.trim()}',
            'Content-Type': 'application/json',
            'Accept': 'text/event-stream',
          },
          validateStatus: (_) => true,
        ),
        cancelToken: cancelToken,
      );
    } on DioException catch (error) {
      throw _mapDioException(error);
    }

    final statusCode = response.statusCode ?? 0;
    if (statusCode < 200 || statusCode >= 300) {
      final body = await _readErrorBody(response.data);
      throw _mapStatus(statusCode, body);
    }

    final bodyStream = response.data?.stream;
    if (bodyStream == null) {
      throw const AiChatException(AiChatErrorKind.invalidResponse, '大模型返回了空响应');
    }

    var receivedDone = false;
    try {
      final lines = bodyStream
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      await for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || !trimmed.startsWith('data:')) continue;
        final payload = trimmed.substring(5).trim();
        if (payload == '[DONE]') {
          receivedDone = true;
          break;
        }
        final content = _parseDeltaContent(payload);
        if (content != null && content.isNotEmpty) yield content;
      }
    } on DioException catch (error) {
      throw _mapDioException(error);
    }

    if (!receivedDone) {
      throw const AiChatException(AiChatErrorKind.invalidResponse, '大模型连接提前结束');
    }
  }

  static String? _parseDeltaContent(String payload) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map) return null;
      final choices = decoded['choices'];
      if (choices is! List || choices.isEmpty) return null;
      final first = choices.first;
      if (first is! Map) return null;
      final delta = first['delta'];
      if (delta is! Map) return null;
      final content = delta['content'];
      return content is String ? content : null;
    } on FormatException {
      return null;
    }
  }

  static Future<String> _readErrorBody(ResponseBody? body) async {
    if (body == null) return '';
    try {
      return await body.stream.cast<List<int>>().transform(utf8.decoder).join();
    } on Object {
      return '';
    }
  }

  static AiChatException _mapStatus(int statusCode, String body) {
    final detail = body.trim();
    final suffix = detail.isEmpty ? '' : '：$detail';
    if (statusCode == 401 || statusCode == 403) {
      return AiChatException(
        AiChatErrorKind.unauthorized,
        'API Key 无效或没有权限$suffix',
        statusCode: statusCode,
      );
    }
    if (statusCode == 429) {
      return AiChatException(
        AiChatErrorKind.rateLimited,
        '请求过于频繁，请稍后再试$suffix',
        statusCode: statusCode,
      );
    }
    if (statusCode == 400) {
      return AiChatException(
        AiChatErrorKind.badRequest,
        '请求参数有误$suffix',
        statusCode: statusCode,
      );
    }
    if (statusCode >= 500) {
      return AiChatException(
        AiChatErrorKind.server,
        '大模型服务暂时不可用$suffix',
        statusCode: statusCode,
      );
    }
    return AiChatException(
      AiChatErrorKind.invalidResponse,
      '大模型返回异常状态 $statusCode$suffix',
      statusCode: statusCode,
    );
  }

  static AiChatException _mapDioException(DioException error) {
    if (CancelToken.isCancel(error)) {
      return const AiChatException(AiChatErrorKind.cancelled, '请求已取消');
    }
    final statusCode = error.response?.statusCode;
    if (statusCode != null) {
      return _mapStatus(statusCode, error.response?.data?.toString() ?? '');
    }
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
        return const AiChatException(
          AiChatErrorKind.network,
          '网络连接失败，请检查网络后重试',
        );
      case DioExceptionType.badResponse:
        return AiChatException(
          AiChatErrorKind.invalidResponse,
          error.message ?? '大模型返回异常响应',
        );
      case DioExceptionType.cancel:
        return const AiChatException(AiChatErrorKind.cancelled, '请求已取消');
      case DioExceptionType.badCertificate:
        return const AiChatException(AiChatErrorKind.network, '安全证书校验失败');
      case DioExceptionType.unknown:
        return AiChatException(
          AiChatErrorKind.network,
          error.message ?? '网络请求失败',
        );
    }
  }
}
