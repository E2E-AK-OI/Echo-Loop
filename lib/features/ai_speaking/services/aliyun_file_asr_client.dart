/// 阿里云 DashScope 非实时语音识别客户端。
///
/// 与实时 WebSocket 识别不同，非实时模型一次上传整段 WAV，服务端通过
/// SSE 依次返回累积文本，适合在一轮说话结束后做高精度整段转写。
/// 协议参考：https://docs.bailian.console.aliyun.com/zh/model-studio/non-realtime-speech-recognition-user-guide
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../models/ai_speaking_settings.dart';
import 'aliyun_tts_client.dart';

/// 一轮整段识别中的一个结果；[isFinal] 为 true 时是最终文本。
class FileAsrResult {
  const FileAsrResult(this.text, {required this.isFinal});

  final String text;
  final bool isFinal;
}

abstract class FileAsrClient {
  Stream<FileAsrResult> transcribe({
    required Uint8List pcm,
    required AiSpeechConfig config,
    required String apiKey,
    CancelToken? cancelToken,
  });
}

class AliyunFileAsrClient implements FileAsrClient {
  AliyunFileAsrClient({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 120),
            ),
          );

  static const sampleRate = 16000;

  final Dio _dio;

  @override
  Stream<FileAsrResult> transcribe({
    required Uint8List pcm,
    required AiSpeechConfig config,
    required String apiKey,
    CancelToken? cancelToken,
  }) async* {
    if (pcm.isEmpty) {
      throw const AiTtsException(AiTtsErrorKind.badRequest, '识别音频不能为空');
    }
    if (apiKey.trim().isEmpty) {
      throw const AiTtsException(
        AiTtsErrorKind.unauthorized,
        'DashScope API Key 未配置',
      );
    }

    final workspace = config.workspaceId.trim();
    final host = workspace.isEmpty
        ? 'dashscope.aliyuncs.com'
        : '$workspace.cn-beijing.maas.aliyuncs.com';
    final endpoint =
        'https://$host/api/v1/services/aigc/multimodal-generation/generation';
    final audio = base64Encode(_wrapWav(pcm));
    final headers = <String, dynamic>{
      'Authorization': 'Bearer ${apiKey.trim()}',
      'Content-Type': 'application/json',
      'X-DashScope-SSE': 'enable',
    };
    if (workspace.isNotEmpty) {
      headers['X-DashScope-WorkSpace'] = workspace;
    }

    Response<ResponseBody> response;
    try {
      response = await _dio.post<ResponseBody>(
        endpoint,
        data: {
          'model': config.asrModel,
          'input': {
            'messages': [
              {
                'role': 'user',
                'content': [
                  {
                    'type': 'input_audio',
                    'input_audio': {'data': 'data:audio/wav;base64,$audio'},
                  },
                ],
              },
            ],
          },
          'parameters': {'format': 'wav', 'sample_rate': '$sampleRate'},
        },
        options: Options(
          responseType: ResponseType.stream,
          headers: headers,
          validateStatus: (_) => true,
        ),
        cancelToken: cancelToken,
      );
    } on DioException catch (error) {
      throw _mapDioException(error);
    }

    final statusCode = response.statusCode ?? 0;
    final body = response.data;
    if (statusCode < 200 || statusCode >= 300) {
      final detail = body == null ? '' : await _readAll(body.stream);
      throw _mapStatus(statusCode, detail);
    }
    if (body == null) {
      throw const AiTtsException(AiTtsErrorKind.invalidResponse, '语音识别响应为空');
    }

    var lastText = '';
    final lines = body.stream
        .map<List<int>>((chunk) => chunk)
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in lines) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('data:')) continue;
      final payload = trimmed.substring(5).trim();
      if (payload.isEmpty || payload == '[DONE]') continue;
      final data = _decode(payload);
      if (data == null) continue;
      final output = data['output'];
      if (output is! Map) continue;
      final text = _extractText(output);
      if (text.isEmpty || text == lastText) continue;
      lastText = text;
      yield FileAsrResult(text, isFinal: false);
    }
    if (lastText.isNotEmpty) {
      yield FileAsrResult(lastText, isFinal: true);
    }
  }

  static String _extractText(Map output) {
    final text = output['text'];
    if (text is String && text.trim().isNotEmpty) return text.trim();
    final sentence = output['sentence'];
    if (sentence is Map) {
      final sentenceText = sentence['text'];
      if (sentenceText is String) return sentenceText.trim();
    }
    if (sentence is List) {
      final parts = <String>[];
      for (final item in sentence) {
        if (item is Map) {
          final sentenceText = item['text'];
          if (sentenceText is String && sentenceText.trim().isNotEmpty) {
            parts.add(sentenceText.trim());
          }
        }
      }
      return parts.join().trim();
    }
    return '';
  }

  /// 把 16kHz / 16bit / 单声道裸 PCM 包成最小 WAV 容器。
  static Uint8List _wrapWav(Uint8List pcm) {
    const channels = 1;
    const bitsPerSample = 16;
    const headerSize = 44;
    final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
    final blockAlign = channels * bitsPerSample ~/ 8;
    final header = ByteData(headerSize)
      ..setUint32(0, 0x52494646, Endian.big) // RIFF
      ..setUint32(4, 36 + pcm.length, Endian.little)
      ..setUint32(8, 0x57415645, Endian.big) // WAVE
      ..setUint32(12, 0x666d7420, Endian.big) // fmt
      ..setUint32(16, 16, Endian.little)
      ..setUint16(20, 1, Endian.little) // PCM
      ..setUint16(22, channels, Endian.little)
      ..setUint32(24, sampleRate, Endian.little)
      ..setUint32(28, byteRate, Endian.little)
      ..setUint16(32, blockAlign, Endian.little)
      ..setUint16(34, bitsPerSample, Endian.little)
      ..setUint32(36, 0x64617461, Endian.big) // data
      ..setUint32(40, pcm.length, Endian.little);
    final builder = BytesBuilder(copy: false)
      ..add(header.buffer.asUint8List())
      ..add(pcm);
    return builder.takeBytes();
  }

  static Map<String, dynamic>? _decode(String payload) {
    try {
      final decoded = jsonDecode(payload);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  static Future<String> _readAll(Stream<List<int>> stream) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      builder.add(chunk);
    }
    return utf8.decode(builder.takeBytes(), allowMalformed: true);
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
        '语音识别请求参数有误$suffix',
        statusCode: statusCode,
      );
    }
    if (statusCode >= 500) {
      return AiTtsException(
        AiTtsErrorKind.server,
        '语音识别服务暂时不可用$suffix',
        statusCode: statusCode,
      );
    }
    return AiTtsException(
      AiTtsErrorKind.invalidResponse,
      '语音识别服务返回异常状态 $statusCode$suffix',
      statusCode: statusCode,
    );
  }

  static AiTtsException _mapDioException(DioException error) {
    if (CancelToken.isCancel(error)) {
      return const AiTtsException(AiTtsErrorKind.cancelled, '语音识别已取消');
    }
    final statusCode = error.response?.statusCode;
    if (statusCode != null) {
      return _mapStatus(statusCode, '');
    }
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
        return const AiTtsException(AiTtsErrorKind.network, '网络连接失败，请检查网络后重试');
      case DioExceptionType.cancel:
        return const AiTtsException(AiTtsErrorKind.cancelled, '语音识别已取消');
      case DioExceptionType.badResponse:
        return AiTtsException(
          AiTtsErrorKind.invalidResponse,
          error.message ?? '语音识别返回异常响应',
        );
      case DioExceptionType.badCertificate:
        return const AiTtsException(AiTtsErrorKind.network, '安全证书校验失败');
      case DioExceptionType.unknown:
        return AiTtsException(
          AiTtsErrorKind.network,
          error.message ?? '语音识别网络请求失败',
        );
    }
  }
}
