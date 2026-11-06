/// 百度网盘功能的基础 Provider。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/download_provider.dart';
import '../../../utils/transcript_picker.dart';
import '../data/baidu_app_key_store.dart';
import '../data/baidu_credential_repository.dart';
import '../data/baidu_credential_store.dart';
import '../data/baidu_implicit_oauth.dart';
import '../data/baidu_netdisk_api.dart';
import '../data/baidu_netdisk_import_service.dart';

/// 用户自建百度应用的 AppKey 存储 provider。
final baiduAppKeyStoreProvider = Provider<BaiduAppKeyStore>((ref) {
  return SharedPreferencesBaiduAppKeyStore();
});

/// 百度简化模式授权服务 provider。
final baiduImplicitOAuthProvider = Provider<BaiduImplicitOAuth>((ref) {
  return BaiduImplicitOAuth();
});

/// 百度 credential secure storage provider。
final baiduCredentialStoreProvider = Provider<BaiduCredentialStore>((ref) {
  return SecureBaiduCredentialStore();
});

/// 百度 credential repository provider。
final baiduCredentialRepositoryProvider = Provider<BaiduCredentialRepository>((
  ref,
) {
  return DefaultBaiduCredentialRepository(
    store: ref.watch(baiduCredentialStoreProvider),
  );
});

/// 百度网盘文件 API provider。
final baiduNetdiskApiProvider = Provider<BaiduNetdiskApi>((ref) {
  return DefaultBaiduNetdiskApi(
    backgroundDownloader: ref.watch(backgroundFileDownloadServiceProvider),
  );
});

/// 百度网盘音频导入服务 provider。
final baiduNetdiskImportServiceProvider = Provider<BaiduNetdiskImportService>((
  ref,
) {
  return DefaultBaiduNetdiskImportService(
    credentialRepository: ref.watch(baiduCredentialRepositoryProvider),
    api: ref.watch(baiduNetdiskApiProvider),
    subtitleImporter: (item, {required text, required ext}) =>
        importLocalSubtitleWithRef(ref, item, text: text, ext: ext),
  );
});
