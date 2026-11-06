import 'package:echo_loop/features/subscription/models/premium_feature.dart';
import 'package:echo_loop/features/subscription/providers/feature_access_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('纯端侧模式下所有高级能力均放行', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    for (final feature in PremiumFeature.values) {
      expect(
        container.read(featureAccessProvider(feature)),
        isTrue,
        reason: '纯端侧不再依赖登录或订阅，${feature.name} 应直接放行',
      );
    }
  });
}
