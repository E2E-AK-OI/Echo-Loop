/// AI 口语练习的 API Key 安全存储。
///
/// 所有密钥只写入 FlutterSecureStorage，不进入 SharedPreferences，也不写日志。
/// 两类密钥共用一个 JSON 文档，避免为每个供应商增加独立存储键：
/// {"llm": {"deepSeek": "..."}, "dashscope": "..."}
library;

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/ai_llm_provider.dart';

enum AiSpeakingCredentialErrorKind {
  unavailable,
  readFailed,
  writeFailed,
  deleteFailed,
  parseFailed,
}

class AiSpeakingCredentialStoreException implements Exception {
  const AiSpeakingCredentialStoreException(
    this.kind,
    this.message, [
    this.cause,
  ]);

  final AiSpeakingCredentialErrorKind kind;
  final String message;
  final Object? cause;

  @override
  String toString() => 'AiSpeakingCredentialStoreException($kind): $message';
}

/// 仅表示「是否已配置」，绝不携带密钥原文。
class AiSpeakingSecretStatus {
  const AiSpeakingSecretStatus({
    required this.hasLlmApiKey,
    required this.hasDashscopeApiKey,
  });

  final bool hasLlmApiKey;
  final bool hasDashscopeApiKey;
}

class AiSpeakingCredentialStore {
  AiSpeakingCredentialStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const storageKey = 'ai_speaking_credentials_v1';

  final FlutterSecureStorage _storage;

  Future<String?> readLlmApiKey(AiLlmProvider provider) async {
    final document = await _readDocument();
    final llm = document['llm'];
    if (llm is! Map) return null;
    final value = llm[provider.storageValue];
    if (value is! String || value.trim().isEmpty) return null;
    return value.trim();
  }

  Future<String?> readDashscopeApiKey() async {
    final document = await _readDocument();
    final value = document['dashscope'];
    if (value is! String || value.trim().isEmpty) return null;
    return value.trim();
  }

  Future<void> writeLlmApiKey(AiLlmProvider provider, String apiKey) async {
    final trimmed = apiKey.trim();
    if (trimmed.isEmpty) {
      await deleteLlmApiKey(provider);
      return;
    }
    final document = await _readDocument();
    final rawLlm = document['llm'];
    if (rawLlm != null && rawLlm is! Map) {
      throw const AiSpeakingCredentialStoreException(
        AiSpeakingCredentialErrorKind.parseFailed,
        '凭据文档中的 llm 字段格式不正确',
      );
    }
    final llm = <String, dynamic>{
      if (rawLlm is Map)
        for (final entry in rawLlm.entries) entry.key.toString(): entry.value,
    };
    llm[provider.storageValue] = trimmed;
    document['llm'] = llm;
    await _writeDocument(document);
  }

  Future<void> writeDashscopeApiKey(String apiKey) async {
    final trimmed = apiKey.trim();
    if (trimmed.isEmpty) {
      await deleteDashscopeApiKey();
      return;
    }
    final document = await _readDocument();
    document['dashscope'] = trimmed;
    await _writeDocument(document);
  }

  Future<void> deleteLlmApiKey(AiLlmProvider provider) async {
    final document = await _readDocument();
    final rawLlm = document['llm'];
    if (rawLlm is! Map) {
      if (rawLlm == null) {
        if (document.isEmpty) {
          await _deleteDocument();
        }
        return;
      }
      throw const AiSpeakingCredentialStoreException(
        AiSpeakingCredentialErrorKind.parseFailed,
        '凭据文档中的 llm 字段格式不正确',
      );
    }
    final llm = <String, dynamic>{
      for (final entry in rawLlm.entries) entry.key.toString(): entry.value,
    };
    llm.remove(provider.storageValue);
    if (llm.isEmpty) {
      document.remove('llm');
    } else {
      document['llm'] = llm;
    }
    if (document.isEmpty) {
      await _deleteDocument();
      return;
    }
    await _writeDocument(document);
  }

  Future<void> deleteDashscopeApiKey() async {
    final document = await _readDocument();
    document.remove('dashscope');
    if (document.isEmpty) {
      await _deleteDocument();
      return;
    }
    await _writeDocument(document);
  }

  /// 设置页只关心是否已配置，读取失败时按未配置展示，避免阻断整个页面。
  Future<AiSpeakingSecretStatus> readStatus(AiLlmProvider provider) async {
    try {
      final document = await _readDocument();
      final llm = document['llm'];
      final hasLlmApiKey =
          llm is Map &&
          llm[provider.storageValue] is String &&
          (llm[provider.storageValue] as String).trim().isNotEmpty;
      final dashscope = document['dashscope'];
      return AiSpeakingSecretStatus(
        hasLlmApiKey: hasLlmApiKey,
        hasDashscopeApiKey: dashscope is String && dashscope.trim().isNotEmpty,
      );
    } on AiSpeakingCredentialStoreException {
      return const AiSpeakingSecretStatus(
        hasLlmApiKey: false,
        hasDashscopeApiKey: false,
      );
    }
  }

  Future<Map<String, dynamic>> _readDocument() async {
    String? raw;
    try {
      raw = await _storage.read(key: storageKey);
    } on MissingPluginException catch (error) {
      throw AiSpeakingCredentialStoreException(
        AiSpeakingCredentialErrorKind.unavailable,
        '当前平台不支持安全存储',
        error,
      );
    } on PlatformException catch (error) {
      throw AiSpeakingCredentialStoreException(
        AiSpeakingCredentialErrorKind.readFailed,
        '读取安全存储失败：${error.message ?? error.code}',
        error,
      );
    }
    if (raw == null || raw.isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw const FormatException('凭据文档不是 JSON 对象');
      }
      return <String, dynamic>{
        for (final entry in decoded.entries) entry.key.toString(): entry.value,
      };
    } on FormatException catch (error) {
      throw AiSpeakingCredentialStoreException(
        AiSpeakingCredentialErrorKind.parseFailed,
        '凭据文档解析失败',
        error,
      );
    }
  }

  Future<void> _writeDocument(Map<String, dynamic> document) async {
    try {
      await _storage.write(key: storageKey, value: jsonEncode(document));
    } on MissingPluginException catch (error) {
      throw AiSpeakingCredentialStoreException(
        AiSpeakingCredentialErrorKind.unavailable,
        '当前平台不支持安全存储',
        error,
      );
    } on PlatformException catch (error) {
      throw AiSpeakingCredentialStoreException(
        AiSpeakingCredentialErrorKind.writeFailed,
        '写入安全存储失败：${error.message ?? error.code}',
        error,
      );
    }
  }

  Future<void> _deleteDocument() async {
    try {
      await _storage.delete(key: storageKey);
    } on MissingPluginException catch (error) {
      throw AiSpeakingCredentialStoreException(
        AiSpeakingCredentialErrorKind.unavailable,
        '当前平台不支持安全存储',
        error,
      );
    } on PlatformException catch (error) {
      throw AiSpeakingCredentialStoreException(
        AiSpeakingCredentialErrorKind.deleteFailed,
        '删除安全存储失败：${error.message ?? error.code}',
        error,
      );
    }
  }
}
