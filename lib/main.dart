import 'package:flutter/material.dart';

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:posthog_flutter/posthog_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:showcaseview/showcaseview.dart';

import 'l10n/app_localizations.dart';
import 'utils/time_format.dart';
import 'utils/echo_loop_scroll_behavior.dart';
import 'database/app_database.dart';
import 'database/providers.dart';
import 'config/client_distribution.dart';
import 'providers/package_info_provider.dart';
import 'providers/dictionary_provider.dart';
import 'providers/download_provider.dart';
import 'providers/settings_provider.dart';
import 'providers/startup_bootstrap_provider.dart';
import 'router/app_router.dart';
import 'theme/app_theme.dart';
import 'providers/review_reminder_provider.dart';
import 'services/notification_tap_router_bridge.dart';
import 'analytics/analytics_providers.dart';
import 'analytics/analytics_service.dart';
import 'analytics/models/event_names.dart';
import 'providers/learning_settings_provider.dart';
import 'providers/tts/tts_settings_provider.dart';
import 'providers/intensive_listen_prefs_provider.dart';
import 'providers/blind_listen_prefs_provider.dart';
import 'providers/retell_prefs_provider.dart';
import 'providers/difficult_practice_prefs_provider.dart';
import 'providers/new_user_guide_provider.dart';
import 'services/app_logger.dart';
import 'services/startup_trace.dart';
import 'services/app_update_migration.dart';
import 'services/media_kit_debug_initializer.dart';
import 'services/user_id_service.dart';
import 'widgets/app_notice_presenter.dart';
import 'widgets/app_startup_gate.dart';
import 'features/community_collections/download/community_download_notifier.dart';
import 'features/onboarding_survey/data/onboarding_survey_storage.dart';
import 'features/onboarding_survey/providers/onboarding_survey_provider.dart';
import 'features/remote_config/remote_config_providers.dart';
import 'features/remote_config/remote_config_service.dart';
import 'features/ai_speaking/models/ai_speaking_settings.dart';
import 'features/ai_speaking/providers/ai_speaking_settings_provider.dart';

