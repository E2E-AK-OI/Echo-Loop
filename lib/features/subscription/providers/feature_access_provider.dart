/// 付费墙挂接 API：查询某能力是否解锁。
///
/// 纯端侧版本不再有账户、订阅与后端权益：所有功能一律放行。
/// 保留 provider 签名，避免散落的调用点需要同步改动。
library;

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/premium_feature.dart';

part 'feature_access_provider.g.dart';

/// 某 [feature] 当前是否对用户可用（纯端侧恒为 true）。
@riverpod
bool featureAccess(Ref ref, PremiumFeature feature) => true;
