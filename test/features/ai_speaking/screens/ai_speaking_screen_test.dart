/// AI 口语页面 Widget 测试。
///
/// 覆盖空态、文本发送、流式回复与语音输入状态切换。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:echo_loop/features/ai_speaking/data/ai_speaking_credential_store.dart';
import 'package:echo_loop/features/ai_speaking/models/ai_llm_provider.dart';
import 'package:echo_loop/features/ai_speaking/models/ai_speaking_message.dart';
import 'package:echo_loop/features/ai_speaking/models/ai_speaking_settings.dart';
import 'package:echo_loop/features/ai_speaking/providers/ai_speaking_session_controller.dart';
import 'package:echo_loop/features/ai_speaking/providers/ai_speaking_settings_provider.dart';
import 'package:echo_loop/features/ai_speaking/screens/ai_speaking_screen.dart';
import 'package:echo_loop/features/ai_speaking/services/ai_chat_client.dart';
import 'package:echo_loop/features/ai_speaking/services/ai_speaking_permission_service.dart';
import 'package:echo_loop/features/ai_speaking/services/aliyun_realtime_asr_client.dart';
import 'package:echo_loop/features/ai_speaking/services/aliyun_tts_client.dart';
import 'package:echo_loop/features/ai_speaking/services/pcm_recorder.dart';
import 'package:echo_loop/l10n/app_localizations.dart';
import 'package:echo_loop/providers/short_audio_player_provider.dart';
import 'package:echo_loop/services/pronunciation/local_audio_clip_player.dart';
import 'package:echo_loop/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
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
  });

  late _MockPcmRecorder recorder;
  late _MockRealtimeAsrClient asrClient;
  late _MockRealtimeAsrSession asrSession;
  late _MockAiChatClient chatClient;
  late _MockAiTtsClient ttsClient;
  late _MockPermissionService permission;
  late _MockCredentialStore credentialStore;
  late _MockLocalAudioClipPlayer player;
  late StreamController<AsrTranscriptEvent> asrEvents;
  late StreamController<Uint8List> pcmEvents;

  setUp(() {
    recorder = _MockPcmRecorder();
    asrClient = _MockRealtimeAsrClient();
    asrSession = _MockRealtimeAsrSession();
    chatClient = _MockAiChatClient();
    ttsClient = _MockAiTtsClient();
    permission = _MockPermissionService();
    credentialStore = _MockCredentialStore();
    player = _MockLocalAudioClipPlayer();
    asrEvents = StreamController<AsrTranscriptEvent>.broadcast();
    pcmEvents = StreamController<Uint8List>.broadcast();

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
    when(() => credentialStore.readStatus(any())).thenAnswer(
      (_) async => const AiSpeakingSecretStatus(
        hasLlmApiKey: false,
        hasDashscopeApiKey: false,
      ),
    );
    when(() => player.playFile(any(), playbackKey: any(named: 'playbackKey')))
        .thenAnswer((_) async => AudioPlaybackResult.completed);
    when(() => player.stop()).thenAnswer((_) async {});
  });

  tearDown(() async {
    await asrEvents.close();
    await pcmEvents.close();
  });

  Widget createTestWidget({bool autoPlay = false}) {
    final settings = AiSpeakingSettings.defaults.copyWith(
      speech: AiSpeakingSettings.defaults.speech.copyWith(autoPlay: autoPlay),
    );
    return ProviderScope(
      overrides: [
        initialAiSpeakingSettingsProvider.overrideWithValue(settings),
        pcmRecorderProvider.overrideWithValue(recorder),
        realtimeAsrClientProvider.overrideWithValue(asrClient),
        aiChatClientProvider.overrideWithValue(chatClient),
        aiTtsClientProvider.overrideWithValue(ttsClient),
        aiSpeakingPermissionServiceProvider.overrideWithValue(permission),
        aiSpeakingCredentialStoreProvider.overrideWithValue(credentialStore),
        shortAudioPlayerProvider.overrideWithValue(player),
      ],
      child: MaterialApp(
        locale: const Locale('en'),
        supportedLocales: const [Locale('en'), Locale('zh')],
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: AppTheme.light(),
        home: const AiSpeakingScreen(),
      ),
    );
  }

  testWidgets('空态显示欢迎内容与三个建议话题', (tester) async {
    await tester.pumpWidget(createTestWidget());
    await tester.pumpAndSettle();

    expect(find.text('AI Speaking Practice'), findsOneWidget);
    expect(find.text("Let's start speaking"), findsOneWidget);
    expect(find.text('Talk about my day'), findsOneWidget);
    expect(find.text('Practice a job interview'), findsOneWidget);
    expect(find.text('Plan a weekend trip'), findsOneWidget);
    expect(find.text('Type in English or tap the microphone'), findsOneWidget);
    expect(find.byIcon(Icons.mic_rounded), findsOneWidget);
  });

  testWidgets('输入文本并发送后展示用户与助手消息', (tester) async {
    when(
      () => chatClient.streamReply(
        config: any(named: 'config'),
        apiKey: any(named: 'apiKey'),
        history: any(named: 'history'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => Stream<String>.fromIterable(['Nice ', 'to meet you!']));

    await tester.pumpWidget(createTestWidget());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Hello teacher');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Hello teacher'), findsOneWidget);
    expect(find.text('Nice to meet you!'), findsOneWidget);
    expect(find.text('Type in English or tap the microphone'), findsOneWidget);
  });

  testWidgets('点击麦克风进入听音状态并显示识别提示', (tester) async {
    await tester.pumpWidget(createTestWidget());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.mic_rounded));
    await tester.pumpAndSettle();

    expect(find.textContaining('Listening'), findsOneWidget);
    expect(find.text('Tap to finish'), findsWidgets);
    expect(find.text('Cancel'), findsOneWidget);

    asrEvents.add(const AsrTranscriptEvent(text: 'Hello', isFinal: false));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Hello'), findsOneWidget);
  });

  testWidgets('缺少 API Key 时显示配置错误横幅', (tester) async {
    when(() => credentialStore.readLlmApiKey(any()))
        .thenAnswer((_) async => null);

    await tester.pumpWidget(createTestWidget());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.mic_rounded));
    await tester.pumpAndSettle();

    expect(
      find.text('Add your API keys in AI Settings first.'),
      findsOneWidget,
    );
    expect(find.text('AI Settings'), findsWidgets);
  });
}
