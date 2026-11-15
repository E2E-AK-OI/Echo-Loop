/// AI 口语会话状态机。
///
/// 页面只调用控制器方法；录音、ASR、LLM 与 TTS 的异步回调都带 turnId，
/// 旧回合的结果会被丢弃，避免用户快速取消或重新开始后旧数据覆盖新状态。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../models/speech_practice_models.dart';
import '../../../providers/asr_engine_provider.dart';
import '../../../providers/asr_model_installation_provider.dart';
import '../../../providers/offline_asr_settings_provider.dart';
import '../../../services/app_logger.dart';
import '../../../services/asr/asr_model_catalog.dart';
import '../../../providers/short_audio_player_provider.dart';
import '../../../providers/tts/tts_controller_provider.dart';
import '../../../services/pronunciation/local_audio_clip_player.dart';
import '../../../services/recording_service.dart';
import '../../../services/speech_practice_platform.dart';
import '../data/ai_speaking_credential_store.dart';
import '../models/ai_speaking_level.dart';
import '../models/ai_speaking_message.dart';
import '../models/ai_speaking_session_state.dart';
import '../models/ai_speaking_settings.dart';
import '../models/speaking_dialog_settings.dart';
import '../models/speaking_engine_settings.dart';
import '../models/speaking_level_config.dart';
import '../services/ai_chat_client.dart';
import '../services/ai_speaking_permission_service.dart';
import '../services/ai_speaking_prompts.dart';
import '../services/aliyun_file_asr_client.dart';
import '../services/aliyun_realtime_asr_client.dart';
import '../services/aliyun_tts_client.dart';
import '../services/aliyun_tts_stream_client.dart';
import '../services/audio_level.dart';
import '../services/echo_text_filter.dart';
import '../services/local_asr_streaming_transcriber.dart';
import '../services/pcm_recorder.dart';
import '../services/pcm_stream_player.dart';
import '../services/qwen_audio_realtime_client.dart';
import '../services/speech_sentence_splitter.dart';
import '../services/vad_turn_detector.dart';
import '../services/voice_audio_session.dart';
import '../services/voice_barge_in_guard.dart';
import 'ai_speaking_level_provider.dart';
import 'ai_speaking_settings_provider.dart';
import 'speaking_level_configs_provider.dart';

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

final fileAsrClientProvider = Provider<FileAsrClient>(
  (ref) => AliyunFileAsrClient(),
);

final aiChatClientProvider = Provider<AiChatClient>(
  (ref) => HttpOpenAiCompatibleChatClient(),
);

final aiTtsClientProvider = Provider<AiTtsClient>((ref) => AliyunTtsClient());

final aiTtsStreamClientProvider = Provider<AiTtsStreamClient>(
  (ref) => AliyunTtsStreamClient(),
);

final speechToSpeechClientProvider = Provider<SpeechToSpeechClient>(
  (ref) => QwenAudioRealtimeClient(),
);

/// 实时语音下行的流式播放器；仅 Android 提供原生实现。
final pcmStreamPlayerProvider = Provider<PcmStreamPlayer>((ref) {
  final player = PlatformPcmStreamPlayer();
  ref.onDispose(() => unawaited(player.stop()));
  return player;
});

/// 外放插话所需的系统音频会话；仅 Android 有原生实现。
final voiceAudioSessionProvider = Provider<VoiceAudioSession>(
  (ref) => PlatformVoiceAudioSession(),
);

/// 录音服务工厂；测试可替换为受控实例。
typedef AiSpeakingRecordingServiceFactory = RecordingService Function(
  SpeechPracticeBackend backend,
);

final aiSpeakingRecordingServiceFactoryProvider =
    Provider<AiSpeakingRecordingServiceFactory>((ref) => RecordingService.new);

/// AI 口语对本地语音合成的最小依赖边界。
abstract interface class AiSpeakingLocalTts {
  Future<AudioPlaybackResult> speak(String text, {required String key});

  /// 后台预合成一句文本，不播放；正式 [speak] 时可直接命中缓存。
  Future<void> prewarm(String text);

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
  Future<void> prewarm(String text) =>
      _ref.read(ttsControllerProvider.notifier).prewarmForReply(text);

  @override
  Future<void> stop() => _ref.read(ttsControllerProvider.notifier).stop();
}

final aiSpeakingLocalTtsProvider = Provider<AiSpeakingLocalTts>(
  (ref) => _TtsControllerLocalTts(ref),
);

/// 语音输入前的公共校验结果。
class _VoiceStartContext {
  const _VoiceStartContext({
    required this.settings,
    required this.speech,
    required this.engineSettings,
    required this.dashscopeApiKey,
  });

  /// 仅提供大模型配置；语音配置见 [speech]。
  final AiSpeakingSettings settings;

  /// 已合并账号级工作空间的语音配置。
  final AiSpeechConfig speech;
  final SpeakingEngineSettings engineSettings;
  final String dashscopeApiKey;
}

class AiSpeakingSessionController extends Notifier<AiSpeakingSessionState> {
  final _uuid = const Uuid();

  RealtimeAsrSession? _asrSession;
  StreamSubscription<AsrTranscriptEvent>? _asrSubscription;
  StreamSubscription<Uint8List>? _pcmSubscription;
  PcmRecorder? _recorder;
  RecordingService? _localRecordingService;
  StreamSubscription<SpeechPracticeEvent>? _localAsrSubscription;
  LocalAsrStreamingTranscriber? _localStreamingTranscriber;
  String? _localPromptId;
  bool _lastTtsWasLocal = false;
  CancelToken? _chatCancelToken;
  CancelToken? _ttsCancelToken;
  int _turnId = 0;
  int _lastPcmLevelAtMs = 0;
  bool _isDisposed = false;

  /// 免提会话（中级/高级）状态：录音在会话期间只启动一次。
  bool _isSessionActive = false;
  bool _isUtteranceOpen = false;
  VadTurnDetector? _vad;
  AiSpeechConfig? _sessionSpeech;
  String? _sessionDashscopeApiKey;

  /// 本地识别用原生静音事件兜底时的断句阈值，跟随当前档位设置。
  int _sessionEndOfSpeechMs = SpeakingDialogSettings.defaultEndOfSpeechMs;

  /// 高级档：AI 朗读期间允许用户插话打断。
  bool _allowsBargeIn = false;

  /// AI 朗读期间判定插话所用的 RMS 门限，来自「打断灵敏度」设置。
  double _bargeInThreshold = 0;

  /// AI 语音正在播放；期间不向 ASR 送流，避免扬声器回声被识别成用户输入。
  bool _isTtsActive = false;

  /// 外放插话判别器；仅在平台 AEC 可用且当前为内置扬声器时启用。
  final VoiceBargeInGuard _bargeInGuard = VoiceBargeInGuard();

  /// TTS 回声文本过滤；只保留最近朗读过的句子，用于丢弃 ASR 尾音。
  final EchoTextFilter _echoTextFilter = EchoTextFilter();

  /// 最近一次原生音频会话状态，决定录音源与 TTS 输出用途。
  VoiceAudioSessionStatus _voiceAudioStatus =
      const VoiceAudioSessionStatus.unsupported();
  bool _isVoiceAudioSessionActive = false;

  /// true 表示当前 TTS 正在走外放 guard（duck/确认）流程，而非 VAD 插话。
  bool _isSpeakerBargeInGuardActive = false;

  /// TTS 音量是否已被 guard 降低；停止播放时必须恢复。
  bool _isSpeakerBargeInDucked = false;

  /// 当前正在朗读的 AI 消息；用户打断时给它打上「已打断」标记。
  String? _activeAssistantId;

  /// 正在等待扬声器尾音衰减并恢复听音；期间同样关闭 ASR/VAD 输入。
  bool _isResumingListening = false;

  /// 恢复听音的代次；新的恢复或结束会话会让旧的延迟恢复失效。
  int _resumeListeningId = 0;

  /// 起音预录：用户开口前最多 400ms 的 PCM，开口时补发给 ASR。
  final List<Uint8List> _prerollFrames = [];
  int _prerollBytes = 0;

  /// 云端 ASR 建连握手期间为 true，此时放宽预录上限，避免丢掉用户刚说的开头。
  bool _isAsrStarting = false;

  /// 当前云端 ASR 的建连任务；收尾时要等它完成才能拿到会话。
  Future<void>? _asrStartFuture;

  /// 非实时识别模型需要先攒完整段音频，收尾时一次性上传。
  BytesBuilder? _batchAudio;
  AiSpeechConfig? _batchSpeech;
  String? _batchApiKey;

  /// 特级档「语音到语音」会话：麦克风 PCM 直送实时模型，音频边收边播。
  bool _isS2sSession = false;
  SpeechToSpeechSession? _s2sSession;
  StreamSubscription<SpeechToSpeechEvent>? _s2sSubscription;
  Timer? _s2sIdleTimer;
  int _s2sLastActivityMs = 0;
  int _s2sIdleExitSeconds = 30;
  String? _s2sAssistantId;
  String _s2sAssistantBuffer = '';

  /// 当前有效的回复 id；用户插话后置空，用于丢弃旧回复的迟到分片。
  String? _s2sActiveResponseId;

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

  /// 读取指定档位的引擎配置；缺省回退默认值。
  SpeakingLevelConfig _levelConfigFor(AiSpeakingLevel level) {
    return ref.read(speakingLevelConfigsProvider)[level] ??
        SpeakingLevelConfig.defaultsFor(level);
  }

  /// 指定档位的语音配置，并合并「AI 设置」中的账号级工作空间。
  AiSpeechConfig _speechConfigFor(AiSpeakingLevel level) {
    final speech = _levelConfigFor(level).speech;
    final workspaceId = ref.read(aiSpeakingSettingsProvider).speech.workspaceId;
    if (workspaceId == speech.workspaceId) return speech;
    return speech.copyWith(workspaceId: workspaceId);
  }

  /// 非实时识别模型：一轮说完后再整段上传，不适合边录边识别。
  bool _usesBatchSpeech(AiSpeechConfig speech) {
    return AiSpeechConfig.isBatchAsrModel(speech.asrModel);
  }

  bool get _usesBatchSessionAsr {
    final speech = _sessionSpeech;
    return speech != null && _usesBatchSpeech(speech);
  }

  /// 当前麦克风音频是否可以送入 ASR/VAD。
  ///
  /// 朗读期间和恢复听音的静默窗口内都必须关闭输入，否则外放尾音会被
  /// 识别成用户输入；高级档的插话判定走单独的 VAD 分支。
  bool get _isSessionInputForwarding {
    if (!_isSessionActive || _isTtsActive || _isResumingListening) {
      return false;
    }
    return state.phase == AiSpeakingPhase.listening ||
        state.phase == AiSpeakingPhase.preparing;
  }

