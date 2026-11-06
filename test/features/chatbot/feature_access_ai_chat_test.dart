/// AI 聊天在纯端侧模式下不依赖登录与订阅门禁。
library;

import 'package:echo_loop/features/subscription/models/premium_feature.dart';
import 'package:echo_loop/features/subscription/providers/feature_access_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('未登录状态也能直接使用 AI 聊天能力', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(
      container.read(featureAccessProvider(PremiumFeature.aiChat)),
      isTrue,
    );
  });
}
