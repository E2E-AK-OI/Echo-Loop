import 'dart:convert';

import 'package:echo_loop/features/baidu_netdisk/models/baidu_credential_bundle.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BaiduCredentialBundle', () {
    test('正常解析并提前 5 分钟视为过期', () {
      final credential = BaiduCredentialBundle.fromJson({
        'accessToken': 'access',
        'refreshToken': 'refresh',
        'expiresAt': '2026-07-18T12:10:00Z',
        'scope': 'basic,netdisk',
      });

      expect(credential.accessToken, 'access');
      expect(credential.canRefresh, isTrue);
      expect(
        credential.isAccessTokenUsable(DateTime.utc(2026, 7, 18, 12, 4)),
        isTrue,
      );
      expect(
        credential.isAccessTokenUsable(DateTime.utc(2026, 7, 18, 12, 5)),
        isFalse,
      );
      expect(
        BaiduCredentialBundle.decode(jsonEncode(credential.toJson())).scope,
        'basic,netdisk',
      );
    });

    test('简化模式允许空 refreshToken 且不能刷新', () {
      final credential = BaiduCredentialBundle.fromJson({
        'accessToken': 'access',
        'refreshToken': '',
        'expiresAt': '2026-07-18T12:10:00Z',
        'scope': 'basic netdisk',
      });

      expect(credential.refreshToken, isEmpty);
      expect(credential.canRefresh, isFalse);
    });

    test('缺少 refreshToken 字段时拒绝解析', () {
      expect(
        () => BaiduCredentialBundle.fromJson({
          'accessToken': 'access',
          'expiresAt': '2026-07-18T12:10:00Z',
          'scope': 'basic,netdisk',
        }),
        throwsFormatException,
      );
    });

    test('非法字段抛 FormatException', () {
      expect(
        () => BaiduCredentialBundle.fromJson({
          'accessToken': '',
          'refreshToken': '',
          'expiresAt': '2026-07-18T12:10:00Z',
          'scope': 'basic,netdisk',
        }),
        throwsFormatException,
      );
      expect(
        () => BaiduCredentialBundle.fromJson({
          'accessToken': 'access',
          'refreshToken': '',
          'expiresAt': 'bad',
          'scope': 'basic,netdisk',
        }),
        throwsFormatException,
      );
      expect(
        () => BaiduCredentialBundle.fromJson({
          'accessToken': 'access',
          'refreshToken': '',
          'expiresAt': '2026-07-18T12:10:00Z',
          'scope': '',
        }),
        throwsFormatException,
      );
    });
  });
}