void main() async {
  final startupTrace = StartupTrace();
  registerStartupTrace(startupTrace);
  startupTrace.mark('dart_main_enter');
  WidgetsFlutterBinding.ensureInitialized();
  startupTrace.mark('flutter_binding_ready');
  startupTrace.runSync('timeago_initialize', initTimeago);

  final packageInfo = await startupTrace.run(
    'package_info',
    PackageInfo.fromPlatform,
  );

  // 检查是否处于演示模式
  final prefs = await startupTrace.run(
    'shared_preferences',
    SharedPreferences.getInstance,
  );
  // SecureStorage 在新装设备上可能较慢。立即并行启动匿名 ID 初始化，但不能让它
  // 阻塞 PostHog channel ready 或首帧；完成后再注册为事件 super property。
  final anonymousIdReady = startUserIdService(prefs);
  final analyticsService = await startupTrace.run(
    'analytics_initialize',
    () => initializeAnalyticsWithFallback(prefs),
  );
  final distribution = clientDistribution;
  if (distribution != null) {
    try {
      // 安装来源是用户属性，不创建额外事件；启动时设置可覆盖匿名用户和已有用户。
      await analyticsService.setUserProperty(
        UserProperties.installSource,
        distribution.headerValue,
      );
    } catch (error, stackTrace) {
      AppLogger.log('Analytics', 'install source registration failed: $error');
      AppLogger.log('Analytics', stackTrace.toString());
    }
  }
  unawaited(_registerAnonymousIdWhenReady(anonymousIdReady, analyticsService));
  // 应用升级迁移由自身记录结构化日志，不包装成普通 StartupTrace 步骤，
  // 避免日志看起来像启动阶段重复执行了一次迁移。
  await runAppUpdateMigrations(prefs);
  final isDemoMode = prefs.getBool('demo_mode') ?? false;

  // 远程配置：启动期只同步读取本地缓存/默认值，不触发网络请求，避免网络慢阻塞首帧。
  // 下游 UI 只读取 provider 暴露的 resolved config；远端刷新由 MainShell 首帧后后台执行。
  final initialRemoteConfig = RemoteConfigService.create(
    prefs: prefs,
    appVersion: packageInfo.version,
  ).loadInitialFromCache();

  // 首次启动检测：哨兵 key `first_launch_done` 不存在即视为首次启动，
  // 立即写入 true。后续所有启动都会读到该 key = true，即非首启。
  // 注意：该机制从此版本引入，老用户升级时哨兵同样缺失，会被当作首启。
  // 需要业务层额外用数据是否为空等 gate 兜底区分升级用户。
  final isFirstLaunch = !(prefs.getBool('first_launch_done') ?? false);
  if (isFirstLaunch) {
    await startupTrace.run(
      'first_launch_marker_write',
      () => prefs.setBool('first_launch_done', true),
    );
  }

  // Onboarding 问卷"是否已完成"同步预读：GoRouter redirect 是同步函数，
  // 必须在 main() 阶段拿到值，否则启动闪屏期间 redirect 失效。
  // 用 `onboarding_completed_at_ms` 存在性判定，不引入冗余 bool key。
  final onboardingCompleted = OnboardingSurveyStorage.readIsCompletedSync(
    prefs,
  );

  // 学习设置（自动跳过复述）同步预读：plan / progress 启动期就需要拿到值。
  final initialLearningSettings = LearningSettings.fromPrefsSync(prefs);

  // 语音合成设置（引擎/口音）同步预读：闪卡翻面等同步发音路径需立即拿到口音，
  // 避免异步 hydrate 前先用默认美音发声。
  final initialTtsSettings = TtsSettings.fromPrefsSync(prefs);

  // AI 口语设置同步预读：进入练习页时无需等待异步 hydrate 即可展示已选供应商。
  final initialAiSpeakingSettings = AiSpeakingSettings.fromPrefsSync(prefs);

  // 各学习子阶段用户偏好(按槽位)同步预读:入口弹窗 / 播放器进入时需立即拿到记忆值。
  final initialIntensiveListenPrefs = intensiveListenPrefsFromPrefsSync(prefs);
  final initialBlindListenPrefs = blindListenPrefsFromPrefsSync(prefs);
  final initialRetellPrefs = retellPrefsFromPrefsSync(prefs);
  final initialDifficultPracticePrefs = difficultPracticePrefsFromPrefsSync(
    prefs,
  );

  // 界面语言同步预读：让首帧 MaterialApp.locale 直接拿到用户已选语言，
  // 避免"先按系统语言渲染、再 hydrate 切到用户设置"的闪烁。
  final initialUiLocale = readInitialUiLocaleSync(prefs);
  // AI 转录「自动合并短句」同步预读：让转录弹窗首帧直接拿到上次选择，
  // 避免在 AppSettings 异步 hydrate 前先读到默认 true。
  final initialAiTranscriptionAutoMergeEnabled =
      readInitialAiTranscriptionAutoMergeEnabledSync(prefs);

  // 初始化数据库（演示模式使用独立数据库文件）
  final dbFileName = isDemoMode ? 'echo_loop_demo.db' : 'echo_loop.db';
  final database = AppDatabase(openConnectionWithName(dbFileName));
  initAppDatabase(database);
  startupTrace.mark(
    'database_instance_registered',
    fields: {'demoMode': isDemoMode},
  );

  // 至此仅完成了绑定、同步 UI 偏好和数据库对象注册。首帧后的本地与第三方
  // 任务由 ProviderScope 内的标准 Riverpod 启动 provider 编排。
  startupTrace.mark('run_app_invoked');
  runApp(
    PostHogWidget(
      child: ProviderScope(
        // Riverpod 3 默认对失败的 provider 指数退避重试（最多 10 次），会重复发起
        // 网络 / 数据库请求。Riverpod 2 无此行为，错误由各 provider 自行处理，这里
        // 关闭自动重试以保持原有语义。
        retry: (_, _) => null,
        overrides: [
          analyticsServiceProvider.overrideWithValue(analyticsService),
          packageInfoProvider.overrideWithValue(packageInfo),
          isFirstLaunchProvider.overrideWithValue(isFirstLaunch),
          sharedPreferencesProvider.overrideWithValue(prefs),
          initialOnboardingCompletedProvider.overrideWithValue(
            onboardingCompleted,
          ),
          initialLearningSettingsProvider.overrideWithValue(
            initialLearningSettings,
          ),
          initialTtsSettingsProvider.overrideWithValue(initialTtsSettings),
          initialAiSpeakingSettingsProvider.overrideWithValue(
            initialAiSpeakingSettings,
          ),
          initialIntensiveListenPrefsProvider.overrideWithValue(
            initialIntensiveListenPrefs,
          ),
          initialBlindListenPrefsProvider.overrideWithValue(
            initialBlindListenPrefs,
          ),
          initialRetellPrefsProvider.overrideWithValue(initialRetellPrefs),
          initialDifficultPracticePrefsProvider.overrideWithValue(
            initialDifficultPracticePrefs,
          ),
          initialUiLocaleProvider.overrideWithValue(initialUiLocale),
          initialAiTranscriptionAutoMergeEnabledProvider.overrideWithValue(
            initialAiTranscriptionAutoMergeEnabled,
          ),
          initialRemoteConfigProvider.overrideWithValue(initialRemoteConfig),
          startupDemoModeProvider.overrideWithValue(isDemoMode),
        ],
        child: const EchoLoopApp(),
      ),
    ),
  );
}

/// 匿名 ID 是附加事件属性，不是 PostHog distinct ID；其迟到不得丢弃已入 SDK 队列
/// 的早期事件，也不得阻塞首帧。
Future<void> _registerAnonymousIdWhenReady(
  Future<String> anonymousIdReady,
  AnalyticsService analyticsService,
) async {
  try {
    final anonymousId = await anonymousIdReady;
    await analyticsService.registerSuperProperties({
      'app_anonymous_id': anonymousId,
    });
  } catch (error, stackTrace) {
    AppLogger.log('Analytics', 'anonymous ID initialization failed: $error');
    AppLogger.log('Analytics', stackTrace.toString());
  }
}

