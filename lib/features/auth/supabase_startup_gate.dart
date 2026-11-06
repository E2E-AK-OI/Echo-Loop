import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 纯端侧模式不使用 Supabase，认证能力恒为不可用。
final supabaseSdkReadyProvider = Provider<bool>((ref) => false);

/// 纯端侧模式没有远端认证配置。
final supabaseAuthConfiguredProvider = FutureProvider<bool>(
  (ref) async => false,
);
