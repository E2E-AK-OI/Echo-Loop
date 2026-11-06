/// 阿里云 DashScope 语音合成客户端。
///
/// v1 使用非实时 HTTP 接口：请求合成后得到 output.audio.url，再下载到临时目录。
/// 同一文本、模型、音色与语速会命中本地缓存，减少重复费用和等待。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import '../models/ai_speaking_settings.dart';

enum AiTtsErrorKind {
  unauthorized,
  badRequest,
  network,
  server,
  invalidResponse,
  cancelled,
}

class AiTtsException implements Exception {
  const AiTtsException(this.kind, this.message, {this.statusCode});

  final AiTtsErrorKind kind;
  final String message;
  final int? statusCode;

  @override
  String toString() => 'AiTtsException($kind): $message';
}

abstract class AiTtsClient {
  Future<String> synthesizeToFile({
    required String text,
    required AiSpeechConfig config,
    required String apiKey,
    CancelToken? cancelToken,
  });
}

class AliyunTtsClient implements AiTtsClient {
  AliyunTtsClient({Dio? dio, Future<Directory> Function()? tempDirProvider})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 60),
            ),
          ),
      _tempDirProvider = tempDirProvider ?? getTemporaryDirectory;

  static const instruction =
      'Speak in natural, clear American English for an English learner.';
  static const maxTextLength = 1000;

  final Dio _dio;
  final Future<Directory> Function() _tempDirProvider;

  @override
  Future<String> synthesizeToFile({
    required String text,
    required AiSpeechConfig config,
    required String apiKey,
    CancelToken? cancelToken,
  }) async {
    final normalized = text.trim();
    if (normalized.isEmpty) {
      throw const AiTtsException(AiTtsErrorKind.badRequest, '朗读文本不能为空');
    }
    if (normalized.runes.length > maxTextLength) {
      throw const AiTtsException(AiTtsErrorKind.badRequest, '朗读文本超过 1000 字符');
    }
    if (apiKey.trim().isEmpty) {
      throw const AiTtsException(
        AiTtsErrorKind.unauthorized,
        'DashScope API Key 未配置',
      );
    }

    final cacheFile = await _cacheFileFor(normalized, config);
    if (await cacheFile.exists() && await cacheFile.length() > 0) {
      return cacheFile.path;
    }

    final workspace = config.workspaceId.trim();
    final endpoint = workspace.isEmpty
        ? 'https://dashscope.aliyuncs.com/api/v1/services/audio/tts/SpeechSynthesizer'
        : 'https://$workspace.cn-beijing.maas.aliyuncs.com/api/v1/services/audio/tts/SpeechSynthesizer';

    Response<dynamic> response;
    try {
      response = await _dio.post<dynamic>(
        endpoint,
        data: {
          'model': config.ttsModel,
          'input': {
            'text': normalized,
            'voice': config.ttsVoice,
            'format': 'mp3',
            'sample_rate': 24000,
            'volume': 50,
            'rate': config.ttsRate,
            'pitch': 1.0,
            'language_hints': ['en'],
            'instruction': instruction,
          },
        },
        options: Options(
          responseType: ResponseType.json,
          headers: {
            'Authorization': 'Bearer ${apiKey.trim()}',
            'Content-Type': 'application/json',
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
      throw _mapStatus(statusCode, _stringify(response.data));
    }
    final audioUrl = _extractAudioUrl(response.data);
    if (audioUrl == null || audioUrl.isEmpty) {
      throw const AiTtsException(
        AiTtsErrorKind.invalidResponse,
        '语音合成响应缺少音频地址',
      );
    }

    Response<List<int>> audioResponse;
    try {
      audioResponse = await _dio.get<List<int>>(
        audioUrl,
        options: Options(
          responseType: ResponseType.bytes,
          validateStatus: (_) => true,
        ),
        cancelToken: cancelToken,
      );
    } on DioException catch (error) {
      throw _mapDioException(error);
    }
    final audioStatus = audioResponse.statusCode ?? 0;
    if (audioStatus < 200 || audioStatus >= 300) {
      throw _mapStatus(audioStatus, '');
    }
    final bytes = audioResponse.data;
    if (bytes == null || bytes.isEmpty) {
      throw const AiTtsException(AiTtsErrorKind.invalidResponse, '下载到的音频为空');
    }

    await cacheFile.parent.create(recursive: true);
    final tempFile = File('${cacheFile.path}.part');
    await tempFile.writeAsBytes(bytes, flush: true);
    await tempFile.rename(cacheFile.path);
    return cacheFile.path;
  }

  Future<File> _cacheFileFor(String text, AiSpeechConfig config) async {
    final baseDirectory = await _tempDirProvider();
    final cacheDirectory = Directory(
      '${baseDirectory.path}${Platform.pathSeparator}ai_speaking_tts',
    );
    final cacheKey = jsonEncode([
      text,
      config.ttsModel,
      config.ttsVoice,
      config.ttsRate,
      instruction,
    ]);
    final hash = sha256.convert(utf8.encode(cacheKey)).toString();
    return File('${cacheDirectory.path}${Platform.pathSeparator}$hash.mp3');
  }

  static String? _extractAudioUrl(Object? data) {
    final decoded = _decodeJson(data);
    if (decoded is! Map) return null;
    final output = decoded['output'];
    if (output is! Map) return null;
    final audio = output['audio'];
    if (audio is! Map) return null;
    final url = audio['url'];
    return url is String ? url : null;
  }

  static Object? _decodeJson(Object? data) {
    if (data is String) {
      try {
        return jsonDecode(data);
      } on FormatException {
        return null;
      }
    }
    return data;
  }

  static String _stringify(Object? data) {
    if (data == null) return '';
    if (data is String) return data;
    try {
      return jsonEncode(data);
    } on Object {
      return data.toString();
    }
  }

  static AiTtsException _mapStatus(int statusCode, String body) {
    final detail = body.trim();
    final suffix = detail.isEmpty ? '' : '：$detail';
    if (statusCode == 401 || statusCode == 403) {
      return AiTtsException(
        AiTtsErrorKind.unauthorized,
        'DashScope API Key 无效或没有权限$suffix',
        statusCode: statusCode,
      );
    }
    if (statusCode == 400) {
      return AiTtsException(
        AiTtsErrorKind.badRequest,
        '语音合成请求参数有误$suffix',
        statusCode: statusCode,
      );
    }
    if (statusCode >= 500) {
      return AiTtsException(
        AiTtsErrorKind.server,
        '语音合成服务暂时不可用$suffix',
        statusCode: statusCode,
      );
    }
    return AiTtsException(
      AiTtsErrorKind.invalidResponse,
      '语音合成服务返回异常状态 $statusCode$suffix',
      statusCode: statusCode,
    );
  }

  static AiTtsException _mapDioException(DioException error) {
    if (CancelToken.isCancel(error)) {
      return const AiTtsException(AiTtsErrorKind.cancelled, '语音合成已取消');
    }
    final statusCode = error.response?.statusCode;
    if (statusCode != null) {
      return _mapStatus(statusCode, _stringify(error.response?.data));
    }
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
        return const AiTtsException(AiTtsErrorKind.network, '网络连接失败，请检查网络后重试');
      case DioExceptionType.cancel:
        return const AiTtsException(AiTtsErrorKind.cancelled, '语音合成已取消');
      case DioExceptionType.badResponse:
        return AiTtsException(
          AiTtsErrorKind.invalidResponse,
          error.message ?? '语音合成返回异常响应',
        );
      case DioExceptionType.badCertificate:
        return const AiTtsException(AiTtsErrorKind.network, '安全证书校验失败');
      case DioExceptionType.unknown:
        return AiTtsException(
          AiTtsErrorKind.network,
          error.message ?? '语音合成网络请求失败',
        );
    }
  }
}
