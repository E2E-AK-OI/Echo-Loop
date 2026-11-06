import 'package:clock/clock.dart';
import 'package:echo_loop/features/baidu_netdisk/data/baidu_implicit_oauth.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late BaiduImplicitOAuth oauth;

  setUp(() {
    oauth = BaiduImplicitOAuth(
      clock: Clock.fixed(DateTime.utc(2026, 11, 6, 12)),
    );
  });

  Uri callback(String fragment) =>
      Uri.parse('https://openapi.baidu.com/oauth/2.0/login_success#$fragment');

  group('BaiduImplicitOAuth', () {
    test('生成简化模式授权地址', () {
      final request = oauth.createAuthorizationRequest(
        appKey: '  my-app-key  ',
      );

      expect(request.uri.path, '/oauth/2.0/authorize');
      expect(request.uri.queryParameters['response_type'], 'token');
      expect(request.uri.queryParameters['client_id'], 'my-app-key');
      expect(request.uri.queryParameters['redirect_uri'], 'oob');
      expect(request.uri.queryParameters['scope'], 'basic,netdisk');
      expect(request.uri.queryParameters['display'], 'popup');
      expect(request.uri.queryParameters['state'], request.state);
      expect(request.state, isNotEmpty);
      expect(request.forceLogin, isFalse);
    });

    test('AppKey 为空时拒绝创建授权请求', () {
      expect(
        () => oauth.createAuthorizationRequest(appKey: '   '),
        throwsA(isA<BaiduOAuthException>()),
      );
    });

    test('强制登录标志透传到授权请求', () {
      final request = oauth.createAuthorizationRequest(
        appKey: 'key',
        forceLogin: true,
      );

      expect(request.forceLogin, isTrue);
    });

    test('只识别百度 oob 回调地址', () {
      expect(
        oauth.isCallback(
          Uri.parse('https://openapi.baidu.com/oauth/2.0/login_success'),
        ),
        isTrue,
      );
      expect(
        oauth.isCallback(
          Uri.parse('http://openapi.baidu.com/oauth/2.0/login_success'),
        ),
        isFalse,
      );
      expect(
        oauth.isCallback(
          Uri.parse('https://openapi.baidu.com/oauth/2.0/authorize'),
        ),
        isFalse,
      );
      expect(
        oauth.isCallback(Uri.parse('https://example.com/login_success')),
        isFalse,
      );
    });

    test('从 fragment 解析凭证', () {
      final request = oauth.createAuthorizationRequest(appKey: 'key');
      final credential = oauth.parseCallback(
        callback(
          'access_token=access-1&expires_in=2592000'
          '&scope=basic+netdisk&state=${request.state}',
        ),
        expectedState: request.state,
      );

      expect(credential.accessToken, 'access-1');
      expect(credential.refreshToken, isEmpty);
      expect(credential.canRefresh, isFalse);
      expect(credential.expiresAt, DateTime.utc(2026, 12, 6, 12));
      expect(credential.scope, 'basic netdisk');
    });

    test('从 query 解析凭证', () {
      final request = oauth.createAuthorizationRequest(appKey: 'key');
      final uri = Uri.parse(
        'https://openapi.baidu.com/oauth/2.0/login_success'
        '?access_token=access-2&expires_in=3600'
        '&scope=basic,netdisk&state=${request.state}',
      );

      final credential = oauth.parseCallback(uri, expectedState: request.state);

      expect(credential.accessToken, 'access-2');
      expect(credential.expiresAt, DateTime.utc(2026, 11, 6, 13));
    });

    test('state 不匹配时拒绝回调', () {
      final request = oauth.createAuthorizationRequest(appKey: 'key');

      expect(
        () => oauth.parseCallback(
          callback(
            'access_token=access&expires_in=3600'
            '&scope=basic,netdisk&state=other',
          ),
          expectedState: request.state,
        ),
        throwsA(isA<BaiduOAuthException>()),
      );
    });

    test('百度返回 error 时展示错误描述', () {
      final request = oauth.createAuthorizationRequest(appKey: 'key');

      expect(
        () => oauth.parseCallback(
          callback(
            'error=access_denied&error_description=用户拒绝授权'
            '&state=${request.state}',
          ),
          expectedState: request.state,
        ),
        throwsA(
          isA<BaiduOAuthException>().having(
            (error) => error.message,
            'message',
            '用户拒绝授权',
          ),
        ),
      );
    });

    test('缺少 access token、有效期或网盘权限时拒绝', () {
      final request = oauth.createAuthorizationRequest(appKey: 'key');
      final state = request.state;

      expect(
        () => oauth.parseCallback(
          callback('expires_in=3600&scope=basic,netdisk&state=$state'),
          expectedState: state,
        ),
        throwsA(isA<BaiduOAuthException>()),
      );
      expect(
        () => oauth.parseCallback(
          callback(
            'access_token=access&expires_in=0'
            '&scope=basic,netdisk&state=$state',
          ),
          expectedState: state,
        ),
        throwsA(isA<BaiduOAuthException>()),
      );
      expect(
        () => oauth.parseCallback(
          callback(
            'access_token=access&expires_in=3600&scope=basic&state=$state',
          ),
          expectedState: state,
        ),
        throwsA(isA<BaiduOAuthException>()),
      );
    });
  });
}
