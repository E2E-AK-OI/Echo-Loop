import 'package:echo_loop/features/baidu_netdisk/data/baidu_app_key_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SharedPreferencesBaiduAppKeyStore', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    test('没有保存时返回 null', () async {
      final store = SharedPreferencesBaiduAppKeyStore();

      expect(await store.read(), isNull);
    });

    test('保存后读取会去掉首尾空白', () async {
      final store = SharedPreferencesBaiduAppKeyStore();

      await store.write('  app-key  ');

      expect(await store.read(), 'app-key');
    });

    test('拒绝写入空 AppKey', () async {
      final store = SharedPreferencesBaiduAppKeyStore();

      await expectLater(store.write('   '), throwsArgumentError);
    });
  });
}
