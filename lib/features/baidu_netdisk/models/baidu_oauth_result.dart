/// 百度网盘授权结果。
///
/// WebView 授权页只负责拿到凭证或错误，由 Controller 决定后续加载流程。
library;

import 'baidu_credential_bundle.dart';

/// 授权结果。
sealed class BaiduOAuthResult {
  /// 构造授权结果。
  const BaiduOAuthResult();
}

/// 授权成功。
final class BaiduOAuthSuccess extends BaiduOAuthResult {
  /// 构造成功结果。
  const BaiduOAuthSuccess(this.credential);

  /// 拿到的凭证。
  final BaiduCredentialBundle credential;
}

/// 授权失败。
final class BaiduOAuthFailure extends BaiduOAuthResult {
  /// 构造失败结果。
  const BaiduOAuthFailure(this.message);

  /// 可展示给用户的错误信息。
  final String message;
}

/// 用户取消授权。
final class BaiduOAuthCancelled extends BaiduOAuthResult {
  /// 构造取消结果。
  const BaiduOAuthCancelled();
}
