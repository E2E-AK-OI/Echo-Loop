/// 系统 Region 的读取入口与中国区判定。
library;

import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../config/regional_service_endpoints.dart';
import '../remote_config/remote_config.dart';
import '../remote_config/remote_config_dependencies.dart';
import '../../services/app_logger.dart';
import '../../services/runtime_endpoint_router.dart';
import 'user_region.dart';
import 'user_region_bootstrapper.dart';
import 'user_region_override.dart';

/// 系统 Region 读取 seam；测试可注入固定国家码。
final userRegionDeviceCountryCodeProvider = Provider<String? Function()>(
  (ref) =>
      () => PlatformDispatcher.instance.locale.countryCode,
);

/// 当前服务端点路由器；测试可注入隔离的路由状态。
final userRegionEndpointRouterProvider = Provider<RuntimeEndpointRouter>(
  (ref) => runtimeEndpointRouter,
);

/// 构造可测试的启动地区解析器，并复用同一个远程配置服务与缓存。
final userRegionBootstrapperProvider = Provider<UserRegionBootstrapper>((ref) {
  final router = ref.watch(userRegionEndpointRouterProvider);
  final remoteConfigService = ref.watch(remoteConfigServiceProvider);
  return UserRegionBootstrapper(
    endpoints: router.endpoints,
    fetchRemoteConfig: (baseUrl, timeout) {
      return remoteConfigService.fetchRemoteFromBaseUrl(
        baseUrl,
        timeout: timeout,
      );
    },
  );
});

/// 纯端侧启动地区判定：系统 Region + 本地开发者覆盖，不探测远端配置。
final userRegionBootstrapProvider = FutureProvider<UserRegionBootstrapResult>((
  ref,
) async {
  final readCountryCode = ref.watch(userRegionDeviceCountryCodeProvider);
  final router = ref.watch(userRegionEndpointRouterProvider);
  await WidgetsBinding.instance.endOfFrame;

  final systemIsChinaUser = _readSystemRegionIsChina(readCountryCode);
  final override = await _readOverride(ref);
  final forcedRegion = override.forcedRegion;
  final isChinaUser = switch (forcedRegion) {
    ServiceEndpointRegion.china => true,
    ServiceEndpointRegion.global => false,
    null => systemIsChinaUser,
  };
  final source = forcedRegion == null
      ? UserRegionDecisionSource.systemFallback
      : UserRegionDecisionSource.developerOverride;
  router.updateFromUserRegion(isChinaUser: isChinaUser);
  AppLogger.log(
    'UserRegion',
    'startup route ready china=$isChinaUser source=${source.name}',
  );
  return UserRegionBootstrapResult(
    isChinaUser: isChinaUser,
    source: source,
    remoteConfig: RemoteConfig.defaults,
  );
});

/// 已解析时使用本地启动判定结果；解析期间或异常时暂用系统 Region 回退值。
final isChinaUserProvider = Provider<bool>((ref) {
  final result = ref.watch(userRegionBootstrapProvider).value;
  return result?.isChinaUser ??
      _readSystemRegionIsChina(ref.watch(userRegionDeviceCountryCodeProvider));
});

/// 读取开发者地区覆盖；读取失败时按自动判定处理，不阻断启动。
Future<UserRegionOverride> _readOverride(Ref ref) async {
  try {
    return await ref.read(userRegionOverrideStoreProvider).load();
  } catch (error) {
    AppLogger.log('UserRegion', 'developer override read failed: $error');
    return UserRegionOverride.auto;
  }
}

bool _readSystemRegionIsChina(String? Function() readCountryCode) {
  try {
    return isChinaSystemRegion(readCountryCode());
  } catch (error, stackTrace) {
    AppLogger.log('UserRegion', 'system Region read failed: $error');
    AppLogger.log('UserRegion', stackTrace.toString());
    return false;
  }
}
