/// 口语引擎设置页：选择 AI 口语练习使用的语音识别、语音合成与 LLM。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../../providers/offline_asr_settings_provider.dart';
import '../../../providers/tts/kokoro_model_provider.dart';
import '../../../providers/tts/piper_model_provider.dart';
import '../../../providers/tts/tts_settings_provider.dart';
import '../../../services/tts/tts_engine.dart';
import '../../../screens/asr_settings_screen.dart';
import '../../../screens/tts_settings_screen.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/common/app_dropdown.dart';
import '../data/ai_speaking_credential_store.dart';
import '../models/ai_llm_provider.dart';
import '../models/ai_speaking_settings.dart';
import '../models/speaking_engine_settings.dart';
import '../providers/ai_speaking_settings_provider.dart';
import '../providers/speaking_engine_settings_provider.dart';
import 'ai_speaking_settings_screen.dart';

/// 口语引擎设置页。
class SpeakingEngineSettingsScreen extends ConsumerStatefulWidget {
  const SpeakingEngineSettingsScreen({super.key});

  @override
  ConsumerState<SpeakingEngineSettingsScreen> createState() =>
      _SpeakingEngineSettingsScreenState();
}

class _SpeakingEngineSettingsScreenState
    extends ConsumerState<SpeakingEngineSettingsScreen> {
  late Future<List<AiLlmProvider>> _configuredProviders;

  @override
  void initState() {
    super.initState();
    _configuredProviders = _loadConfiguredProviders();
  }

  /// 读取所有已保存 LLM Key 的供应商，只允许从中选择。
  Future<List<AiLlmProvider>> _loadConfiguredProviders() async {
    final store = ref.read(aiSpeakingCredentialStoreProvider);
    final configured = <AiLlmProvider>[];
    for (final provider in AiLlmProvider.values) {
      try {
        final status = await store.readStatus(provider);
        if (status.hasLlmApiKey) configured.add(provider);
      } on AiSpeakingCredentialStoreException {
        // 单个供应商读取失败不影响其他供应商的展示。
      }
    }
    return configured;
  }

  Future<void> _openAiSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const AiSpeakingSettingsScreen()),
    );
    if (!mounted) return;
    setState(() {
      _configuredProviders = _loadConfiguredProviders();
    });
  }

  Future<void> _openAsrSettings() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const AsrSettingsScreen()));
  }

  Future<void> _openTtsSettings() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const TtsSettingsScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final settings = ref.watch(speakingEngineSettingsProvider);
    final aiSettings = ref.watch(aiSpeakingSettingsProvider);
    final offlineAsr = ref.watch(offlineAsrSettingsProvider);
    final ttsSettings = ref.watch(ttsSettingsProvider);
    final secretStatus = ref.watch(aiSpeakingSecretStatusProvider);
    final hasDashscopeKey = secretStatus.value?.hasDashscopeApiKey ?? false;
    final needsDashscopeKey = !settings.usesLocalAsr || !settings.usesLocalTts;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.speakingEngineSettingsTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.m,
          AppSpacing.s,
          AppSpacing.m,
          AppSpacing.l,
        ),
        children: [
          _SectionTitle(l10n.speakingEngineLlmSection),
          _SettingsCard(children: [_buildLlmSection(l10n, aiSettings)]),
          if (needsDashscopeKey && !hasDashscopeKey) ...[
            const SizedBox(height: AppSpacing.m),
            _InlineNotice(
              message: l10n.speakingEngineDashscopeKeyMissing,
              actionLabel: l10n.speakingEngineOpenAiSettings,
              onAction: _openAiSettings,
            ),
          ],
          const SizedBox(height: AppSpacing.l),
          _SectionTitle(l10n.speakingEngineAsrSection),
          _SettingsCard(
            children: [
              RadioGroup<SpeakingAsrSource>(
                groupValue: settings.asrSource,
                onChanged: (source) {
                  if (source == null) return;
                  ref
                      .read(speakingEngineSettingsProvider.notifier)
                      .setAsrSource(source);
                },
                child: Column(
                  children: [
                    RadioListTile<SpeakingAsrSource>(
                      contentPadding: EdgeInsets.zero,
                      value: SpeakingAsrSource.ai,
                      title: Text(l10n.speakingEngineAsrAi),
                      subtitle: Text(
                        '${l10n.speakingEngineAsrAiDescription}\n'
                        '${aiSettings.speech.asrModel}',
                      ),
                    ),
                    const Divider(height: 1),
                    RadioListTile<SpeakingAsrSource>(
                      contentPadding: EdgeInsets.zero,
                      value: SpeakingAsrSource.local,
                      title: Text(l10n.speakingEngineAsrLocal),
                      subtitle: Text(
                        '${l10n.speakingEngineAsrLocalDescription}\n'
                        '${offlineAsr.selectedModel.displayName}',
                      ),
                    ),
                  ],
                ),
              ),
              if (settings.usesLocalAsr &&
                  offlineAsr.backend == AsrBackend.offline &&
                  !offlineAsr.isOfflineReady)
                _InlineNotice(
                  message: l10n.speakingEngineAsrNotReady,
                  actionLabel: l10n.speakingEngineOpenAsrSettings,
                  onAction: _openAsrSettings,
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.l),
          _SectionTitle(l10n.speakingEngineTtsSection),
          _SettingsCard(
            children: [
              RadioGroup<SpeakingTtsSource>(
                groupValue: settings.ttsSource,
                onChanged: (source) {
                  if (source == null) return;
                  ref
                      .read(speakingEngineSettingsProvider.notifier)
                      .setTtsSource(source);
                },
                child: Column(
                  children: [
                    RadioListTile<SpeakingTtsSource>(
                      contentPadding: EdgeInsets.zero,
                      value: SpeakingTtsSource.ai,
                      title: Text(l10n.speakingEngineTtsAi),
                      subtitle: Text(
                        '${l10n.speakingEngineTtsAiDescription}\n'
                        '${_aiTtsSummary(aiSettings.speech)}',
                      ),
                    ),
                    const Divider(height: 1),
                    RadioListTile<SpeakingTtsSource>(
                      contentPadding: EdgeInsets.zero,
                      value: SpeakingTtsSource.local,
                      title: Text(l10n.speakingEngineTtsLocal),
                      subtitle: Text(
                        '${l10n.speakingEngineTtsLocalDescription}\n'
                        '${_ttsEngineLabel(l10n, ttsSettings.engine)}'
                        '${_localVoiceSuffix(ttsSettings.activeVoiceName)}',
                      ),
                    ),
                  ],
                ),
              ),
              if (settings.usesLocalTts &&
                  ttsSettings.engine.requiresLocalModel &&
                  !_isLocalTtsReady(ttsSettings.engine))
                _InlineNotice(
                  message: l10n.speakingEngineTtsNotReady,
                  actionLabel: l10n.speakingEngineOpenTtsSettings,
                  onAction: _openTtsSettings,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLlmSection(
    AppLocalizations l10n,
    AiSpeakingSettings aiSettings,
  ) {
    return FutureBuilder<List<AiLlmProvider>>(
      future: _configuredProviders,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.m),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final providers = snapshot.data ?? const <AiLlmProvider>[];
        if (providers.isEmpty) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.speakingEngineNoConfiguredLlm,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton(
                  onPressed: _openAiSettings,
                  child: Text(l10n.speakingEngineOpenAiSettings),
                ),
              ),
            ],
          );
        }

        final currentProvider = providers.contains(aiSettings.llm.provider)
            ? aiSettings.llm.provider
            : null;
        final preset = currentProvider == null
            ? null
            : AiLlmPreset.of(currentProvider);
        final models = preset == null
            ? const <String>[]
            : <String>{
                ...preset.models,
                if (aiSettings.llm.model.isNotEmpty) aiSettings.llm.model,
              }.toList();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _FieldBlock(
              label: l10n.aiSpeakingProviderLabel,
              subtitle: l10n.speakingEngineLlmDescription,
              child: _dropdownContainer(
                child: AppDropdown<AiLlmProvider>(
                  value: currentProvider,
                  isExpanded: true,
                  items: providers
                      .map(
                        (provider) => DropdownMenuItem<AiLlmProvider>(
                          value: provider,
                          child: Text(_providerLabel(l10n, provider)),
                        ),
                      )
                      .toList(),
                  onChanged: (provider) {
                    if (provider == null) return;
                    ref
                        .read(aiSpeakingSettingsProvider.notifier)
                        .setProvider(provider);
                  },
                ),
              ),
            ),
            if (currentProvider == null)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Text(
                  l10n.speakingEngineSelectConfiguredLlm,
                  style: AppTextStyles.caption(context)
                      .copyWith(color: Theme.of(context).colorScheme.error),
                ),
              )
            else ...[
              _FieldBlock(
                label: l10n.aiSpeakingModelLabel,
                child: _dropdownContainer(
                  child: AppDropdown<String>(
                    value: models.contains(aiSettings.llm.model)
                        ? aiSettings.llm.model
                        : models.first,
                    isExpanded: true,
                    items: models
                        .map(
                          (model) => DropdownMenuItem<String>(
                            value: model,
                            child: Text(model),
                          ),
                        )
                        .toList(),
                    onChanged: (model) {
                      if (model == null) return;
                      ref
                          .read(aiSpeakingSettingsProvider.notifier)
                          .setModel(model);
                    },
                  ),
                ),
              ),
              _FieldBlock(
                label: l10n.aiSpeakingTemperatureLabel,
                subtitle: aiSettings.llm.temperature.toStringAsFixed(2),
                child: Slider(
                  value: aiSettings.llm.temperature.clamp(0.0, 2.0),
                  min: 0,
                  max: 2,
                  divisions: 20,
                  label: aiSettings.llm.temperature.toStringAsFixed(2),
                  onChanged: (value) {
                    ref
                        .read(aiSpeakingSettingsProvider.notifier)
                        .setTemperature(value);
                  },
                ),
              ),
            ],
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton(
                onPressed: _openAiSettings,
                child: Text(l10n.speakingEngineOpenAiSettings),
              ),
            ),
          ],
        );
      },
    );
  }

  bool _isLocalTtsReady(TtsEngineKind engine) {
    return switch (engine) {
      TtsEngineKind.kokoro => ref.watch(kokoroReadyProvider),
      TtsEngineKind.piper => ref.watch(piperReadyProvider),
      TtsEngineKind.platform || TtsEngineKind.edge => true,
    };
  }

  String _aiTtsSummary(AiSpeechConfig speech) {
    final voices = AiSpeechConfig.voicesForModel(speech.ttsModel);
    final voice = voices.firstWhere(
      (option) => option.value == speech.ttsVoice,
      orElse: () => voices.first,
    );
    return '${speech.ttsModel} · ${voice.label}';
  }

  String _localVoiceSuffix(String? voiceName) {
    if (voiceName == null || voiceName.isEmpty) return '';
    return ' · $voiceName';
  }

  String _ttsEngineLabel(AppLocalizations l10n, TtsEngineKind engine) {
    return switch (engine) {
      TtsEngineKind.platform => l10n.ttsEnginePlatform,
      TtsEngineKind.edge => l10n.ttsEngineEdge,
      TtsEngineKind.kokoro => l10n.ttsEngineEchoLoop,
      TtsEngineKind.piper => l10n.ttsEnginePiper,
    };
  }

  String _providerLabel(AppLocalizations l10n, AiLlmProvider provider) {
    return switch (provider) {
      AiLlmProvider.deepSeek => l10n.aiSpeakingProviderDeepSeek,
      AiLlmProvider.aliyunBailian => l10n.aiSpeakingProviderBailian,
      AiLlmProvider.openAi => l10n.aiSpeakingProviderOpenAi,
      AiLlmProvider.custom => l10n.aiSpeakingProviderCustom,
    };
  }

  Widget _dropdownContainer({required Widget child}) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
      decoration: BoxDecoration(
        border: Border.all(color: colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: child,
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: AppSpacing.xs, bottom: AppSpacing.s),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final divided = <Widget>[];
    for (var index = 0; index < children.length; index++) {
      if (index > 0) {
        divided.add(
          Divider(
            height: 1,
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        );
      }
      divided.add(children[index]);
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: divided,
        ),
      ),
    );
  }
}

class _FieldBlock extends StatelessWidget {
  const _FieldBlock({required this.label, required this.child, this.subtitle});

  final String label;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppTextStyles.sectionHeader(context)),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(subtitle!, style: AppTextStyles.caption(context)),
          ],
          const SizedBox(height: AppSpacing.s),
          child,
        ],
      ),
    );
  }
}

class _InlineNotice extends StatelessWidget {
  const _InlineNotice({required this.message, this.actionLabel, this.onAction});

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline,
            size: 20,
            color: theme.colorScheme.onSecondaryContainer,
          ),
          const SizedBox(width: AppSpacing.s),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ),
          ),
          if (actionLabel != null && onAction != null)
            TextButton(onPressed: onAction, child: Text(actionLabel!)),
        ],
      ),
    );
  }
}
