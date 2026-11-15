/// 口语档位选择器：初级 / 中级 / 高级 / 特级。
///
/// 只负责展示与回调，档位状态由 [aiSpeakingLevelProvider] 持有。
library;

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../theme/app_theme.dart';
import '../models/ai_speaking_level.dart';

/// 档位名称的多语言映射。
String aiSpeakingLevelLabel(AppLocalizations l10n, AiSpeakingLevel level) {
  return switch (level) {
    AiSpeakingLevel.beginner => l10n.aiSpeakingLevelBeginner,
    AiSpeakingLevel.intermediate => l10n.aiSpeakingLevelIntermediate,
    AiSpeakingLevel.advanced => l10n.aiSpeakingLevelAdvanced,
    AiSpeakingLevel.expert => l10n.aiSpeakingLevelExpert,
  };
}

/// 档位说明的多语言映射。
String aiSpeakingLevelDescription(
  AppLocalizations l10n,
  AiSpeakingLevel level,
) {
  return switch (level) {
    AiSpeakingLevel.beginner => l10n.aiSpeakingLevelBeginnerDescription,
    AiSpeakingLevel.intermediate => l10n.aiSpeakingLevelIntermediateDescription,
    AiSpeakingLevel.advanced => l10n.aiSpeakingLevelAdvancedDescription,
    AiSpeakingLevel.expert => l10n.aiSpeakingLevelExpertDescription,
  };
}

/// 四档分段选择器，下方展示当前档位的一句话说明。
class AiSpeakingLevelSelector extends StatelessWidget {
  const AiSpeakingLevelSelector({
    required this.level,
    required this.onChanged,
    super.key,
  });

  final AiSpeakingLevel level;
  final ValueChanged<AiSpeakingLevel> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<AiSpeakingLevel>(
            showSelectedIcon: false,
            segments: [
              for (final option in AiSpeakingLevel.values)
                ButtonSegment<AiSpeakingLevel>(
                  value: option,
                  label: Text(
                    aiSpeakingLevelLabel(l10n, option),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
            ],
            selected: {level},
            onSelectionChanged: (selection) {
              if (selection.isEmpty) return;
              onChanged(selection.first);
            },
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          aiSpeakingLevelDescription(l10n, level),
          style: AppTextStyles.caption(context),
        ),
      ],
    );
  }
}
