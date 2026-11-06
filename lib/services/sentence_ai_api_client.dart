/// AI 句子翻译/解析/词典客户端（纯端侧 BYOK 版）。
///
/// 不再访问自建后端，所有请求都通过 [ByokAiService] 直连用户配置的 OpenAI
/// 兼容接口。保留原有帧类型与调用签名，减少上层 provider/UI 的改动。
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:universal_io/io.dart';

import '../models/dictionary/dictionary_entry.dart';
import '../models/retell_review_evaluation.dart';
import '../models/sense_group_result.dart';
import '../models/sentence_ai_result.dart';
import 'byok_ai_service.dart';
import 'dictionary/dictionary_source.dart';

part 'sentence_ai_api_client.g.dart';

/// AI 词典结果帧。
class AiDictionaryStreamFrame {
  final AiDictionaryEntry entry;
  final bool isFinal;

  const AiDictionaryStreamFrame({required this.entry, required this.isFinal});
}

/// AI 句子解析结果帧。
class SentenceAnalysisStreamFrame {
  final SentenceAnalysis analysis;
  final bool isFinal;

  const SentenceAnalysisStreamFrame({
    required this.analysis,
    required this.isFinal,
  });
}

/// 句子解析流内错误。
class SentenceAnalysisStreamException implements Exception {
  const SentenceAnalysisStreamException();

  @override
  String toString() => 'SentenceAnalysisStreamException';
}

/// AI 句子翻译结果帧。
class SentenceTranslationStreamFrame {
  final SentenceTranslation translation;
  final bool isFinal;

  const SentenceTranslationStreamFrame({
    required this.translation,
    required this.isFinal,
  });
}

/// 句子翻译流内错误。
class SentenceTranslationStreamException implements Exception {
  const SentenceTranslationStreamException();

  @override
  String toString() => 'SentenceTranslationStreamException';
}

/// AI 意群拆分结果帧。
class SenseGroupsStreamFrame {
  final SenseGroupResult result;
  final bool isFinal;

  const SenseGroupsStreamFrame({required this.result, required this.isFinal});
}

/// 意群拆分流内错误。
class SenseGroupsStreamException implements Exception {
  const SenseGroupsStreamException();

  @override
  String toString() => 'SenseGroupsStreamException';
}

/// AI 句子翻译/解析客户端。
class SentenceAiApiClient {
  final ByokAiService? _service;
  final Dio _dio;

  SentenceAiApiClient({required ByokAiService service, Dio? dio})
    : _service = service,
      _dio = dio ?? Dio();

  /// 测试用构造函数。没有注入 BYOK 服务时，真正发起请求会抛配置错误。
  SentenceAiApiClient.withDio(this._dio) : _service = null;

  /// 请求公共 headers（仅测试用）。
  @visibleForTesting
  Map<String, dynamic> get defaultHeaders => _dio.options.headers;

  /// 当前 Dio adapter（仅测试用）。
  @visibleForTesting
  HttpClientAdapter get debugHttpClientAdapter => _dio.httpClientAdapter;

  ByokAiService _requireService() {
    final service = _service;
    if (service == null) {
      throw const ByokAiException(ByokAiErrorKind.missingConfig, 'AI 客户端未配置');
    }
    return service;
  }

  /// 翻译句子（流式累积）。
  Stream<SentenceTranslationStreamFrame> translateStream(
    String text, {
    required String accessToken,
    String? previousText,
    String? nextText,
    String? targetLanguage,
    CancelToken? cancelToken,
  }) async* {
    final buffer = StringBuffer();
    final messages = <Map<String, String>>[
      {'role': 'system', 'content': '你是英语学习助手。请把用户给出的英文句子翻译成目标语言，只输出译文，不要解释。'},
      {
        'role': 'user',
        'content':
            '目标语言：${targetLanguage ?? 'zh-CN'}\n'
            '前一句：${previousText ?? ''}\n'
            '目标句：$text\n'
            '后一句：${nextText ?? ''}',
      },
    ];
    await for (final delta in _requireService().streamText(
      messages: messages,
      cancelToken: cancelToken,
    )) {
      buffer.write(delta);
      yield SentenceTranslationStreamFrame(
        translation: SentenceTranslation(translation: buffer.toString()),
        isFinal: false,
      );
    }
    yield SentenceTranslationStreamFrame(
      translation: SentenceTranslation(translation: buffer.toString()),
      isFinal: true,
    );
  }

  /// 解析句子（一次性返回结构化结果）。
  Stream<SentenceAnalysisStreamFrame> analyzeStream(
    String text, {
    required String accessToken,
    String? targetLanguage,
    CancelToken? cancelToken,
  }) async* {
    final messages = <Map<String, String>>[
      {
        'role': 'system',
        'content':
            '你是英语语法老师。请分析英文句子，只输出 JSON 对象，结构为 '
            '{"grammar":[{"point":"结构标签","note":"说明"}],'
            '"vocabulary":[{"term":"词汇","note":"说明"}],'
            '"listening":[{"phrase":"短语","note":"发音或听力说明"}]}。'
            '所有说明使用目标语言。',
      },
      {
        'role': 'user',
        'content': '目标语言：${targetLanguage ?? 'zh-CN'}\n句子：$text',
      },
    ];
    try {
      final json = await _requireService().completeJson(
        messages: messages,
        cancelToken: cancelToken,
      );
      yield SentenceAnalysisStreamFrame(
        analysis: SentenceAnalysis.fromJson(json),
        isFinal: true,
      );
    } on ByokAiException {
      throw const SentenceAnalysisStreamException();
    }
  }

