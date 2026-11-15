/// AI 口语会话控制器状态机测试。
///
/// 覆盖配置缺失、权限拒绝、语音识别流程、文本发送、流式回复、
/// 自动朗读以及取消/重试等状态转换。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:echo_loop/features/ai_speaking/data/ai_speaking_credential_store.dart';
import 'package:echo_loop/features/ai_speaking/models/ai_llm_provider.dart';
import 'package:echo_loop/features/ai_speaking/models/ai_speaking_level.dart';
import 'package:echo_loop/features/ai_speaking/models/ai_speaking_message.dart';
import 'package:echo_loop/features/ai_speaking/models/ai_speaking_session_state.dart';
import 'package:echo_loop/features/ai_speaking/models/ai_speaking_settings.dart';
import 'package:echo_loop/features/ai_speaking/models/speaking_dialog_settings.dart';
import 'package:echo_loop/features/ai_speaking/models/speaking_engine_settings.dart';
import 'package:echo_loop/features/ai_speaking/models/speaking_level_config.dart';
import 'package:echo_loop/features/ai_speaking/providers/ai_speaking_level_provider.dart';
import 'package:echo_loop/features/ai_speaking/providers/ai_speaking_session_controller.dart';
import 'package:echo_loop/features/ai_speaking/providers/ai_speaking_settings_provider.dart';
import 'package:echo_loop/features/ai_speaking/providers/speaking_level_configs_provider.dart';
import 'package:echo_loop/features/ai_speaking/services/ai_chat_client.dart';
import 'package:echo_loop/features/ai_speaking/services/ai_speaking_permission_service.dart';
import 'package:echo_loop/features/ai_speaking/services/aliyun_file_asr_client.dart';
import 'package:echo_loop/features/ai_speaking/services/aliyun_realtime_asr_client.dart';
import 'package:echo_loop/features/ai_speaking/services/aliyun_tts_client.dart';
import 'package:echo_loop/features/ai_speaking/services/aliyun_tts_stream_client.dart';
import 'package:echo_loop/features/ai_speaking/services/pcm_recorder.dart';
import 'package:echo_loop/features/ai_speaking/services/pcm_stream_player.dart';
import 'package:echo_loop/features/ai_speaking/services/qwen_audio_realtime_client.dart';
import 'package:echo_loop/features/ai_speaking/services/voice_audio_session.dart';
import 'package:echo_loop/models/speech_practice_models.dart';
import 'package:echo_loop/providers/asr_model_installation_gate.dart';
import 'package:echo_loop/providers/asr_model_installation_provider.dart';
import 'package:echo_loop/services/asr/asr_model_manager.dart';
import 'package:echo_loop/providers/offline_asr_settings_provider.dart';
import 'package:echo_loop/providers/short_audio_player_provider.dart';
import 'package:echo_loop/services/recording_service.dart';
import 'package:echo_loop/services/speech_practice_platform.dart';
import 'package:echo_loop/services/pronunciation/local_audio_clip_player.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockPcmRecorder extends Mock implements PcmRecorder {}

class _MockRealtimeAsrClient extends Mock implements RealtimeAsrClient {}

class _MockFileAsrClient extends Mock implements FileAsrClient {}

class _MockRealtimeAsrSession extends Mock implements RealtimeAsrSession {}

class _MockAiChatClient extends Mock implements AiChatClient {}

class _MockAiTtsClient extends Mock implements AiTtsClient {}

class _MockAiTtsStreamClient extends Mock implements AiTtsStreamClient {}

class _MockPermissionService extends Mock
    implements AiSpeakingPermissionService {}

class _MockCredentialStore extends Mock implements AiSpeakingCredentialStore {}

class _MockLocalAudioClipPlayer extends Mock implements LocalAudioClipPlayer {}

class _MockRecordingService extends Mock implements RecordingService {}

class _MockLocalTts extends Mock implements AiSpeakingLocalTts {}

class _MockSpeechPracticeBackend extends Mock
    implements SpeechPracticeBackend {}

class _MockAsrModelInstallationGate extends Mock
    implements AsrModelInstallationGate {}

class _MockSpeechToSpeechClient extends Mock implements SpeechToSpeechClient {}

class _MockSpeechToSpeechSession extends Mock
    implements SpeechToSpeechSession {}

class _MockPcmStreamPlayer extends Mock implements PcmStreamPlayer {}

/// 可切换路由与 AEC 能力的音频会话替身，避免测试依赖真实平台通道。
class _FakeVoiceAudioSession implements VoiceAudioSession {
  _FakeVoiceAudioSession([
    this.status = const VoiceAudioSessionStatus.unsupported(),
  ]);

  VoiceAudioSessionStatus status;
  int beginCount = 0;
  int prepareCount = 0;
  int endCount = 0;

  @override
  bool get isSupported => status.isSupported;

  @override
  Future<VoiceAudioSessionStatus> begin() async {
    beginCount++;
    return status;
  }

  @override
  Future<VoiceAudioSessionStatus> prepareForTts() async {
    prepareCount++;
    return status;
  }

  @override
  Future<void> end() async {
    endCount++;
  }
}

/// 模拟 record 插件：dispose 后不能再次 start，用于覆盖连续多轮录音。
class _SingleUsePcmRecorder implements PcmRecorder {
  bool _isDisposed = false;
  int startCount = 0;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<Stream<Uint8List>> start({
    int sampleRate = 16000,
    int numChannels = 1,
  }) async {
    if (_isDisposed) {
      throw StateError('录音器已释放');
    }
    startCount++;
    return const Stream<Uint8List>.empty();
  }

  @override
  Future<Stream<Uint8List>> startForVoiceCommunication({
    int sampleRate = 16000,
    int numChannels = 1,
  }) => start(sampleRate: sampleRate, numChannels: numChannels);

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    _isDisposed = true;
  }
}

OfflineAsrSettingsState _offlineAsrState({
  required bool isReady,
  AsrBackend backend = AsrBackend.offline,
}) {
  final model = availableModels.firstWhere(
    (candidate) => candidate.id == 'whisper-base-en-int8',
  );
  return OfflineAsrSettingsState(
    backend: backend,
    engineReady: isReady,
    recommendedModel: model,
    modelStates: {
      model.id: AsrModelState(
        downloadStatus: isReady
            ? AsrModelDownloadStatus.downloaded
            : AsrModelDownloadStatus.notDownloaded,
      ),
    },
  );
}

