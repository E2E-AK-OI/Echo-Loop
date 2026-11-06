import 'package:clock/clock.dart';
import 'package:echo_loop/features/baidu_netdisk/data/baidu_credential_repository.dart';
import 'package:echo_loop/features/baidu_netdisk/data/baidu_credential_store.dart';
import 'package:echo_loop/features/baidu_netdisk/models/baidu_credential_bundle.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockStore extends Mock implements BaiduCredentialStore {}

void main() {
  late _MockStore store;
  late DefaultBaiduCredentialRepository repository;

  setUpAll(() {
    registerFallbackValue(
      BaiduCredentialBundle(
        accessToken: 'fallback-access',
        refreshToken: '',
        expiresAt: DateTime.utc(2026),
        scope: 'basic,netdisk',
      ),
    );
  });

  BaiduCredentialBundle credential({
    String access = 'access',
    String refresh = '',
    DateTime? expiresAt,
  }) {
    return BaiduCredentialBundle(
      accessToken: access,
      refreshToken: refresh,
      expiresAt: expiresAt ?? DateTime.utc(2026, 7, 18, 12, 30),
      scope: 'basic,netdisk',
    );
  }

  setUp(() {
    store = _MockStore();
    repository = DefaultBaiduCredentialRepository(
      store: store,
      clock: Clock.fixed(DateTime.utc(2026, 7, 18, 12)),
    );
  });

  group('DefaultBaiduCredentialRepository', () {
    test('主动断开清除凭据并标记下一次授权强制登录', () async {
      when(() => store.clear()).thenAnswer((_) async {});
      when(() => store.writeForceLoginOnce()).thenAnswer((_) async {});

      await repository.disconnect();

      verifyInOrder([() => store.clear(), () => store.writeForceLoginOnce()]);
    });

    test('读取强制登录标志但不清除', () async {
      when(() => store.readForceLoginOnce()).thenAnswer((_) async => true);

      expect(await repository.readForceLoginOnce(), isTrue);
      verifyNever(() => store.clearForceLoginOnce());
    });

    test('消费强制登录标志只清除标志', () async {
      when(() => store.clearForceLoginOnce()).thenAnswer((_) async {});

      await repository.consumeForceLoginOnce();

      verify(() => store.clearForceLoginOnce()).called(1);
      verifyNever(() => store.clear());
    });

    test('保存授权凭证写入 secure storage', () async {
      final bundle = credential(access: 'new-access');
      when(() => store.write(any())).thenAnswer((_) async {});

      await repository.saveCredential(bundle);

      verify(() => store.write(bundle)).called(1);
    });

    test('保存凭证失败时向上抛出存储错误', () async {
      when(() => store.write(any())).thenThrow(Exception('disk full'));

      await expectLater(
        repository.saveCredential(credential()),
        throwsA(isA<Exception>()),
      );
    });

    test('普通清除凭据不设置强制登录标志', () async {
      when(() => store.clear()).thenAnswer((_) async {});

      await repository.clearCredential();

      verifyNever(() => store.writeForceLoginOnce());
    });

    test('没有凭证时返回 null', () async {
      when(() => store.read()).thenAnswer((_) async => null);

      expect(await repository.getValidAccessToken(), isNull);
      verifyNever(() => store.clear());
    });

    test('未过期 credential 直接返回 access token', () async {
      when(() => store.read()).thenAnswer((_) async => credential());

      expect(await repository.getValidAccessToken(), 'access');
      verifyNever(() => store.clear());
    });

    test('提前 5 分钟过期时清除凭证并返回 null', () async {
      when(() => store.read()).thenAnswer(
        (_) async => credential(expiresAt: DateTime.utc(2026, 7, 18, 12, 4)),
      );
      when(() => store.clear()).thenAnswer((_) async {});

      expect(await repository.getValidAccessToken(), isNull);
      verify(() => store.clear()).called(1);
    });
  });
}
