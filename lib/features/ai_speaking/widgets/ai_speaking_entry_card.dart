import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/app_localizations.dart';
import '../../../router/app_router.dart';
import '../../../theme/app_theme.dart';
import '../models/ai_llm_provider.dart';
import '../providers/ai_speaking_settings_provider.dart';

/// 学习页的 AI 口语练习入口卡片。
class AiSpeakingEntryCard extends ConsumerWidget {
  const AiSpeakingEntryCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final settings = ref.watch(aiSpeakingSettingsProvider);

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => context.push(AppRoutes.aiSpeaking),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.m),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  Icons.record_voice_over_rounded,
                  color: colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: AppSpacing.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.aiSpeakingEntryTitle,
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      l10n.aiSpeakingEntrySubtitle,
                      style: AppTextStyles.label(context),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      '${_providerLabel(l10n, settings.llm.provider)} · ${settings.llm.model}',
                      style: AppTextStyles.caption(context),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.s),
              Icon(
                Icons.arrow_forward_ios_rounded,
                size: 16,
                color: colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _providerLabel(AppLocalizations l10n, AiLlmProvider provider) {
    return switch (provider) {
      AiLlmProvider.deepSeek => l10n.aiSpeakingProviderDeepSeek,
      AiLlmProvider.aliyunBailian => l10n.aiSpeakingProviderBailian,
      AiLlmProvider.openAi => l10n.aiSpeakingProviderOpenAi,
      AiLlmProvider.custom => l10n.aiSpeakingProviderCustom,
    };
  }
}
