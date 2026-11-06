/// 百度网盘简化模式（Implicit Grant）授权。
///
/// 纯端侧实现不保存 SecretKey，只使用用户自己的 AppKey。百度在授权完成后把
/// access_token 放在回调 URL 的 fragment 中，App 内 WebView 拦截该 URL 即可拿到
/// 凭证，不需要后端交换 code。简化模式不返回 refresh token，access token 约 30 天
/// 过期，过期后必须重新授权。
library;

import 'dart:convert';
import 'dart:math';

import 'package:clock/clock.dart';

import '../models/baidu_credential_bundle.dart';

/// 简化模式授权地址。
const baiduOAuthAuthorizeEndpoint =
    'https://openapi.baidu.com/oauth/2.0/authorize';

/// 百度无 server 应用使用 oob 时，授权完成后的默认回调地址。
const baiduOAuthCallbackEndpoint =
    'https://openapi.baidu.com/oauth/2.0/login_success';

/// 百度网盘授权申请的 scope。
const baiduOAuthScope = 'basic,netdisk';

/// 简化模式授权异常。
class BaiduOAuthException implements Exception {
  /// 构造授权异常。
  const BaiduOAuthException(this.message);

  /// 可展示给用户的错误信息。
  final String message;

  @override
  String toString() => 'BaiduOAuthException($message)';
}

/// 一次简化模式授权请求。
class BaiduAuthorizationRequest {
  /// 构造授权请求。
  const BaiduAuthorizationRequest({
    required this.uri,
    required this.state,
    this.forceLogin = false,
  });

  /// 授权页地址。
  final Uri uri;

  /// 用于校验回调来源的随机 state。
  final String state;

  /// 是否先清除百度登录态，强制用户重新登录以切换账号。
  final bool forceLogin;
}

/// 百度网盘简化模式授权服务。
class BaiduImplicitOAuth {
  /// 构造授权服务。
  ///
  /// [clock] 与 [random] 仅用于测试注入；生产环境使用系统时间和安全随机数。
  BaiduImplicitOAuth({Clock? clock, Random? random})
    : _clock = clock ?? const Clock(),
      _random = random ?? Random.secure();

  final Clock _clock;
  final Random _random;

  /// 创建授权请求。
  BaiduAuthorizationRequest createAuthorizationRequest({
    required String appKey,
    bool forceLogin = false,
  }) {
    final normalizedAppKey = appKey.trim();
    if (normalizedAppKey.isEmpty) {
      throw const BaiduOAuthException('请先填写百度应用 AppKey。');
    }
    final state = _createState();
    final uri = Uri.parse(baiduOAuthAuthorizeEndpoint).replace(
      queryParameters: <String, String>{
        'response_type': 'token',
        'client_id': normalizedAppKey,
        'redirect_uri': 'oob',
        'scope': baiduOAuthScope,
        'display': 'popup',
        'state': state,
      },
    );
    return BaiduAuthorizationRequest(
      uri: uri,
      state: state,
      forceLogin: forceLogin,
    );
  }

  /// 判断 URL 是否为百度授权完成后的回调。
  bool isCallback(Uri uri) {
    return uri.scheme == 'https' &&
        uri.host == 'openapi.baidu.com' &&
        uri.path == '/oauth/2.0/login_success';
  }

  /// 从回调 URL 解析凭证。
  ///
  /// 百度把 token 放在 fragment 中；部分 WebView 或中间页会把参数放到 query，
  /// 因此两处都接受。必须校验 [expectedState]，避免把其他来源的回调当成授权结果。
  BaiduCredentialBundle parseCallback(
    Uri uri, {
    required String expectedState,
  }) {
    if (!isCallback(uri)) {
      throw const BaiduOAuthException('不是百度授权回调地址。');
    }
    final raw = uri.fragment.isNotEmpty ? uri.fragment : uri.query;
    final params = Uri.splitQueryString(raw);
    final error = params['error'];
    if (error != null && error.isNotEmpty) {
      final description = params['error_description'];
      throw BaiduOAuthException(
        description == null || description.isEmpty ? error : description,
      );
    }
    if (params['state'] != expectedState) {
      throw const BaiduOAuthException('授权状态校验失败，请重试。');
    }
    final accessToken = params['access_token'];
    if (accessToken == null || accessToken.isEmpty) {
      throw const BaiduOAuthException('百度未返回 access token。');
    }
    final expiresIn = int.tryParse(params['expires_in'] ?? '');
    if (expiresIn == null || expiresIn <= 0) {
      throw const BaiduOAuthException('百度返回的授权有效期无效。');
    }
    final scope = params['scope'];
    if (scope == null || scope.isEmpty) {
      throw const BaiduOAuthException('百度未返回授权范围。');
    }
    final scopes = scope
        .split(RegExp(r'[,\s]+'))
        .where((item) => item.isNotEmpty)
        .toSet();
    if (!scopes.contains('basic') || !scopes.contains('netdisk')) {
      throw const BaiduOAuthException('百度授权范围缺少网盘权限。');
    }
    return BaiduCredentialBundle(
      accessToken: accessToken,
      refreshToken: '',
      expiresAt: _clock.now().toUtc().add(Duration(seconds: expiresIn)),
      scope: scope,
    );
  }

  String _createState() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }
}
