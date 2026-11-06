/// 百度 OAuth credential bundle。
///
/// App 端用一个 secure storage JSON key 保存完整 bundle。简化模式没有 refresh
/// token，refreshToken 允许为空；后续如果接入授权码模式，仍可保存完整 bundle。
library;

import 'dart:convert';

/// 百度 OAuth 凭证集合。
class BaiduCredentialBundle {
  /// 构造凭证集合。
  const BaiduCredentialBundle({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
    required this.scope,
  });

  /// Access token。
  final String accessToken;

  /// Refresh token；简化模式授权时为空字符串。
  final String refreshToken;

  /// Access token 过期时间（UTC）。
  final DateTime expiresAt;

  /// 百度返回的 scope 原文。
  final String scope;

  /// 是否具备刷新能力；简化模式授权没有 refresh token。
  bool get canRefresh => refreshToken.isNotEmpty;

  /// access token 在 [earlyExpiryWindow] 内过期时提前视为失效。
  bool isAccessTokenUsable(
    DateTime now, {
    Duration earlyExpiryWindow = const Duration(minutes: 5),
  }) {
    return now.toUtc().add(earlyExpiryWindow).isBefore(expiresAt.toUtc());
  }

  /// 转为 secure storage 保存用 JSON。
  Map<String, Object?> toJson() => <String, Object?>{
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'scope': scope,
  };

  /// 从任意 JSON 解码结果安全解析。
  factory BaiduCredentialBundle.fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException('credential 必须是对象');
    }
    final accessToken = json['accessToken'];
    final refreshToken = json['refreshToken'];
    final rawExpiresAt = json['expiresAt'];
    final scope = json['scope'];
    if (accessToken is! String || accessToken.isEmpty) {
      throw const FormatException('accessToken 非法');
    }
    if (refreshToken is! String) {
      throw const FormatException('refreshToken 非法');
    }
    if (scope is! String || scope.isEmpty) {
      throw const FormatException('scope 非法');
    }
    if (rawExpiresAt is! String) {
      throw const FormatException('expiresAt 非法');
    }
    final expiresAt = DateTime.tryParse(rawExpiresAt);
    if (expiresAt == null) {
      throw const FormatException('expiresAt 非法');
    }
    return BaiduCredentialBundle(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAt: expiresAt.toUtc(),
      scope: scope,
    );
  }

  /// 从 JSON 字符串解析。
  static BaiduCredentialBundle decode(String raw) {
    return BaiduCredentialBundle.fromJson(jsonDecode(raw));
  }
}
