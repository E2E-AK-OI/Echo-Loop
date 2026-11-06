import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../theme/app_theme.dart';
import '../models/ai_speaking_session_state.dart';

/// 底部输入与录音控制区。
class AiSpeakingComposer extends StatelessWidget {
  const AiSpeakingComposer({
    super.key,
    required this.state,
    required this.textController,
    required this.focusNode,
    required this.recordDuration,
    required this.onSend,
    required this.onStartListening,
    required this.onStopListening,
    required this.onCancelListening,
    required this.onStopGenerating,
    required this.onStopSpeaking,
  });

  final AiSpeakingSessionState state;
  final TextEditingController textController;
  final FocusNode focusNode;
  final Duration recordDuration;
  final VoidCallback onSend;
  final VoidCallback onStartListening;
  final VoidCallback onStopListening;
  final VoidCallback onCancelListening;
  final VoidCallback onStopGenerating;
  final VoidCallback onStopSpeaking;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          top: BorderSide(color: colorScheme.outlineVariant, width: 0.5),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.m,
            AppSpacing.s,
            AppSpacing.m,
            AppSpacing.s,
          ),
          child: switch (state.phase) {
            AiSpeakingPhase.listening => _buildListening(context, l10n),
            AiSpeakingPhase.finalizing => _buildBusy(
              context,
              l10n.aiSpeakingFinalizing,
            ),
            AiSpeakingPhase.thinking => _buildThinking(context, l10n),
            AiSpeakingPhase.speaking => _buildSpeaking(context, l10n),
            AiSpeakingPhase.idle ||
            AiSpeakingPhase.error => _buildInput(context, l10n),
          },
        ),
      ),
    );
  }

  Widget _buildInput(BuildContext context, AppLocalizations l10n) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: TextField(
            controller: textController,
            focusNode: focusNode,
            minLines: 1,
            maxLines: 4,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => onSend(),
            decoration: InputDecoration(
              hintText: l10n.aiSpeakingInputHint,
              filled: true,
              fillColor: colorScheme.surfaceContainerHighest,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.m,
                vertical: AppSpacing.s + 4,
              ),
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.s),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: textController,
          builder: (context, value, _) {
            final canSend = value.text.trim().isNotEmpty;
            return IconButton(
              onPressed: canSend ? onSend : null,
              icon: const Icon(Icons.send_rounded),
              color: colorScheme.primary,
              tooltip: l10n.aiSpeakingSend,
            );
          },
        ),
        const SizedBox(width: AppSpacing.xs),
        SizedBox(
          width: 52,
          height: 52,
          child: FilledButton(
            onPressed: onStartListening,
            style: FilledButton.styleFrom(
              padding: EdgeInsets.zero,
              shape: const CircleBorder(),
            ),
            child: const Icon(Icons.mic_rounded, size: 24),
          ),
        ),
      ],
    );
  }

  Widget _buildListening(BuildContext context, AppLocalizations l10n) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: colorScheme.primaryContainer,
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.mic_rounded, color: colorScheme.onPrimaryContainer),
        ),
        const SizedBox(width: AppSpacing.m),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${l10n.aiSpeakingListening}  ${_formatDuration(recordDuration)}',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                state.partialTranscript.isEmpty
                    ? l10n.aiSpeakingTapToFinish
                    : state.partialTranscript,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.label(context),
              ),
            ],
          ),
        ),
        TextButton(
          onPressed: onCancelListening,
          child: Text(l10n.aiSpeakingCancel),
        ),
        const SizedBox(width: AppSpacing.xs),
        FilledButton(
          onPressed: onStopListening,
          child: Text(l10n.aiSpeakingTapToFinish),
        ),
      ],
    );
  }

  Widget _buildThinking(BuildContext context, AppLocalizations l10n) {
    return Row(
      children: [
        const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: AppSpacing.m),
        Expanded(child: Text(l10n.aiSpeakingThinking)),
        TextButton(
          onPressed: onStopGenerating,
          child: Text(l10n.aiSpeakingStop),
        ),
      ],
    );
  }

  Widget _buildSpeaking(BuildContext context, AppLocalizations l10n) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(Icons.volume_up_rounded, color: colorScheme.primary),
        const SizedBox(width: AppSpacing.m),
        Expanded(child: Text(l10n.aiSpeakingSpeaking)),
        TextButton(onPressed: onStopSpeaking, child: Text(l10n.aiSpeakingStop)),
      ],
    );
  }

  Widget _buildBusy(BuildContext context, String label) {
    return Row(
      children: [
        const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: AppSpacing.m),
        Text(label),
      ],
    );
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}
