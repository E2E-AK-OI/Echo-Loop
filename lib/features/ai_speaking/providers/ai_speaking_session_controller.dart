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

import '../../../providers/short_audio_player_provider.dart';
import '../../../services/pronunciation/local_audio_clip_player.dart';
import '../data/ai_speaking_credential_store.dart';
import '../models/ai_speaking_message.dart';
import '../models/ai_speaking_session_state.dart';
import '../services/ai_chat_client.dart';
import '../services/ai_speaking_permission_service.dart';
import '../services/aliyun_realtime_asr_client.dart';
import '../services/aliyun_tts_client.dart';
import '../services/pcm_recorder.dart';
import 'ai_speaking_settings_provider.dart';

final pcmRecorderProvider = Provider<PcmRecorder>((ref) => RecordPcmRecorder());

final realtimeAsrClientProvider = Provider<RealtimeAsrClient>(
  (ref) => AliyunRealtimeAsrClient(),
);

final aiChatClientProvider = Provider<AiChatClient>(
  (ref) => HttpOpenAiCompatibleChatClient(),
);

final aiTtsClientProvider = Provider<AiTtsClient>((ref) => AliyunTtsClient());

class AiSpeakingSessionController extends Notifier<AiSpeakingSessionState> {
  final _uuid = const Uuid();

  RealtimeAsrSession? _asrSession;
  StreamSubscription<AsrTranscriptEvent>? _asrSubscription;
  StreamSubscription<Uint8List>? _pcmSubscription;
  PcmRecorder? _recorder;
  CancelToken? _chatCancelToken;
  CancelToken? _ttsCancelToken;
  int _turnId = 0;
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
    String? llmKey;
    String? dashscopeKey;
    try {
      final store = ref.read(aiSpeakingCredentialStoreProvider);
      llmKey = await store.readLlmApiKey(settings.llm.provider);
      dashscopeKey = await store.readDashscopeApiKey();
    } on AiSpeakingCredentialStoreException catch (error) {
      _setError(AiSpeakingErrorKind.missingConfig, error.message);
      return;
    }
    if (llmKey == null ||
        llmKey.trim().isEmpty ||
        dashscopeKey == null ||
        dashscopeKey.trim().isEmpty) {
      _setError(
        AiSpeakingErrorKind.missingConfig,
        '请先在设置页填写大模型与 DashScope 的 API Key',
      );
      return;
    }

    final granted = await permission.ensurePermission();
    if (!granted) {
      _setError(AiSpeakingErrorKind.permissionDenied, '需要麦克风权限才能进行语音练习');
      return;
    }

    _turnId++;
    final turnId = _turnId;
    RealtimeAsrSession? asrSession;
    PcmRecorder? recorder;
    late final Stream<Uint8List> pcmStream;
    try {
      asrSession = await ref
          .read(realtimeAsrClientProvider)
          .start(config: settings.speech, apiKey: dashscopeKey.trim());
      if (!_isActive(turnId)) {
        await asrSession.cancel();
        return;
      }
      final recorderInstance = ref.read(pcmRecorderProvider);
      recorder = recorderInstance;
      pcmStream = await recorderInstance.start();
      if (!_isActive(turnId)) {
        await recorderInstance.stop();
        await recorderInstance.dispose();
        await asrSession.cancel();
        return;
      }
    } on Object catch (error) {
      await asrSession?.cancel();
      await recorder?.dispose();
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
    _pcmSubscription = pcmStream.listen(
      (bytes) {
        if (!_isActive(turnId)) return;
        _asrSession?.appendPcm(bytes);
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
      clearError: true,
    );
  }

  Future<void> stopListening() async {
    if (state.phase != AiSpeakingPhase.listening) return;
    final turnId = _turnId;
    state = state.copyWith(phase: AiSpeakingPhase.finalizing);

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
    unawaited(ref.read(shortAudioPlayerProvider).stop());
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
    unawaited(ref.read(shortAudioPlayerProvider).stop());
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
    unawaited(ref.read(shortAudioPlayerProvider).stop());
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

  Future<void> _cleanupAsr() async {
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
      try {
        await recorder.dispose();
      } on Object {
        // dispose 失败不影响会话状态。
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
