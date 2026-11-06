/// 百度 credential 仓库。
///
/// 纯端侧简化模式没有后端会话，也没有 refresh token：仓库只负责 secure storage
/// 读写、过期清理和“下次授权强制登录”标志。Controller 与导入服务只依赖这里的
/// 抽象获取可用 access token。
library;

import 'package:clock/clock.dart';

import '../models/baidu_credential_bundle.dart';
import 'baidu_credential_store.dart';

/// access token 不可用，需要用户重新授权。
class BaiduReauthorizationRequiredException implements Exception {
  /// 构造重新授权异常。
  const BaiduReauthorizationRequiredException();

  @override
  String toString() => 'BaiduReauthorizationRequiredException';
}

/// 百度凭证仓库抽象。
abstract interface class BaiduCredentialRepository {
  /// 读取“下次授权强制登录”标志，读取后不清除。
  Future<bool> readForceLoginOnce();

  /// 清除“下次授权强制登录”标志。
  Future<void> consumeForceLoginOnce();

  /// 保存授权拿到的凭证。
  Future<void> saveCredential(BaiduCredentialBundle credential);

  /// 返回可用 access token；凭证缺失或已过期时返回 null 并清理过期凭证。
  Future<String?> getValidAccessToken();

  /// 清除本地凭证。
  Future<void> clearCredential();

  /// 断开用户主动退出的百度网盘连接，并标记下一次授权强制登录。
  Future<void> disconnect();
}

/// 默认百度凭证仓库实现。
class DefaultBaiduCredentialRepository implements BaiduCredentialRepository {
  /// 构造仓库。
  DefaultBaiduCredentialRepository({
    required BaiduCredentialStore store,
    Clock? clock,
  }) : _store = store,
       _clock = clock ?? const Clock();

  final BaiduCredentialStore _store;
  final Clock _clock;

  @override
  Future<bool> readForceLoginOnce() {
    return _store.readForceLoginOnce();
  }

  @override
  Future<void> consumeForceLoginOnce() {
    return _store.clearForceLoginOnce();
  }

  @override
  Future<void> saveCredential(BaiduCredentialBundle credential) async {
    await _store.write(credential);
  }

  @override
  Future<String?> getValidAccessToken() async {
    final credential = await _store.read();
    if (credential == null) return null;
    if (credential.isAccessTokenUsable(_clock.now())) {
      return credential.accessToken;
    }
    // 简化模式没有 refresh token，过期后只能重新授权。
    await _store.clear();
    return null;
  }

  @override
  Future<void> clearCredential() async {
    await _store.clear();
  }

  @override
  Future<void> disconnect() async {
    await _store.clear();
    await _store.writeForceLoginOnce();
  }
}
