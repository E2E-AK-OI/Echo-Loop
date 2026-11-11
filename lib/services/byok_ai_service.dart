/// 通用 BYOK（Bring Your Own Key）AI 服务。
///
/// 纯端侧模式下所有 AI 能力都直接访问用户配置的 OpenAI 兼容接口，不再经过
/// 自建后端。供应商、Base URL、模型与温度复用 AI 设置，API Key 从安全
/// 存储读取。
library;

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/ai_speaking/data/ai_speaking_credential_store.dart';
import '../features/ai_speaking/models/ai_speaking_settings.dart';
import '../features/ai_speaking/providers/ai_speaking_settings_provider.dart';

/// BYOK 调用错误类型。
enum ByokAiErrorKind {
  missingConfig,
  unauthorized,
  rateLimited,
  badRequest,
  network,
  server,
  invalidResponse,
  cancelled,
}

/// BYOK 调用异常。
class ByokAiException implements Exception {
  final ByokAiErrorKind kind;
  final String message;
  final int? statusCode;

  const ByokAiException(this.kind, this.message, {this.statusCode});

  @override
  String toString() => 'ByokAiException(${kind.name}): $message';
}

/// OpenAI 兼容接口客户端。
class ByokAiService {
  ByokAiService({
    required AiSpeakingSettings Function() readSettings,
    required AiSpeakingCredentialStore credentialStore,
    Dio? dio,
  }) : _readSettings = readSettings,
       _credentialStore = credentialStore,
       _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 15),
               receiveTimeout: const Duration(seconds: 120),
               sendTimeout: const Duration(seconds: 30),
             ),
           );

  final AiSpeakingSettings Function() _readSettings;
  final AiSpeakingCredentialStore _credentialStore;
  final Dio _dio;

  /// 查询当前供应商可用模型列表。
  Future<List<String>> listModels({CancelToken? cancelToken}) async {
    // 刷新模型列表时只需要 Base URL 与 Key，允许尚未选择模型的自定义供应商先拉取列表。
    final resolved = await _resolveConfig(requireModel: false);
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '${_baseUrl(resolved.config.baseUrl)}/models',
        options: Options(
          headers: {'Authorization': 'Bearer ${resolved.apiKey}'},
        ),
        cancelToken: cancelToken,
      );
      final data = response.data;
      final rawList = data?['data'] ?? data?['models'];
      if (rawList is! List) {
        throw const ByokAiException(
          ByokAiErrorKind.invalidResponse,
          '模型列表响应格式不正确',
        );
      }
      final models = <String>[];
      for (final item in rawList) {
        if (item is String && item.trim().isNotEmpty) {
          models.add(item.trim());
        } else if (item is Map) {
          final id = item['id'] ?? item['name'];
          if (id is String && id.trim().isNotEmpty) models.add(id.trim());
        }
      }
      if (models.isEmpty) {
        throw const ByokAiException(
          ByokAiErrorKind.invalidResponse,
          '没有获取到可用模型',
        );
      }
      models.sort();
      return models;
    } on ByokAiException {
      rethrow;
    } on DioException catch (error) {
      throw _mapDioException(error);
    }
  }

  /// 非流式对话，返回完整文本。
  Future<String> completeText({
    required List<Map<String, String>> messages,
    double? temperature,
    CancelToken? cancelToken,
  }) async {
    final resolved = await _resolveConfig();
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '${_baseUrl(resolved.config.baseUrl)}/chat/completions',
        data: {
          'model': resolved.config.model,
          'messages': messages,
          'temperature': temperature ?? resolved.config.temperature,
          'stream': false,
        },
        options: Options(
          headers: {'Authorization': 'Bearer ${resolved.apiKey}'},
        ),
        cancelToken: cancelToken,
      );
      final choices = response.data?['choices'];
      if (choices is! List || choices.isEmpty) {
        throw const ByokAiException(
          ByokAiErrorKind.invalidResponse,
          'AI 返回内容为空',
        );
      }
      final first = choices.first;
      final message = first is Map ? first['message'] : null;
      final content = message is Map ? message['content'] : null;
      if (content is! String) {
        throw const ByokAiException(
          ByokAiErrorKind.invalidResponse,
          'AI 返回内容格式不正确',
        );
      }
      return content;
    } on ByokAiException {
      rethrow;
    } on DioException catch (error) {
      throw _mapDioException(error);
    }
  }

  /// 非流式 JSON 对话，解析为 Map。
  Future<Map<String, dynamic>> completeJson({
    required List<Map<String, String>> messages,
    CancelToken? cancelToken,
  }) async {
    final text = await completeText(
      messages: messages,
      temperature: 0.2,
      cancelToken: cancelToken,
    );
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw const ByokAiException(
        ByokAiErrorKind.invalidResponse,
        'AI 返回内容不是有效 JSON',
      );
    }
    try {
      final decoded = jsonDecode(text.substring(start, end + 1));
      if (decoded is! Map<String, dynamic>) {
        throw const ByokAiException(
          ByokAiErrorKind.invalidResponse,
          'AI 返回 JSON 结构不正确',
        );
      }
      return decoded;
    } on FormatException {
      throw const ByokAiException(
        ByokAiErrorKind.invalidResponse,
        'AI 返回内容不是有效 JSON',
      );
    }
  }

  /// 流式对话，逐段返回增量文本。
  Stream<String> streamText({
    required List<Map<String, String>> messages,
    double? temperature,
    CancelToken? cancelToken,
  }) async* {
    final resolved = await _resolveConfig();
    Response<ResponseBody> response;
    try {
      response = await _dio.post<ResponseBody>(
        '${_baseUrl(resolved.config.baseUrl)}/chat/completions',
        data: {
          'model': resolved.config.model,
          'messages': messages,
          'temperature': temperature ?? resolved.config.temperature,
          'stream': true,
        },
        options: Options(
          responseType: ResponseType.stream,
          validateStatus: (_) => true,
          headers: {'Authorization': 'Bearer ${resolved.apiKey}'},
        ),
        cancelToken: cancelToken,
      );
    } on DioException catch (error) {
      throw _mapDioException(error);
    }

    final body = response.data;
    if (body == null) {
      throw const ByokAiException(ByokAiErrorKind.invalidResponse, 'AI 返回空响应');
    }
    if (response.statusCode != 200) {
      final errorText = await _readBodyText(body);
      throw _mapStatus(response.statusCode ?? 0, _messageFromBody(errorText));
    }

    var producedText = false;
    try {
      final lines = body.stream
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      await for (final line in lines) {
        final trimmed = line.trim();
        if (!trimmed.startsWith('data:')) continue;
        final payload = trimmed.substring(5).trim();
        if (payload.isEmpty) continue;
        if (payload == '[DONE]') break;
        final decoded = jsonDecode(payload);
        if (decoded is! Map<String, dynamic>) continue;
        final choices = decoded['choices'];
        if (choices is! List || choices.isEmpty) continue;
        final first = choices.first;
        if (first is! Map) continue;
        final delta = first['delta'];
        if (delta is! Map) continue;
        final content = delta['content'];
        if (content is String && content.isNotEmpty) {
          producedText = true;
          yield content;
        }
      }
    } on FormatException {
      throw const ByokAiException(
        ByokAiErrorKind.invalidResponse,
        'AI 流式响应格式不正确',
      );
    }
    if (!producedText) {
      throw const ByokAiException(
        ByokAiErrorKind.invalidResponse,
        'AI 没有返回任何内容',
      );
    }
  }

  Future<({AiLlmConfig config, String apiKey})> _resolveConfig({
    bool requireModel = true,
  }) async {
    final settings = _readSettings();
    final config = settings.llm;
    final hasBaseUrl = config.baseUrl.trim().isNotEmpty;
    final hasModel = config.model.trim().isNotEmpty;
    if (!hasBaseUrl || (requireModel && !hasModel)) {
      throw const ByokAiException(
        ByokAiErrorKind.missingConfig,
        '请先在 AI 设置中填写 Base URL 与模型',
      );
    }
    final apiKey = await _credentialStore.readLlmApiKey(config.provider);
    if (apiKey == null || apiKey.trim().isEmpty) {
      throw const ByokAiException(
        ByokAiErrorKind.missingConfig,
        '请先在 AI 设置中填写 API Key',
      );
    }
    return (config: config, apiKey: apiKey.trim());
  }

  String _baseUrl(String value) => value.trim().replaceAll(RegExp(r'/+$'), '');

  Future<String> _readBodyText(ResponseBody body) async {
    try {
      return await utf8.decodeStream(body.stream);
    } catch (_) {
      return '';
    }
  }

  String _messageFromBody(String text) {
    if (text.isEmpty) return '';
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is Map && error['message'] is String) {
          return error['message'] as String;
        }
        if (decoded['message'] is String) return decoded['message'] as String;
      }
    } catch (_) {
      // 忽略无法解析的错误体。
    }
    return text.length > 200 ? text.substring(0, 200) : text;
  }

  ByokAiException _mapDioException(DioException error) {
    if (CancelToken.isCancel(error)) {
      return const ByokAiException(ByokAiErrorKind.cancelled, '请求已取消');
    }
    final status = error.response?.statusCode;
    if (status != null) {
      return _mapStatus(
        status,
        _messageFromBody('${error.response?.data ?? ''}'),
      );
    }
    return const ByokAiException(
      ByokAiErrorKind.network,
      '网络连接失败，请检查网络与 Base URL',
    );
  }

  ByokAiException _mapStatus(int status, String message) {
    final fallback = message.isEmpty ? 'AI 请求失败（HTTP $status）' : message;
    if (status == 401 || status == 403) {
      return ByokAiException(
        ByokAiErrorKind.unauthorized,
        fallback,
        statusCode: status,
      );
    }
    if (status == 429) {
      return ByokAiException(
        ByokAiErrorKind.rateLimited,
        fallback,
        statusCode: status,
      );
    }
    if (status >= 400 && status < 500) {
      return ByokAiException(
        ByokAiErrorKind.badRequest,
        fallback,
        statusCode: status,
      );
    }
    return ByokAiException(
      ByokAiErrorKind.server,
      fallback,
      statusCode: status,
    );
  }
}

/// BYOK AI 服务 Provider。
final byokAiServiceProvider = Provider<ByokAiService>((ref) {
  return ByokAiService(
    readSettings: () => ref.read(aiSpeakingSettingsProvider),
    credentialStore: ref.read(aiSpeakingCredentialStoreProvider),
  );
});
