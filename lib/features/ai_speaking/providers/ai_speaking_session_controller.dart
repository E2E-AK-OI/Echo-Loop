/// AI 口语会话状态机。
///
/// 页面只调用控制器方法；录音、ASR、LLM 与 TTS 的异步回调都带 turnId，
/// 旧回合的结果会被丢弃，避免用户快速取消或重新开始后旧数据覆盖新状态。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../models/speech_practice_models.dart';
import '../../../providers/asr_model_installation_provider.dart';
import '../../../providers/offline_asr_settings_provider.dart';
import '../../../providers/short_audio_player_provider.dart';
import '../../../providers/tts/tts_controller_provider.dart';
import '../../../services/pronunciation/local_audio_clip_player.dart';
import '../../../services/recording_service.dart';
import '../../../services/speech_practice_platform.dart';
import '../data/ai_speaking_credential_store.dart';
import '../models/ai_speaking_message.dart';
import '../models/ai_speaking_session_state.dart';
import '../services/ai_chat_client.dart';
import '../services/ai_speaking_permission_service.dart';
import '../services/aliyun_realtime_asr_client.dart';
import '../services/aliyun_tts_client.dart';
import '../services/audio_level.dart';
import '../services/pcm_recorder.dart';
import 'ai_speaking_settings_provider.dart';
import 'speaking_engine_settings_provider.dart';

final pcmRecorderProvider = Provider<PcmRecorder>((ref) {
  final recorder = RecordPcmRecorder();
  // 录音器由 provider 持有并在容器销毁时释放；每轮对话只 stop，
  // 否则第二轮会对已 dispose 的原生录音器再次 start。
  ref.onDispose(() => unawaited(recorder.dispose()));
  return recorder;
});

final realtimeAsrClientProvider = Provider<RealtimeAsrClient>(
  (ref) => AliyunRealtimeAsrClient(),
);

final aiChatClientProvider = Provider<AiChatClient>(
  (ref) => HttpOpenAiCompatibleChatClient(),
);

final aiTtsClientProvider = Provider<AiTtsClient>((ref) => AliyunTtsClient());

/// 录音服务工厂；测试可替换为受控实例。
typedef AiSpeakingRecordingServiceFactory = RecordingService Function(
  SpeechPracticeBackend backend,
);

final aiSpeakingRecordingServiceFactoryProvider =
    Provider<AiSpeakingRecordingServiceFactory>((ref) => RecordingService.new);

/// AI 口语对本地语音合成的最小依赖边界。
abstract interface class AiSpeakingLocalTts {
  Future<AudioPlaybackResult> speak(String text, {required String key});

  Future<void> stop();
}

class _TtsControllerLocalTts implements AiSpeakingLocalTts {
  _TtsControllerLocalTts(this._ref);

  final Ref _ref;

  @override
  Future<AudioPlaybackResult> speak(String text, {required String key}) {
    return _ref
        .read(ttsControllerProvider.notifier)
        .speakWithResult(text, key: key);
  }

  @override
  Future<void> stop() => _ref.read(ttsControllerProvider.notifier).stop();
}

final aiSpeakingLocalTtsProvider = Provider<AiSpeakingLocalTts>(
  (ref) => _TtsControllerLocalTts(ref),
);

class AiSpeakingSessionController extends Notifier<AiSpeakingSessionState> {
  final _uuid = const Uuid();

  RealtimeAsrSession? _asrSession;
  StreamSubscription<AsrTranscriptEvent>? _asrSubscription;
  StreamSubscription<Uint8List>? _pcmSubscription;
  PcmRecorder? _recorder;
  RecordingService? _localRecordingService;
  StreamSubscription<SpeechPracticeEvent>? _localAsrSubscription;
  String? _localPromptId;
  bool _lastTtsWasLocal = false;
  CancelToken? _chatCancelToken;
  CancelToken? _ttsCancelToken;
  int _turnId = 0;
  int _lastPcmLevelAtMs = 0;
  bool _isDisposed = false;

  @override
  AiSpeakingSessionState build() {
    ref.onDispose(() {
      _isDisposed = true;
      _chatCancelToken?.cancel();
      _ttsCancelToken?.cancel();
      unawaited(_cleanupAsr());
    });
    return const AiSpeakingSessionState();
  }