  /// 查单词（流式帧）。
  Stream<AiDictionaryStreamFrame> lookupWordStreamFrames(
    String word, {
    required String accessToken,
    String? targetLanguage,
    CancelToken? cancelToken,
  }) async* {
    final json = await _lookupJson(
      word,
      isPhrase: false,
      targetLanguage: targetLanguage,
      cancelToken: cancelToken,
    );
    yield AiDictionaryStreamFrame(
      entry: DictionaryEntry.fromJson(json),
      isFinal: true,
    );
  }

  /// 查词组（流式帧）。
  Stream<AiDictionaryStreamFrame> lookupPhraseStreamFrames(
    String phrase, {
    required String accessToken,
    String? targetLanguage,
    CancelToken? cancelToken,
  }) async* {
    final json = await _lookupJson(
      phrase,
      isPhrase: true,
      targetLanguage: targetLanguage,
      cancelToken: cancelToken,
    );
    yield AiDictionaryStreamFrame(
      entry: MultiWordDictionaryEntry.fromJson(json),
      isFinal: true,
    );
  }

  /// 查单词（兼容旧调用方的结果流）。
  Stream<AiDictionaryEntry> lookupWordStream(
    String word, {
    required String accessToken,
    String? targetLanguage,
    CancelToken? cancelToken,
  }) async* {
    await for (final frame in lookupWordStreamFrames(
      word,
      accessToken: accessToken,
      targetLanguage: targetLanguage,
      cancelToken: cancelToken,
    )) {
      yield frame.entry;
    }
  }

  /// 查词组（兼容旧调用方的结果流）。
  Stream<AiDictionaryEntry> lookupPhraseStream(
    String phrase, {
    required String accessToken,
    String? targetLanguage,
    CancelToken? cancelToken,
  }) async* {
    await for (final frame in lookupPhraseStreamFrames(
      phrase,
      accessToken: accessToken,
      targetLanguage: targetLanguage,
      cancelToken: cancelToken,
    )) {
      yield frame.entry;
    }
  }

  Future<Map<String, dynamic>> _lookupJson(
    String query, {
    required bool isPhrase,
    String? targetLanguage,
    CancelToken? cancelToken,
  }) async {
    final schema = isPhrase
        ? '{"originalExpression":"原表达","naturalness":"自然度说明","category":"类别",'
              '"pronunciationTips":["发音提示"],'
              '"keyPoints":[{"point":"要点","sentence":"例句","translation":"译文"}],'
              '"meanings":[{"translation":["释义"],"examples":[{"sentence":"例句","translation":"译文"}]}],'
              '"similarExpressions":[{"expression":"表达","difference":"区别","sentence":"例句","translation":"译文"}],'
              '"background":"背景说明"}'
        : '{"headword":"词头","pronunciation":{"uk":"英音","us":"美音"},'
              '"meanings":[{"partOfSpeech":"词性","translation":["释义"],"definition":"英文释义",'
              '"usageNote":"用法","examples":[{"sentence":"例句","translation":"译文"}],'
              '"synonyms":["同义词"],"antonyms":["反义词"]}],'
              '"commonExpressions":[{"expression":"搭配","type":"类型","meaning":"含义",'
              '"example":{"sentence":"例句","translation":"译文"}}],'
              '"wordFamily":[{"word":"派生词","partOfSpeech":"词性","meaning":"含义",'
              '"example":"例句"}],"forms":[{"form":"形式","label":"说明"}],'
              '"etymology":"词源","learnerTips":["学习提示"]}';
    final messages = <Map<String, String>>[
      {
        'role': 'system',
        'content':
            '你是英语词典编写助手。请只输出 JSON 对象，不要 Markdown 代码块。'
            '缺失信息用空字符串或空数组。JSON 模板：$schema',
      },
      {
        'role': 'user',
        'content': '目标语言：${targetLanguage ?? 'zh-CN'}\n查询内容：$query',
      },
    ];
    try {
      return await _requireService().completeJson(
        messages: messages,
        cancelToken: cancelToken,
      );
    } on ByokAiException {
      throw const DictionaryStreamException();
    }
  }

  /// 意群拆分（一次性返回双粒度结果）。
  Stream<SenseGroupsStreamFrame> senseGroupsStream(
    String text, {
    required String accessToken,
    CancelToken? cancelToken,
  }) async* {
    final messages = <Map<String, String>>[
      {
        'role': 'system',
        'content':
            '你是英语口语教练。请把英文句子按语义/呼吸意群切分，只输出 JSON：'
            '{"medium":["中等粒度意群"],"fine":["细粒度意群"]}。'
            '所有片段按顺序拼接后必须与原文完全一致，不得增删单词。',
      },
      {'role': 'user', 'content': text},
    ];
    try {
      final json = await _requireService().completeJson(
        messages: messages,
        cancelToken: cancelToken,
      );
      yield SenseGroupsStreamFrame(
        result: SenseGroupResult.fromJson(json),
        isFinal: true,
      );
    } on ByokAiException {
      throw const SenseGroupsStreamException();
    }
  }

  /// 本地端侧模式暂不支持语音复述 AI 评分。
  Stream<RetellReviewStreamFrame> evaluateReviewStream({
    required File audioFile,
    required String originalText,
    required String targetLanguage,
    required String accessToken,
    CancelToken? cancelToken,
  }) async* {
    throw const RetellReviewStreamException();
  }

  /// 释放资源。
  void dispose() {}
}

/// AI 客户端 Provider。
@Riverpod(keepAlive: true)
SentenceAiApiClient sentenceAiApiClient(Ref ref) {
  final client = SentenceAiApiClient(service: ref.watch(byokAiServiceProvider));
  ref.onDispose(client.dispose);
  return client;
}
