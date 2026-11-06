import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 登录入口（纯端侧版本已移除账户体系，保留空实现以兼容旧调用点）。
void openSignInPage(BuildContext context) {}

/// 受保护操作前检查。纯端侧没有登录，恒返回 true。
Future<bool> ensureSignedInForAction({
  required BuildContext context,
  required WidgetRef ref,
  required String title,
  required String message,
}) async => true;
