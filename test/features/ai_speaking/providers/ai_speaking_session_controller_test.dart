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
import 'package:echo_loop/features/ai_speaking/models/ai_speaking_message.dart';
import 'package:echo_loop/features/ai_speaking/models/ai_speaking_session_state.dart';
import 'package:echo_loop/features/ai_speaking/models/ai_speaking_settings.dart';
import 'package:echo_loop/features/ai_speaking/models/speaking_engine_settings.dart';
import 'package:echo_loop/features/ai_speaking/providers/ai_speaking_session_controller.dart';
import 'package:echo_loop/features/ai_speaking/providers/ai_speaking_settings_provider.dart';
import 'package:echo_loop/features/ai_speaking/providers/speaking_engine_settings_provider.dart';
import 'package:echo_loop/features/ai_speaking/services/ai_chat_client.dart';
import 'package:echo_loop/features/ai_speaking/services/ai_speaking_permission_service.dart';
import 'package:echo_loop/features/ai_speaking/services/aliyun_realtime_asr_client.dart';
import 'package:echo_loop/features/ai_speaking/services/aliyun_tts_client.dart';
import 'package:echo_loop/features/ai_speaking/services/pcm_recorder.dart';
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

class _MockRealtimeAsrSession extends Mock implements RealtimeAsrSession {}

class _MockAiChatClient extends Mock implements AiChatClient {}

class _MockAiTtsClient extends Mock implements AiTtsClient {}

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
    registerFallbackValue(0);
    registerFallbackValue(false);
    registerFallbackValue(Duration.zero);
  });

  late _MockPcmRecorder recorder;
  late _MockRealtimeAsrClient asrClient;
  late _MockRealtimeAsrSession asrSession;
  late _MockAiChatClient chatClient;
  late _MockAiTtsClient ttsClient;
  late _MockPermissionService permission;
  late _MockCredentialStore credentialStore;
  late _MockLocalAudioClipPlayer player;
  late _MockRecordingService localRecordingService;
  late _MockLocalTts localTts;
  late _MockAsrModelInstallationGate installationGate;
  late StreamController<AsrTranscriptEvent> asrEvents;
  late StreamController<Uint8List> pcmEvents;
  late StreamController<SpeechPracticeEvent> localSpeechEvents;

  setUp(() {
    recorder = _MockPcmRecorder();
    asrClient = _MockRealtimeAsrClient();
    asrSession = _MockRealtimeAsrSession();
    chatClient = _MockAiChatClient();
    ttsClient = _MockAiTtsClient();
    permission = _MockPermissionService();
    credentialStore = _MockCredentialStore();
    player = _MockLocalAudioClipPlayer();
    localRecordingService = _MockRecordingService();
    localTts = _MockLocalTts();
    installationGate = _MockAsrModelInstallationGate();
    asrEvents = StreamController<AsrTranscriptEvent>.broadcast();
    pcmEvents = StreamController<Uint8List>.broadcast();
    localSpeechEvents = StreamController<SpeechPracticeEvent>.broadcast();

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
    when(() => localTts.speak(any(), key: any(named: 'key')))
        .thenAnswer((_) async => AudioPlaybackResult.completed);
    when(() => localTts.stop()).thenAnswer((_) async {});
    when(() => installationGate.ensureInstallationStatesLoaded())
        .thenAnswer((_) async {});
  });

  tearDown(() async {
    await asrEvents.close();
    await pcmEvents.close();
    await localSpeechEvents.close();
  });

  ProviderContainer makeContainer({
    bool autoPlay = false,
    PcmRecorder? pcmRecorder,
    SpeakingEngineSettings engineSettings = SpeakingEngineSettings.defaults,
    bool localAsrReady = true,
    AsrBackend localAsrBackend = AsrBackend.offline,
  }) {
    final settings = AiSpeakingSettings.defaults.copyWith(
      speech: AiSpeakingSettings.defaults.speech.copyWith(autoPlay: autoPlay),
    );
    final container = ProviderContainer(
      overrides: [
        initialAiSpeakingSettingsProvider.overrideWithValue(settings),
        pcmRecorderProvider.overrideWithValue(pcmRecorder ?? recorder),
        realtimeAsrClientProvider.overrideWithValue(asrClient),
        aiChatClientProvider.overrideWithValue(chatClient),
        aiTtsClientProvider.overrideWithValue(ttsClient),
        aiSpeakingPermissionServiceProvider.overrideWithValue(permission),
        aiSpeakingCredentialStoreProvider.overrideWithValue(credentialStore),
        shortAudioPlayerProvider.overrideWithValue(player),
        initialSpeakingEngineSettingsProvider.overrideWithValue(engineSettings),
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
    verify(() => localTts.speak('Hello!', key: state.messages.last.id))
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
}