class EchoLoopApp extends ConsumerStatefulWidget {
  const EchoLoopApp({super.key});

  @override
  ConsumerState<EchoLoopApp> createState() => _EchoLoopAppState();
}

class _EchoLoopAppState extends ConsumerState<EchoLoopApp>
    with WidgetsBindingObserver {
  StreamSubscription<NotificationIntent>? _intentSubscription;
  ProviderSubscription<AsyncValue<StartupReport>>? _localStartupSubscription;
  late final ShowcaseView _showcase;
  bool _hasLoggedRouterCreated = false;
  bool _didStartLocalEffects = false;

  @override
  void initState() {
    super.initState();
    activeStartupTrace?.mark('app_widget_init_state');
    _localStartupSubscription = ref.listenManual<AsyncValue<StartupReport>>(
      localStartupProvider,
      (_, next) {
        if (next.hasValue) unawaited(_startAfterLocalDataReady());
      },
      fireImmediately: true,
    );
    // 纯端侧模式下仅保留本地音频与维护任务，不再初始化任何云端 SDK。
    unawaited(ref.read(thirdPartyStartupProvider.future));

    WidgetsBinding.instance.addObserver(this);

    // 新手引导 showcase 控制器全局注册（替代旧的 ShowCaseWidget InheritedWidget）。
    // 整段 tour 走完或被 dismiss 时，通过 GuideShowcaseBus 触发 controller 的
    // completeActiveFlow 标记已看并清空 active。
    _showcase = ShowcaseView.register(
      enableAutoScroll: true,
      onFinish: GuideShowcaseBus.fireEnd,
      onDismiss: (_) => GuideShowcaseBus.fireEnd(),
    );
  }

  /// 依次启动所有不属于首帧关键路径的本地预热任务。
  Future<void> _startAfterLocalDataReady() async {
    if (!mounted || _didStartLocalEffects) return;
    if (!ref.read(localStartupProvider).hasValue) return;
    _didStartLocalEffects = true;
    activeStartupTrace?.mark('main_navigation_released');

    // 下载注册表和词典预热都可能访问文件系统，统一放到首帧后。
    unawaited(startRegisteredDownloads(ref));
    _scheduleMediaKitPrewarm();
    ref.read(dictionaryProvider);

    final bridge = ref.read(notificationTapRouterBridgeProvider);
    _intentSubscription = bridge.intents.listen(_handleNotificationIntent);
    final pendingIntent = bridge.takePendingIntent();
    if (pendingIntent != null) _handleNotificationIntent(pendingIntent);
  }

  /// 业务内容提交后再预热，不让原生播放器依赖阻塞进入学习页。
  void _scheduleMediaKitPrewarm() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        Future<void>(() {
          activeStartupTrace?.runSync(
            'media_kit_initialize',
            ensureMediaKitInitialized,
          );
        }).catchError((Object _) {}),
      );
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _intentSubscription?.cancel();
    _localStartupSubscription?.close();
    _showcase.unregister();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    activeStartupTrace?.mark(
      'app_lifecycle_changed',
      fields: {'state': state.name},
    );
    AppLogger.log('Lifecycle', 'state=${state.name}');
    switch (state) {
      case AppLifecycleState.resumed:
        // 纯端侧模式无云端会话或订阅需要恢复。
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        // 立即刷新 PostHog 埋点队列，避免 Application Backgrounded 等事件
        // 卡在内存队列里，App 被 OS 挂起 / 杀进程时丢失。
        // PostHog 默认 flushAt=20 / flushInterval=30s，单纯依赖默认策略
        // 在快速切后台场景容易丢。
        unawaited(Posthog().flush());
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      // no-op
    }
  }

  void _handleNotificationIntent(NotificationIntent intent) {
    if (!mounted) return;
    switch (intent) {
      case OpenStudyTasks():
        ref.read(appRouterProvider).go(AppRoutes.study);
      case OpenFavorites():
        ref.read(appRouterProvider).go(AppRoutes.favorites);
      case OpenAudioLearningPlan(:final audioId):
        final router = ref.read(appRouterProvider);
        router.go(AppRoutes.study);
        router.push(AppRoutes.audioLearningPlan(audioId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(appSettingsProvider);
    final router = ref.watch(appRouterProvider);
    if (!_hasLoggedRouterCreated) {
      _hasLoggedRouterCreated = true;
      activeStartupTrace?.mark('router_created');
    }

    return MaterialApp.router(
      title: 'Echo Loop',
      debugShowCheckedModeBanner: false,
      scrollBehavior: const EchoLoopScrollBehavior(),
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: settings.themeMode,
      locale: settings.locale,
      supportedLocales: const [Locale('en'), Locale('zh', 'CN')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      routerConfig: router,
      builder: (context, child) => AppStartupGate(
        child: AppNoticePresenter(child: child ?? const SizedBox.shrink()),
      ),
      scaffoldMessengerKey: communityDownloadScaffoldMessengerKey,
    );
  }
}
