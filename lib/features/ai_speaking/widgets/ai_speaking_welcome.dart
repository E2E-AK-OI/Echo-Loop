import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../theme/app_theme.dart';

/// AI 口语空态欢迎页。
class AiSpeakingWelcome extends StatelessWidget {
  const AiSpeakingWelcome({super.key, required this.onStarterSelected});

  final ValueChanged<String> onStarterSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.l,
            vertical: AppSpacing.xl,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight - 64),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [colorScheme.primary, colorScheme.tertiary],
                    ),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.record_voice_over_rounded,
                    size: 48,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: AppSpacing.l),
                Text(
                  l10n.aiSpeakingWelcomeTitle,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: AppSpacing.s),
                Text(
                  l10n.aiSpeakingWelcomeBody,
                  textAlign: TextAlign.center,
                  style: AppTextStyles.label(context).copyWith(height: 1.5),
                ),
                const SizedBox(height: AppSpacing.l),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: AppSpacing.s,
                  runSpacing: AppSpacing.s,
                  children: [
                    _StarterChip(
                      icon: Icons.wb_sunny_outlined,
                      label: l10n.aiSpeakingStarterDaily,
                      onTap: () => onStarterSelected(
                        'Let us talk about my day. Please ask me questions.',
                      ),
                    ),
                    _StarterChip(
                      icon: Icons.work_outline,
                      label: l10n.aiSpeakingStarterInterview,
                      onTap: () => onStarterSelected(
                        'I would like to practice a job interview in English.',
                      ),
                    ),
                    _StarterChip(
                      icon: Icons.landscape_outlined,
                      label: l10n.aiSpeakingStarterWeekend,
                      onTap: () => onStarterSelected(
                        'Let us plan a weekend trip together.',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xl),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.lock_outline,
                      size: 14,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Flexible(
                      child: Text(
                        l10n.aiSpeakingPrivacyNotice,
                        textAlign: TextAlign.center,
                        style: AppTextStyles.caption(context),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _StarterChip extends StatelessWidget {
  const _StarterChip({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      avatar: Icon(icon, size: 18),
      label: Text(label),
      onPressed: onTap,
      backgroundColor: Theme.of(context).colorScheme.surface,
      side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s,
        vertical: AppSpacing.xs,
      ),
    );
  }
}
