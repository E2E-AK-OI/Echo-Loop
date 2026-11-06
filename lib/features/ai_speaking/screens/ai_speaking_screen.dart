import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../theme/app_theme.dart';
import '../models/ai_speaking_message.dart';
import '../models/ai_speaking_session_state.dart';
import '../providers/ai_speaking_session_controller.dart';
import '../services/ai_speaking_permission_service.dart';
import '../widgets/ai_speaking_composer.dart';
import '../widgets/ai_speaking_message_bubble.dart';
import '../widgets/ai_speaking_welcome.dart';
import 'ai_speaking_settings_screen.dart';

/// AI 口语自由练习页面。
class AiSpeakingScreen extends ConsumerStatefulWidget {
  const AiSpeakingScreen({super.key});

  @override
  ConsumerState<AiSpeakingScreen> createState() => _AiSpeakingScreenState();
}

class _AiSpeakingScreenState extends ConsumerState<AiSpeakingScreen> {
  late final AiSpeakingSessionController _controller;
  final _scrollController = ScrollController();
  final _textController = TextEditingController();
  final _inputFocus = FocusNode();
  Timer? _timer;
  Duration _recordDuration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(aiSpeakingSessionControllerProvider.notifier);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.stopActiveAudio();
    _scrollController.dispose();
    _textController.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _sendText() {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    _textController.clear();
    _inputFocus.unfocus();
    unawaited(_controller.sendText(text));
  }

  void _onStarterSelected(String prompt) {
    unawaited(_controller.sendText(prompt));
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const AiSpeakingSettingsScreen()),
    );
  }

  Future<void> _confirmNewConversation() async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.aiSpeakingNewConversation),
        content: Text(l10n.aiSpeakingNewConversationConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.aiSpeakingCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.aiSpeakingConfirm),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _controller.newConversation();
    }
  }

  void _handleStateChange(AiSpeakingSessionState next) {
    if (next.phase == AiSpeakingPhase.listening) {
      if (_timer == null) {
        _recordDuration = Duration.zero;
        _timer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (!mounted) return;
          setState(() => _recordDuration += const Duration(seconds: 1));
        });
      }
    } else {
      _timer?.cancel();
      _timer = null;
      _recordDuration = Duration.zero;
    }
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final state = ref.watch(aiSpeakingSessionControllerProvider);
    ref.listen<AiSpeakingSessionState>(
      aiSpeakingSessionControllerProvider,
      (previous, next) => _handleStateChange(next),
    );
    final hasMessages = state.messages.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.aiSpeakingTitle),
        actions: [
          IconButton(
            onPressed: hasMessages ? _confirmNewConversation : null,
            icon: const Icon(Icons.add_comment_outlined),
            tooltip: l10n.aiSpeakingNewConversation,
          ),
          IconButton(
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_outlined),
            tooltip: l10n.aiSpeakingSettingsTitle,
          ),
        ],
      ),
      body: Column(
        children: [
          if (state.phase == AiSpeakingPhase.error)
            _ErrorBanner(
              text: _errorText(l10n, state),
              detail: state.errorMessage,
              actionLabel: _errorActionLabel(l10n, state.errorKind),
              onAction: () => _handleErrorAction(state.errorKind),
              onDismiss: _controller.dismissError,
            ),
          Expanded(
            child: hasMessages
                ? ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.m,
                      AppSpacing.m,
                      AppSpacing.m,
                      AppSpacing.s,
                    ),
                    itemCount: state.messages.length,
                    itemBuilder: (context, index) {
                      final message = state.messages[index];
                      return AiSpeakingMessageBubble(
                        message: message,
                        onReplay: message.role == AiSpeakingRole.assistant
                            ? () => _controller.replayMessage(message.id)
                            : null,
                      );
                    },
                  )
                : AiSpeakingWelcome(onStarterSelected: _onStarterSelected),
          ),
          AiSpeakingComposer(
            state: state,
            textController: _textController,
            focusNode: _inputFocus,
            recordDuration: _recordDuration,
            onSend: _sendText,
            onStartListening: _controller.startListening,
            onStopListening: _controller.stopListening,
            onCancelListening: _controller.cancelListening,
            onStopGenerating: _controller.stopGenerating,
            onStopSpeaking: _controller.stopSpeaking,
          ),
        ],
      ),
    );
  }

  String _errorText(AppLocalizations l10n, AiSpeakingSessionState state) {
    return switch (state.errorKind) {
      AiSpeakingErrorKind.missingConfig => l10n.aiSpeakingMissingConfig,
      AiSpeakingErrorKind.permissionDenied => l10n.aiSpeakingPermissionDenied,
      AiSpeakingErrorKind.unsupportedPlatform =>
        l10n.aiSpeakingUnsupportedPlatform,
      AiSpeakingErrorKind.noSpeech => l10n.aiSpeakingNoSpeech,
      AiSpeakingErrorKind.asrFailed => l10n.aiSpeakingErrorAsr,
      AiSpeakingErrorKind.llmFailed => l10n.aiSpeakingErrorLlm,
      AiSpeakingErrorKind.ttsFailed => l10n.aiSpeakingErrorTts,
      null => '',
    };
  }

  String _errorActionLabel(AppLocalizations l10n, AiSpeakingErrorKind? kind) {
    return switch (kind) {
      AiSpeakingErrorKind.missingConfig => l10n.aiSpeakingSettingsTitle,
      AiSpeakingErrorKind.permissionDenied => l10n.aiSpeakingOpenSettings,
      AiSpeakingErrorKind.asrFailed ||
      AiSpeakingErrorKind.llmFailed ||
      AiSpeakingErrorKind.ttsFailed => l10n.aiSpeakingRetry,
      _ => l10n.aiSpeakingRetry,
    };
  }

  void _handleErrorAction(AiSpeakingErrorKind? kind) {
    switch (kind) {
      case AiSpeakingErrorKind.missingConfig:
        unawaited(_openSettings());
        return;
      case AiSpeakingErrorKind.permissionDenied:
        unawaited(ref.read(aiSpeakingPermissionServiceProvider).openSettings());
        return;
      case AiSpeakingErrorKind.asrFailed:
      case AiSpeakingErrorKind.llmFailed:
      case AiSpeakingErrorKind.ttsFailed:
        unawaited(_controller.retryLastTurn());
        return;
      case AiSpeakingErrorKind.unsupportedPlatform:
      case AiSpeakingErrorKind.noSpeech:
      case null:
        _controller.dismissError();
        return;
    }
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({
    required this.text,
    required this.detail,
    required this.actionLabel,
    required this.onAction,
    required this.onDismiss,
  });

  final String text;
  final String? detail;
  final String actionLabel;
  final VoidCallback onAction;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: colorScheme.errorContainer,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.m,
        AppSpacing.s,
        AppSpacing.s,
        AppSpacing.s,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, color: colorScheme.onErrorContainer),
          const SizedBox(width: AppSpacing.s),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  text,
                  style: TextStyle(color: colorScheme.onErrorContainer),
                ),
                if (detail != null && detail!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      detail!,
                      style: AppTextStyles.caption(context).copyWith(
                        color: colorScheme.onErrorContainer.withValues(
                          alpha: 0.75,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          TextButton(onPressed: onAction, child: Text(actionLabel)),
          IconButton(
            onPressed: onDismiss,
            icon: const Icon(Icons.close, size: 18),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}
