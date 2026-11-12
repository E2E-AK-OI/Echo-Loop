import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/short_audio_player_provider.dart';
import '../../../l10n/app_localizations.dart';
import '../../../services/byok_ai_service.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/common/app_dropdown.dart';
import '../data/ai_speaking_credential_store.dart';
import '../models/ai_llm_provider.dart';
import '../models/ai_speaking_settings.dart';
import '../providers/ai_speaking_session_controller.dart';
import '../providers/ai_speaking_settings_provider.dart';
import '../services/aliyun_tts_client.dart';

/// AI 设置页：大模型与阿里云语音服务配置。
class AiSpeakingSettingsScreen extends ConsumerStatefulWidget {
  const AiSpeakingSettingsScreen({super.key});

  @override
  ConsumerState<AiSpeakingSettingsScreen> createState() =>
      _AiSpeakingSettingsScreenState();
}

class _AiSpeakingSettingsScreenState
    extends ConsumerState<AiSpeakingSettingsScreen> {
  static const _ttsModels = <String>[
    AiSpeechConfig.defaultTtsModel,
    AiSpeechConfig.flashTtsModel,
  ];

  late final TextEditingController _baseUrlController;
  late final TextEditingController _modelController;
  late final TextEditingController _llmKeyController;
  late final TextEditingController _dashscopeKeyController;
  late final TextEditingController _workspaceController;
  bool _obscureLlmKey = true;
  bool _obscureDashscopeKey = true;
  bool _savingLlmKey = false;
  bool _savingDashscopeKey = false;
  bool _previewing = false;
  bool _loadingModels = false;
  List<String> _availableModels = const <String>[];

  @override
  void initState() {
    super.initState();
    final settings = ref.read(aiSpeakingSettingsProvider);
    _baseUrlController = TextEditingController(text: settings.llm.baseUrl);
    _modelController = TextEditingController(text: settings.llm.model);
    _llmKeyController = TextEditingController();
    _dashscopeKeyController = TextEditingController();
    _workspaceController = TextEditingController(
      text: settings.speech.workspaceId,
    );
    unawaited(_loadKeys(settings.llm.provider));
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _modelController.dispose();
    _llmKeyController.dispose();
    _dashscopeKeyController.dispose();
    _workspaceController.dispose();
    super.dispose();
  }

  Future<void> _loadKeys(AiLlmProvider provider) async {
    final store = ref.read(aiSpeakingCredentialStoreProvider);
    try {
      final llmKey = await store.readLlmApiKey(provider);
      final dashscopeKey = await store.readDashscopeApiKey();
      if (!mounted) return;
      setState(() {
        _llmKeyController.text = llmKey ?? '';
        _dashscopeKeyController.text = dashscopeKey ?? '';
      });
    } on AiSpeakingCredentialStoreException catch (error) {
      _showMessage(error.message);
    }
  }

  void _onProviderChanged(AiLlmProvider? provider) {
    if (provider == null) return;
    ref.read(aiSpeakingSettingsProvider.notifier).setProvider(provider);
    final settings = ref.read(aiSpeakingSettingsProvider);
    _baseUrlController.text = settings.llm.baseUrl;
    _modelController.text = settings.llm.model;
    setState(() => _availableModels = const <String>[]);
    unawaited(_loadKeys(provider));
  }

  /// 从当前供应商的 /models 接口拉取可选模型，失败时仅提示不影响手填。
  Future<void> _refreshModels() async {
    if (_loadingModels) return;
    setState(() => _loadingModels = true);
    try {
      final models = await ref.read(byokAiServiceProvider).listModels();
      if (!mounted) return;
      setState(() {
        _availableModels = models;
      });
      _showMessage('已获取 ${models.length} 个可用模型');
    } on ByokAiException catch (error) {
      if (mounted) _showMessage(error.message);
    } finally {
      if (mounted) setState(() => _loadingModels = false);
    }
  }

  Future<void> _saveLlmKey() async {
    if (_savingLlmKey) return;
    setState(() => _savingLlmKey = true);
    final l10n = AppLocalizations.of(context)!;
    final provider = ref.read(aiSpeakingSettingsProvider).llm.provider;
    final store = ref.read(aiSpeakingCredentialStoreProvider);
    final key = _llmKeyController.text.trim();
    try {
      if (key.isEmpty) {
        await store.deleteLlmApiKey(provider);
      } else {
        await store.writeLlmApiKey(provider, key);
      }
      ref.invalidate(aiSpeakingSecretStatusProvider);
      _showMessage(l10n.aiSpeakingSaved);
    } on AiSpeakingCredentialStoreException catch (error) {
      _showMessage(error.message);
    } finally {
      if (mounted) setState(() => _savingLlmKey = false);
    }
  }

  Future<void> _saveDashscopeKey() async {
    if (_savingDashscopeKey) return;
    setState(() => _savingDashscopeKey = true);
    final l10n = AppLocalizations.of(context)!;
    final store = ref.read(aiSpeakingCredentialStoreProvider);
    final key = _dashscopeKeyController.text.trim();
    try {
      if (key.isEmpty) {
        await store.deleteDashscopeApiKey();
      } else {
        await store.writeDashscopeApiKey(key);
      }
      ref.invalidate(aiSpeakingSecretStatusProvider);
      _showMessage(l10n.aiSpeakingSaved);
    } on AiSpeakingCredentialStoreException catch (error) {
      _showMessage(error.message);
    } finally {
      if (mounted) setState(() => _savingDashscopeKey = false);
    }
  }

  Future<void> _previewVoice() async {
    if (_previewing) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() => _previewing = true);
    try {
      final apiKey = await ref
          .read(aiSpeakingCredentialStoreProvider)
          .readDashscopeApiKey();
      if (apiKey == null || apiKey.trim().isEmpty) {
        _showMessage(l10n.aiSpeakingMissingConfig);
        return;
      }
      final config = ref.read(aiSpeakingSettingsProvider).speech;
      final path = await ref
          .read(aiTtsClientProvider)
          .synthesizeToFile(
            text: 'Hello! This is how I will sound during our English conversation.',
            config: config,
            apiKey: apiKey.trim(),
          );
      await ref
          .read(shortAudioPlayerProvider)
          .playFile(path, playbackKey: 'ai_speaking_preview');
    } on AiTtsException catch (error) {
      _showMessage(error.message);
    } on Object {
      _showMessage(l10n.aiSpeakingPreviewFailed);
    } finally {
      if (mounted) setState(() => _previewing = false);
    }
  }

  void _showMessage(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final settings = ref.watch(aiSpeakingSettingsProvider);
    final secretStatus = ref.watch(aiSpeakingSecretStatusProvider).value;
    final isCustom = settings.llm.provider.isCustom;
    final voiceOptions = AiSpeechConfig.voicesForModel(
      settings.speech.ttsModel,
    );
    final selectedVoice = AiSpeechConfig.resolveTtsVoice(
      model: settings.speech.ttsModel,
      voice: settings.speech.ttsVoice,
    );

    return Scaffold(
      appBar: AppBar(title: Text(l10n.aiSpeakingSettingsTitle)),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.m),
        children: [
          _SectionTitle(l10n.aiSpeakingLlmSection),
          _SettingsCard(
            children: [
              _FieldBlock(
                label: l10n.aiSpeakingProviderLabel,
                child: _dropdownContainer(
                  child: AppDropdown<AiLlmProvider>(
                    value: settings.llm.provider,
                    isExpanded: true,
                    items: AiLlmProvider.values
                        .map(
                          (provider) => DropdownMenuItem<AiLlmProvider>(
                            value: provider,
                            child: Text(_providerLabel(l10n, provider)),
                          ),
                        )
                        .toList(),
                    onChanged: _onProviderChanged,
                  ),
                ),
              ),
              _FieldBlock(
                label: l10n.aiSpeakingBaseUrlLabel,
                child: TextField(
                  controller: _baseUrlController,
                  enabled: isCustom,
                  keyboardType: TextInputType.url,
                  onChanged: (value) => ref
                      .read(aiSpeakingSettingsProvider.notifier)
                      .setBaseUrl(value),
                  decoration: InputDecoration(
                    hintText: 'https://api.example.com/v1',
                    errorText:
                        isCustom && !_isValidBaseUrl(settings.llm.baseUrl)
                        ? l10n.aiSpeakingInvalidBaseUrl
                        : null,
                  ),
                ),
              ),
              _FieldBlock(
                label: l10n.aiSpeakingApiKeyLabel,
                subtitle: secretStatus?.hasLlmApiKey == true
                    ? l10n.aiSpeakingKeyConfigured
                    : l10n.aiSpeakingKeyMissing,
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _llmKeyController,
                        obscureText: _obscureLlmKey,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: InputDecoration(
                          hintText: 'sk-...',
                          suffixIcon: IconButton(
                            onPressed: () => setState(
                              () => _obscureLlmKey = !_obscureLlmKey,
                            ),
                            icon: Icon(
                              _obscureLlmKey
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.s),
                    FilledButton(
                      onPressed: _savingLlmKey ? null : _saveLlmKey,
                      child: Text(l10n.aiSpeakingSave),
                    ),
                  ],
                ),
              ),
              _FieldBlock(
                label: l10n.aiSpeakingModelLabel,
                child: Row(
                  children: [
                    Expanded(
                      child: _availableModels.isEmpty && isCustom
                          ? TextField(
                              controller: _modelController,
                              onChanged: (value) => ref
                                  .read(aiSpeakingSettingsProvider.notifier)
                                  .setModel(value),
                              decoration: const InputDecoration(
                                hintText: 'model-name',
                              ),
                            )
                          : _buildModelDropdown(settings),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    IconButton(
                      onPressed: _loadingModels ? null : _refreshModels,
                      icon: _loadingModels
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh_rounded),
                    ),
                  ],
                ),
              ),
              _FieldBlock(
                label: l10n.aiSpeakingTemperatureLabel,
                child: Row(
                  children: [
                    Expanded(
                      child: Slider(
                        min: 0,
                        max: 2,
                        divisions: 20,
                        value: settings.llm.temperature,
                        label: settings.llm.temperature.toStringAsFixed(1),
                        onChanged: (value) => ref
                            .read(aiSpeakingSettingsProvider.notifier)
                            .setTemperature(value),
                      ),
                    ),
                    SizedBox(
                      width: 40,
                      child: Text(
                        settings.llm.temperature.toStringAsFixed(1),
                        textAlign: TextAlign.end,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.l),
          _SectionTitle(l10n.aiSpeakingSpeechSection),
          _SettingsCard(
            children: [
              _FieldBlock(
                label: l10n.aiSpeakingDashscopeKeyLabel,
                subtitle: secretStatus?.hasDashscopeApiKey == true
                    ? l10n.aiSpeakingKeyConfigured
                    : l10n.aiSpeakingKeyMissing,
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _dashscopeKeyController,
                        obscureText: _obscureDashscopeKey,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: InputDecoration(
                          hintText: 'sk-...',
                          suffixIcon: IconButton(
                            onPressed: () => setState(
                              () =>
                                  _obscureDashscopeKey = !_obscureDashscopeKey,
                            ),
                            icon: Icon(
                              _obscureDashscopeKey
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.s),
                    FilledButton(
                      onPressed: _savingDashscopeKey ? null : _saveDashscopeKey,
                      child: Text(l10n.aiSpeakingSave),
                    ),
                  ],
                ),
              ),
              _FieldBlock(
                label: l10n.aiSpeakingWorkspaceIdLabel,
                child: TextField(
                  controller: _workspaceController,
                  autocorrect: false,
                  enableSuggestions: false,
                  onChanged: (value) => ref
                      .read(aiSpeakingSettingsProvider.notifier)
                      .setWorkspaceId(value),
                  decoration: const InputDecoration(
                    hintText: 'workspace-id（可选）',
                  ),
                ),
              ),
              _FieldBlock(
                label: l10n.aiSpeakingAsrModelLabel,
                child: Text(
                  settings.speech.asrModel,
                  style: AppTextStyles.label(context),
                ),
              ),
              _FieldBlock(
                label: l10n.aiSpeakingTtsModelLabel,
                child: _dropdownContainer(
                  child: AppDropdown<String>(
                    value: settings.speech.ttsModel,
                    isExpanded: true,
                    items: _ttsModels
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
                          .setTtsModel(model);
                    },
                  ),
                ),
              ),
              _FieldBlock(
                label: l10n.aiSpeakingVoiceLabel,
                child: _dropdownContainer(
                  child: AppDropdown<String>(
                    value: selectedVoice,
                    isExpanded: true,
                    items: voiceOptions
                        .map(
                          (voice) => DropdownMenuItem<String>(
                            value: voice.value,
                            child: Text(
                              '${voice.label} (${voice.value})',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (voice) {
                      if (voice == null) return;
                      ref
                          .read(aiSpeakingSettingsProvider.notifier)
                          .setTtsVoice(voice);
                    },
                  ),
                ),
              ),
              _FieldBlock(
                label: l10n.aiSpeakingRateLabel,
                child: Row(
                  children: [
                    Expanded(
                      child: Slider(
                        min: 0.5,
                        max: 2,
                        divisions: 15,
                        value: settings.speech.ttsRate,
                        label: settings.speech.ttsRate.toStringAsFixed(1),
                        onChanged: (value) => ref
                            .read(aiSpeakingSettingsProvider.notifier)
                            .setTtsRate(value),
                      ),
                    ),
                    SizedBox(
                      width: 40,
                      child: Text(
                        settings.speech.ttsRate.toStringAsFixed(1),
                        textAlign: TextAlign.end,
                      ),
                    ),
                  ],
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.aiSpeakingAutoPlayLabel),
                value: settings.speech.autoPlay,
                onChanged: (value) => ref
                    .read(aiSpeakingSettingsProvider.notifier)
                    .setAutoPlay(value),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _previewing ? null : _previewVoice,
                  icon: _previewing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow_rounded),
                  label: Text(l10n.aiSpeakingPreview),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.l),
          _SettingsCard(
            children: [
              _FieldBlock(
                label: l10n.aiSpeakingPrivacyTitle,
                child: Text(
                  l10n.aiSpeakingPrivacyBody,
                  style: AppTextStyles.label(context).copyWith(height: 1.5),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 合并远程拉取结果、预设与当前值，保证下拉始终能显示当前选择。
  Widget _buildModelDropdown(AiSpeakingSettings settings) {
    final preset = AiLlmPreset.of(settings.llm.provider);
    final models = <String>{
      ..._availableModels,
      ...preset.models,
      if (settings.llm.model.isNotEmpty) settings.llm.model,
    }.toList();
    return _dropdownContainer(
      child: AppDropdown<String>(
        value: models.contains(settings.llm.model)
            ? settings.llm.model
            : models.first,
        isExpanded: true,
        items: models
            .map(
              (model) =>
                  DropdownMenuItem<String>(value: model, child: Text(model)),
            )
            .toList(),
        onChanged: (model) {
          if (model == null) return;
          _modelController.text = model;
          ref.read(aiSpeakingSettingsProvider.notifier).setModel(model);
        },
      ),
    );
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

  bool _isValidBaseUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
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
