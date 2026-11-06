/// ChatApi 单例 provider。
library;

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../services/byok_ai_service.dart';
import '../chatbot_flags.dart';
import '../services/chat_api_client.dart';
import '../services/fake_chat_api_client.dart';

part 'chat_api_client_provider.g.dart';

/// ChatApi 单例（keepAlive）。
///
/// kChatbotUseFakeApi=true（仅 debug 联调用）时返回假实现；否则使用 BYOK 直连。
@Riverpod(keepAlive: true)
ChatApi chatApiClient(Ref ref) {
  if (kChatbotUseFakeApi) return const FakeChatApiClient();
  final client = ChatApiClient(byokService: ref.watch(byokAiServiceProvider));
  ref.onDispose(client.dispose);
  return client;
}