/// 构造一帧 16kHz/16bit 单声道 PCM，amplitude 为采样幅值（0 表示静音）。
Uint8List _pcmFrame(int amplitude) {
  final data = ByteData(320);
  for (var i = 0; i < 160; i++) {
    data.setInt16(i * 2, amplitude, Endian.little);
  }
  return data.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(AiSpeakingSettings.defaults.llm);
    registerFallbackValue(AiSpeakingSettings.defaults.speech);
    registerFallbackValue(AiLlmProvider.deepSeek);
    registerFallbackValue(<AiSpeakingMessage>[]);
    registerFallbackValue(CancelToken());
    registerFallbackValue('');
    registerFallbackValue(Uint8List(0));
    registerFallbackValue(const Stream<String>.empty());
    registerFallbackValue(0);
    registerFallbackValue(false);
    registerFallbackValue(Duration.zero);
    registerFallbackValue(PcmOutputUsage.media);
  });

  late _MockPcmRecorder recorder;
  late _MockRealtimeAsrClient asrClient;
  late _MockFileAsrClient fileAsrClient;
  late _MockRealtimeAsrSession asrSession;
  late _MockAiChatClient chatClient;
  late _MockAiTtsClient ttsClient;
  late _MockAiTtsStreamClient ttsStreamClient;
  late _MockPermissionService permission;
  late _MockCredentialStore credentialStore;
  late _MockLocalAudioClipPlayer player;
  late _MockRecordingService localRecordingService;
  late _MockLocalTts localTts;
  late _MockAsrModelInstallationGate installationGate;
  late _MockSpeechToSpeechClient speechToSpeechClient;
  late _MockSpeechToSpeechSession s2sSession;
  late _MockPcmStreamPlayer pcmStreamPlayer;
  late _FakeVoiceAudioSession voiceAudioSession;
  late StreamController<SpeechToSpeechEvent> s2sEvents;
  late StreamController<AsrTranscriptEvent> asrEvents;
  late StreamController<Uint8List> pcmEvents;
  late StreamController<SpeechPracticeEvent> localSpeechEvents;

  setUp(() {
    recorder = _MockPcmRecorder();
    asrClient = _MockRealtimeAsrClient();
    fileAsrClient = _MockFileAsrClient();
    asrSession = _MockRealtimeAsrSession();
    chatClient = _MockAiChatClient();
    ttsClient = _MockAiTtsClient();
    ttsStreamClient = _MockAiTtsStreamClient();
    when(
      () => ttsStreamClient.synthesizeStream(
        text: any(named: 'text'),
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => const Stream<Uint8List>.empty());
    when(
      () => ttsStreamClient.synthesizeChunks(
        textChunks: any(named: 'textChunks'),
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => const Stream<Uint8List>.empty());
    permission = _MockPermissionService();
    credentialStore = _MockCredentialStore();
    player = _MockLocalAudioClipPlayer();
    localRecordingService = _MockRecordingService();
    localTts = _MockLocalTts();
    installationGate = _MockAsrModelInstallationGate();
    speechToSpeechClient = _MockSpeechToSpeechClient();
    s2sSession = _MockSpeechToSpeechSession();
    pcmStreamPlayer = _MockPcmStreamPlayer();
    voiceAudioSession = _FakeVoiceAudioSession();
    s2sEvents = StreamController<SpeechToSpeechEvent>.broadcast();
    asrEvents = StreamController<AsrTranscriptEvent>.broadcast();
    pcmEvents = StreamController<Uint8List>.broadcast();
    localSpeechEvents = StreamController<SpeechPracticeEvent>.broadcast();

    when(
      () => fileAsrClient.transcribe(
        pcm: any(named: 'pcm'),
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => const Stream<FileAsrResult>.empty());
    when(() => asrSession.events).thenAnswer((_) => asrEvents.stream);
    when(() => asrSession.appendPcm(any())).thenReturn(null);
    when(() => asrSession.finish()).thenAnswer((_) async => '');
    when(() => asrSession.cancel()).thenAnswer((_) async {});
    when(
      () => asrClient.start(
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
      ),
    ).thenAnswer((_) async => asrSession);
    when(
      () => recorder.start(
        sampleRate: any(named: 'sampleRate'),
        numChannels: any(named: 'numChannels'),
      ),
    ).thenAnswer((_) async => pcmEvents.stream);
    when(
      () => recorder.startForVoiceCommunication(
        sampleRate: any(named: 'sampleRate'),
        numChannels: any(named: 'numChannels'),
      ),
    ).thenAnswer((_) async => pcmEvents.stream);
    when(() => recorder.stop()).thenAnswer((_) async {});
    when(() => recorder.dispose()).thenAnswer((_) async {});
    when(() => permission.isSupported).thenReturn(true);
    when(() => permission.ensurePermission()).thenAnswer((_) async => true);
    when(() => credentialStore.readLlmApiKey(any()))
        .thenAnswer((_) async => 'llm-key');
    when(() => credentialStore.readDashscopeApiKey())
        .thenAnswer((_) async => 'dash-key');
    when(() => player.playFile(any(), playbackKey: any(named: 'playbackKey')))
        .thenAnswer((_) async => AudioPlaybackResult.completed);
    when(() => player.stop()).thenAnswer((_) async {});
    when(() => localRecordingService.events)
        .thenAnswer((_) => localSpeechEvents.stream);
    when(
      () => localRecordingService.startRecording(
        promptId: any(named: 'promptId'),
        recognitionEnabled: any(named: 'recognitionEnabled'),
      ),
    ).thenAnswer((_) async => '/tmp/local.wav');
    when(
      () => localRecordingService.stopSession(
        promptId: any(named: 'promptId'),
        effectiveDurationMs: any(named: 'effectiveDurationMs'),
      ),
    ).thenAnswer(
      (_) async => const RecordingResult(filePath: '/tmp/local.wav'),
    );
    when(
      () => localRecordingService.waitForTranscript(
        filePath: any(named: 'filePath'),
        timeout: any(named: 'timeout'),
      ),
    ).thenAnswer(
      (_) async => const RecordingResult(
        filePath: '/tmp/local.wav',
        finalTranscript: 'Hello local',
      ),
    );
    when(
      () => localRecordingService.cancelRecording(
        discardStoppedRecording: any(named: 'discardStoppedRecording'),
      ),
    ).thenAnswer((_) async {});
    when(() => localRecordingService.dispose()).thenAnswer((_) async {});
    when(() => localTts.prewarm(any())).thenAnswer((_) async {});
    when(() => localTts.speak(any(), key: any(named: 'key')))
        .thenAnswer((_) async => AudioPlaybackResult.completed);
    when(() => localTts.stop()).thenAnswer((_) async {});
    when(() => installationGate.ensureInstallationStatesLoaded())
        .thenAnswer((_) async {});
    when(() => s2sSession.events).thenAnswer((_) => s2sEvents.stream);
    when(() => s2sSession.appendPcm(any())).thenReturn(null);
    when(() => s2sSession.cancelResponse()).thenAnswer((_) async {});
    when(() => s2sSession.close()).thenAnswer((_) async {});
    when(
      () => speechToSpeechClient.start(
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        instructions: any(named: 'instructions'),
      ),
    ).thenAnswer((_) async => s2sSession);
    when(() => pcmStreamPlayer.isSupported).thenReturn(true);
    when(
      () => pcmStreamPlayer.startWithUsage(
        sampleRate: any(named: 'sampleRate'),
        usage: any(named: 'usage'),
      ),
    ).thenAnswer((_) async {});
    when(() => pcmStreamPlayer.start()).thenAnswer((_) async {});
    when(() => pcmStreamPlayer.setVolume(any())).thenAnswer((_) async {});
    when(() => pcmStreamPlayer.write(any())).thenAnswer((_) async {});
    when(() => pcmStreamPlayer.flush()).thenAnswer((_) async {});
    when(() => pcmStreamPlayer.finish()).thenAnswer((_) async {});
    when(() => pcmStreamPlayer.stop()).thenAnswer((_) async {});
  });

  tearDown(() async {
    await asrEvents.close();
    await pcmEvents.close();
    await localSpeechEvents.close();
    await s2sEvents.close();
  });

  ProviderContainer makeContainer({
    bool autoPlay = false,
    AiSpeakingLevel level = AiSpeakingLevel.beginner,
    PcmRecorder? pcmRecorder,
    SpeakingEngineSettings engineSettings = SpeakingEngineSettings.defaults,
    bool localAsrReady = true,
    AsrBackend localAsrBackend = AsrBackend.offline,
    String asrModel = AiSpeechConfig.defaultAsrModel,
  }) {
    final settings = AiSpeakingSettings.defaults.copyWith(
      speech: AiSpeakingSettings.defaults.speech.copyWith(autoPlay: autoPlay),
    );
    final levelConfigs = {
      for (final option in AiSpeakingLevel.values)
        option: SpeakingLevelConfig(
          engine: engineSettings,
          speech: settings.speech.copyWith(asrModel: asrModel),
          dialog: SpeakingDialogSettings.defaults,
        ),
    };
    final container = ProviderContainer(
      overrides: [
        initialAiSpeakingSettingsProvider.overrideWithValue(settings),
        initialAiSpeakingLevelProvider.overrideWithValue(level),
        pcmRecorderProvider.overrideWithValue(pcmRecorder ?? recorder),
        realtimeAsrClientProvider.overrideWithValue(asrClient),
        fileAsrClientProvider.overrideWithValue(fileAsrClient),
        aiChatClientProvider.overrideWithValue(chatClient),
        aiTtsClientProvider.overrideWithValue(ttsClient),
        aiTtsStreamClientProvider.overrideWithValue(ttsStreamClient),
        aiSpeakingPermissionServiceProvider.overrideWithValue(permission),
        aiSpeakingCredentialStoreProvider.overrideWithValue(credentialStore),
        shortAudioPlayerProvider.overrideWithValue(player),
        initialSpeakingLevelConfigsProvider.overrideWithValue(levelConfigs),
        aiSpeakingRecordingServiceFactoryProvider.overrideWithValue(
          (_) => localRecordingService,
        ),
        aiSpeakingLocalTtsProvider.overrideWithValue(localTts),
        speechPracticeBackendProvider.overrideWithValue(
          _MockSpeechPracticeBackend(),
        ),
        initialOfflineAsrSettingsStateProvider.overrideWithValue(
          _offlineAsrState(isReady: localAsrReady, backend: localAsrBackend),
        ),
        asrModelInstallationGateProvider.overrideWithValue(installationGate),
        speechToSpeechClientProvider.overrideWithValue(speechToSpeechClient),
        pcmStreamPlayerProvider.overrideWithValue(pcmStreamPlayer),
        voiceAudioSessionProvider.overrideWithValue(voiceAudioSession),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('平台不支持语音时进入 unsupportedPlatform 错误', () async {
    when(() => permission.isSupported).thenReturn(false);
    final container = makeContainer();
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );

    await controller.startListening();

    final state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.phase, AiSpeakingPhase.error);
    expect(state.errorKind, AiSpeakingErrorKind.unsupportedPlatform);
  });

  test('缺少 API Key 时提示 missingConfig 且不启动录音', () async {
    when(() => credentialStore.readLlmApiKey(any()))
        .thenAnswer((_) async => null);
    final container = makeContainer();
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );

    await controller.startListening();

    final state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.phase, AiSpeakingPhase.error);
    expect(state.errorKind, AiSpeakingErrorKind.missingConfig);
    verifyNever(
      () => asrClient.start(
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
      ),
    );
  });

  test('麦克风权限被拒绝时进入 permissionDenied 错误', () async {
    when(() => permission.ensurePermission()).thenAnswer((_) async => false);
    final container = makeContainer();
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );

    await controller.startListening();

    final state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.phase, AiSpeakingPhase.error);
    expect(state.errorKind, AiSpeakingErrorKind.permissionDenied);
  });

  test('录音 PCM 驱动输入电平并在取消后归零', () async {
    final container = makeContainer();
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );

    await controller.startListening();
    expect(container.read(aiSpeakingSessionControllerProvider).inputLevel, 0);

    final sample = ByteData(2)..setInt16(0, 1311, Endian.little);
    pcmEvents.add(sample.buffer.asUint8List());
    await Future<void>.delayed(Duration.zero);

    expect(
      container.read(aiSpeakingSessionControllerProvider).inputLevel,
      closeTo(0.36, 0.01),
    );

    await controller.cancelListening();
    expect(container.read(aiSpeakingSessionControllerProvider).inputLevel, 0);
  });

  test('录音识别完成后发送用户消息并生成流式回复', () async {
    when(() => asrSession.finish())
        .thenAnswer((_) async => '  Hello teacher  ');
    when(
      () => chatClient.streamReply(
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        history: any(named: 'history'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => Stream<String>.fromIterable(['Nice ', 'to meet you!']));
    final container = makeContainer();
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );

    await controller.startListening();
    expect(
      container.read(aiSpeakingSessionControllerProvider).phase,
      AiSpeakingPhase.listening,
    );

    final listeningState = container.read(aiSpeakingSessionControllerProvider);
    final turnId = listeningState.messages.length;
    expect(turnId, 0);

    await controller.stopListening();

    final state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.phase, AiSpeakingPhase.idle);
    expect(state.messages.length, 2);
    expect(state.messages[0].role, AiSpeakingRole.user);
    expect(state.messages[0].content, 'Hello teacher');
    expect(state.messages[1].role, AiSpeakingRole.assistant);
    expect(state.messages[1].content, 'Nice to meet you!');
    expect(state.messages[1].status, AiSpeakingMessageStatus.done);
  });

  test('连续两轮语音输入都能重新开始录音', () async {
    when(() => asrSession.finish()).thenAnswer((_) async => 'Hello');
    when(
      () => chatClient.streamReply(
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        history: any(named: 'history'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => Stream<String>.value('Hi!'));
    final singleUseRecorder = _SingleUsePcmRecorder();
    final container = makeContainer(pcmRecorder: singleUseRecorder);
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );

    await controller.startListening();
    expect(
      container.read(aiSpeakingSessionControllerProvider).phase,
      AiSpeakingPhase.listening,
    );
    await controller.stopListening();
    expect(
      container.read(aiSpeakingSessionControllerProvider).phase,
      AiSpeakingPhase.idle,
    );

    await controller.startListening();

    final state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.phase, AiSpeakingPhase.listening);
    expect(state.errorKind, isNull);
    expect(singleUseRecorder.startCount, 2);
    await controller.cancelListening();
  });

  test('ASR 部分结果写入 partialTranscript', () async {
    when(() => asrSession.finish()).thenAnswer((_) async => '');
    final container = makeContainer();
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );
    await controller.startListening();

    asrEvents.add(const AsrTranscriptEvent(text: 'Hel', isFinal: false));
    await Future<void>.delayed(Duration.zero);

    expect(
      container.read(aiSpeakingSessionControllerProvider).partialTranscript,
      'Hel',
    );
  });

  test('自动朗读开启时合成语音并记录音频路径', () async {
    when(
      () => chatClient.streamReply(
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        history: any(named: 'history'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => Stream<String>.value('Hello!'));
    when(
      () => ttsClient.synthesizeToFile(
        text: any(named: 'text'),
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => '/tmp/reply.mp3');
    // 非 Android 平台不具备 PCM 流式播放能力，退回 HTTP 合成 + 文件播放。
    when(() => pcmStreamPlayer.isSupported).thenReturn(false);
    final container = makeContainer(autoPlay: true);
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );

    await controller.sendText('Hi');

    final state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.phase, AiSpeakingPhase.idle);
    expect(state.messages.length, 2);
    expect(state.messages[1].audioPath, '/tmp/reply.mp3');
    verify(
      () =>
          player.playFile('/tmp/reply.mp3', playbackKey: state.messages[1].id),
    ).called(1);
  });

  test('自动朗读在支持流式播放时直接播放合成 PCM', () async {
    when(
      () => chatClient.streamReply(
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        history: any(named: 'history'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => Stream<String>.value('Hello!'));
    when(
      () => ttsStreamClient.synthesizeChunks(
        textChunks: any(named: 'textChunks'),
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) => Stream<Uint8List>.fromIterable([
        Uint8List.fromList([1, 2]),
        Uint8List.fromList([3]),
      ]),
    );
    final container = makeContainer(autoPlay: true);
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );

    await controller.sendText('Hi');

    final state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.phase, AiSpeakingPhase.idle);
    verify(
      () => pcmStreamPlayer.startWithUsage(
        sampleRate: 24000,
        usage: PcmOutputUsage.media,
      ),
    ).called(1);
    final written = verify(() => pcmStreamPlayer.write(captureAny())).captured;
    expect(written.map((chunk) => (chunk as Uint8List).toList()), [
      [1, 2],
      [3],
    ]);
    // 自然结束必须等播放器排空，不能用 stop 直接丢弃尾部音频。
    verify(() => pcmStreamPlayer.finish()).called(1);
    verifyNever(() => pcmStreamPlayer.stop());
    verifyNever(
      () => player.playFile(any(), playbackKey: any(named: 'playbackKey')),
    );
  });

  test('首句到达时立即开始合成，不等待大模型结束', () async {
    final reply = StreamController<String>();
    final audio = StreamController<Uint8List>();
    final speech = <String>[];
    final firstSentence = Completer<void>();
    when(
      () => chatClient.streamReply(
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        history: any(named: 'history'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => reply.stream);
    when(
      () => ttsStreamClient.synthesizeChunks(
        textChunks: any(named: 'textChunks'),
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((invocation) {
      final chunks = invocation.namedArguments[#textChunks] as Stream<String>;
      chunks.listen((sentence) {
        speech.add(sentence);
        if (!firstSentence.isCompleted) firstSentence.complete();
      });
      return audio.stream;
    });
    final container = makeContainer(autoPlay: true);
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );

    final send = controller.sendText('Hi');
    reply.add('Hello! ');
    await firstSentence.future.timeout(const Duration(seconds: 1));

    // 大模型文本流仍未关闭，TTS 已经收到第一句并进入朗读阶段。
    expect(reply.isClosed, isFalse);
    expect(speech, <String>['Hello!']);
    expect(
      container.read(aiSpeakingSessionControllerProvider).phase,
      AiSpeakingPhase.speaking,
    );
    reply.add('How are you?');
    await reply.close();
    audio.add(Uint8List.fromList([1, 2]));
    await audio.close();
    await send;

    expect(speech, <String>['Hello!', 'How are you?']);
    // 第二句只能追加到同一条文本流，不能并发启动第二个 TTS 会话。
    verify(
      () => ttsStreamClient.synthesizeChunks(
        textChunks: any(named: 'textChunks'),
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).called(1);
    final state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.phase, AiSpeakingPhase.idle);
    expect(state.messages.last.content, 'Hello! How are you?');
  });

  test('分句器没有可读文本时回退整段合成，不停在思考中', () async {
    final synthesized = <String>[];
    when(
      () => chatClient.streamReply(
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        history: any(named: 'history'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => Stream<String>.value('**'));
    when(
      () => ttsStreamClient.synthesizeChunks(
        textChunks: any(named: 'textChunks'),
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((invocation) {
      final chunks = invocation.namedArguments[#textChunks] as Stream<String>;
      chunks.listen(synthesized.add);
      return Stream<Uint8List>.value(Uint8List.fromList([1, 2]));
    });
    final container = makeContainer(autoPlay: true);
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );

    await controller.sendText('Hi');

    expect(synthesized, <String>['**']);
    final state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.phase, AiSpeakingPhase.idle);
    expect(state.messages.last.status, AiSpeakingMessageStatus.done);
  });

  test('停止首句朗读时同时取消仍在生成的大模型回复', () async {
    final reply = StreamController<String>();
    final audio = StreamController<Uint8List>();
    final firstSentence = Completer<void>();
    CancelToken? chatToken;
    when(
      () => chatClient.streamReply(
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        history: any(named: 'history'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((invocation) {
      chatToken = invocation.namedArguments[#cancelToken] as CancelToken;
      return reply.stream;
    });
    when(
      () => ttsStreamClient.synthesizeChunks(
        textChunks: any(named: 'textChunks'),
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((invocation) {
      final chunks = invocation.namedArguments[#textChunks] as Stream<String>;
      chunks.listen((_) {
        if (!firstSentence.isCompleted) firstSentence.complete();
      });
      return audio.stream;
    });
    final container = makeContainer(autoPlay: true);
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );

    final send = controller.sendText('Hi');
    reply.add('Hello!');
    await firstSentence.future.timeout(const Duration(seconds: 1));
    expect(
      container.read(aiSpeakingSessionControllerProvider).phase,
      AiSpeakingPhase.speaking,
    );

    await controller.stopSpeaking();

    expect(chatToken?.isCancelled, isTrue);
    var state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.phase, AiSpeakingPhase.idle);
    expect(state.messages.last.content, 'Hello!');
    expect(state.messages.last.status, AiSpeakingMessageStatus.done);

    await reply.close();
    await audio.close();
    await send;
    state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.phase, AiSpeakingPhase.idle);
    expect(state.errorKind, isNull);
  });

  test('本地 TTS 按句顺序朗读并预合成后续句子', () async {
    final reply = StreamController<String>();
    final spoken = <String>[];
    final keys = <String>[];
    final firstSpoken = Completer<void>();
    when(
      () => chatClient.streamReply(
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        history: any(named: 'history'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => reply.stream);
    when(() => localTts.speak(any(), key: any(named: 'key'))).thenAnswer((
      invocation,
    ) {
      spoken.add(invocation.positionalArguments.first as String);
      keys.add(invocation.namedArguments[#key] as String);
      if (!firstSpoken.isCompleted) firstSpoken.complete();
      return Future<AudioPlaybackResult>.value(AudioPlaybackResult.completed);
    });
    final container = makeContainer(
      autoPlay: true,
      engineSettings: const SpeakingEngineSettings(
        asrSource: SpeakingAsrSource.local,
        ttsSource: SpeakingTtsSource.local,
      ),
    );
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );

    final send = controller.sendText('Hi');
    reply.add('Hello!');
    await firstSpoken.future.timeout(const Duration(seconds: 1));

    expect(reply.isClosed, isFalse);
    expect(spoken, <String>['Hello!']);
    expect(
      container.read(aiSpeakingSessionControllerProvider).phase,
      AiSpeakingPhase.speaking,
    );

    reply.add('How are you?');
    await reply.close();
    await send;

    final state = container.read(aiSpeakingSessionControllerProvider);
    final assistantId = state.messages.last.id;
    expect(spoken, <String>['Hello!', 'How are you?']);
    expect(keys, <String>['$assistantId-0', '$assistantId-1']);
    verify(() => localTts.prewarm('Hello!')).called(1);
    verify(() => localTts.prewarm('How are you?')).called(1);
    expect(state.phase, AiSpeakingPhase.idle);
  });

  test('停止流式朗读时立即停止播放器且不等待排空', () async {
    final chunks = StreamController<Uint8List>();
    when(
      () => chatClient.streamReply(
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        history: any(named: 'history'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => Stream<String>.value('Hello!'));
    when(
      () => ttsStreamClient.synthesizeChunks(
        textChunks: any(named: 'textChunks'),
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => chunks.stream);
    final started = Completer<void>();
    when(
      () => pcmStreamPlayer.startWithUsage(
        sampleRate: any(named: 'sampleRate'),
        usage: any(named: 'usage'),
      ),
    ).thenAnswer((_) async {
      if (!started.isCompleted) started.complete();
    });
    final container = makeContainer(autoPlay: true);
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );

    final send = controller.sendText('Hi');
    await started.future;
    await controller.stopSpeaking();

    // 用户打断时必须立即丢弃缓冲区，不能等 finish 排空。
    verify(() => pcmStreamPlayer.stop()).called(1);
    verifyNever(() => pcmStreamPlayer.finish());
    await chunks.close();
    await send;
  });

  test('大模型返回错误时标记回复失败并进入 llmFailed', () async {
    when(
      () => chatClient.streamReply(
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        history: any(named: 'history'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) => Stream<String>.error(
        const AiChatException(AiChatErrorKind.network, '网络连接失败'),
      ),
    );
    final container = makeContainer();
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );

    await controller.sendText('Hi');

    final state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.phase, AiSpeakingPhase.error);
    expect(state.errorKind, AiSpeakingErrorKind.llmFailed);
    expect(state.messages.last.status, AiSpeakingMessageStatus.error);
    expect(state.messages.last.content, '回复生成失败');
  });

  test('stopGenerating 移除流式占位消息并回到空闲', () async {
    final streamController = StreamController<String>();
    addTearDown(streamController.close);
    when(
      () => chatClient.streamReply(
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        history: any(named: 'history'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => streamController.stream);
    final container = makeContainer();
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );

    unawaited(controller.sendText('Hi'));
    await Future<void>.delayed(Duration.zero);
    expect(
      container.read(aiSpeakingSessionControllerProvider).phase,
      AiSpeakingPhase.thinking,
    );
    expect(
      container.read(aiSpeakingSessionControllerProvider).messages.last.status,
      AiSpeakingMessageStatus.streaming,
    );

    controller.stopGenerating();

    final state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.phase, AiSpeakingPhase.idle);
    expect(state.messages.length, 1);
    expect(state.messages.single.role, AiSpeakingRole.user);
  });

  test('newConversation 清空消息与错误状态', () async {
    final container = makeContainer();
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );
    await controller.sendText('Hi');

    await controller.newConversation();

    final state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.messages, isEmpty);
    expect(state.phase, AiSpeakingPhase.idle);
    expect(state.errorMessage, isNull);
  });

  test('本地 ASR 使用本地转录文本发送消息且不依赖 DashScope Key', () async {
    when(() => credentialStore.readDashscopeApiKey())
        .thenAnswer((_) async => null);
    when(
      () => chatClient.streamReply(
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        history: any(named: 'history'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => Stream<String>.value('Hi there!'));
    final container = makeContainer(
      engineSettings: const SpeakingEngineSettings(
        asrSource: SpeakingAsrSource.local,
        ttsSource: SpeakingTtsSource.local,
      ),
    );
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );

    await controller.startListening();
    expect(
      container.read(aiSpeakingSessionControllerProvider).phase,
      AiSpeakingPhase.listening,
    );
    verify(
      () => localRecordingService.startRecording(
        promptId: any(named: 'promptId'),
        recognitionEnabled: false,
      ),
    ).called(1);
    verifyNever(
      () => asrClient.start(
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
      ),
    );

    localSpeechEvents.add(
      const SpeechPracticeEvent(
        type: SpeechPracticeEventType.partialTranscriptUpdated,
        promptId: 'ai-speaking',
        transcript: 'Hel',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(
      container.read(aiSpeakingSessionControllerProvider).partialTranscript,
      'Hel',
    );

    localSpeechEvents.add(
      const SpeechPracticeEvent(
        type: SpeechPracticeEventType.audioLevel,
        promptId: 'ai-speaking',
        audioLevel: 0.04,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(
      container.read(aiSpeakingSessionControllerProvider).inputLevel,
      closeTo(0.36, 0.01),
    );

    await controller.stopListening();

    final state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.phase, AiSpeakingPhase.idle);
    expect(state.inputLevel, 0);
    expect(state.messages.first.content, 'Hello local');
    expect(state.messages.last.content, 'Hi there!');
  });

  test('本地 TTS 自动朗读走本地语音合成而不是 DashScope', () async {
    when(
      () => chatClient.streamReply(
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        history: any(named: 'history'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => Stream<String>.value('Hello!'));
    final container = makeContainer(
      autoPlay: true,
      engineSettings: const SpeakingEngineSettings(
        asrSource: SpeakingAsrSource.local,
        ttsSource: SpeakingTtsSource.local,
      ),
    );
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );

    await controller.sendText('Hi');

    final state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.phase, AiSpeakingPhase.idle);
    verify(() => localTts.speak('Hello!', key: '${state.messages.last.id}-0'))
        .called(1);
    verifyNever(
      () => ttsClient.synthesizeToFile(
        text: any(named: 'text'),
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        cancelToken: any(named: 'cancelToken'),
      ),
    );
    verifyNever(
      () => player.playFile(any(), playbackKey: any(named: 'playbackKey')),
    );
  });

  test('本地 ASR 使用平台识别后端时开启平台转录', () async {
    final container = makeContainer(
      engineSettings: const SpeakingEngineSettings(
        asrSource: SpeakingAsrSource.local,
        ttsSource: SpeakingTtsSource.local,
      ),
      localAsrBackend: AsrBackend.platform,
      localAsrReady: false,
    );
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );

    await controller.startListening();

    expect(
      container.read(aiSpeakingSessionControllerProvider).phase,
      AiSpeakingPhase.listening,
    );
    verify(
      () => localRecordingService.startRecording(
        promptId: any(named: 'promptId'),
        recognitionEnabled: true,
      ),
    ).called(1);
  });

  test('本地 ASR 模型未就绪时提示 asrFailed 且不开始录音', () async {
    final container = makeContainer(
      engineSettings: const SpeakingEngineSettings(
        asrSource: SpeakingAsrSource.local,
        ttsSource: SpeakingTtsSource.local,
      ),
      localAsrReady: false,
    );
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );

    await controller.startListening();

    final state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.phase, AiSpeakingPhase.error);
    expect(state.errorKind, AiSpeakingErrorKind.asrFailed);
    verifyNever(
      () => localRecordingService.startRecording(
        promptId: any(named: 'promptId'),
        recognitionEnabled: any(named: 'recognitionEnabled'),
      ),
    );
  });

  test('发送空白文本不产生消息', () async {
    final container = makeContainer();
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );

    await controller.sendText('   ');

    expect(
      container.read(aiSpeakingSessionControllerProvider).messages,
      isEmpty,
    );
  });

  test('初级档位不会进入免提会话', () async {
    final container = makeContainer();
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );

    await controller.startSession();

    final state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.phase, AiSpeakingPhase.idle);
    expect(state.isSessionActive, isFalse);
    verifyNever(
      () => recorder.start(
        sampleRate: any(named: 'sampleRate'),
        numChannels: any(named: 'numChannels'),
      ),
    );
  });

  test('中级会话点话筒开始录音，再点结束回到空闲', () async {
    final container = makeContainer(level: AiSpeakingLevel.intermediate);
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );

    await controller.startSession();

    var state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.isSessionActive, isTrue);
    expect(state.phase, AiSpeakingPhase.preparing);
    verify(
      () => recorder.start(
        sampleRate: any(named: 'sampleRate'),
        numChannels: any(named: 'numChannels'),
      ),
    ).called(1);
    // 识别连接在开口前就已建立，不依赖 VAD 首次判定。
    verify(
      () => asrClient.start(
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
      ),
    ).called(1);

    pcmEvents.add(_pcmFrame(0));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.phase, AiSpeakingPhase.listening);

    await controller.stopSession();

    state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.isSessionActive, isFalse);
    expect(state.phase, AiSpeakingPhase.idle);
  });

  test('中级会话由 VAD 切分轮次并在朗读后恢复听音', () async {
    when(() => asrSession.finish()).thenAnswer((_) async => 'Hello there');
    when(
      () => chatClient.streamReply(
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        history: any(named: 'history'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => Stream<String>.fromIterable(['Hi!']));
    final container = makeContainer(level: AiSpeakingLevel.intermediate);
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );

    await controller.startSession();
    // 连续说话约 280ms 后 VAD 判定开口；连接在开口前已建立，总调用次数应为一次。
    for (var i = 0; i < 4; i++) {
      pcmEvents.add(_pcmFrame(9000));
      await Future<void>.delayed(const Duration(milliseconds: 70));
    }
    verify(
      () => asrClient.start(
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
      ),
    ).called(1);
    // 静音超过默认 800ms 尾静音后收尾本轮。
    for (var i = 0; i < 15; i++) {
      pcmEvents.add(_pcmFrame(0));
      await Future<void>.delayed(const Duration(milliseconds: 70));
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.messages.length, 2);
    expect(state.messages.first.content, 'Hello there');
    expect(state.messages.last.content, 'Hi!');
    expect(state.phase, AiSpeakingPhase.listening);
    expect(state.isSessionActive, isTrue);
  });

  test('中级档朗读期间阻断扬声器回声进入识别，停止后留静默窗口', () async {
    when(() => asrSession.finish()).thenAnswer((_) async => 'Hello there');
    when(
      () => chatClient.streamReply(
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        history: any(named: 'history'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => Stream<String>.fromIterable(['Hi!']));
    final audio = StreamController<Uint8List>();
    addTearDown(audio.close);
    when(
      () => ttsStreamClient.synthesizeChunks(
        textChunks: any(named: 'textChunks'),
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => audio.stream);
    final container = makeContainer(
      autoPlay: true,
      level: AiSpeakingLevel.intermediate,
    );
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );

    await controller.startSession();
    for (var i = 0; i < 4; i++) {
      pcmEvents.add(_pcmFrame(9000));
      await Future<void>.delayed(const Duration(milliseconds: 70));
    }
    for (var i = 0; i < 15; i++) {
      pcmEvents.add(_pcmFrame(0));
      await Future<void>.delayed(const Duration(milliseconds: 70));
    }
    await Future<void>.delayed(const Duration(milliseconds: 80));

    var state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.phase, AiSpeakingPhase.speaking);
    expect(state.messages.length, 2);

    clearInteractions(asrSession);
    // 朗读期间麦克风帧仍会到达，但不应再写入识别连接；模拟扬声器尾音
    // 被识别成句末时也不能生成新的用户轮次。
    for (var i = 0; i < 6; i++) {
      pcmEvents.add(_pcmFrame(6000));
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
    asrEvents.add(const AsrTranscriptEvent(text: 'Hi!', isFinal: true));
    await Future<void>.delayed(const Duration(milliseconds: 60));

    state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.phase, AiSpeakingPhase.speaking);
    expect(state.messages.length, 2);
    verifyNever(() => asrSession.appendPcm(any()));

    final stopFuture = controller.stopSpeaking();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    state = container.read(aiSpeakingSessionControllerProvider);
    // 停止播放后先等待扬声器尾音静默，再重新打开识别。
    expect(state.phase, AiSpeakingPhase.preparing);
    await stopFuture;

    state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.phase, AiSpeakingPhase.listening);
    expect(state.messages.length, 2);
  });

  test('高级档收到服务端句末结果时立即收尾本轮', () async {
    when(() => asrSession.finish()).thenAnswer((_) async => 'Hello there');
    when(
      () => chatClient.streamReply(
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        history: any(named: 'history'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => Stream<String>.fromIterable(['Hi!']));
    final container = makeContainer(level: AiSpeakingLevel.advanced);
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );

    await controller.startSession();
    pcmEvents.add(_pcmFrame(0));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // 服务端在尾静音后下发 sentence_end；本地 RMS 可能被底噪卡住，
    // 这里应直接按服务端判停收尾，不再等本地 VAD。
    asrEvents.add(const AsrTranscriptEvent(text: 'Hello there', isFinal: true));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.messages.first.content, 'Hello there');
    expect(state.messages.last.content, 'Hi!');
    expect(state.phase, AiSpeakingPhase.listening);
    expect(state.isSessionActive, isTrue);
    verify(() => asrSession.finish()).called(1);
  });

  test('高级档收尾失败时用已显示的识别文本继续对话', () async {
    when(() => asrSession.finish())
        .thenThrow(const AliyunAsrException('等待语音识别结果超时'));
    when(
      () => chatClient.streamReply(
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        history: any(named: 'history'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => Stream<String>.fromIterable(['Hi!']));
    final container = makeContainer(level: AiSpeakingLevel.advanced);
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );

    await controller.startSession();
    pcmEvents.add(_pcmFrame(0));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    asrEvents.add(
      const AsrTranscriptEvent(text: 'Partial hello', isFinal: false),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    asrEvents.add(
      const AsrTranscriptEvent(text: 'Partial hello', isFinal: true),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.messages.first.content, 'Partial hello');
    expect(state.phase, AiSpeakingPhase.listening);
    expect(state.errorKind, isNull);
  });

  test('非实时识别模型在松开后整段上传并生成回复', () async {
    final uploaded = <Uint8List>[];
    when(
      () => fileAsrClient.transcribe(
        pcm: any(named: 'pcm'),
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((invocation) {
      uploaded.add(invocation.namedArguments[#pcm] as Uint8List);
      return Stream<FileAsrResult>.value(
        const FileAsrResult('Batch answer', isFinal: true),
      );
    });
    when(
      () => chatClient.streamReply(
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        history: any(named: 'history'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => Stream<String>.fromIterable(['Hi!']));
    final container = makeContainer(
      asrModel: AiSpeechConfig.nonRealtimeAsrModel,
    );
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );

    await controller.startListening();
    expect(
      container.read(aiSpeakingSessionControllerProvider).phase,
      AiSpeakingPhase.listening,
    );
    verifyNever(
      () => asrClient.start(
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
      ),
    );

    for (var i = 0; i < 3; i++) {
      pcmEvents.add(_pcmFrame(9000));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await controller.stopListening();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(uploaded, hasLength(1));
    expect(uploaded.single.length, 3 * 320);
    final state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.messages.first.content, 'Batch answer');
    expect(state.messages.last.content, 'Hi!');
    expect(state.phase, AiSpeakingPhase.idle);
  });

  test('中级会话选择非实时识别模型时说完再整段上传', () async {
    final uploaded = <Uint8List>[];
    when(
      () => fileAsrClient.transcribe(
        pcm: any(named: 'pcm'),
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((invocation) {
      uploaded.add(invocation.namedArguments[#pcm] as Uint8List);
      return Stream<FileAsrResult>.fromIterable(const [
        FileAsrResult('Batch hello', isFinal: false),
        FileAsrResult('Batch hello', isFinal: true),
      ]);
    });
    when(
      () => chatClient.streamReply(
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        history: any(named: 'history'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => Stream<String>.fromIterable(['Hi!']));
    final container = makeContainer(
      level: AiSpeakingLevel.intermediate,
      asrModel: AiSpeechConfig.nonRealtimeAsrModel,
    );
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );

    await controller.startSession();
    verifyNever(
      () => asrClient.start(
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
      ),
    );
    for (var i = 0; i < 4; i++) {
      pcmEvents.add(_pcmFrame(9000));
      await Future<void>.delayed(const Duration(milliseconds: 70));
    }
    for (var i = 0; i < 15; i++) {
      pcmEvents.add(_pcmFrame(0));
      await Future<void>.delayed(const Duration(milliseconds: 70));
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(uploaded, hasLength(1));
    // 预录缓冲要包含开口前的起音，否则整段识别仍会丢开头。
    expect(uploaded.single.length, greaterThan(4 * 320));
    final state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.messages.first.content, 'Batch hello');
    expect(state.messages.last.content, 'Hi!');
    expect(state.phase, AiSpeakingPhase.listening);
    expect(state.isSessionActive, isTrue);
  });

  test('中级会话 ASR 建连较慢时不丢失开口头几个词', () async {
    final appended = <Uint8List>[];
    when(() => asrSession.appendPcm(any())).thenAnswer((invocation) {
      appended.add(invocation.positionalArguments.first as Uint8List);
    });
    final startCompleter = Completer<RealtimeAsrSession>();
    when(
      () => asrClient.start(
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
      ),
    ).thenAnswer((_) => startCompleter.future);
    final container = makeContainer(level: AiSpeakingLevel.intermediate);
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );

    await controller.startSession();
    // 先连续说话约 280ms 触发 VAD；此时 ASR 仍在建连。
    final amplitudes = <int>[1000, 2000, 3000, 4000];
    for (final amplitude in amplitudes) {
      pcmEvents.add(_pcmFrame(amplitude));
      await Future<void>.delayed(const Duration(milliseconds: 70));
    }
    // 握手期间继续说话，总音频超过原来的 400ms 预录上限。
    for (var i = 0; i < 45; i++) {
      final amplitude = 5000 + i;
      amplitudes.add(amplitude);
      pcmEvents.add(_pcmFrame(amplitude));
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(appended, isEmpty);

    startCompleter.complete(asrSession);
    await Future<void>.delayed(const Duration(milliseconds: 30));

    // 建连成功后按时间顺序补发整段音频，不能只补最后 400ms。
    expect(
      appended.map(
        (frame) => ByteData.sublistView(frame).getInt16(0, Endian.little),
      ),
      amplitudes,
    );

    pcmEvents.add(_pcmFrame(9000));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    // 补发结束后新到的音频继续实时送流，顺序不中断。
    expect(appended.length, amplitudes.length + 1);
    expect(
      ByteData.sublistView(appended.last).getInt16(0, Endian.little),
      9000,
    );
  });

  test('中级会话 ASR 握手未完成时说完也不会丢掉整段话', () async {
    final startCompleter = Completer<RealtimeAsrSession>();
    when(
      () => asrClient.start(
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
      ),
    ).thenAnswer((_) => startCompleter.future);
    when(() => asrSession.finish()).thenAnswer((_) async => 'Hello there');
    when(
      () => chatClient.streamReply(
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        history: any(named: 'history'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => Stream<String>.fromIterable(['Hi!']));
    final container = makeContainer(level: AiSpeakingLevel.intermediate);
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );

    await controller.startSession();
    for (var i = 0; i < 4; i++) {
      pcmEvents.add(_pcmFrame(9000));
      await Future<void>.delayed(const Duration(milliseconds: 70));
    }
    // 用户说完时建连仍未完成，finish 应等待握手完成而不是按空转写收尾。
    for (var i = 0; i < 15; i++) {
      pcmEvents.add(_pcmFrame(0));
      await Future<void>.delayed(const Duration(milliseconds: 70));
    }
    expect(
      container.read(aiSpeakingSessionControllerProvider).phase,
      AiSpeakingPhase.finalizing,
    );

    startCompleter.complete(asrSession);
    await Future<void>.delayed(const Duration(milliseconds: 80));

    final state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.messages.length, 2);
    expect(state.messages.first.content, 'Hello there');
    expect(state.messages.last.content, 'Hi!');
  });

  test('中级会话使用本地识别时走逐轮录音', () async {
    final container = makeContainer(
      level: AiSpeakingLevel.intermediate,
      engineSettings: const SpeakingEngineSettings(
        asrSource: SpeakingAsrSource.local,
        ttsSource: SpeakingTtsSource.ai,
      ),
    );
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );

    await controller.startSession();

    expect(
      container.read(aiSpeakingSessionControllerProvider).phase,
      AiSpeakingPhase.listening,
    );
    verify(
      () => localRecordingService.startRecording(
        promptId: any(named: 'promptId'),
        recognitionEnabled: any(named: 'recognitionEnabled'),
      ),
    ).called(1);
    verifyNever(
      () => recorder.start(
        sampleRate: any(named: 'sampleRate'),
        numChannels: any(named: 'numChannels'),
      ),
    );
  });

  test('中级会话用原生静音事件为本地识别断句', () async {
    when(
      () => chatClient.streamReply(
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        history: any(named: 'history'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => Stream<String>.fromIterable(['Hi!']));
    final container = makeContainer(
      level: AiSpeakingLevel.intermediate,
      engineSettings: const SpeakingEngineSettings(
        asrSource: SpeakingAsrSource.local,
        ttsSource: SpeakingTtsSource.ai,
      ),
    );
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );

    await controller.startSession();
    localSpeechEvents.add(
      const SpeechPracticeEvent(
        type: SpeechPracticeEventType.partialTranscriptUpdated,
        promptId: 'ai-speaking',
        transcript: 'Hel',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    localSpeechEvents.add(
      const SpeechPracticeEvent(
        type: SpeechPracticeEventType.silenceProgress,
        promptId: 'ai-speaking',
        silenceDuration: Duration(milliseconds: 900),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.messages.first.content, 'Hello local');
    expect(state.messages.last.content, 'Hi!');
    expect(state.phase, AiSpeakingPhase.listening);
    expect(state.isSessionActive, isTrue);
    verify(
      () => localRecordingService.stopSession(promptId: any(named: 'promptId')),
    ).called(1);
  });

  test('本地最终解码超时时用预览文本继续对话', () async {
    when(
      () => localRecordingService.waitForTranscript(
        filePath: any(named: 'filePath'),
        timeout: any(named: 'timeout'),
      ),
    ).thenAnswer(
      (_) async => const RecordingResult(
        filePath: '/tmp/local.wav',
        errorCode: 'timeout',
        errorMessage: '本地语音识别超时',
      ),
    );
    when(
      () => chatClient.streamReply(
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        history: any(named: 'history'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => Stream<String>.fromIterable(['Hi!']));
    final container = makeContainer(
      level: AiSpeakingLevel.intermediate,
      engineSettings: const SpeakingEngineSettings(
        asrSource: SpeakingAsrSource.local,
        ttsSource: SpeakingTtsSource.ai,
      ),
    );
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );

    await controller.startSession();
    localSpeechEvents.add(
      const SpeechPracticeEvent(
        type: SpeechPracticeEventType.partialTranscriptUpdated,
        promptId: 'ai-speaking',
        transcript: 'Hello partial',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    localSpeechEvents.add(
      const SpeechPracticeEvent(
        type: SpeechPracticeEventType.silenceProgress,
        promptId: 'ai-speaking',
        silenceDuration: Duration(milliseconds: 900),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.messages.first.content, 'Hello partial');
    expect(state.phase, AiSpeakingPhase.listening);
    expect(state.isSessionActive, isTrue);
    expect(state.errorKind, isNull);
  });

  test('高级档位使用本地识别时提示需要云端实时识别', () async {
    final container = makeContainer(
      level: AiSpeakingLevel.advanced,
      engineSettings: const SpeakingEngineSettings(
        asrSource: SpeakingAsrSource.local,
        ttsSource: SpeakingTtsSource.ai,
      ),
    );
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );

    await controller.startSession();

    final state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.phase, AiSpeakingPhase.error);
    expect(state.errorKind, AiSpeakingErrorKind.missingConfig);
    expect(state.isSessionActive, isFalse);
  });

  test('高级档朗读期间用户开口会打断朗读并重新开始识别', () async {
    when(() => asrSession.finish()).thenAnswer((_) async => 'Hello there');
    when(
      () => chatClient.streamReply(
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        history: any(named: 'history'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => Stream<String>.fromIterable(['Hi!']));
    when(
      () => ttsClient.synthesizeToFile(
        text: any(named: 'text'),
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => '/tmp/reply.mp3');
    // 播放一直挂起，模拟 AI 正在朗读，直到用户开口打断。
    final playback = Completer<AudioPlaybackResult>();
    when(() => player.playFile(any(), playbackKey: any(named: 'playbackKey')))
        .thenAnswer((_) => playback.future);
    when(() => pcmStreamPlayer.isSupported).thenReturn(false);
    final container = makeContainer(
      level: AiSpeakingLevel.advanced,
      autoPlay: true,
    );
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );

    await controller.startSession();
    for (var i = 0; i < 4; i++) {
      pcmEvents.add(_pcmFrame(9000));
      await Future<void>.delayed(const Duration(milliseconds: 70));
    }
    for (var i = 0; i < 15; i++) {
      pcmEvents.add(_pcmFrame(0));
      await Future<void>.delayed(const Duration(milliseconds: 70));
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      container.read(aiSpeakingSessionControllerProvider).phase,
      AiSpeakingPhase.speaking,
    );

    // 朗读期间 VAD 保持判定：用户开口约 280ms 后触发打断（minSpeech 180ms）。
    for (var i = 0; i < 5; i++) {
      pcmEvents.add(_pcmFrame(9000));
      await Future<void>.delayed(const Duration(milliseconds: 70));
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.phase, AiSpeakingPhase.listening);
    expect(state.isSessionActive, isTrue);
    // 被打断的回复保留在消息列表里，只中断音频。
    expect(state.messages.length, 2);
    expect(state.messages.last.content, 'Hi!');
    verify(() => player.stop()).called(1);
    verify(
      () => asrClient.start(
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
      ),
    ).called(2);

    playback.complete(AudioPlaybackResult.cancelled);
  });

  test('高级档外放但 AEC 不可用时关闭语音插话', () async {
    when(() => asrSession.finish()).thenAnswer((_) async => 'Hello there');
    final audio = StreamController<Uint8List>();
    addTearDown(() async {
      if (!audio.isClosed) await audio.close();
    });
    when(
      () => chatClient.streamReply(
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        history: any(named: 'history'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => Stream<String>.value('Hi!'));
    when(
      () => ttsStreamClient.synthesizeChunks(
        textChunks: any(named: 'textChunks'),
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => audio.stream);
    voiceAudioSession = _FakeVoiceAudioSession(
      const VoiceAudioSessionStatus(
        isSupported: true,
        isSpeakerOutput: true,
        isAecAvailable: false,
        outputUsage: PcmOutputUsage.voiceCommunication,
        isRouteKnown: true,
      ),
    );
    final container = makeContainer(
      level: AiSpeakingLevel.advanced,
      autoPlay: true,
    );
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );

    await controller.startSession();
    for (var i = 0; i < 4; i++) {
      pcmEvents.add(_pcmFrame(9000));
      await Future<void>.delayed(const Duration(milliseconds: 70));
    }
    for (var i = 0; i < 15; i++) {
      pcmEvents.add(_pcmFrame(0));
      await Future<void>.delayed(const Duration(milliseconds: 70));
    }
    audio.add(Uint8List.fromList([1, 2]));
    await Future<void>.delayed(const Duration(milliseconds: 100));

    var state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.phase, AiSpeakingPhase.speaking);
    expect(state.isVoiceBargeInAvailable, isFalse);

    // 外放时 VAD 必须保持静音，即使麦克风持续收到很响的声音也不能打断。
    clearInteractions(asrClient);
    for (var i = 0; i < 5; i++) {
      pcmEvents.add(_pcmFrame(9000));
      await Future<void>.delayed(const Duration(milliseconds: 70));
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));

    state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.phase, AiSpeakingPhase.speaking);
    expect(state.messages.length, 2);
    verifyNever(
      () => asrClient.start(
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
      ),
    );

    await controller.stopSpeaking();
    expect(
      container.read(aiSpeakingSessionControllerProvider).phase,
      AiSpeakingPhase.listening,
    );
    verify(
      () => asrClient.start(
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
      ),
    ).called(1);
  });

  test('高级档外放 AEC 可用时 duck 后确认用户插话', () async {
    when(() => asrSession.finish()).thenAnswer((_) async => 'Hello there');
    final audio = StreamController<Uint8List>();
    addTearDown(() async {
      if (!audio.isClosed) await audio.close();
    });
    when(
      () => chatClient.streamReply(
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        history: any(named: 'history'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => Stream<String>.value('Hi!'));
    when(
      () => ttsStreamClient.synthesizeChunks(
        textChunks: any(named: 'textChunks'),
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => audio.stream);
    voiceAudioSession = _FakeVoiceAudioSession(
      const VoiceAudioSessionStatus(
        isSupported: true,
        isSpeakerOutput: true,
        isAecAvailable: true,
        outputUsage: PcmOutputUsage.voiceCommunication,
        isRouteKnown: true,
      ),
    );
    final container = makeContainer(
      level: AiSpeakingLevel.advanced,
      autoPlay: true,
    );
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );

    await controller.startSession();
    for (var i = 0; i < 4; i++) {
      pcmEvents.add(_pcmFrame(9000));
      await Future<void>.delayed(const Duration(milliseconds: 70));
    }
    for (var i = 0; i < 15; i++) {
      pcmEvents.add(_pcmFrame(0));
      await Future<void>.delayed(const Duration(milliseconds: 70));
    }
    audio.add(Uint8List.fromList([1, 2]));
    // 等待回复与 TTS 真正进入播放态，避免固定延时在慢机器上产生竞态。
    final speakingDeadline = DateTime.now().add(const Duration(seconds: 3));
    while (container.read(aiSpeakingSessionControllerProvider).phase !=
            AiSpeakingPhase.speaking &&
        DateTime.now().isBefore(speakingDeadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    // phase 进入 speaking 后，播放器启动与插话判别配置仍在异步收尾。
    await Future<void>.delayed(const Duration(milliseconds: 200));

    var state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.phase, AiSpeakingPhase.speaking);
    expect(state.isVoiceBargeInAvailable, isTrue);

    clearInteractions(pcmStreamPlayer);
    // 先持续人声触发 duck，再用低电平模拟 AEC 收敛后的回声残留，
    // 最后重新出现人声才应确认插话。
    // 两声高电平足以触发 duck；随后立刻用低电平覆盖 180ms 的 AEC 收敛窗口。
    for (var i = 0; i < 3; i++) {
      pcmEvents.add(_pcmFrame(9000));
      await Future<void>.delayed(const Duration(milliseconds: 70));
    }
    for (var i = 0; i < 3; i++) {
      pcmEvents.add(_pcmFrame(500));
      await Future<void>.delayed(const Duration(milliseconds: 70));
    }
    for (var i = 0; i < 8; i++) {
      pcmEvents.add(_pcmFrame(9000));
      await Future<void>.delayed(const Duration(milliseconds: 70));
    }
    await Future<void>.delayed(const Duration(milliseconds: 120));

    state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.phase, AiSpeakingPhase.listening);
    expect(state.messages.length, 2);
    expect(state.messages.last.content, 'Hi!');
    expect(state.messages.last.wasInterrupted, isTrue);
    verify(() => pcmStreamPlayer.setVolume(0.12)).called(1);
    verify(() => pcmStreamPlayer.stop()).called(1);
    verify(
      () => asrClient.start(
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
      ),
    ).called(2);
  });

  test('高级档外放 duck 未能压低回声时关闭插话', () async {
    when(() => asrSession.finish()).thenAnswer((_) async => 'Hello there');
    final audio = StreamController<Uint8List>();
    addTearDown(() async {
      if (!audio.isClosed) await audio.close();
    });
    when(
      () => chatClient.streamReply(
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        history: any(named: 'history'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => Stream<String>.value('Hi!'));
    when(
      () => ttsStreamClient.synthesizeChunks(
        textChunks: any(named: 'textChunks'),
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => audio.stream);
    voiceAudioSession = _FakeVoiceAudioSession(
      const VoiceAudioSessionStatus(
        isSupported: true,
        isSpeakerOutput: true,
        isAecAvailable: true,
        outputUsage: PcmOutputUsage.voiceCommunication,
        isRouteKnown: true,
      ),
    );
    final container = makeContainer(
      level: AiSpeakingLevel.advanced,
      autoPlay: true,
    );
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );

    await controller.startSession();
    for (var i = 0; i < 4; i++) {
      pcmEvents.add(_pcmFrame(9000));
      await Future<void>.delayed(const Duration(milliseconds: 70));
    }
    for (var i = 0; i < 15; i++) {
      pcmEvents.add(_pcmFrame(0));
      await Future<void>.delayed(const Duration(milliseconds: 70));
    }
    audio.add(Uint8List.fromList([1, 2]));
    // 等待回复与 TTS 真正进入播放态，避免固定延时在慢机器上产生竞态。
    final speakingDeadline = DateTime.now().add(const Duration(seconds: 3));
    while (container.read(aiSpeakingSessionControllerProvider).phase !=
            AiSpeakingPhase.speaking &&
        DateTime.now().isBefore(speakingDeadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    // phase 进入 speaking 后，播放器启动与插话判别配置仍在异步收尾。
    await Future<void>.delayed(const Duration(milliseconds: 200));

    var state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.phase, AiSpeakingPhase.speaking);
    expect(state.isVoiceBargeInAvailable, isTrue);

    clearInteractions(pcmStreamPlayer);
    // duck 后回声仍保持原电平，说明 AEC 没有生效，必须关闭插话。
    for (var i = 0; i < 12; i++) {
      pcmEvents.add(_pcmFrame(9000));
      await Future<void>.delayed(const Duration(milliseconds: 70));
    }
    await Future<void>.delayed(const Duration(milliseconds: 120));

    state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.phase, AiSpeakingPhase.speaking);
    expect(state.isVoiceBargeInAvailable, isFalse);
    expect(state.messages.length, 2);
    expect(state.messages.last.wasInterrupted, isFalse);
    verify(() => pcmStreamPlayer.setVolume(0.12)).called(1);
    verifyNever(() => pcmStreamPlayer.stop());
  });

  test('特级档由实时语音模型完成一轮对话并停止会话', () async {
    final container = makeContainer(level: AiSpeakingLevel.expert);
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );

    await controller.startSession();

    expect(
      container.read(aiSpeakingSessionControllerProvider).isSessionActive,
      isTrue,
    );
    verify(
      () => speechToSpeechClient.start(
        config: any(named: 'config'),
        apiKey: 'dash-key',
        instructions: any(named: 'instructions'),
      ),
    ).called(1);
    verify(() => pcmStreamPlayer.start()).called(1);

    // 麦克风 PCM 原样转发给实时模型。
    pcmEvents.add(_pcmFrame(9000));
    await Future<void>.delayed(Duration.zero);
    verify(() => s2sSession.appendPcm(any())).called(1);

    s2sEvents.add(
      const SpeechToSpeechUserTranscript(text: 'Hello', isFinal: true),
    );
    s2sEvents.add(const SpeechToSpeechResponseStarted('resp-1'));
    s2sEvents.add(
      const SpeechToSpeechAssistantTranscript(
        text: 'Hi',
        isFinal: false,
        responseId: 'resp-1',
      ),
    );
    s2sEvents.add(
      SpeechToSpeechAudio(Uint8List.fromList([1, 2, 3]), responseId: 'resp-1'),
    );
    await Future<void>.delayed(Duration.zero);

    var state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.phase, AiSpeakingPhase.speaking);
    expect(state.messages.length, 2);
    expect(state.messages.first.content, 'Hello');
    expect(state.messages.last.content, 'Hi');
    verify(() => pcmStreamPlayer.write(any())).called(1);

    s2sEvents.add(
      const SpeechToSpeechResponseDone(cancelled: false, responseId: 'resp-1'),
    );
    await Future<void>.delayed(Duration.zero);
    state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.phase, AiSpeakingPhase.listening);
    expect(state.messages.last.status, AiSpeakingMessageStatus.done);

    await controller.stopSession();
    state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.phase, AiSpeakingPhase.idle);
    expect(state.isSessionActive, isFalse);
    verify(() => pcmStreamPlayer.stop()).called(1);
    verify(() => s2sSession.close()).called(1);
  });

  test('特级档服务端先回助手转写时用户消息仍排在前', () async {
    final container = makeContainer(level: AiSpeakingLevel.expert);
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );
    await controller.startSession();

    // 服务端可能先推送助手回复转写，再回报用户最终转写；展示顺序必须仍是
    // 用户在前、助手在后。
    s2sEvents.add(const SpeechToSpeechResponseStarted('resp-1'));
    s2sEvents.add(
      const SpeechToSpeechAssistantTranscript(
        text: 'Hi',
        isFinal: false,
        responseId: 'resp-1',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    s2sEvents.add(
      const SpeechToSpeechUserTranscript(text: 'Hello', isFinal: true),
    );
    await Future<void>.delayed(Duration.zero);

    final messages = container
        .read(aiSpeakingSessionControllerProvider)
        .messages;
    expect(messages.map((message) => message.content).toList(), [
      'Hello',
      'Hi',
    ]);

    await controller.stopSession();
  });

  test('特级档空转写回到听音态而不是停在思考态', () async {
    final container = makeContainer(level: AiSpeakingLevel.expert);
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );
    await controller.startSession();

    // 噪声触发的空转写不会有 AI 回复，必须回到听音态，否则会话卡在思考态。
    s2sEvents.add(
      const SpeechToSpeechUserTranscript(text: '   ', isFinal: true),
    );
    await Future<void>.delayed(Duration.zero);

    final state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.phase, AiSpeakingPhase.listening);
    expect(state.messages, isEmpty);
  });

  test('特级档用户开口时清空本地播放并丢弃旧回复分片', () async {
    final container = makeContainer(level: AiSpeakingLevel.expert);
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );
    await controller.startSession();

    s2sEvents.add(const SpeechToSpeechResponseStarted('resp-1'));
    s2sEvents.add(
      SpeechToSpeechAudio(Uint8List.fromList([1, 2]), responseId: 'resp-1'),
    );
    await Future<void>.delayed(Duration.zero);
    expect(
      container.read(aiSpeakingSessionControllerProvider).phase,
      AiSpeakingPhase.speaking,
    );

    // 用户开口：服务端会取消当前回复，本地立即清空排队音频。
    s2sEvents.add(const SpeechToSpeechSpeechStarted());
    await Future<void>.delayed(Duration.zero);
    verify(() => pcmStreamPlayer.flush()).called(1);
    expect(
      container.read(aiSpeakingSessionControllerProvider).phase,
      AiSpeakingPhase.listening,
    );

    // 旧回复的迟到分片被丢弃，新回复照常播放。
    s2sEvents.add(
      SpeechToSpeechAudio(Uint8List.fromList([3]), responseId: 'resp-1'),
    );
    s2sEvents.add(const SpeechToSpeechResponseStarted('resp-2'));
    s2sEvents.add(
      SpeechToSpeechAudio(Uint8List.fromList([4]), responseId: 'resp-2'),
    );
    await Future<void>.delayed(Duration.zero);
    final writtenPcm = verify(() => pcmStreamPlayer.write(captureAny()))
        .captured
        .cast<Uint8List>();
    // 旧回复的迟到分片被丢弃，只播放新回复的分片。
    expect(writtenPcm.map((chunk) => chunk.toList()), [
      [1, 2],
      [4],
    ]);
    expect(
      container.read(aiSpeakingSessionControllerProvider).phase,
      AiSpeakingPhase.speaking,
    );
  });

  test('特级档缺少 DashScope Key 时提示先配置', () async {
    when(() => credentialStore.readDashscopeApiKey())
        .thenAnswer((_) async => null);
    final container = makeContainer(level: AiSpeakingLevel.expert);
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );

    await controller.startSession();

    final state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.phase, AiSpeakingPhase.error);
    expect(state.errorKind, AiSpeakingErrorKind.missingConfig);
    expect(state.isSessionActive, isFalse);
    verifyNever(() => pcmStreamPlayer.start());
  });

  test('特级档平台不支持流式播放时提示降级', () async {
    when(() => pcmStreamPlayer.isSupported).thenReturn(false);
    final container = makeContainer(level: AiSpeakingLevel.expert);
    final controller = container.read(
      aiSpeakingSessionControllerProvider.notifier,
    );

    await controller.startSession();

    final state = container.read(aiSpeakingSessionControllerProvider);
    expect(state.phase, AiSpeakingPhase.error);
    expect(state.errorKind, AiSpeakingErrorKind.unsupportedPlatform);
    expect(state.isSessionActive, isFalse);
  });
}
