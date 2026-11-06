/// 百度网盘 AppKey 的本地存储。
///
/// AppKey 不是机密信息，但每个用户填写的值不同，因此保存在 SharedPreferences 中，
/// 不写入 secure storage，也不打进安装包。
library;

import 'package:shared_preferences/shared_preferences.dart';

/// AppKey 存储抽象。
abstract interface class BaiduAppKeyStore {
  /// 读取已保存的 AppKey；没有时返回 null。
  Future<String?> read();

  /// 保存 AppKey。
  Future<void> write(String appKey);
}

/// 基于 SharedPreferences 的实现。
class SharedPreferencesBaiduAppKeyStore implements BaiduAppKeyStore {
  /// 存储 key。
  static const storageKey = 'baidu_netdisk_app_key_v1';

  @override
  Future<String?> read() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(storageKey)?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  @override
  Future<void> write(String appKey) async {
    final normalized = appKey.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(appKey, 'appKey', 'AppKey 不能为空');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(storageKey, normalized);
  }
}