  Future<void> startListening() async {
    if (state.phase == AiSpeakingPhase.preparing ||
        state.phase == AiSpeakingPhase.listening ||
        state.phase == AiSpeakingPhase.finalizing ||
        state.phase == AiSpeakingPhase.thinking ||
        state.phase == AiSpeakingPhase.speaking) {
      return;
    }
    final prepared = await _prepareVoiceStart();
    if (prepared == null) return;
    final speech = prepared.speech;
    final engineSettings = prepared.engineSettings;

    _turnId++;
    final turnId = _turnId;
    if (engineSettings.usesLocalAsr) {
      await _startLocalListening(turnId);
      return;
    }
    if (_usesBatchSpeech(speech)) {
      await _startBatchListening(turnId, speech, prepared.dashscopeApiKey);
      return;
    }
    RealtimeAsrSession? asrSession;
    PcmRecorder? recorder;
    late final Stream<Uint8List> pcmStream;
    final dashscopeApiKey = prepared.dashscopeApiKey;
    try {
      asrSession = await ref
          .read(realtimeAsrClientProvider)
          .start(config: speech, apiKey: dashscopeApiKey);
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

  /// 非实时识别：按住说话期间只录音并攒 PCM，松开后一次性上传。
  Future<void> _startBatchListening(
    int turnId,
    AiSpeechConfig speech,
    String apiKey,
  ) async {
    _batchSpeech = speech;
    _batchApiKey = apiKey;
    final recorderInstance = ref.read(pcmRecorderProvider);
    _recorder = recorderInstance;
    final buffer = BytesBuilder(copy: false);
    _batchAudio = buffer;
    try {
      final pcmStream = await recorderInstance.start();
      if (!_isActive(turnId)) {
        await recorderInstance.stop();
        _batchAudio = null;
        return;
      }
      _lastPcmLevelAtMs = 0;
      _pcmSubscription = pcmStream.listen(
        (bytes) {
          if (!_isActive(turnId)) return;
          buffer.add(bytes);
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
    } on Object catch (error) {
      _batchAudio = null;
      if (_isActive(turnId)) {
        _setError(AiSpeakingErrorKind.asrFailed, '启动语音识别失败：$error');
      }
      return;
    }
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

    final batchAudio = _batchAudio?.takeBytes();
    if (batchAudio != null) {
      // 非实时模型先把整段音频取出来，再释放录音资源。
      final speech = _batchSpeech;
      final apiKey = _batchApiKey;
      _batchAudio = null;
      await _cleanupAsr();
      if (!_isActive(turnId) || speech == null || apiKey == null) return;
      await _transcribeBatch(turnId, batchAudio, speech, apiKey);
      return;
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

  /// 是否处于免提会话中。
  bool get isSessionActive => _isSessionActive;

  /// 开始免提会话（中级/高级）：点一次话筒开始，再点一次停止。
  ///
  /// 录音只在会话开始时启动一次；云端 ASR 同样从开始听音时就建连并
  /// 持续送流，服务端能收到开口前的连续音频，VAD 只负责判定说话结束。
  /// 本地识别由 RecordingService 逐轮录音，VAD 从它的 audioLevel 事件取电平。
  /// AI 朗读期间 VAD 静音，外放回声不会触发新一轮，因此不允许插话。
  Future<void> startSession() async {
    if (_isSessionActive || state.phase != AiSpeakingPhase.idle) return;
    final level = ref.read(aiSpeakingLevelProvider);
    if (!level.usesContinuousSession) return;
    if (level.usesSpeechToSpeech) {
      await _startSpeechToSpeechSession();
      return;
    }
    final prepared = await _prepareVoiceStart();
    if (prepared == null) return;
    if (level.requiresRealtimeAsr && prepared.engineSettings.usesLocalAsr) {
      _setError(
        AiSpeakingErrorKind.missingConfig,
        '高级档位需要云端实时语音识别，请在「口语引擎」设置中把语音识别切换为 AI',
      );
      return;
    }

    final dialog = _levelConfigFor(level).dialog;
    _turnId++;
    final turnId = _turnId;
    _isSessionActive = true;
    _isUtteranceOpen = false;
    _allowsBargeIn = level.allowsBargeIn;
    _bargeInThreshold = dialog.bargeInSensitivity.bargeInThreshold;
    _sessionSpeech = prepared.speech;
    _sessionDashscopeApiKey = prepared.dashscopeApiKey;
    _sessionEndOfSpeechMs = dialog.endOfSpeechMs;
    _vad = VadTurnDetector(
      endOfSpeech: Duration(milliseconds: dialog.endOfSpeechMs),
      idleTimeout: Duration(seconds: dialog.idleExitSeconds),
      hardLimit: Duration(
        milliseconds: SpeakingDialogSettings.hardLimitEndOfSpeechMs,
      ),
    );
    _resetPreroll();
    if (_allowsBargeIn) {
      // 必须在录音启动前切换通话音频模式，否则平台 AEC 拿不到 TTS 参考信号。
      await _beginVoiceAudioSession();
      if (!_isActive(turnId) || !_isSessionActive) return;
    }
    if (!prepared.engineSettings.usesLocalAsr) {
      // 不等 VAD 确认开口再建连：从会话一开始就建连并持续送流，
      // 否则握手期间的开头几个词会落在服务端接收窗口之外。
      unawaited(_ensureCloudAsr(turnId));
    }
    state = state.copyWith(
      phase: AiSpeakingPhase.preparing,
      isSessionActive: true,
      partialTranscript: '',
      inputLevel: 0,
      clearError: true,
    );
    if (prepared.engineSettings.usesLocalAsr) {
      // 本地识别自带录音：先开始第一轮，VAD 用其电平事件决定何时收尾。
      await _startLocalListening(turnId);
      return;
    }
    try {
      final recorderInstance = ref.read(pcmRecorderProvider);
      _recorder = recorderInstance;
      final pcmStream = _allowsBargeIn && _voiceAudioStatus.isSpeakerOutput
          ? await recorderInstance.startForVoiceCommunication()
          : await recorderInstance.start();
      if (!_isActive(turnId) || !_isSessionActive) {
        await recorderInstance.stop();
        return;
      }
      _pcmSubscription = pcmStream.listen(
        (bytes) => _onSessionPcm(turnId, bytes),
        onError: (Object error) {
          if (!_isActive(turnId)) return;
          _setError(AiSpeakingErrorKind.asrFailed, '录音读取失败：$error');
        },
      );
    } on Object catch (error) {
      if (_isActive(turnId)) {
        _setError(AiSpeakingErrorKind.asrFailed, '启动语音识别失败：$error');
      }
    }
  }

  /// 结束免提会话并释放录音与识别资源。
  Future<void> stopSession() async {
    if (!_isSessionActive) return;
    if (_isS2sSession) {
      await _stopSpeechToSpeechSession();
      return;
    }
    _turnId++;
    _vad?.reset();
    _clearSessionFields();
    await _cleanupAsr();
    if (_isDisposed) return;
    state = state.copyWith(
      phase: AiSpeakingPhase.idle,
      isSessionActive: false,
      partialTranscript: '',
      inputLevel: 0,
      clearError: true,
    );
  }

  /// 处理会话期间的 PCM 帧：驱动电平动画、VAD 与当前轮次的 ASR。
  void _onSessionPcm(int turnId, Uint8List bytes) {
    if (!_isActive(turnId) || !_isSessionActive) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final rms = pcm16Rms(bytes);
    if (now - _lastPcmLevelAtMs >= 80) {
      _lastPcmLevelAtMs = now;
      state = state.copyWith(inputLevel: normalizeAudioLevel(rms));
    }
    if (_isSpeakerBargeInGuardActive &&
        _isTtsActive &&
        _allowsBargeIn &&
        state.phase == AiSpeakingPhase.speaking) {
      // 外放时 VAD 保持静音，直接用 PCM 电平做 duck/确认判别。
      _handleSpeakerBargeInFrame(turnId, rms);
      return;
    }
    if (state.phase == AiSpeakingPhase.preparing &&
        !_isResumingListening &&
        !_isTtsActive) {
      // 第一帧录音数据说明麦克风已真正开始工作，此时才向用户显示「对话进行中」。
      state = state.copyWith(phase: AiSpeakingPhase.listening);
    }
    final canForward = _isSessionInputForwarding;
    if (canForward) {
      _appendPreroll(bytes);
      _asrSession?.appendPcm(bytes);
    }
    final wasUtteranceOpen = _isUtteranceOpen;
    // 高级档朗读期间仍要喂 VAD 判断插话；中级档不打开 VAD，避免把外放
    // 尾音当成用户开口。朗读期间不向 ASR 送流，也不更新识别文本。
    final canDetectBargeIn =
        _isTtsActive &&
        _allowsBargeIn &&
        !_isSpeakerBargeInGuardActive &&
        state.phase == AiSpeakingPhase.speaking;
    final event = (canForward || canDetectBargeIn)
        ? _vad?.feed(level: rms, timestampMs: now)
        : null;
    if (canForward &&
        _usesBatchSessionAsr &&
        wasUtteranceOpen &&
        _isUtteranceOpen) {
      // 非实时模型不建 WebSocket，开口后的每一帧都留到说完再上传。
      _batchAudio?.add(bytes);
    }
    switch (event) {
      case VadTurnEvent.speechStarted:
        _handleSessionSpeechStarted(turnId);
      case VadTurnEvent.speechEnded:
        unawaited(_finishSessionUtterance(turnId));
      case VadTurnEvent.idleTimeout:
        // AI 朗读或思考期间不计入用户空闲；否则长回复会把会话提前结束。
        if (state.phase == AiSpeakingPhase.listening) {
          unawaited(stopSession());
        }
      case null:
        break;
    }
  }

  /// VAD 确认开口：正常聆听时 ASR 已经在持续送流，只需确保会话仍在；
  /// 高级档 AI 朗读中则先打断朗读，再为新一轮建连。
  void _handleSessionSpeechStarted(int turnId) {
    if (!_isActive(turnId) || !_isSessionActive || _isResumingListening) {
      return;
    }
    if (state.phase == AiSpeakingPhase.speaking) {
      unawaited(_bargeIn(turnId));
      return;
    }
    if (_isTtsActive) return;
    if (state.phase != AiSpeakingPhase.listening &&
        state.phase != AiSpeakingPhase.preparing) {
      return;
    }
    if (_usesBatchSessionAsr) {
      if (!_isUtteranceOpen) {
        _isUtteranceOpen = true;
        _batchAudio ??= BytesBuilder(copy: false);
        // VAD 确认开口时，前面几百毫秒的起音只存在预录缓冲里。
        for (final frame in _prerollFrames) {
          _batchAudio!.add(frame);
        }
      }
      return;
    }
    if (!_isUtteranceOpen) {
      unawaited(_ensureCloudAsr(turnId));
    }
  }

  /// 高级档插话打断：立即停止朗读并转入新一轮识别。
  ///
  /// 不做语义判停，只按本地能量 VAD 判定用户开口；被打断的回复已经完整生成，
  /// 保留在消息列表里，仅中断音频播放。
  Future<void> _bargeIn(int turnId) async {
    if (!_isActive(turnId) || !_isSessionActive || !_allowsBargeIn) return;
    if (state.phase != AiSpeakingPhase.speaking) return;
    _markActiveAssistantInterrupted();
    _ttsCancelToken?.cancel();
    _ttsCancelToken = null;
    // 首句朗读可能早于大模型生成结束，插话时必须一起取消后续生成。
    _chatCancelToken?.cancel();
    // 等播放器真正停下再恢复识别，否则插话后的第一帧可能还是外放尾音。
    await _stopTtsPlayback();
    _settleStreamingMessages();
    if (!_isActive(turnId) || !_isSessionActive || !_allowsBargeIn) return;
    // 插话时用户已经在说话，不再额外等待尾音静默，避免丢掉开头。
    await _resumeSessionListening();
  }

  /// 启动原生音频会话，记录当前输出路由与 AEC 能力。
  Future<void> _beginVoiceAudioSession() async {
    if (_isDisposed) return;
    final session = ref.read(voiceAudioSessionProvider);
    if (!session.isSupported) {
      _voiceAudioStatus = const VoiceAudioSessionStatus.unsupported();
      return;
    }
    try {
      final status = await session.begin();
      _voiceAudioStatus = status;
      _isVoiceAudioSessionActive = status.isSupported;
      AppLogger.log(
        'AiSpeakingAudio',
        '音频会话开始：外放=${status.isSpeakerOutput}，AEC=${status.isAecAvailable}，'
            '支持插话=${status.canUseSpeakerBargeIn}',
      );
    } on Object catch (error) {
      _voiceAudioStatus = const VoiceAudioSessionStatus.unsupported();
      _isVoiceAudioSessionActive = false;
      AppLogger.log('AiSpeakingAudio', '启动音频会话失败，降级手动停止：$error');
    }
  }

  /// 结束原生音频会话并恢复用户原来的音频模式。
  Future<void> _endVoiceAudioSession() async {
    final wasActive = _isVoiceAudioSessionActive;
    _isVoiceAudioSessionActive = false;
    _voiceAudioStatus = const VoiceAudioSessionStatus.unsupported();
    if (!wasActive || _isDisposed) return;
    try {
      await ref.read(voiceAudioSessionProvider).end();
    } on Object catch (error) {
      AppLogger.log('AiSpeakingAudio', '结束音频会话失败：$error');
    }
  }

  /// 在 TTS 启动前刷新路由；返回本次播放应使用的输出用途。
  Future<VoiceAudioSessionStatus> _prepareTtsOutput() async {
    if (!_allowsBargeIn || _isDisposed) {
      return const VoiceAudioSessionStatus.unsupported();
    }
    final session = ref.read(voiceAudioSessionProvider);
    if (!session.isSupported) {
      return const VoiceAudioSessionStatus.unsupported();
    }
    try {
      final status = _isVoiceAudioSessionActive
          ? await session.prepareForTts()
          : await session.begin();
      _voiceAudioStatus = status;
      _isVoiceAudioSessionActive = status.isSupported;
      return status;
    } on Object catch (error) {
      _voiceAudioStatus = const VoiceAudioSessionStatus.unsupported();
      AppLogger.log('AiSpeakingAudio', '刷新 TTS 音频路由失败：$error');
      return _voiceAudioStatus;
    }
  }

  /// 外放时逐帧驱动 duck 判别；确认后才真正打断，避免尾音误触发。
  void _handleSpeakerBargeInFrame(int turnId, double level) {
    final actions = _bargeInGuard.onInputFrame(level);
    for (final action in actions) {
      switch (action.type) {
        case VoiceBargeInActionType.duck:
          _isSpeakerBargeInDucked = true;
          unawaited(
            ref
                .read(pcmStreamPlayerProvider)
                .setVolume(action.volume ?? _bargeInGuard.duckVolume),
          );
          AppLogger.log('AiSpeakingBargeIn', '检测到持续人声，先降低 TTS 音量');
        case VoiceBargeInActionType.confirm:
          AppLogger.log('AiSpeakingBargeIn', 'duck 后仍有人声，确认用户插话');
          unawaited(_bargeIn(turnId));
        case VoiceBargeInActionType.resume:
          _restoreTtsVolume();
          AppLogger.log('AiSpeakingBargeIn', '人声衰减，判定为回声，恢复 TTS 音量');
        case VoiceBargeInActionType.disable:
          _restoreTtsVolume();
          _isSpeakerBargeInGuardActive = false;
          _vad?.mute();
          state = state.copyWith(isVoiceBargeInAvailable: false);
          AppLogger.log('AiSpeakingBargeIn', 'duck 后回声未下降，关闭外放语音插话，仅保留手动停止');
      }
    }
  }

  /// 恢复 TTS 原音量；重复调用安全。
  void _restoreTtsVolume() {
    if (!_isSpeakerBargeInDucked) return;
    _isSpeakerBargeInDucked = false;
    unawaited(ref.read(pcmStreamPlayerProvider).setVolume(1));
  }

  /// TTS 播放结束/被打断后的统一收尾：恢复音量、复位 guard 与外放会话。
  Future<void> _finishTtsPlayback() async {
    _bargeInGuard.onPlaybackStopped();
    _restoreTtsVolume();
    _isSpeakerBargeInGuardActive = false;
    _activeAssistantId = null;
    if (!_isSessionActive) {
      await _endVoiceAudioSession();
    }
  }

  /// 记录已经送去合成的 TTS 文本，供后续 ASR 回声过滤使用。
  void _rememberTtsText(String text) {
    if (!_allowsBargeIn || text.trim().isEmpty) return;
    _echoTextFilter.updateTtsText(text);
  }

  /// ASR 最终文本若是刚朗读过的句子，视为扬声器尾音并丢弃。
  bool _isLikelyAsrEcho(String text) {
    if (!_allowsBargeIn || !_echoTextFilter.isLikelyEcho(text)) return false;
    AppLogger.log('AiSpeakingBargeIn', '丢弃疑似 TTS 回声的识别结果：$text');
    _echoTextFilter.clear();
    return true;
  }

  /// 高级档：AI 开始朗读时保持 VAD 判定，并抬高门限抵消外放回声。
  void _enableBargeInListening() {
    if (!_isSessionActive || !_allowsBargeIn) return;
    _vad?.raiseThreshold(_bargeInThreshold);
    _vad?.unmute(timestampMs: DateTime.now().millisecondsSinceEpoch);
  }

  /// 保留最近 400ms 音频，用户开口时补发给 ASR，减少首个音节的丢失。
  void _appendPreroll(Uint8List bytes) {
    // 400ms @ 16kHz / 16bit / 单声道 = 12800 字节。
    const maxPrerollBytes = 12800;
    // ASR 建连通常要几百毫秒，握手期间若仍按 400ms 裁剪，用户开口头几个
    // 词会被挤出缓冲；这里放宽到 5s 音频作为内存上限。
    const maxStartingBytes = 160000;
    _prerollFrames.add(bytes);
    _prerollBytes += bytes.length;
    final limit = _isAsrStarting ? maxStartingBytes : maxPrerollBytes;
    while (_prerollBytes > limit && _prerollFrames.length > 1) {
      _prerollBytes -= _prerollFrames.removeAt(0).length;
    }
  }

  /// 把预录音频按时间顺序补发给刚建连的 ASR，并清空缓冲。
  void _flushPreroll(RealtimeAsrSession session) {
    for (final frame in _prerollFrames) {
      session.appendPcm(frame);
    }
    _resetPreroll();
  }

  void _resetPreroll() {
    _prerollFrames.clear();
    _prerollBytes = 0;
  }

  /// 确保本轮云端 ASR 已建连；重复调用复用同一个建连任务。
  ///
  /// 正常聆听时由 [startSession] / [_resumeSessionListening] 提前建连，
  /// 只有会话中途缺失连接（例如插话打断后）才由这里补建。
  Future<void> _ensureCloudAsr(int turnId) {
    if (_isTtsActive || _isResumingListening) {
      return Future<void>.value();
    }
    if (_usesBatchSessionAsr) {
      // 非实时模型没有长连接可建，只需要准备本轮的音频缓冲。
      _batchAudio ??= BytesBuilder(copy: false);
      _isUtteranceOpen = false;
      return Future<void>.value();
    }
    final inFlight = _asrStartFuture;
    if (inFlight != null) return inFlight;
    if (!_isActive(turnId) || !_isSessionActive || _asrSession != null) {
      return Future<void>.value();
    }
    late final Future<void> future;
    future = _startCloudAsr(turnId).whenComplete(() {
      if (identical(_asrStartFuture, future)) _asrStartFuture = null;
    });
    _asrStartFuture = future;
    return future;
  }

  /// 建立云端 ASR 并持续接收 PCM；建连期间先缓存，成功后按序补发。
  Future<void> _startCloudAsr(int turnId) async {
    if (!_isActive(turnId) || !_isSessionActive) return;
    if (_isTtsActive || _isResumingListening) return;
    if (_asrSession != null || _isAsrStarting) return;
    final speech = _sessionSpeech;
    if (speech == null) return;
    _isUtteranceOpen = true;
    // 建连握手期间用户可能已经开口，先放宽预录裁剪，等建连成功后再按序补发。
    _isAsrStarting = true;
    state = state.copyWith(partialTranscript: '', clearError: true);
    try {
      final session = await ref
          .read(realtimeAsrClientProvider)
          .start(config: speech, apiKey: _sessionDashscopeApiKey ?? '');
      if (!_isActive(turnId) ||
          !_isSessionActive ||
          !_isUtteranceOpen ||
          _isTtsActive ||
          _isResumingListening) {
        await session.cancel();
        _resetPreroll();
        return;
      }
      _asrSession = session;
      _asrSubscription = session.events.listen(
        (event) {
          if (!_isActive(turnId) || _isTtsActive || _isResumingListening) {
            return;
          }
          if (event.isFinal) {
            _handleCloudFinalTranscript(turnId, event.text);
            return;
          }
          if (!_isUtteranceOpen ||
              (state.phase != AiSpeakingPhase.listening &&
                  state.phase != AiSpeakingPhase.preparing)) {
            return;
          }
          state = state.copyWith(partialTranscript: event.text);
        },
        onError: (Object error) {
          if (!_isActive(turnId)) return;
          _setError(AiSpeakingErrorKind.asrFailed, '语音识别失败：$error');
        },
      );
      _flushPreroll(session);
    } on Object catch (error) {
      _isUtteranceOpen = false;
      _resetPreroll();
      if (_isActive(turnId)) {
        _setError(AiSpeakingErrorKind.asrFailed, '启动语音识别失败：$error');
      }
    } finally {
      _isAsrStarting = false;
    }
  }

  /// 服务端判定一句结束（尾静音达到 max_sentence_silence）时主动收尾本轮。
  ///
  /// 不再只依赖本地 RMS：嘈杂环境下底噪可能一直高于本地门限，导致
  /// 用户说完后迟迟不产生 speechEnded。
  void _handleCloudFinalTranscript(int turnId, String text) {
    if (!_isActive(turnId) ||
        !_isSessionActive ||
        !_isUtteranceOpen ||
        _isTtsActive ||
        _isResumingListening) {
      return;
    }
    if (state.phase != AiSpeakingPhase.listening) return;
    final normalized = text.trim();
    if (normalized.isEmpty && state.partialTranscript.trim().isEmpty) return;
    if (normalized.isNotEmpty) {
      state = state.copyWith(partialTranscript: normalized);
    }
    unawaited(_finishSessionUtterance(turnId));
  }

  /// 上传一轮完整 PCM，转写完成后把文本交给大模型。
  Future<void> _transcribeBatch(
    int turnId,
    Uint8List audio,
    AiSpeechConfig speech,
    String apiKey,
  ) async {
    if (!_isActive(turnId)) return;
    var transcript = '';
    try {
      final stream = ref
          .read(fileAsrClientProvider)
          .transcribe(pcm: audio, config: speech, apiKey: apiKey);
      await for (final result in stream) {
        if (!_isActive(turnId)) return;
        final text = result.text.trim();
        if (text.isEmpty || text == transcript) continue;
        transcript = text;
        state = state.copyWith(partialTranscript: transcript);
      }
    } on AiTtsException catch (error) {
      if (!_isActive(turnId) || error.kind == AiTtsErrorKind.cancelled) return;
      _setError(AiSpeakingErrorKind.asrFailed, error.message);
      return;
    } on Object catch (error) {
      if (!_isActive(turnId)) return;
      _setError(AiSpeakingErrorKind.asrFailed, '语音识别失败：$error');
      return;
    }
    if (!_isActive(turnId)) return;
    final normalized = transcript.trim();
    state = state.copyWith(partialTranscript: '', clearError: true);
    if (normalized.isEmpty) {
      if (_isSessionActive) {
        await _resumeSessionListening();
      } else {
        state = state.copyWith(phase: AiSpeakingPhase.idle);
      }
      return;
    }
    await _sendUserTurn(normalized, turnId);
  }

  /// 云端 ASR：VAD 判定说完后收尾本轮并把转写交给大模型。
  Future<void> _finishSessionUtterance(int turnId) async {
    // 同一轮的 VAD、服务端句末与手动停止可能同时到达；只有仍处于聆听态
    // 的第一个调用可以开始收尾，避免重复 finish 或重复发送同一条用户消息。
    if (!_isActive(turnId) ||
        !_isSessionActive ||
        !_isUtteranceOpen ||
        state.phase != AiSpeakingPhase.listening) {
      return;
    }
    _vad?.mute();
    state = state.copyWith(phase: AiSpeakingPhase.finalizing, inputLevel: 0);
    if (_usesBatchSessionAsr) {
      _isUtteranceOpen = false;
      final audio = _batchAudio?.takeBytes() ?? Uint8List(0);
      _batchAudio = null;
      final speech = _sessionSpeech;
      if (audio.isEmpty || speech == null) {
        state = state.copyWith(partialTranscript: '', clearError: true);
        await _resumeSessionListening();
        return;
      }
      await _transcribeBatch(
        turnId,
        audio,
        speech,
        _sessionDashscopeApiKey ?? '',
      );
      return;
    }
    // 建连握手可能还在进行；先等它完成，否则会把整段话当成空转写丢掉。
    // 期间保持 _isUtteranceOpen，避免建连成功后被当作过期会话取消。
    final startFuture = _asrStartFuture;
    if (startFuture != null) {
      try {
        await startFuture;
      } on Object catch (_) {
        // 建连错误已由 _startCloudAsr 上报，这里只负责继续收尾。
      }
    }
    if (!_isActive(turnId) || !_isSessionActive) return;
    _isUtteranceOpen = false;
    final asrSession = _asrSession;
    await _asrSubscription?.cancel();
    _asrSubscription = null;
    String transcript = '';
    try {
      transcript = await asrSession?.finish() ?? '';
    } on Object catch (error) {
      _asrSession = null;
      if (asrSession != null) unawaited(asrSession.cancel());
      if (!_isActive(turnId)) return;
      final fallback = state.partialTranscript.trim();
      if (fallback.isNotEmpty) {
        // 连接在收尾阶段断开时，用已经展示的识别文本继续对话，
        // 不把可用的半句结果直接升级成会话错误。
        state = state.copyWith(partialTranscript: '', clearError: true);
        await _sendUserTurn(fallback, turnId);
        return;
      }
      _setError(AiSpeakingErrorKind.asrFailed, '语音识别失败：$error');
      return;
    }
    _asrSession = null;
    if (!_isActive(turnId)) return;
    final normalized = transcript.trim();
    if (normalized.isEmpty) {
      state = state.copyWith(partialTranscript: '', clearError: true);
      await _resumeSessionListening();
      return;
    }
    state = state.copyWith(partialTranscript: '', clearError: true);
    await _sendUserTurn(normalized, turnId);
  }

  /// 本地识别的电平事件驱动 VAD；本地识别每轮单独录音。
  void _feedLocalSessionVad(int turnId, double level) {
    if (!_isSessionActive || !_isActive(turnId)) return;
    final event = _vad?.feed(
      level: level,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
    );
    switch (event) {
      case VadTurnEvent.speechEnded:
        unawaited(_finishLocalSessionUtterance(turnId));
      case VadTurnEvent.idleTimeout:
        if (state.phase == AiSpeakingPhase.listening) {
          unawaited(stopSession());
        }
      case VadTurnEvent.speechStarted:
      case null:
        break;
    }
  }

  Future<void> _finishLocalSessionUtterance(int turnId) async {
    if (!_isSessionActive || state.phase != AiSpeakingPhase.listening) return;
    _vad?.mute();
    state = state.copyWith(phase: AiSpeakingPhase.finalizing, inputLevel: 0);
    await _stopLocalListening(turnId);
  }

  /// AI 说完后恢复听音；不在会话中时保持原状。
  ///
  /// [waitForSpeakerTail] 为 true 时先留一段静默窗口再打开输入。停止或
  /// 自然播完后扬声器仍有余音，ASR 立刻开始会把 AI 最后一个词录进新一轮
  /// 用户输入，形成「AI 把自己说的话当成用户发言」的反馈环。
  Future<void> _resumeSessionListening({
    bool waitForSpeakerTail = false,
  }) async {
    if (!_isSessionActive || _isDisposed) return;
    if (_isS2sSession) {
      // 特级档录音常开，恢复听音只需把状态切回聆听。
      state = state.copyWith(
        phase: AiSpeakingPhase.listening,
        partialTranscript: '',
        inputLevel: 0,
        clearError: true,
      );
      return;
    }
    if (_isTtsActive) return;
    final turnId = _turnId;
    final resumeId = ++_resumeListeningId;
    _isResumingListening = true;
    _vad?.mute();
    _vad?.raiseThreshold(null);
    // 静默窗口内不积累预录，避免把窗口之前的尾音补发给 ASR。
    _resetPreroll();
    state = state.copyWith(
      phase: AiSpeakingPhase.preparing,
      partialTranscript: '',
      inputLevel: 0,
      clearError: true,
    );
    if (waitForSpeakerTail) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    final isCurrentResume = resumeId == _resumeListeningId;
    if (!isCurrentResume ||
        !_isActive(turnId) ||
        !_isSessionActive ||
        _isDisposed ||
        _isTtsActive) {
      if (isCurrentResume) _isResumingListening = false;
      return;
    }
    _isResumingListening = false;
    _resetPreroll();
    final usesLocalAsr = _levelConfigFor(ref.read(aiSpeakingLevelProvider))
        .engine
        .usesLocalAsr;
    state = state.copyWith(
      phase: AiSpeakingPhase.listening,
      partialTranscript: '',
      inputLevel: 0,
      clearError: true,
    );
    _vad?.unmute(timestampMs: DateTime.now().millisecondsSinceEpoch);
    if (usesLocalAsr) {
      // 本地识别每轮单独录音，恢复听音即开始下一轮录音。
      unawaited(_startLocalListening(turnId));
    } else {
      unawaited(_ensureCloudAsr(turnId));
    }
  }

  /// 出错时结束会话，但不覆盖错误状态（错误由 _setError 统一设置）。
  void _abortSessionOnError() {
    if (!_isSessionActive) return;
    _clearSessionFields();
    state = state.copyWith(isSessionActive: false);
    unawaited(_cleanupAsr());
  }

  /// 清空会话内部状态；调用方决定随后把 state 置成什么。
  void _clearSessionFields() {
    _isSessionActive = false;
    _bargeInGuard.reset();
    _echoTextFilter.clear();
    _isSpeakerBargeInGuardActive = false;
    _isSpeakerBargeInDucked = false;
    _activeAssistantId = null;
    unawaited(_endVoiceAudioSession());
    _isUtteranceOpen = false;
    _allowsBargeIn = false;
    _bargeInThreshold = 0;
    _vad = null;
    _sessionSpeech = null;
    _sessionDashscopeApiKey = null;
    _isAsrStarting = false;
    _asrStartFuture = null;
    _isTtsActive = false;
    _isResumingListening = false;
    _resumeListeningId++;
    _batchAudio = null;
    _batchSpeech = null;
    _batchApiKey = null;
    _resetPreroll();
    _clearS2sFields();
  }

  /// 特级档：启动语音到语音会话。
  ///
  /// 单一实时模型同时负责识别、对话与合成，客户端只做三件事：持续推送
  /// 麦克风 PCM、把下行音频写入流式播放器、按服务端事件维护消息与状态。
  Future<void> _startSpeechToSpeechSession() async {
    final permission = ref.read(aiSpeakingPermissionServiceProvider);
    if (!permission.isSupported) {
      _setError(AiSpeakingErrorKind.unsupportedPlatform, '当前平台不支持语音输入，请使用文字输入');
      return;
    }
    final player = ref.read(pcmStreamPlayerProvider);
    if (!player.isSupported) {
      _setError(
        AiSpeakingErrorKind.unsupportedPlatform,
        '当前平台不支持实时语音播放，请改用初级或中级档位',
      );
      return;
    }
    String? apiKey;
    try {
      apiKey = await ref
          .read(aiSpeakingCredentialStoreProvider)
          .readDashscopeApiKey();
    } on AiSpeakingCredentialStoreException catch (error) {
      _setError(AiSpeakingErrorKind.missingConfig, error.message);
      return;
    }
    if (apiKey == null || apiKey.trim().isEmpty) {
      _setError(
        AiSpeakingErrorKind.missingConfig,
        '请先在「AI 设置」中填写 DashScope API Key',
      );
      return;
    }
    if (!await permission.ensurePermission()) {
      _setError(AiSpeakingErrorKind.permissionDenied, '需要麦克风权限才能进行语音练习');
      return;
    }

    final level = ref.read(aiSpeakingLevelProvider);
    final speech = _speechConfigFor(level);
    final dialog = _levelConfigFor(level).dialog;
    _turnId++;
    final turnId = _turnId;
    _isSessionActive = true;
    _isS2sSession = true;
    _allowsBargeIn = true;
    _s2sIdleExitSeconds = dialog.idleExitSeconds;
    _s2sLastActivityMs = DateTime.now().millisecondsSinceEpoch;
    _s2sAssistantId = null;
    _s2sAssistantBuffer = '';
    _s2sActiveResponseId = null;
    _sessionSpeech = speech;
    state = state.copyWith(
      phase: AiSpeakingPhase.listening,
      isSessionActive: true,
      partialTranscript: '',
      inputLevel: 0,
      clearError: true,
    );

    SpeechToSpeechSession? session;
    PcmRecorder? recorder;
    try {
      await player.start();
      session = await ref
          .read(speechToSpeechClientProvider)
          .start(
            config: speech,
            apiKey: apiKey.trim(),
            instructions: aiSpeakingSystemPrompt,
          );
      if (!_isActive(turnId) || !_isS2sSession) {
        await session.close();
        await player.stop();
        return;
      }
      _s2sSession = session;
      _s2sSubscription = session.events.listen(
        (event) => _onSpeechToSpeechEvent(turnId, event),
        onError: (Object error) {
          if (!_isActive(turnId)) return;
          _setError(AiSpeakingErrorKind.asrFailed, '实时语音对话失败：$error');
        },
      );
      final recorderInstance = ref.read(pcmRecorderProvider);
      recorder = recorderInstance;
      _recorder = recorder;
      final pcmStream = await recorderInstance.start();
      if (!_isActive(turnId) || !_isS2sSession) {
        await recorderInstance.stop();
        return;
      }
      _pcmSubscription = pcmStream.listen(
        (bytes) => _onSpeechToSpeechPcm(turnId, bytes),
        onError: (Object error) {
          if (!_isActive(turnId)) return;
          _setError(AiSpeakingErrorKind.asrFailed, '录音读取失败：$error');
        },
      );
      _s2sIdleTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _checkSpeechToSpeechIdle(turnId),
      );
    } on Object catch (error) {
      await session?.close();
      try {
        await recorder?.stop();
      } on Object {
        // 启动失败时录音器可能尚未开始，停止失败不应掩盖原始错误。
      }
      await player.stop();
      if (_isActive(turnId)) {
        _setError(AiSpeakingErrorKind.asrFailed, '启动实时语音对话失败：$error');
      }
    }
  }

  /// 麦克风 PCM 直送实时模型，同时刷新电平动画。
  void _onSpeechToSpeechPcm(int turnId, Uint8List bytes) {
    if (!_isActive(turnId) || !_isS2sSession) return;
    _s2sSession?.appendPcm(bytes);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastPcmLevelAtMs >= 80) {
      _lastPcmLevelAtMs = now;
      state = state.copyWith(inputLevel: normalizeAudioLevel(pcm16Rms(bytes)));
    }
  }

  void _onSpeechToSpeechEvent(int turnId, SpeechToSpeechEvent event) {
    if (!_isActive(turnId) || !_isS2sSession) return;
    switch (event) {
      case SpeechToSpeechSpeechStarted():
        // 服务端会自行取消被打断的回复；本地先停播并丢弃旧回复的迟到分片。
        _s2sLastActivityMs = DateTime.now().millisecondsSinceEpoch;
        _s2sActiveResponseId = null;
        unawaited(ref.read(pcmStreamPlayerProvider).flush());
        _finishSpeechToSpeechAssistant();
        state = state.copyWith(
          phase: AiSpeakingPhase.listening,
          partialTranscript: '',
          inputLevel: 0,
          clearError: true,
        );
      case SpeechToSpeechSpeechStopped():
        state = state.copyWith(phase: AiSpeakingPhase.thinking, inputLevel: 0);
      case SpeechToSpeechUserTranscript(:final text, :final isFinal):
        if (!isFinal) {
          state = state.copyWith(partialTranscript: text);
          return;
        }
        final normalized = text.trim();
        _s2sLastActivityMs = DateTime.now().millisecondsSinceEpoch;
        if (normalized.isEmpty) {
          // 空转写（噪声/误触发）不会有回复，必须回到听音态，否则会话会卡在思考态。
          state = state.copyWith(
            partialTranscript: '',
            phase: AiSpeakingPhase.listening,
            clearError: true,
          );
          return;
        }
        state = state.copyWith(
          partialTranscript: '',
          phase: AiSpeakingPhase.thinking,
          clearError: true,
        );
        final userMessage = AiSpeakingMessage(
          id: _uuid.v4(),
          role: AiSpeakingRole.user,
          content: normalized,
          status: AiSpeakingMessageStatus.done,
          createdAt: DateTime.now(),
        );
        // 服务端的回复转写可能先于用户转写到达；此时必须把用户消息
        // 插到对应的 AI 消息之前，保证界面顺序始终是「用户 → AI」。
        final assistantId = _s2sAssistantId;
        final messages = [...state.messages];
        final assistantIndex = assistantId == null
            ? -1
            : messages.indexWhere((message) => message.id == assistantId);
        if (assistantIndex >= 0) {
          messages.insert(assistantIndex, userMessage);
        } else {
          messages.add(userMessage);
        }
        state = state.copyWith(messages: messages);
      case SpeechToSpeechResponseStarted(:final responseId):
        _s2sActiveResponseId = responseId;
      case SpeechToSpeechAssistantTranscript(
        :final text,
        :final isFinal,
        :final responseId,
      ):
        if (!_isCurrentResponse(responseId)) return;
        if (isFinal) {
          // done 事件携带完整文本，用它校准增量累积的结果。
          _finishSpeechToSpeechAssistant(content: text);
          return;
        }
        if (text.trim().isEmpty) return;
        _appendSpeechToSpeechAssistant(text);
        state = state.copyWith(
          phase: AiSpeakingPhase.speaking,
          clearError: true,
        );
      case SpeechToSpeechAudio(:final pcm, :final responseId):
        if (!_isCurrentResponse(responseId)) return;
        state = state.copyWith(
          phase: AiSpeakingPhase.speaking,
          clearError: true,
        );
        unawaited(ref.read(pcmStreamPlayerProvider).write(pcm));
      case SpeechToSpeechResponseDone():
        _s2sActiveResponseId = null;
        _finishSpeechToSpeechAssistant();
        _s2sLastActivityMs = DateTime.now().millisecondsSinceEpoch;
        state = state.copyWith(
          phase: AiSpeakingPhase.listening,
          partialTranscript: '',
          inputLevel: 0,
          clearError: true,
        );
      case SpeechToSpeechFailure(:final message):
        _setError(AiSpeakingErrorKind.asrFailed, '实时语音对话失败：$message');
    }
  }

  /// 只接受当前回复的分片；用户插话后旧回复的迟到分片一律丢弃。
  bool _isCurrentResponse(String responseId) {
    if (responseId.isEmpty) return true;
    return responseId == _s2sActiveResponseId;
  }

  void _appendSpeechToSpeechAssistant(String delta) {
    _s2sAssistantBuffer += delta;
    final id = _s2sAssistantId;
    if (id == null) {
      final messageId = _uuid.v4();
      _s2sAssistantId = messageId;
      state = state.copyWith(
        messages: [
          ...state.messages,
          AiSpeakingMessage(
            id: messageId,
            role: AiSpeakingRole.assistant,
            content: _s2sAssistantBuffer,
            status: AiSpeakingMessageStatus.streaming,
            createdAt: DateTime.now(),
          ),
        ],
      );
      return;
    }
    _updateAssistant(id, content: _s2sAssistantBuffer);
  }

  /// 收尾当前 AI 消息；[content] 非空时用服务端完整文本覆盖增量累积结果。
  void _finishSpeechToSpeechAssistant({String? content}) {
    final id = _s2sAssistantId;
    if (id == null) return;
    final text = (content ?? _s2sAssistantBuffer).trim();
    _updateAssistant(
      id,
      content: text.isEmpty ? '回复为空' : text,
      status: text.isEmpty
          ? AiSpeakingMessageStatus.error
          : AiSpeakingMessageStatus.done,
    );
    _s2sAssistantId = null;
    _s2sAssistantBuffer = '';
  }

  /// 用户主动停止当前回复：取消服务端生成、清空本地音频并继续听音。
  void _cancelSpeechToSpeechResponse() {
    unawaited(_s2sSession?.cancelResponse() ?? Future<void>.value());
    unawaited(ref.read(pcmStreamPlayerProvider).flush());
    _finishSpeechToSpeechAssistant();
    _s2sActiveResponseId = null;
    _s2sLastActivityMs = DateTime.now().millisecondsSinceEpoch;
    state = state.copyWith(
      phase: AiSpeakingPhase.listening,
      partialTranscript: '',
      inputLevel: 0,
      clearError: true,
    );
  }

  /// 长时间没有用户语音时退出会话；AI 回复期间不计时。
  void _checkSpeechToSpeechIdle(int turnId) {
    if (!_isActive(turnId) || !_isS2sSession) return;
    // 只在「AI 正在出声」或「服务端已开始生成回复」时暂停计时；
    // 思考态但没有任何回复（服务端丢弃了这一轮）仍应能按空闲阈值退出。
    if (state.phase == AiSpeakingPhase.speaking) return;
    if (state.phase == AiSpeakingPhase.thinking &&
        _s2sActiveResponseId != null) {
      return;
    }
    final idleMs = DateTime.now().millisecondsSinceEpoch - _s2sLastActivityMs;
    if (idleMs >= _s2sIdleExitSeconds * 1000) {
      unawaited(stopSession());
    }
  }

  /// 结束特级档会话：先收尾消息，再断开实时连接、停播与停止录音。
  Future<void> _stopSpeechToSpeechSession() async {
    _finishSpeechToSpeechAssistant();
    _s2sIdleTimer?.cancel();
    _s2sIdleTimer = null;
    _isS2sSession = false;
    _turnId++;
    final session = _s2sSession;
    final subscription = _s2sSubscription;
    _s2sSession = null;
    _s2sSubscription = null;
    _s2sActiveResponseId = null;
    _isSessionActive = false;
    await _cleanupAsr();
    await subscription?.cancel();
    await session?.close();
    if (!_isDisposed) {
      await ref.read(pcmStreamPlayerProvider).stop();
    }
    if (_isDisposed) return;
    state = state.copyWith(
      phase: AiSpeakingPhase.idle,
      isSessionActive: false,
      partialTranscript: '',
      inputLevel: 0,
      clearError: true,
    );
  }

  /// 清理特级档会话字段；不改变 state，由调用方决定后续状态。
  void _clearS2sFields() {
    _isS2sSession = false;
    _s2sIdleTimer?.cancel();
    _s2sIdleTimer = null;
    final session = _s2sSession;
    _s2sSession = null;
    if (session != null) unawaited(session.close());
    final subscription = _s2sSubscription;
    _s2sSubscription = null;
    if (subscription != null) unawaited(subscription.cancel());
    _s2sActiveResponseId = null;
    _s2sAssistantId = null;
    _s2sAssistantBuffer = '';
    if (!_isDisposed) {
      unawaited(ref.read(pcmStreamPlayerProvider).stop());
    }
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
    if (state.phase == AiSpeakingPhase.preparing ||
        state.phase == AiSpeakingPhase.listening ||
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
    if (state.phase == AiSpeakingPhase.preparing ||
        state.phase == AiSpeakingPhase.thinking ||
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
    _clearSessionFields();
    _turnId++;
    _chatCancelToken?.cancel();
    _ttsCancelToken?.cancel();
    await _stopTtsPlayback();
    await _cleanupAsr();
    state = const AiSpeakingSessionState();
  }

  /// 重新朗读一条已完成的 AI 回复。
  Future<void> replayMessage(String messageId) async {
    if (state.phase == AiSpeakingPhase.preparing ||
        state.phase == AiSpeakingPhase.listening ||
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
    if (_isS2sSession) {
      _cancelSpeechToSpeechResponse();
      return;
    }
    if (_isSessionActive) {
      // 会话中停止生成只结束本轮，随后继续听音，不打断整个会话。
      _chatCancelToken?.cancel();
      final messages = state.messages
          .where(
            (message) => message.status != AiSpeakingMessageStatus.streaming,
          )
          .toList();
      state = state.copyWith(messages: messages, clearError: true);
      unawaited(_resumeSessionListening());
      return;
    }
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

  Future<void> stopSpeaking() async {
    if (state.phase != AiSpeakingPhase.speaking) return;
    if (_isS2sSession) {
      _cancelSpeechToSpeechResponse();
      return;
    }
    _markActiveAssistantInterrupted();
    _ttsCancelToken?.cancel();
    // 分句朗读开始后阶段已切到 speaking，但大模型可能仍在生成；停止朗读
    // 必须同时取消生成，否则流式回复会在后台继续并留下转圈消息。
    _chatCancelToken?.cancel();
    await _stopTtsPlayback();
    _settleStreamingMessages();
    if (_isSessionActive) {
      await _resumeSessionListening(waitForSpeakerTail: true);
      return;
    }
    _turnId++;
    state = state.copyWith(phase: AiSpeakingPhase.idle, clearError: true);
  }

  /// 用户关闭错误提示后回到空闲状态。
  void dismissError() {
    if (state.phase != AiSpeakingPhase.error) return;
    state = state.copyWith(phase: AiSpeakingPhase.idle, clearError: true);
  }

  /// 页面退出时停止录音、识别、生成与朗读，但保留当前对话内容。
  void stopActiveAudio() {
    if (_isSessionActive) {
      _clearSessionFields();
      state = state.copyWith(isSessionActive: false);
    }
    _turnId++;
    _chatCancelToken?.cancel();
    _ttsCancelToken?.cancel();
    unawaited(_stopTtsPlayback());
    unawaited(_cleanupAsr());
    if (state.phase != AiSpeakingPhase.idle) {
      state = state.copyWith(phase: AiSpeakingPhase.idle, clearError: true);
    }
  }

  Future<void> _sendUserTurn(String text, int turnId) async {
    if (!_isActive(turnId)) return;
    // 朗读刚结束时 ASR 可能把扬声器尾音单独识别成一轮；命中已朗读文本
    // 就直接丢弃，不产生用户消息，也不触发下一轮回复。
    if (_isLikelyAsrEcho(text)) {
      state = state.copyWith(partialTranscript: '', clearError: true);
      if (_isSessionActive) {
        await _resumeSessionListening();
      } else {
        state = state.copyWith(phase: AiSpeakingPhase.idle);
      }
      return;
    }
    // 正常用户文本消费掉回声窗口，避免同一句话在很久以后被误判。
    _echoTextFilter.clear();
    // 进入思考阶段后不再接收新的语音轮次。
    _vad?.mute();
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
    _activeAssistantId = assistantId;
    state = state.copyWith(
      messages: [...state.messages, placeholder],
      phase: AiSpeakingPhase.thinking,
      clearError: true,
    );

    _chatCancelToken = CancelToken();
    var buffer = '';
    final autoPlay = _speechConfigFor(ref.read(aiSpeakingLevelProvider))
        .autoPlay;
    final useSentenceTts = autoPlay && _supportsSentenceTts;
    final splitter = SpeechSentenceSplitter();
    StreamController<String>? speechInput;
    Future<bool>? speechFuture;
    var llmFinished = false;
    var speechEndedBeforeLlm = false;

    // 关闭动作不能等待订阅者消费 done：云端在缺 Key 或已取消时不会订阅该流，
    // 等待会让整轮回复永远卡住。
    void closeSpeechInput() {
      final input = speechInput;
      speechInput = null;
      if (input != null && !input.isClosed) {
        unawaited(input.close());
      }
    }

    Future<bool> awaitSpeech() async {
      final future = speechFuture;
      if (future == null) return true;
      try {
        return await future;
      } on Object catch (error) {
        if (_isActive(turnId) && state.phase != AiSpeakingPhase.error) {
          _setError(AiSpeakingErrorKind.ttsFailed, '语音合成失败：$error');
        }
        return false;
      }
    }

    void emitSpeech(List<String> sentences) {
      if (!useSentenceTts || sentences.isEmpty) return;
      final input = speechInput ??= StreamController<String>();
      for (final sentence in sentences) {
        if (!input.isClosed) input.add(sentence);
      }
      // 只有第一句负责启动朗读。后续句子只往同一条文本流里追加，否则会
      // 并发启动多个 TTS 会话争抢同一路音频，表现为只播开头就被重置。
      if (speechFuture != null) return;
      final future = _speakAssistantSentences(
        turnId,
        assistantId,
        input.stream,
      );
      speechFuture = future;
      // 分句合成若在全文生成结束前就返回，后续句子会失去消费者，表现
      // 为只播出开头。记录该异常，等全文到齐后回退重读完整回复。
      unawaited(
        future.then<void>((_) {
          if (!llmFinished) speechEndedBeforeLlm = true;
        }, onError: (_) {}),
      );
    }

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
        if (!_isActive(turnId)) {
          _chatCancelToken?.cancel();
          closeSpeechInput();
          return;
        }
        // 用户插话或停止朗读后，朗读阶段会回到聆听/空闲，继续生成没有意义。
        if (state.phase == AiSpeakingPhase.error ||
            state.phase == AiSpeakingPhase.listening ||
            state.phase == AiSpeakingPhase.idle) {
          _chatCancelToken?.cancel();
          closeSpeechInput();
          return;
        }
        buffer += delta;
        _updateAssistant(assistantId, content: buffer);
        if (useSentenceTts) {
          emitSpeech(splitter.add(delta));
        }
      }
      llmFinished = true;
    } on AiChatException catch (error) {
      if (!_isActive(turnId) || error.kind == AiChatErrorKind.cancelled) {
        closeSpeechInput();
        return;
      }
      _ttsCancelToken?.cancel();
      await _stopTtsPlayback();
      closeSpeechInput();
      await awaitSpeech();
      if (!_isActive(turnId)) return;
      _updateAssistant(
        assistantId,
        content: buffer.isEmpty ? '回复生成失败' : buffer,
        status: AiSpeakingMessageStatus.error,
      );
      _setError(AiSpeakingErrorKind.llmFailed, error.message);
      return;
    } on Object catch (error) {
      if (!_isActive(turnId)) {
        closeSpeechInput();
        return;
      }
      _ttsCancelToken?.cancel();
      await _stopTtsPlayback();
      closeSpeechInput();
      await awaitSpeech();
      if (!_isActive(turnId)) return;
      _updateAssistant(
        assistantId,
        content: buffer.isEmpty ? '回复生成失败' : buffer,
        status: AiSpeakingMessageStatus.error,
      );
      _setError(AiSpeakingErrorKind.llmFailed, '生成回复失败：$error');
      return;
    }

    if (!_isActive(turnId)) {
      closeSpeechInput();
      return;
    }
    if (useSentenceTts) {
      emitSpeech(splitter.flush());
    }
    closeSpeechInput();
    final reply = buffer.trim();
    if (reply.isEmpty) {
      _ttsCancelToken?.cancel();
      await _stopTtsPlayback();
      await awaitSpeech();
      if (!_isActive(turnId)) return;
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
    // 极少数回复被 Markdown 清理后没有任何可读句子，仍用完整文本合成一次，
    // 否则不会进入 speaking，整轮会停在 thinking。
    if (useSentenceTts && speechFuture == null) {
      speechFuture = _speakAssistantSentences(
        turnId,
        assistantId,
        Stream<String>.value(reply),
      );
    }

    if (!autoPlay) {
      if (_isSessionActive) {
        await _resumeSessionListening();
      } else {
        state = state.copyWith(phase: AiSpeakingPhase.idle, clearError: true);
      }
      return;
    }
    if (useSentenceTts) {
      final spoken = await awaitSpeech();
      if (!spoken ||
          !_isActive(turnId) ||
          state.phase != AiSpeakingPhase.speaking) {
        return;
      }
      if (speechEndedBeforeLlm && !(_ttsCancelToken?.isCancelled ?? false)) {
        // 服务端任务提前结束时，已发送的后续句子不会再有消费者。全文已到齐，
        // 用新的分句流重读完整回复，避免只播出开头就被恢复听音当成用户输入。
        final replaySplitter = SpeechSentenceSplitter();
        final replaySentences = <String>[
          ...replaySplitter.add(reply),
          ...replaySplitter.flush(),
        ];
        AppLogger.log(
          'AiSpeakingTts',
          '分句朗读提前结束，回退整段朗读：${replaySentences.length} 句 / '
              '${reply.length} 字符',
        );
        final replayed = await _speakAssistantSentences(
          turnId,
          assistantId,
          Stream<String>.fromIterable(replaySentences),
          allowSpeaking: true,
        );
        if (!replayed ||
            !_isActive(turnId) ||
            state.phase != AiSpeakingPhase.speaking) {
          return;
        }
      }
      if (_isSessionActive) {
        await _resumeSessionListening(waitForSpeakerTail: true);
        return;
      }
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
    await _suspendSessionAsrForTts();
    if (!_isActive(turnId)) return;
    if (_levelConfigFor(ref.read(aiSpeakingLevelProvider))
        .engine
        .usesLocalTts) {
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

    state = state.copyWith(
      phase: AiSpeakingPhase.speaking,
      isVoiceBargeInAvailable: true,
      clearError: true,
    );
    _ttsCancelToken = CancelToken();
    final config = _speechConfigFor(ref.read(aiSpeakingLevelProvider));
    if (ref.read(pcmStreamPlayerProvider).isSupported) {
      final completed = await _speakAssistantStreaming(
        turnId,
        assistantId,
        text,
        config,
        apiKey.trim(),
      );
      if (!completed || !_isActive(turnId)) return;
      // 插话或停止可能已把状态切到 listening/idle，不能再让旧回复收尾。
      if (state.phase != AiSpeakingPhase.speaking) return;
    } else {
      // 文件播放没有可查询的音频路由，保留原有的语音插话行为。
      _enableBargeInListening();
      String audioPath;
      try {
        audioPath = await ref
            .read(aiTtsClientProvider)
            .synthesizeToFile(
              text: text,
              config: config,
              apiKey: apiKey.trim(),
              cancelToken: _ttsCancelToken,
            );
      } on AiTtsException catch (error) {
        if (!_isActive(turnId) || error.kind == AiTtsErrorKind.cancelled) {
          return;
        }
        _setError(AiSpeakingErrorKind.ttsFailed, error.message);
        return;
      } on Object catch (error) {
        if (!_isActive(turnId)) return;
        _setError(AiSpeakingErrorKind.ttsFailed, '语音合成失败：$error');
        return;
      }
      if (!_isActive(turnId)) return;
      _updateAssistant(assistantId, audioPath: audioPath);
      late final AudioPlaybackResult result;
      _isTtsActive = true;
      try {
        result = await ref
            .read(shortAudioPlayerProvider)
            .playFile(audioPath, playbackKey: assistantId);
      } on Object catch (error) {
        if (!_isActive(turnId)) return;
        _setError(AiSpeakingErrorKind.ttsFailed, '音频播放失败：$error');
        return;
      } finally {
        _isTtsActive = false;
      }
      if (!_isActive(turnId)) return;
      if (result == AudioPlaybackResult.failed) {
        _setError(AiSpeakingErrorKind.ttsFailed, '音频播放失败');
        return;
      }
      if (result == AudioPlaybackResult.cancelled) return;
      if (!_isActive(turnId)) return;
    }
    if (state.phase != AiSpeakingPhase.speaking) return;
    if (_isSessionActive) {
      await _resumeSessionListening(waitForSpeakerTail: true);
      return;
    }
    state = state.copyWith(phase: AiSpeakingPhase.idle, clearError: true);
  }

  /// 当前档位的 TTS 是否能按句启动。
  ///
  /// 云端需要 Android 原生 PCM 播放器才能边合成边播放；本地引擎按句排队播放，
  /// 其他平台继续走整段 HTTP 合成，不强行分句。
  bool get _supportsSentenceTts {
    final engine = _levelConfigFor(ref.read(aiSpeakingLevelProvider)).engine;
    return engine.usesLocalTts || ref.read(pcmStreamPlayerProvider).isSupported;
  }

  /// TTS 开始前断开 ASR。朗读期间麦克风仍用于高级档插话判断，但任何音频
  /// 都不再送进识别，避免扬声器回声被当成用户发言。
  Future<void> _suspendSessionAsrForTts() async {
    _resetPreroll();
    _isUtteranceOpen = false;
    _batchAudio = null;
    await _asrSubscription?.cancel();
    _asrSubscription = null;
    final session = _asrSession;
    _asrSession = null;
    if (session != null) unawaited(session.cancel());
  }

  /// 边接收大模型句子边合成朗读；返回 false 表示已取消或已上报错误。
  ///
  /// 第一句到达时就开始合成，因此这里会先把阶段切到 speaking。后续句子继续
  /// 送入 [sentences]，直到大模型结束并关闭文本流。[allowSpeaking] 用于
  /// 服务端提前结束后的整段重读，此时阶段已经是 speaking。
  Future<bool> _speakAssistantSentences(
    int turnId,
    String assistantId,
    Stream<String> sentences, {
    bool allowSpeaking = false,
  }) async {
    bool canStart() =>
        _isActive(turnId) &&
        (allowSpeaking
            ? state.phase == AiSpeakingPhase.speaking
            : state.phase == AiSpeakingPhase.thinking);
    if (!canStart()) {
      return false;
    }
    // 朗读开始前先断开 ASR；中级档没有插话判定，朗读期间绝不能把
    // 外放声音当成用户输入，高级档只保留 VAD 用于打断。
    await _suspendSessionAsrForTts();
    if (!canStart()) {
      return false;
    }
    final level = ref.read(aiSpeakingLevelProvider);
    if (_levelConfigFor(level).engine.usesLocalTts) {
      return _speakLocalSentences(turnId, assistantId, sentences);
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
      return false;
    }
    if (apiKey == null || apiKey.trim().isEmpty) {
      if (_isActive(turnId)) {
        _setError(AiSpeakingErrorKind.ttsFailed, '请先填写 DashScope API Key');
      }
      return false;
    }
    if (!canStart()) {
      return false;
    }

    state = state.copyWith(
      phase: AiSpeakingPhase.speaking,
      isVoiceBargeInAvailable: true,
      clearError: true,
    );
    _ttsCancelToken = CancelToken();
    _lastTtsWasLocal = false;
    final config = _speechConfigFor(level);
    return _playTtsChunks(
      turnId,
      () => ref
          .read(aiTtsStreamClientProvider)
          .synthesizeChunks(
            textChunks: sentences.map((sentence) {
              _rememberTtsText(sentence);
              return sentence;
            }),
            config: config,
            apiKey: apiKey!.trim(),
            cancelToken: _ttsCancelToken,
          ),
    );
  }

  /// 本地引擎逐句合成并顺序播放；后续句子在排队期间预合成。
  Future<bool> _speakLocalSentences(
    int turnId,
    String assistantId,
    Stream<String> sentences,
  ) async {
    _bargeInGuard.reset();
    final status = await _prepareTtsOutput();
    if (!_isActive(turnId)) return false;
    final canVoiceBargeIn =
        !_allowsBargeIn || (status.isRouteKnown && !status.isSpeakerOutput);
    state = state.copyWith(
      phase: AiSpeakingPhase.speaking,
      isVoiceBargeInAvailable: canVoiceBargeIn,
      clearError: true,
    );
    if (canVoiceBargeIn) {
      _enableBargeInListening();
    } else {
      // 本地 TTS 走独立播放器，无法像 PCM 通道那样 duck，外放时只保留手动停止。
      _vad?.mute();
      AppLogger.log('AiSpeakingBargeIn', '本地 TTS 外放，关闭语音插话');
    }
    _ttsCancelToken = CancelToken();
    _lastTtsWasLocal = true;

    final localTts = ref.read(aiSpeakingLocalTtsProvider);
    final pending = Queue<String>();
    var inputDone = false;
    Object? inputError;
    Completer<void>? wake;
    final subscription = sentences.listen(
      (sentence) {
        final normalized = sentence.trim();
        if (normalized.isEmpty) return;
        _rememberTtsText(normalized);
        pending.add(normalized);
        // 当前句播放时，后到的句子已在后台合成，轮到播放时可直接命中缓存。
        unawaited(localTts.prewarm(normalized));
        if (wake != null && !wake!.isCompleted) wake!.complete();
        wake = null;
      },
      onError: (Object error, StackTrace stackTrace) {
        inputError = error;
        inputDone = true;
        if (wake != null && !wake!.isCompleted) wake!.complete();
        wake = null;
      },
      onDone: () {
        inputDone = true;
        if (wake != null && !wake!.isCompleted) wake!.complete();
        wake = null;
      },
      cancelOnError: false,
    );

    var spoken = false;
    var index = 0;
    try {
      while (true) {
        if (!_isActive(turnId) ||
            state.phase != AiSpeakingPhase.speaking ||
            (_ttsCancelToken?.isCancelled ?? false)) {
          break;
        }
        if (pending.isEmpty) {
          if (inputDone) break;
          final waiter = Completer<void>();
          wake = waiter;
          await Future.any([
            waiter.future,
            Future<void>.delayed(const Duration(milliseconds: 100)),
          ]);
          if (identical(wake, waiter)) wake = null;
          continue;
        }
        final text = pending.removeFirst();
        late final AudioPlaybackResult result;
        _isTtsActive = true;
        try {
          result = await localTts.speak(text, key: '$assistantId-${index++}');
        } on Object catch (error) {
          if (!_isActive(turnId)) return false;
          _setError(AiSpeakingErrorKind.ttsFailed, '本地语音合成失败：$error');
          return false;
        } finally {
          _isTtsActive = false;
        }
        if (!_isActive(turnId) ||
            state.phase != AiSpeakingPhase.speaking ||
            result == AudioPlaybackResult.cancelled) {
          return false;
        }
        if (result == AudioPlaybackResult.failed) {
          _setError(AiSpeakingErrorKind.ttsFailed, '本地语音合成失败，请检查语音合成设置');
          return false;
        }
        spoken = true;
      }
    } finally {
      _lastTtsWasLocal = false;
      await subscription.cancel();
      await _finishTtsPlayback();
    }
    if (!_isActive(turnId) || state.phase != AiSpeakingPhase.speaking) {
      return false;
    }
    if (inputError != null) {
      _setError(AiSpeakingErrorKind.ttsFailed, '本地语音合成失败：$inputError');
      return false;
    }
    if (!spoken) {
      _setError(AiSpeakingErrorKind.ttsFailed, '本地语音合成没有返回音频');
      return false;
    }
    return true;
  }

  /// 边合成边写入原生 AudioTrack；返回 false 表示已取消或已上报错误。
  Future<bool> _playTtsChunks(
    int turnId,
    Stream<Uint8List> Function() openAudio,
  ) async {
    final player = ref.read(pcmStreamPlayerProvider);
    var receivedAudio = false;
    var shouldDrain = false;
    var drained = false;
    _bargeInGuard.reset();
    _isTtsActive = true;
    try {
      // 先保持 VAD 静音，等确认实际输出路由后再决定是否允许语音插话。
      _vad?.mute();
      final status = await _prepareTtsOutput();
      await player.startWithUsage(
        sampleRate: AliyunTtsStreamClient.sampleRate,
        usage: status.outputUsage,
      );
      _configureVoiceBargeInForTts(status, turnId);
      await for (final chunk in openAudio()) {
        if (!_isActive(turnId) || (_ttsCancelToken?.isCancelled ?? false)) {
          break;
        }
        receivedAudio = true;
        await player.write(chunk);
      }
      // 只有合成自然结束且未被取消时才等待排空；插话、停止或错误走后文的
      // stop，立即丢弃缓冲区，避免继续朗读。
      shouldDrain =
          receivedAudio &&
          _isActive(turnId) &&
          !(_ttsCancelToken?.isCancelled ?? false);
    } on AiTtsException catch (error) {
      if (!_isActive(turnId) || error.kind == AiTtsErrorKind.cancelled) {
        return false;
      }
      _setError(AiSpeakingErrorKind.ttsFailed, error.message);
      return false;
    } on Object catch (error) {
      if (!_isActive(turnId)) return false;
      _setError(AiSpeakingErrorKind.ttsFailed, '语音合成失败：$error');
      return false;
    } finally {
      try {
        if (shouldDrain) {
          try {
            await player.finish();
            drained = true;
          } on Object catch (error) {
            if (_isActive(turnId)) {
              _setError(AiSpeakingErrorKind.ttsFailed, '语音播放失败：$error');
            }
          }
        } else {
          await player.stop();
        }
      } finally {
        _isTtsActive = false;
        await _finishTtsPlayback();
      }
    }
    if (!_isActive(turnId)) return false;
    if (!receivedAudio) {
      _setError(AiSpeakingErrorKind.ttsFailed, '语音合成没有返回音频');
      return false;
    }
    if (!drained) return false;
    return true;
  }

  /// 根据 TTS 的实际播放路由决定高级档是否允许语音插话。
  ///
  /// 外放且平台 AEC 可用时走 duck 判别：先压低音量，确认不是回声后再打断；
  /// AEC 不可用时只保留手动停止，避免把 AI 自己的声音当成用户插话。
  void _configureVoiceBargeInForTts(
    VoiceAudioSessionStatus status,
    int turnId,
  ) {
    if (!_allowsBargeIn) return;
    if (!_isActive(turnId) ||
        !_isTtsActive ||
        state.phase != AiSpeakingPhase.speaking) {
      return;
    }
    if (!status.isRouteKnown) {
      state = state.copyWith(isVoiceBargeInAvailable: false);
      _vad?.mute();
      AppLogger.log('AiSpeakingTts', '无法确认输出路由，关闭语音插话');
      return;
    }
    if (!status.isSpeakerOutput) {
      state = state.copyWith(isVoiceBargeInAvailable: true);
      _enableBargeInListening();
      return;
    }
    if (!status.canUseSpeakerBargeIn) {
      state = state.copyWith(isVoiceBargeInAvailable: false);
      AppLogger.log('AiSpeakingTts', '外放但平台回声消除不可用，关闭语音插话');
      return;
    }
    state = state.copyWith(isVoiceBargeInAvailable: true);
    _isSpeakerBargeInGuardActive = true;
    _bargeInGuard.onPlaybackStarted(
      candidateThreshold: math.max(0.05, _bargeInThreshold * 1.6),
    );
    AppLogger.log('AiSpeakingBargeIn', '外放 AEC 可用，启用 duck 插话判别');
  }

  /// 单段全文合成入口：保留非分句路径与非 Android 的原有行为。
  Future<bool> _speakAssistantStreaming(
    int turnId,
    String assistantId,
    String text,
    AiSpeechConfig config,
    String apiKey,
  ) {
    _rememberTtsText(text);
    return _playTtsChunks(
      turnId,
      () => ref
          .read(aiTtsStreamClientProvider)
          .synthesizeStream(
            text: text,
            config: config,
            apiKey: apiKey,
            cancelToken: _ttsCancelToken,
          ),
    );
  }

  /// 用户打断时结束仍在流式输出的回复，避免消息一直停留在 streaming。
  /// 空占位直接移除，已有内容保留为完成态。
  void _settleStreamingMessages() {
    final messages = state.messages
        .where(
          (message) =>
              message.status != AiSpeakingMessageStatus.streaming ||
              message.content.trim().isNotEmpty,
        )
        .map(
          (message) => message.status == AiSpeakingMessageStatus.streaming
              ? message.copyWith(status: AiSpeakingMessageStatus.done)
              : message,
        )
        .toList();
    state = state.copyWith(messages: messages);
  }

  /// 给当前朗读中的 AI 回复标记「已打断」，但保留已生成的完整文本。
  void _markActiveAssistantInterrupted() {
    final id = _activeAssistantId;
    if (id == null) return;
    _activeAssistantId = null;
    final messages = state.messages
        .map(
          (message) => message.id == id
              ? message.copyWith(wasInterrupted: true)
              : message,
        )
        .toList();
    state = state.copyWith(messages: messages);
  }

  void _updateAssistant(
    String id, {
    String? content,
    AiSpeakingMessageStatus? status,
    String? audioPath,
    bool? wasInterrupted,
  }) {
    final messages = state.messages
        .map(
          (message) => message.id == id
              ? message.copyWith(
                  content: content,
                  status: status,
                  audioPath: audioPath,
                  wasInterrupted: wasInterrupted,
                )
              : message,
        )
        .toList();
    state = state.copyWith(messages: messages);
  }

  void _setError(AiSpeakingErrorKind kind, String message) {
    // 会话中出错即结束会话，避免半途状态继续占用麦克风。
    _abortSessionOnError();
    state = state.copyWith(
      phase: AiSpeakingPhase.error,
      errorKind: kind,
      errorMessage: message,
    );
  }

  /// 语音输入前的公共校验：平台能力、API Key、本地模型与麦克风权限。
  ///
  /// 初级按键说话与免提会话共用同一套校验，避免两处出现不一致的提示文案。
  Future<_VoiceStartContext?> _prepareVoiceStart() async {
    final permission = ref.read(aiSpeakingPermissionServiceProvider);
    if (!permission.isSupported) {
      _setError(AiSpeakingErrorKind.unsupportedPlatform, '当前平台不支持语音输入，请使用文字输入');
      return null;
    }

    final level = ref.read(aiSpeakingLevelProvider);
    final settings = ref.read(aiSpeakingSettingsProvider);
    final engineSettings = _levelConfigFor(level).engine;
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
      return null;
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
      return null;
    }
    if (engineSettings.usesLocalAsr && !await _ensureLocalAsrReady()) {
      return null;
    }

    final granted = await permission.ensurePermission();
    if (!granted) {
      _setError(AiSpeakingErrorKind.permissionDenied, '需要麦克风权限才能进行语音练习');
      return null;
    }
    return _VoiceStartContext(
      settings: settings,
      speech: _speechConfigFor(level),
      engineSettings: engineSettings,
      dashscopeApiKey: dashscopeKey?.trim() ?? '',
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
          final level = event.audioLevel ?? 0;
          state = state.copyWith(inputLevel: normalizeAudioLevel(level));
          _feedLocalSessionVad(turnId, level);
          return;
        }
        if (event.type == SpeechPracticeEventType.silenceProgress) {
          // 原生 VAD 的门限比 Flutter 侧更低：环境底噪高于本地门限时，
          // 原生静音事件仍能正常推进，作为本轮断句的独立兜底。
          final silenceMs = event.silenceDuration?.inMilliseconds ?? 0;
          if (silenceMs >= _sessionEndOfSpeechMs &&
              state.phase == AiSpeakingPhase.listening) {
            unawaited(_finishLocalSessionUtterance(turnId));
          }
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
      final wavPath = await service.startRecording(
        promptId: promptId,
        recognitionEnabled: usesPlatformRecognition,
      );
      _startLocalStreamingPreview(turnId, wavPath);
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

  /// SenseVoice 档位在录音期间周期性解码，先把不断增长的文字显示出来。
  void _startLocalStreamingPreview(int turnId, String wavPath) {
    final settings = ref.read(offlineAsrSettingsProvider);
    if (settings.backend != AsrBackend.offline ||
        settings.selectedModel.id != senseVoiceSmallModelId) {
      return;
    }
    final transcriber = LocalAsrStreamingTranscriber(
      engine: ref.read(offlineAsrEngineProvider),
      wavPath: wavPath,
      onPartial: (text) {
        if (!_isActive(turnId) || state.phase != AiSpeakingPhase.listening) {
          return;
        }
        state = state.copyWith(partialTranscript: text);
      },
    );
    _localStreamingTranscriber = transcriber;
    transcriber.start();
  }

  /// 停止本地录音并等待离线模型给出最终文本。
  Future<void> _stopLocalListening(int turnId) async {
    // 停止预览前先留住已经显示出来的文字，最终解码超时时用它兜底。
    final previewTranscript = state.partialTranscript.trim();
    final preview = _localStreamingTranscriber;
    _localStreamingTranscriber = null;
    preview?.stop();
    if (preview != null) unawaited(preview.dispose());
    final service = _localRecordingService;
    final promptId = _localPromptId;
    if (service == null || promptId == null) {
      await _cleanupAsr();
      if (!_isActive(turnId)) return;
      if (_isSessionActive) {
        await _resumeSessionListening();
        return;
      }
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
        if (result.errorCode == 'timeout' && previewTranscript.isNotEmpty) {
          // 最终解码超时时先用录音期间已展示的中间结果继续对话，
          // 避免一个迟到的解码结果把整场会话按错误结束。
          transcript = previewTranscript;
        } else if (result.errorCode != null) {
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
      if (_isSessionActive) {
        await _resumeSessionListening();
        return;
      }
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
    _rememberTtsText(text);
    _bargeInGuard.reset();
    final status = await _prepareTtsOutput();
    if (!_isActive(turnId)) return;
    final canVoiceBargeIn =
        !_allowsBargeIn || (status.isRouteKnown && !status.isSpeakerOutput);
    state = state.copyWith(
      phase: AiSpeakingPhase.speaking,
      isVoiceBargeInAvailable: canVoiceBargeIn,
      clearError: true,
    );
    if (canVoiceBargeIn) {
      _enableBargeInListening();
    } else {
      _vad?.mute();
    }
    _lastTtsWasLocal = true;
    late final AudioPlaybackResult result;
    _isTtsActive = true;
    try {
      result = await ref
          .read(aiSpeakingLocalTtsProvider)
          .speak(text, key: assistantId);
    } on Object catch (error) {
      _lastTtsWasLocal = false;
      if (!_isActive(turnId)) return;
      _setError(AiSpeakingErrorKind.ttsFailed, '本地语音合成失败：$error');
      return;
    } finally {
      _isTtsActive = false;
      await _finishTtsPlayback();
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
    if (_isSessionActive) {
      await _resumeSessionListening(waitForSpeakerTail: true);
      return;
    }
    state = state.copyWith(phase: AiSpeakingPhase.idle, clearError: true);
  }

  /// 停止当前可能正在播放的 AI 或本地语音，并等待播放器真正停下。
  Future<void> _stopTtsPlayback() async {
    try {
      await ref.read(shortAudioPlayerProvider).stop();
    } on Object {
      // 播放器可能已停止，停止失败不阻塞恢复听音。
    }
    try {
      await ref.read(pcmStreamPlayerProvider).stop();
    } on Object {
      // 同上：确保后续恢复听音不会被单个播放器异常卡住。
    }
    if (_lastTtsWasLocal) {
      try {
        await ref.read(aiSpeakingLocalTtsProvider).stop();
      } on Object {
        // 本地引擎已停止时忽略重复停止错误。
      }
      _lastTtsWasLocal = false;
    }
    _isTtsActive = false;
    await _finishTtsPlayback();
  }

  Future<void> _cleanupAsr() async {
    final preview = _localStreamingTranscriber;
    _localStreamingTranscriber = null;
    preview?.stop();
    if (preview != null) unawaited(preview.dispose());
    _batchAudio = null;
    _batchSpeech = null;
    _batchApiKey = null;
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