  bool _isActive(int turnId) => !_isDisposed && turnId == _turnId;

  Future<void> startListening() async {
    if (state.phase == AiSpeakingPhase.listening ||
        state.phase == AiSpeakingPhase.finalizing ||
        state.phase == AiSpeakingPhase.thinking ||
        state.phase == AiSpeakingPhase.speaking) {
      return;
    }
    final permission = ref.read(aiSpeakingPermissionServiceProvider);
    if (!permission.isSupported) {
      _setError(AiSpeakingErrorKind.unsupportedPlatform, '当前平台不支持语音输入，请使用文字输入');
      return;
    }

    final settings = ref.read(aiSpeakingSettingsProvider);
    final engineSettings = ref.read(speakingEngineSettingsProvider);
    // 只有链路中仍使用 AI 语音服务时才要求 DashScope Key。
    final needsDashscopeKey =
        !engineSettings.usesLocalAsr || !engineSettings.usesLocalTts;
    String? llmKey;
    String? dashscopeKey;
    try {
      final store = ref.read(aiSpeakingCredentialStoreProvider);
      llmKey = await store.readLlmApiKey(settings.llm.provider);
      if (needsDashscopeKey) {
        dashscopeKey = await store.readDashscopeApiKey();
      }
    } on AiSpeakingCredentialStoreException catch (error) {
      _setError(AiSpeakingErrorKind.missingConfig, error.message);
      return;
    }
    if (llmKey == null ||
        llmKey.trim().isEmpty ||
        (needsDashscopeKey &&
            (dashscopeKey == null || dashscopeKey.trim().isEmpty))) {
      _setError(
        AiSpeakingErrorKind.missingConfig,
        needsDashscopeKey
            ? '请先在设置页填写大模型与 DashScope 的 API Key'
            : '请先在设置页填写大模型 API Key',
      );
      return;
    }
    if (engineSettings.usesLocalAsr && !await _ensureLocalAsrReady()) {
      return;
    }

    final granted = await permission.ensurePermission();
    if (!granted) {
      _setError(AiSpeakingErrorKind.permissionDenied, '需要麦克风权限才能进行语音练习');
      return;
    }

    _turnId++;
    final turnId = _turnId;
    if (engineSettings.usesLocalAsr) {
      await _startLocalListening(turnId);
      return;
    }
    RealtimeAsrSession? asrSession;
    PcmRecorder? recorder;
    late final Stream<Uint8List> pcmStream;
    final dashscopeApiKey = dashscopeKey?.trim() ?? '';
    try {
      asrSession = await ref
          .read(realtimeAsrClientProvider)
          .start(config: settings.speech, apiKey: dashscopeApiKey);
      if (!_isActive(turnId)) {
        await asrSession.cancel();
        return;
      }
      final recorderInstance = ref.read(pcmRecorderProvider);
      recorder = recorderInstance;
      pcmStream = await recorderInstance.start();
      if (!_isActive(turnId)) {
        await recorderInstance.stop();
        await asrSession.cancel();
        return;
      }
    } on Object catch (error) {
      await asrSession?.cancel();
      try {
        await recorder?.stop();
      } on Object {
        // 启动失败时录音器可能尚未真正开始，停止失败不应掩盖原始错误。
      }
      if (_isActive(turnId)) {
        _setError(AiSpeakingErrorKind.asrFailed, '启动语音识别失败：$error');
      }
      return;
    }

    _asrSession = asrSession;
    _recorder = recorder;
    _asrSubscription = asrSession.events.listen(
      (event) {
        if (!_isActive(turnId)) return;
        state = state.copyWith(partialTranscript: event.text);
      },
      onError: (Object error) {
        if (!_isActive(turnId)) return;
        _setError(AiSpeakingErrorKind.asrFailed, '语音识别失败：$error');
        unawaited(_cleanupAsr());
      },
    );
    _lastPcmLevelAtMs = 0;
    _pcmSubscription = pcmStream.listen(
      (bytes) {
        if (!_isActive(turnId)) return;
        _asrSession?.appendPcm(bytes);
        // 原始 PCM 每 20~40ms 到达一帧，节流后再刷新 UI，避免过度重建。
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - _lastPcmLevelAtMs >= 80) {
          _lastPcmLevelAtMs = now;
          state = state.copyWith(
            inputLevel: normalizeAudioLevel(pcm16Rms(bytes)),
          );
        }
      },
      onError: (Object error) {
        if (!_isActive(turnId)) return;
        _setError(AiSpeakingErrorKind.asrFailed, '录音读取失败：$error');
        unawaited(_cleanupAsr());
      },
    );
    state = state.copyWith(
      phase: AiSpeakingPhase.listening,
      partialTranscript: '',
      inputLevel: 0,
      clearError: true,
    );
  }

  Future<void> stopListening() async {
    if (state.phase != AiSpeakingPhase.listening) return;
    final turnId = _turnId;
    state = state.copyWith(phase: AiSpeakingPhase.finalizing, inputLevel: 0);
    if (_localRecordingService != null) {
      await _stopLocalListening(turnId);
      return;
    }

    await _pcmSubscription?.cancel();
    _pcmSubscription = null;
    try {
      await _recorder?.stop();
    } on Object {
      // 录音停止失败不应掩盖后续的识别结果。
    }

    String transcript = '';
    try {
      transcript = await _asrSession?.finish() ?? '';
    } on Object catch (error) {
      await _cleanupAsr();
      if (_isActive(turnId)) {
        _setError(AiSpeakingErrorKind.asrFailed, '语音识别失败：$error');
      }
      return;
    }
    await _cleanupAsr();
    if (!_isActive(turnId)) return;

    final normalized = transcript.trim();
    if (normalized.isEmpty) {
      state = state.copyWith(
        phase: AiSpeakingPhase.idle,
        partialTranscript: '',
        clearError: true,
      );
      return;
    }
    state = state.copyWith(partialTranscript: '', clearError: true);
    await _sendUserTurn(normalized, turnId);
  }

  Future<void> cancelListening() async {
    if (state.phase != AiSpeakingPhase.listening &&
        state.phase != AiSpeakingPhase.finalizing) {
      return;
    }
    _turnId++;
    await _cleanupAsr();
    state = state.copyWith(
      phase: AiSpeakingPhase.idle,
      partialTranscript: '',
      inputLevel: 0,
      clearError: true,
    );
  }

  Future<void> sendText(String text) async {
    final normalized = text.trim();
    if (normalized.isEmpty) return;
    if (state.phase == AiSpeakingPhase.listening ||
        state.phase == AiSpeakingPhase.finalizing ||
        state.phase == AiSpeakingPhase.thinking ||
        state.phase == AiSpeakingPhase.speaking) {
      return;
    }
    _turnId++;
    final turnId = _turnId;
    state = state.copyWith(clearError: true);
    await _sendUserTurn(normalized, turnId);
  }

  Future<void> retryLastTurn() async {
    if (state.phase == AiSpeakingPhase.thinking ||
        state.phase == AiSpeakingPhase.speaking ||
        state.phase == AiSpeakingPhase.listening ||
        state.phase == AiSpeakingPhase.finalizing) {
      return;
    }
    final messages = List<AiSpeakingMessage>.from(state.messages);
    if (messages.isEmpty) return;

    // 朗读失败时回复已经生成完成，只需重试语音合成，避免重复请求大模型。
    if (state.errorKind == AiSpeakingErrorKind.ttsFailed &&
        messages.last.role == AiSpeakingRole.assistant &&
        messages.last.status == AiSpeakingMessageStatus.done) {
      final lastAssistant = messages.last;
      _turnId++;
      final turnId = _turnId;
      state = state.copyWith(clearError: true);
      await _speakAssistant(turnId, lastAssistant.id, lastAssistant.content);
      return;
    }

    if (messages.last.role == AiSpeakingRole.assistant &&
        messages.last.status == AiSpeakingMessageStatus.error) {
      messages.removeLast();
    }
    // 只有最后一条是用户消息时才能重新请求回复；否则说明识别在产生用户消息前就失败了，
    // 此时直接重新开始录音更符合预期。
    if (messages.isEmpty || messages.last.role != AiSpeakingRole.user) {
      if (state.errorKind == AiSpeakingErrorKind.asrFailed) {
        await startListening();
      }
      return;
    }
    _turnId++;
    final turnId = _turnId;
    state = state.copyWith(
      messages: messages,
      phase: AiSpeakingPhase.thinking,
      clearError: true,
    );
    await _requestAssistantReply(turnId);
  }

  Future<void> newConversation() async {
    _turnId++;
    _chatCancelToken?.cancel();
    _ttsCancelToken?.cancel();
    _stopTtsPlayback();
    await _cleanupAsr();
    state = const AiSpeakingSessionState();
  }

  /// 重新朗读一条已完成的 AI 回复。
  Future<void> replayMessage(String messageId) async {
    if (state.phase == AiSpeakingPhase.listening ||
        state.phase == AiSpeakingPhase.finalizing ||
        state.phase == AiSpeakingPhase.thinking ||
        state.phase == AiSpeakingPhase.speaking) {
      return;
    }
    AiSpeakingMessage? target;
    for (final message in state.messages) {
      if (message.id == messageId) {
        target = message;
        break;
      }
    }
    if (target == null ||
        target.role != AiSpeakingRole.assistant ||
        target.status != AiSpeakingMessageStatus.done ||
        target.content.trim().isEmpty) {
      return;
    }
    _turnId++;
    final turnId = _turnId;
    state = state.copyWith(clearError: true);
    await _speakAssistant(turnId, target.id, target.content);
  }

  void stopGenerating() {
    if (state.phase != AiSpeakingPhase.thinking) return;
    _turnId++;
    _chatCancelToken?.cancel();
    final messages = state.messages
        .where((message) => message.status != AiSpeakingMessageStatus.streaming)
        .toList();
    state = state.copyWith(
      messages: messages,
      phase: AiSpeakingPhase.idle,
      clearError: true,
    );
  }

  void stopSpeaking() {
    if (state.phase != AiSpeakingPhase.speaking) return;
    _turnId++;
    _ttsCancelToken?.cancel();
    _stopTtsPlayback();
    state = state.copyWith(phase: AiSpeakingPhase.idle, clearError: true);
  }

  /// 用户关闭错误提示后回到空闲状态。
  void dismissError() {
    if (state.phase != AiSpeakingPhase.error) return;
    state = state.copyWith(phase: AiSpeakingPhase.idle, clearError: true);
  }

  /// 页面退出时停止录音、识别、生成与朗读，但保留当前对话内容。
  void stopActiveAudio() {
    _turnId++;
    _chatCancelToken?.cancel();
    _ttsCancelToken?.cancel();
    _stopTtsPlayback();
    unawaited(_cleanupAsr());
    if (state.phase != AiSpeakingPhase.idle) {
      state = state.copyWith(phase: AiSpeakingPhase.idle, clearError: true);
    }
  }

  Future<void> _sendUserTurn(String text, int turnId) async {
    if (!_isActive(turnId)) return;
    final userMessage = AiSpeakingMessage(
      id: _uuid.v4(),
      role: AiSpeakingRole.user,
      content: text,
      status: AiSpeakingMessageStatus.done,
      createdAt: DateTime.now(),
    );
    state = state.copyWith(
      messages: [...state.messages, userMessage],
      phase: AiSpeakingPhase.thinking,
      clearError: true,
    );
    await _requestAssistantReply(turnId);
  }

  Future<void> _requestAssistantReply(int turnId) async {
    if (!_isActive(turnId)) return;
    final settings = ref.read(aiSpeakingSettingsProvider);
    String? apiKey;
    try {
      apiKey = await ref
          .read(aiSpeakingCredentialStoreProvider)
          .readLlmApiKey(settings.llm.provider);
    } on AiSpeakingCredentialStoreException catch (error) {
      if (_isActive(turnId)) {
        _setError(AiSpeakingErrorKind.missingConfig, error.message);
      }
      return;
    }
    if (apiKey == null || apiKey.trim().isEmpty) {
      if (!_isActive(turnId)) return;
      _setError(AiSpeakingErrorKind.missingConfig, '请先在设置页填写大模型 API Key');
      return;
    }

    final assistantId = _uuid.v4();
    final history = List<AiSpeakingMessage>.from(state.messages);
    final placeholder = AiSpeakingMessage(
      id: assistantId,
      role: AiSpeakingRole.assistant,
      content: '',
      status: AiSpeakingMessageStatus.streaming,
      createdAt: DateTime.now(),
    );
    state = state.copyWith(
      messages: [...state.messages, placeholder],
      phase: AiSpeakingPhase.thinking,
      clearError: true,
    );

    _chatCancelToken = CancelToken();
    var buffer = '';
    try {
      final stream = ref
          .read(aiChatClientProvider)
          .streamReply(
            config: settings.llm,
            apiKey: apiKey.trim(),
            history: history,
            cancelToken: _chatCancelToken,
          );
      await for (final delta in stream) {
        if (!_isActive(turnId)) return;
        buffer += delta;
        _updateAssistant(assistantId, content: buffer);
      }
    } on AiChatException catch (error) {
      if (!_isActive(turnId) || error.kind == AiChatErrorKind.cancelled) {
        return;
      }
      _updateAssistant(
        assistantId,
        content: buffer.isEmpty ? '回复生成失败' : buffer,
        status: AiSpeakingMessageStatus.error,
      );
      _setError(AiSpeakingErrorKind.llmFailed, error.message);
      return;
    } on Object catch (error) {
      if (!_isActive(turnId)) return;
      _updateAssistant(
        assistantId,
        content: buffer.isEmpty ? '回复生成失败' : buffer,
        status: AiSpeakingMessageStatus.error,
      );
      _setError(AiSpeakingErrorKind.llmFailed, '生成回复失败：$error');
      return;
    }

    if (!_isActive(turnId)) return;
    final reply = buffer.trim();
    if (reply.isEmpty) {
      _updateAssistant(
        assistantId,
        content: '回复为空',
        status: AiSpeakingMessageStatus.error,
      );
      _setError(AiSpeakingErrorKind.llmFailed, '大模型没有返回内容');
      return;
    }
    _updateAssistant(
      assistantId,
      content: reply,
      status: AiSpeakingMessageStatus.done,
    );

    if (!settings.speech.autoPlay) {
      state = state.copyWith(phase: AiSpeakingPhase.idle, clearError: true);
      return;
    }
    await _speakAssistant(turnId, assistantId, reply);
  }

  Future<void> _speakAssistant(
    int turnId,
    String assistantId,
    String text,
  ) async {
    if (!_isActive(turnId)) return;
    if (ref.read(speakingEngineSettingsProvider).usesLocalTts) {
      await _speakWithLocalTts(turnId, assistantId, text);
      return;
    }
    String? apiKey;
    try {
      apiKey = await ref
          .read(aiSpeakingCredentialStoreProvider)
          .readDashscopeApiKey();
    } on AiSpeakingCredentialStoreException catch (error) {
      if (_isActive(turnId)) {
        _setError(AiSpeakingErrorKind.ttsFailed, error.message);
      }
      return;
    }
    if (apiKey == null || apiKey.trim().isEmpty) {
      if (!_isActive(turnId)) return;
      _setError(AiSpeakingErrorKind.ttsFailed, '请先填写 DashScope API Key');
      return;
    }

    state = state.copyWith(phase: AiSpeakingPhase.speaking, clearError: true);
    _ttsCancelToken = CancelToken();
    String audioPath;
    try {
      final config = ref.read(aiSpeakingSettingsProvider).speech;
      audioPath = await ref
          .read(aiTtsClientProvider)
          .synthesizeToFile(
            text: text,
            config: config,
            apiKey: apiKey.trim(),
            cancelToken: _ttsCancelToken,
          );
    } on AiTtsException catch (error) {
      if (!_isActive(turnId) || error.kind == AiTtsErrorKind.cancelled) return;
      _setError(AiSpeakingErrorKind.ttsFailed, error.message);
      return;
    } on Object catch (error) {
      if (!_isActive(turnId)) return;
      _setError(AiSpeakingErrorKind.ttsFailed, '语音合成失败：$error');
      return;
    }
    if (!_isActive(turnId)) return;
    _updateAssistant(assistantId, audioPath: audioPath);
    try {
      final result = await ref
          .read(shortAudioPlayerProvider)
          .playFile(audioPath, playbackKey: assistantId);
      if (!_isActive(turnId)) return;
      if (result == AudioPlaybackResult.failed) {
        _setError(AiSpeakingErrorKind.ttsFailed, '音频播放失败');
        return;
      }
      if (result == AudioPlaybackResult.cancelled) return;
    } on Object catch (error) {
      if (!_isActive(turnId)) return;
      _setError(AiSpeakingErrorKind.ttsFailed, '音频播放失败：$error');
      return;
    }
    if (!_isActive(turnId)) return;
    state = state.copyWith(phase: AiSpeakingPhase.idle, clearError: true);
  }

  void _updateAssistant(
    String id, {
    String? content,
    AiSpeakingMessageStatus? status,
    String? audioPath,
  }) {
    final messages = state.messages
        .map(
          (message) => message.id == id
              ? message.copyWith(
                  content: content,
                  status: status,
                  audioPath: audioPath,
                )
              : message,
        )
        .toList();
    state = state.copyWith(messages: messages);
  }

  void _setError(AiSpeakingErrorKind kind, String message) {
    state = state.copyWith(
      phase: AiSpeakingPhase.error,
      errorKind: kind,
      errorMessage: message,
    );
  }

  /// 确保本地离线识别模型已下载并加载到内存。
  Future<bool> _ensureLocalAsrReady() async {
    final asrSettings = ref.read(offlineAsrSettingsProvider);
    // 平台识别（如 Apple Speech）不需要下载本地模型。
    if (asrSettings.backend == AsrBackend.platform) return true;
    if (asrSettings.isOfflineReady) return true;
    try {
      await ref
          .read(asrModelInstallationGateProvider)
          .ensureInstallationStatesLoaded();
      await ref.read(offlineAsrSettingsProvider.notifier).loadEngine();
    } on Object catch (error) {
      _setError(AiSpeakingErrorKind.asrFailed, '本地语音识别初始化失败：$error');
      return false;
    }
    if (ref.read(offlineAsrSettingsProvider).isOfflineReady) return true;
    _setError(AiSpeakingErrorKind.asrFailed, '本地语音识别模型尚未就绪，请先在语音识别设置中下载并启用模型');
    return false;
  }

  /// 启动本地录音；识别在停止后由离线模型完成。
  Future<void> _startLocalListening(int turnId) async {
    final promptId = 'ai-speaking-${_uuid.v4()}';
    final service = ref.read(aiSpeakingRecordingServiceFactoryProvider)(
      ref.read(speechPracticeBackendProvider),
    );
    _localRecordingService = service;
    _localPromptId = promptId;
    _localAsrSubscription = service.events.listen(
      (event) {
        if (!_isActive(turnId)) return;
        if (event.type == SpeechPracticeEventType.audioLevel) {
          state = state.copyWith(
            inputLevel: normalizeAudioLevel(event.audioLevel ?? 0),
          );
          return;
        }
        if (event.type != SpeechPracticeEventType.partialTranscriptUpdated) {
          return;
        }
        final transcript = event.transcript?.trim() ?? '';
        if (transcript.isEmpty) return;
        state = state.copyWith(partialTranscript: transcript);
      },
      onError: (Object error) {
        if (!_isActive(turnId)) return;
        _setError(AiSpeakingErrorKind.asrFailed, '语音识别失败：$error');
        unawaited(_cleanupAsr());
      },
    );
    final usesPlatformRecognition =
        ref.read(offlineAsrSettingsProvider).backend == AsrBackend.platform;
    try {
      await service.startRecording(
        promptId: promptId,
        recognitionEnabled: usesPlatformRecognition,
      );
    } on Object catch (error) {
      await _cleanupAsr();
      if (_isActive(turnId)) {
        _setError(AiSpeakingErrorKind.asrFailed, '启动语音识别失败：$error');
      }
      return;
    }
    if (!_isActive(turnId)) {
      await _cleanupAsr();
      return;
    }
    state = state.copyWith(
      phase: AiSpeakingPhase.listening,
      partialTranscript: '',
      inputLevel: 0,
      clearError: true,
    );
  }

  /// 停止本地录音并等待离线模型给出最终文本。
  Future<void> _stopLocalListening(int turnId) async {
    final service = _localRecordingService;
    final promptId = _localPromptId;
    if (service == null || promptId == null) {
      await _cleanupAsr();
      if (!_isActive(turnId)) return;
      state = state.copyWith(
        phase: AiSpeakingPhase.idle,
        partialTranscript: '',
        clearError: true,
      );
      return;
    }

    String? transcript;
    String? errorMessage;
    try {
      final stopped = await service.stopSession(promptId: promptId);
      final filePath = stopped.filePath;
      if (stopped.errorCode != null) {
        errorMessage = stopped.errorMessage ?? '停止录音失败';
      } else if (filePath == null || filePath.isEmpty) {
        errorMessage = '录音文件缺失';
      } else {
        final result = await service.waitForTranscript(
          filePath: filePath,
          // 离线模型推理通常需要数秒，给足超时时间。
          timeout: const Duration(seconds: 30),
        );
        if (result.errorCode != null) {
          errorMessage = result.errorMessage ?? '本地语音识别失败';
        } else {
          transcript = result.finalTranscript;
        }
      }
    } on Object catch (error) {
      errorMessage = '本地语音识别失败：$error';
    }
    await _cleanupAsr();
    if (!_isActive(turnId)) return;
    if (errorMessage != null) {
      _setError(AiSpeakingErrorKind.asrFailed, errorMessage);
      return;
    }
    final normalized = (transcript ?? '').trim();
    if (normalized.isEmpty) {
      state = state.copyWith(
        phase: AiSpeakingPhase.idle,
        partialTranscript: '',
        clearError: true,
      );
      return;
    }
    state = state.copyWith(partialTranscript: '', clearError: true);
    await _sendUserTurn(normalized, turnId);
  }

  /// 使用语音合成设置中的本地引擎朗读回复。
  Future<void> _speakWithLocalTts(
    int turnId,
    String assistantId,
    String text,
  ) async {
    state = state.copyWith(phase: AiSpeakingPhase.speaking, clearError: true);
    _lastTtsWasLocal = true;
    late final AudioPlaybackResult result;
    try {
      result = await ref
          .read(aiSpeakingLocalTtsProvider)
          .speak(text, key: assistantId);
    } on Object catch (error) {
      _lastTtsWasLocal = false;
      if (!_isActive(turnId)) return;
      _setError(AiSpeakingErrorKind.ttsFailed, '本地语音合成失败：$error');
      return;
    }
    if (!_isActive(turnId)) {
      _lastTtsWasLocal = false;
      return;
    }
    _lastTtsWasLocal = false;
    if (result == AudioPlaybackResult.failed) {
      _setError(AiSpeakingErrorKind.ttsFailed, '本地语音合成失败，请检查语音合成设置');
      return;
    }
    if (result == AudioPlaybackResult.cancelled) return;
    state = state.copyWith(phase: AiSpeakingPhase.idle, clearError: true);
  }

  /// 停止当前可能正在播放的 AI 或本地语音。
  void _stopTtsPlayback() {
    unawaited(ref.read(shortAudioPlayerProvider).stop());
    if (_lastTtsWasLocal) {
      unawaited(ref.read(aiSpeakingLocalTtsProvider).stop());
      _lastTtsWasLocal = false;
    }
  }

  Future<void> _cleanupAsr() async {
    await _localAsrSubscription?.cancel();
    _localAsrSubscription = null;
    final localService = _localRecordingService;
    _localRecordingService = null;
    _localPromptId = null;
    if (localService != null) {
      try {
        await localService.cancelRecording(discardStoppedRecording: true);
      } on Object {
        // 录音已停止或服务已释放时忽略。
      }
      try {
        await localService.dispose();
      } on Object {
        // 清理阶段不掩盖原始错误。
      }
    }

    await _pcmSubscription?.cancel();
    _pcmSubscription = null;
    await _asrSubscription?.cancel();
    _asrSubscription = null;

    final recorder = _recorder;
    _recorder = null;
    if (recorder != null) {
      try {
        await recorder.stop();
      } on Object {
        // 已停止或平台不支持重复 stop，忽略。
      }
    }

    final asrSession = _asrSession;
    _asrSession = null;
    if (asrSession != null) {
      try {
        await asrSession.cancel();
      } on Object {
        // 会话已关闭时忽略。
      }
    }
  }
}

final aiSpeakingSessionControllerProvider =
    NotifierProvider<AiSpeakingSessionController, AiSpeakingSessionState>(
      AiSpeakingSessionController.new,
    );
