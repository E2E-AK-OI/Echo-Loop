import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../theme/app_theme.dart';
import '../models/ai_speaking_level.dart';
import '../models/ai_speaking_session_state.dart';

/// 底部输入与录音控制区。
class AiSpeakingComposer extends StatelessWidget {
  const AiSpeakingComposer({
    super.key,
    required this.state,
    required this.level,
    required this.textController,
    required this.focusNode,
    required this.recordDuration,
    required this.onSend,
    required this.onStartListening,
    required this.onStopListening,
    required this.onCancelListening,
    required this.onStopGenerating,
    required this.onStopSpeaking,
    required this.onStartSession,
    required this.onStopSession,
  });

  final AiSpeakingSessionState state;
  final AiSpeakingLevel level;
  final TextEditingController textController;
  final FocusNode focusNode;
  final Duration recordDuration;
  final VoidCallback onSend;
  final VoidCallback onStartListening;
  final VoidCallback onStopListening;
  final VoidCallback onCancelListening;
  final VoidCallback onStopGenerating;
  final VoidCallback onStopSpeaking;
  final VoidCallback onStartSession;
  final VoidCallback onStopSession;

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
          child: level.usesContinuousSession
              ? _buildSession(context, l10n)
              : _buildPushToTalk(context, l10n),
        ),
      ),
    );
  }

  /// 按键说话档位：每轮手动开始与结束。
  Widget _buildPushToTalk(BuildContext context, AppLocalizations l10n) {
    return switch (state.phase) {
      AiSpeakingPhase.preparing => _buildBusy(
        context,
        l10n.aiSpeakingPreparing,
      ),
      AiSpeakingPhase.listening => _buildListening(context, l10n),
      AiSpeakingPhase.finalizing => _buildBusy(
        context,
        l10n.aiSpeakingFinalizing,
      ),
      AiSpeakingPhase.thinking => _buildThinking(context, l10n),
      AiSpeakingPhase.speaking => _buildSpeaking(context, l10n),
      AiSpeakingPhase.idle ||
      AiSpeakingPhase.error => _buildInput(context, l10n),
    };
  }

  /// 免提会话档位：点一次开始、再点一次结束，轮次由 VAD 自动切分。
  Widget _buildSession(BuildContext context, AppLocalizations l10n) {
    return switch (state.phase) {
      AiSpeakingPhase.preparing => _buildSessionPreparing(context, l10n),
      AiSpeakingPhase.listening => _buildSessionListening(context, l10n),
      AiSpeakingPhase.finalizing => _buildBusy(
        context,
        l10n.aiSpeakingFinalizing,
      ),
      AiSpeakingPhase.thinking => _buildThinking(context, l10n),
      AiSpeakingPhase.speaking => _buildSpeaking(context, l10n),
      AiSpeakingPhase.idle ||
      AiSpeakingPhase.error => _buildSessionIdle(context, l10n),
    };
  }

  /// 会话未开始时仍可文字提问，麦克风按钮换成「开始对话」。
  Widget _buildSessionIdle(BuildContext context, AppLocalizations l10n) {
    return _buildInput(
      context,
      l10n,
      trailing: FilledButton.icon(
        onPressed: onStartSession,
        icon: const Icon(Icons.mic_rounded, size: 20),
        label: Text(l10n.aiSpeakingSessionStart),
        style: FilledButton.styleFrom(
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.m),
        ),
      ),
    );
  }

  /// 麦克风与识别连接尚未就绪：显示准备状态，并允许随时结束会话。
  Widget _buildSessionPreparing(BuildContext context, AppLocalizations l10n) {
    return Row(
      children: [
        const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: AppSpacing.m),
        Expanded(child: Text(l10n.aiSpeakingPreparing)),
        OutlinedButton(
          onPressed: onStopSession,
          child: Text(l10n.aiSpeakingSessionStop),
        ),
      ],
    );
  }

  Widget _buildSessionListening(BuildContext context, AppLocalizations l10n) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        _ListeningIndicator(level: state.inputLevel),
        const SizedBox(width: AppSpacing.m),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                l10n.aiSpeakingSessionActive,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                state.partialTranscript.isEmpty
                    ? l10n.aiSpeakingSessionHint
                    : state.partialTranscript,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.label(context),
              ),
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.xs),
        OutlinedButton(
          onPressed: onStopSession,
          child: Text(l10n.aiSpeakingSessionStop),
        ),
      ],
    );
  }

  Widget _buildInput(
    BuildContext context,
    AppLocalizations l10n, {
    Widget? trailing,
  }) {
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
        trailing ??
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
        _ListeningIndicator(level: state.inputLevel),
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
    // 高级档允许插话：朗读期间提示用户可以直接开口打断。
    final canBargeIn =
        level.allowsBargeIn &&
        state.isSessionActive &&
        state.isVoiceBargeInAvailable;
    final bargeInUnavailable =
        level.allowsBargeIn &&
        state.isSessionActive &&
        !state.isVoiceBargeInAvailable;
    return Row(
      children: [
        Icon(Icons.volume_up_rounded, color: colorScheme.primary),
        const SizedBox(width: AppSpacing.m),
        Expanded(
          child: canBargeIn
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(l10n.aiSpeakingSpeaking),
                    const SizedBox(height: 2),
                    Text(
                      l10n.aiSpeakingBargeInHint,
                      style: AppTextStyles.label(context),
                    ),
                  ],
                )
              : bargeInUnavailable
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(l10n.aiSpeakingSpeaking),
                    const SizedBox(height: 2),
                    Text(
                      l10n.aiSpeakingBargeInUnavailableHint,
                      style: AppTextStyles.label(context),
                    ),
                  ],
                )
              : Text(l10n.aiSpeakingSpeaking),
        ),
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

/// 录音中的话筒指示器：外圈随输入电平放大、颜色逐渐加深。
///
/// 电平由控制器按 80ms 节流更新，这里再用 120ms 补间，避免动画抖动。
class _ListeningIndicator extends StatelessWidget {
  const _ListeningIndicator({required this.level});

  final double level;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final target = level.isFinite ? level.clamp(0.0, 1.0) : 0.0;
    return SizedBox(
      width: 60,
      height: 60,
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(end: target),
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        builder: (context, animatedLevel, _) {
          final intensity = (animatedLevel * 1.6).clamp(0.0, 1.0);
          final glowDiameter = 44 + 14 * animatedLevel;
          return Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: glowDiameter,
                height: glowDiameter,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: colorScheme.primary.withValues(
                    alpha: 0.10 + 0.22 * animatedLevel,
                  ),
                ),
              ),
              Transform.scale(
                scale: 1 + 0.14 * animatedLevel,
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color.lerp(
                      colorScheme.primaryContainer,
                      colorScheme.primary,
                      intensity,
                    ),
                  ),
                  child: Icon(
                    Icons.mic_rounded,
                    color: Color.lerp(
                      colorScheme.onPrimaryContainer,
                      colorScheme.onPrimary,
                      intensity,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
