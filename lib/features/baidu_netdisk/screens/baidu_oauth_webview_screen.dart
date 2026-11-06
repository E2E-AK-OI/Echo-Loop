/// 百度网盘应用内授权页。
///
/// 使用 WebView 打开百度简化模式授权地址，并拦截 oob 回调
/// `https://openapi.baidu.com/oauth/2.0/login_success#access_token=...`。
/// 页面只负责拿凭证，目录加载由 Controller 处理。
library;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../l10n/app_localizations.dart';
import '../../../services/app_logger.dart';
import '../../../theme/app_theme.dart';
import '../data/baidu_implicit_oauth.dart';
import '../models/baidu_oauth_result.dart';

/// 百度网盘授权 WebView 页面。
class BaiduOAuthWebViewScreen extends StatefulWidget {
  /// 构造授权页。
  const BaiduOAuthWebViewScreen({
    super.key,
    required this.request,
    required this.oauth,
  });

  /// 授权请求。
  final BaiduAuthorizationRequest request;

  /// 授权解析服务。
  final BaiduImplicitOAuth oauth;

  @override
  State<BaiduOAuthWebViewScreen> createState() =>
      _BaiduOAuthWebViewScreenState();
}

class _BaiduOAuthWebViewScreenState extends State<BaiduOAuthWebViewScreen> {
  /// 只清理百度相关站点的 Cookie，避免影响其它站点的 WebView 登录态。
  static const List<String> _baiduCookieUrls = <String>[
    'https://openapi.baidu.com',
    'https://pan.baidu.com',
    'https://passport.baidu.com',
  ];

  bool _preparing = true;
  bool _loading = true;
  bool _failed = false;
  bool _completed = false;
  int _reloadToken = 0;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    if (widget.request.forceLogin) {
      for (final url in _baiduCookieUrls) {
        try {
          await CookieManager.instance().deleteCookies(url: WebUri(url));
        } catch (error) {
          AppLogger.log(
            'BAIDU-NETDISK',
            '清除百度登录态失败: url=$url type=${error.runtimeType}',
          );
        }
      }
    }
    if (!mounted) return;
    setState(() => _preparing = false);
  }

  void _handleUrl(WebUri? url) {
    if (_completed || url == null) return;
    final uri = Uri.tryParse(url.toString());
    if (uri == null || !widget.oauth.isCallback(uri)) return;
    _completed = true;
    try {
      final credential = widget.oauth.parseCallback(
        uri,
        expectedState: widget.request.state,
      );
      _finish(BaiduOAuthSuccess(credential));
    } on BaiduOAuthException catch (error) {
      _finish(BaiduOAuthFailure(error.message));
    } catch (error) {
      AppLogger.log('BAIDU-NETDISK', '解析授权回调失败: type=${error.runtimeType}');
      _finish(const BaiduOAuthFailure('百度授权失败，请重试。'));
    }
  }

  void _finish(BaiduOAuthResult result) {
    if (!mounted) return;
    Navigator.of(context).pop(result);
  }

  void _retry() {
    setState(() {
      _failed = false;
      _loading = true;
      _reloadToken++;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.baiduNetdiskAuthorizeTitle),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: l10n.baiduNetdiskClose,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: _preparing
          ? const Center(child: CircularProgressIndicator.adaptive())
          : Stack(
              fit: StackFit.expand,
              children: [
                InAppWebView(
                  key: ValueKey<int>(_reloadToken),
                  initialUrlRequest: URLRequest(
                    url: WebUri(widget.request.uri.toString()),
                  ),
                  initialSettings: InAppWebViewSettings(
                    javaScriptEnabled: true,
                    cacheEnabled: false,
                    transparentBackground: false,
                  ),
                  onLoadStart: (_, url) => _handleUrl(url),
                  onUpdateVisitedHistory: (_, url, _) => _handleUrl(url),
                  onLoadStop: (_, url) {
                    _handleUrl(url);
                    if (mounted && _loading) {
                      setState(() => _loading = false);
                    }
                  },
                  onReceivedError: (_, request, error) {
                    if (request.isForMainFrame != true) return;
                    AppLogger.log(
                      'BAIDU-NETDISK',
                      '授权页加载失败: type=${error.type} '
                          'description=${error.description}',
                    );
                    if (mounted) {
                      setState(() {
                        _loading = false;
                        _failed = true;
                      });
                    }
                  },
                ),
                if (_loading)
                  const ColoredBox(
                    color: Colors.white,
                    child: Center(child: CircularProgressIndicator.adaptive()),
                  ),
                if (_failed)
                  ColoredBox(
                    color: Theme.of(context).colorScheme.surface,
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(AppSpacing.m),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              l10n.baiduNetdiskAuthorizeFailed,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: AppSpacing.s),
                            FilledButton.tonal(
                              onPressed: _retry,
                              child: Text(l10n.baiduNetdiskRetry),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
