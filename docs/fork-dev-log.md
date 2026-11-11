# Echo Loop Fork 开发变更日志

> 原项目：https://github.com/echo-loop/Echo-Loop
> 本 fork：https://github.com/E2E-AK-OI/Echo-Loop
> 基线提交：`5df50638`（FIX: 百度网盘导入改为入队时整批获取 dlink，切后台后可接力下载）
> 变更时间：2026-11-05 至 2026-11-11
> 发布平台：Android
> 当前状态：代码与文档已完成；静态分析 0 error；定向测试通过；2026-11-06 修复“从网盘导入”入口，并将百度网盘 OAuth 改为纯端侧简化模式，移除最后一个后端依赖；2026-11-11 合并上游 v1.0.46 的 7 个非冲突提交，保留端侧优先与离线词典；待 Android 真机验收。

## 1. 变更总览

本次 fork 在原版 Echo Loop 的本地学习能力之上，完成三类改动：

1. **新增 AI 口语自由练习**：用户的英语口语可以从麦克风实时转写，交给可配置的大模型生成英语回复，再用 TTS 朗读；支持 BYOK 供应商、模型、温度与语音参数配置。
2. **改造为端侧优先运行（Android）**：移除账号登录、订阅权益、社区合集、精选播客与自建后端 AI/转录/聊天链路；AI 能力统一改为客户端 BYOK 直连，学习数据与凭据只留在本机。百度网盘导入入口按用户要求保留，OAuth 改为应用内简化模式，用户填写自建应用 AppKey，不再依赖自建后端。
3. **移除应用内升级检查**：删除启动、前台恢复与设置页中的版本检查、更新弹窗和安装包跳转。

本次改动没有修改本地数据库 schema；原有素材、收藏、单词/意群、学习记录仍按原结构读取。

## 2. 需求来源

- 用户要求在 fork 中新增「AI 口语自由练习」，并支持自由设置大模型供应商、模型与温度。
- 语音识别使用阿里云百炼实时 ASR：`qwen-audio-3.1-asr-flash-streaming`。
- 语音合成使用阿里云百炼 TTS：`qwen-audio-3.1-tts-plus`，默认音色 `longanlingxin_v3.1`。
- 大模型至少支持 DeepSeek，同时支持阿里云百炼、OpenAI 与自定义 OpenAI 兼容接口。
- 用户随后要求移除账号登录及相关登录限制，并清理应用内升级检查。
- 用户最终确认将项目改造成 Android 端侧优先版本：AI 使用用户自备 API Key 直连供应商，保留本地学习、本地导入与本地备份；当时移除自建后台依赖，后于 2026-11-06 恢复百度网盘入口。
- 用户要求研究纯端侧能否实现百度网盘 OAuth；确认只有简化模式不需要 `client_secret`，并接受在应用内填写自己在百度开放平台创建的应用 AppKey，不复用上游应用、不内置任何密钥。
- 2026-11-06 用户复核发现原版“从网盘导入”入口在改造中丢失，要求恢复；随后又要求移除该入口对原项目后端的 OAuth 依赖，改为纯端侧简化模式。

## 3. 新增能力

### 3.1 AI 口语自由练习

新增独立功能域 `lib/features/ai_speaking/`，不改动既有 `lib/features/chatbot/`、`lib/services/asr/`、`lib/services/tts/` 的职责边界。

产品流程：

- 学习页主列表与「今日已完成」状态均新增 AI 口语入口卡片。
- 设置页学习分组新增「AI 口语练习」入口。
- 路由新增 `/ai-speaking`，全屏页面，无底部 Tab。
- 半双工会话：点按开始说话 → 实时字幕 → 点按结束 → 等待最终识别 → LLM 流式回复 → TTS 自动朗读。
- 支持文字兜底输入、重试、停止生成、停止朗读、重新开始对话。
- 对话内容仅保存在内存；退出页面不会写入数据库，重新进入仍可看到当前会话，直到新建对话。

语音链路：

- ASR：阿里云 DashScope 实时 WebSocket 协议。`run-task` → `task-started` → PCM 音频帧 → `result-generated` → `finish-task` → `task-finished`。
- 默认模型 `qwen-audio-3.1-asr-flash-streaming`，16 kHz、单声道、PCM16；结束录音后等待最终结果，带超时与错误传播。
- TTS：阿里云 DashScope HTTP 接口，默认模型 `qwen-audio-3.1-tts-plus`，默认音色 `longanlingxin_v3.1`。
- TTS 支持 `qwen-audio-3.1-tts-flash` 与英文音色切换，支持语速 0.5–2.0、自动朗读开关与试听。
- TTS 音频按文本、模型、音色、语速与指令生成缓存键，写入临时目录后播放；相同文本再次朗读优先命中本地缓存。
- Workspace ID 可选；留空时使用 `dashscope.aliyuncs.com`，填写时使用对应的 `{workspace}.cn-beijing.maas.aliyuncs.com` 域名。

大模型与配置：

- 支持 DeepSeek、阿里云百炼、OpenAI、自定义 OpenAI 兼容四类供应商。
- Base URL、模型、温度（0.0–2.0）可配置；默认 DeepSeek `https://api.deepseek.com/v1`、`deepseek-chat`、温度 0.7。
- LLM 统一使用 OpenAI 兼容 `POST /chat/completions` + SSE 流式解析，DeepSeek、百炼兼容模式、OpenAI 与自定义端点共用一套客户端。
- API Key 按供应商分别保存到 `flutter_secure_storage`，不写入 SharedPreferences、日志或备份文件。
- 设置页模型区域新增「刷新」按钮与下拉选择：调用 BYOK `/models` 获取当前可用模型，按名称排序；刷新失败保留当前模型并提示错误，不写坏设置。
- 自定义供应商在未获取远程模型列表时仍可手动输入模型名。

主要文件：

- `lib/features/ai_speaking/models/ai_llm_provider.dart`：供应商预设、LLM 配置、语音配置与默认值。
- `lib/features/ai_speaking/models/ai_speaking_settings.dart`：设置模型与 SharedPreferences 键。
- `lib/features/ai_speaking/models/ai_speaking_message.dart`、`ai_speaking_session_state.dart`：消息与状态机模型。
- `lib/features/ai_speaking/data/ai_speaking_credential_store.dart`：API Key 安全存储。
- `lib/features/ai_speaking/providers/ai_speaking_settings_provider.dart`：设置读写与首帧预读。
- `lib/features/ai_speaking/providers/ai_speaking_session_controller.dart`：录音、ASR、LLM、TTS 与会话状态编排。
- `lib/features/ai_speaking/services/ai_chat_client.dart`：OpenAI 兼容流式聊天客户端。
- `lib/features/ai_speaking/services/aliyun_realtime_asr_client.dart`：实时 ASR WebSocket 客户端。
- `lib/features/ai_speaking/services/aliyun_tts_client.dart`：TTS HTTP 客户端与本地缓存。
- `lib/features/ai_speaking/services/pcm_recorder.dart`：16 kHz 单声道 PCM16 录音封装。
- `lib/features/ai_speaking/services/ai_speaking_permission_service.dart`：Android 麦克风权限。
- `lib/features/ai_speaking/screens/ai_speaking_screen.dart`、`ai_speaking_settings_screen.dart`：练习页与设置页。
- `lib/features/ai_speaking/widgets/`：入口卡片、欢迎页、消息气泡、底部输入区。

### 3.2 统一 BYOK AI 服务

新增 `lib/services/byok_ai_service.dart`，作为纯端侧 AI 的唯一入口：

- `listModels()`：`GET {baseUrl}/models`，兼容 `data` 与 `models` 两种返回结构，支持字符串、`id`、`name` 三种模型项。
- `completeText()`：`POST {baseUrl}/chat/completions`，非流式返回完整文本。
- `completeJson()`：从模型输出中截取 JSON 对象并解析，供句子解析、单词/意群解析等结构化场景使用。
- `streamText()`：`POST {baseUrl}/chat/completions` + SSE，供翻译与聊天增量输出。
- 统一读取 AI 口语设置中的供应商、Base URL、模型、温度，以及 `AiSpeakingCredentialStore` 中对应供应商的 API Key。
- 错误统一收敛为 `ByokAiException`：`missingConfig`、`unauthorized`、`rateLimited`、`badRequest`、`network`、`server`、`invalidResponse`、`cancelled`。

### 3.3 AI 讲解与 AI 学习助手改为 BYOK

- `lib/services/sentence_ai_api_client.dart`：翻译、解析、查词、意群改为 BYOK；公开方法签名尽量保持不变，上层页面不感知供应商细节。
- `lib/providers/sentence_ai_provider.dart`：删除登录 token 空判与 `AiFeatureAuthRequiredException`，只注入缓存 DAO 与 BYOK 客户端。
- `lib/services/dictionary/ai_dictionary_source.dart`：删除 token 空判。
- `lib/features/chatbot/services/chat_api_client.dart`：`streamChat` 改为 BYOK 流式输出，保留原聊天 UI 与历史会话控制器接口。
- `lib/features/chatbot/providers/chat_session_controller.dart`：删除登录、订阅、试用三道门禁及试用计数逻辑。
- `lib/providers/retell_review_evaluation_provider.dart`：删除登录与订阅门禁；复述 AI 评估入口暂时隐藏。
- `lib/widgets/practice/sentence_explanation_view.dart`：AI 讲解自动加载不再依赖 Supabase access token；自动加载只由用户的 AI 显示设置控制。

### 3.4 端侧优先架构

账号与权益：

- 删除 `lib/features/auth/screens/` 下 5 个登录/账号页面。
- `lib/features/auth/sign_in_required_dialog.dart` 的 `ensureSignedInForAction` 恒返回 `true`，`openSignInPage` 保留为空实现，兼容旧调用点。
- `lib/features/auth/supabase_startup_gate.dart` 的 `supabaseSdkReadyProvider`、`supabaseAuthConfiguredProvider` 恒为不可用。
- `lib/features/subscription/providers/feature_access_provider.dart` 的 `featureAccess` 恒为 `true`。
- `lib/features/subscription/widgets/feature_gate.dart` 的 `openPaywall` 改为空实现，不再导航到付费页。

路由与设置：

- `lib/router/app_router.dart` 删除登录、邮箱登录、检查邮箱、密码登录、账号、Paywall 路由与重定向；新增 `/ai-speaking` 全屏路由。
- `lib/screens/settings_screen.dart` 删除账号与订阅分组、地区覆盖入口、手动检查更新入口；新增 AI 口语设置入口与供应商/模型摘要。

启动链路：

- `lib/main.dart` 不再初始化窗口管理器、Supabase 会话订阅、地区启动订阅、Paddle 深链、社区同步触发与第三方依赖任务。
- `lib/providers/startup_bootstrap_provider.dart` 的 `thirdPartyStartupProvider` 只等待本地启动，再执行本地音频、权限快照与维护任务；`initializeThirdParty` 不再初始化 Firebase、Supabase 与 RevenueCat。
- `lib/widgets/app_startup_gate.dart` 只等待本地启动结果，不再等待第三方 SDK 或地区探测。
- `lib/router/main_shell.dart` 删除应用更新监听与弹窗；保留首帧后的本地任务。
- `lib/features/user_region/user_region_providers.dart` 改为「系统 Region + 本地开发者覆盖」，不再请求自建远程配置。

AI 与内容入口收敛：

- `lib/features/podcast/screens/podcast_discovery_screen.dart` 删除精选播客列表、分页与刷新逻辑，保留搜索与 RSS 链接导入提示。
- `lib/screens/library_screen.dart` 删除「发现社区合集」入口 Banner。
- `lib/screens/collection_detail_screen.dart` 删除社区合集下拉刷新与同步逻辑，只展示本地已有内容。
- `lib/widgets/import_audio_sheet.dart` 保留本地文件、音频直链与“从网盘导入”三个入口；网盘 OAuth 改为应用内简化模式，文件列表与下载由客户端直连百度 API。
- `lib/widgets/manage_subtitles_sheet.dart` 默认本地转录，隐藏 AI 云端转录与免费试用入口。
- `lib/screens/retell_player_screen.dart` 隐藏 AI 复述评估按钮。

百度网盘导入入口恢复（2026-11-06）：

- `lib/widgets/import_audio_sheet.dart` 的来源选择恢复为“本地文件 / 从网盘导入 / 音频直链”三项，`_ChooseSourcePanel` 新增 `onCloudDrive` 回调并接入 `_ImportStep.cloudDrive`；原有的网盘来源页、百度网盘目录页、导入任务管理与下载队列继续复用。
- 百度网盘 OAuth 随后改为应用内简化模式，用户填写自建应用 AppKey；文件列表与下载仍由 `lib/features/baidu_netdisk/data/baidu_netdisk_api.dart` 直连 `https://pan.baidu.com/rest/2.0/xpan/*`，不再经过原项目后端。详见 3.5。
- 应用本身仍无账号登录、订阅与付费门禁。

### 3.5 百度网盘 OAuth 改为纯端侧简化模式（2026-11-06）

- 背景：恢复“从网盘导入”后，OAuth 仍通过原项目后端桥接，是端侧主流程之外唯一的后端依赖；用户要求研究纯端侧可行性。
- 结论：官方文档中只有简化模式（Implicit Grant）不需要 `client_secret`，可在端侧完成；授权码模式、设备码模式与 Android OAuth SDK 的换 token/刷新都强制要求 `client_secret`，把 SecretKey 打进 APK 不可接受，因此不采用。
- 授权流程：用户在应用内填写自己在百度网盘开放平台创建的应用 AppKey → WebView 打开 `https://openapi.baidu.com/oauth/2.0/authorize?response_type=token&client_id=...&redirect_uri=oob&scope=basic,netdisk&display=popup&state=...` → 授权成功后跳转 `https://openapi.baidu.com/oauth/2.0/login_success#access_token=...` → WebView 拦截回调，校验 `state`、`access_token`、`expires_in` 与 `scope` 后保存凭据。
- 新增 `lib/features/baidu_netdisk/data/baidu_implicit_oauth.dart`（授权 URL 构造、16 字节 base64Url `state`、回调解析与校验）、`screens/baidu_oauth_webview_screen.dart`（内嵌 WebView、回调拦截、关闭/重试）、`data/baidu_app_key_store.dart`（AppKey 本地存取）、`models/baidu_oauth_result.dart`（成功/失败/取消三态）。
- `models/baidu_credential_bundle.dart` 允许空 `refreshToken` 并新增 `canRefresh`；`data/baidu_credential_repository.dart` 改为 token 过期即清除、不再刷新；`providers/baidu_netdisk_import_controller.dart` 的授权入口改为 `authorizeAndLoad(appKey, authorize)`；`lib/widgets/import_audio_sheet.dart` 授权态新增 AppKey 输入框与“连接网盘”按钮。
- 删除 `data/baidu_oauth_api.dart`、`services/baidu_oauth_launcher.dart`、`models/baidu_oauth_session.dart`、`models/baidu_oauth_session_status.dart`、`models/baidu_netdisk_error.dart` 及对应测试，移除后端 OAuth 接口与浏览器/应用跳转授权实现。
- 安全边界：AppKey 不是机密，存 SharedPreferences（`baidu_netdisk_app_key_v1`）；access token 存既有凭据存储；应用内不包含 SecretKey。
- 限制：简化模式不返回 refresh token，access token 约 30 天过期，需要重新授权；百度个人应用默认限 10 个用户；2026-06-03 之后创建的应用，`download`、`filemanager`、`precreate`、`meta`、`move` 与 `multimedia.listall` 等接口仅能访问 `/apps/{appname}` 目录，可能影响浏览和下载任意目录文件；真机尚未验证百度登录、回调拦截与授权后目录浏览。

### 3.6 移除应用内升级检查

- 删除 `lib/models/app_update_info.dart`、`lib/providers/app_update_provider.dart`、`app_update_provider.g.dart`。
- 删除 `lib/services/app_update_checker.dart`、`lib/services/app_update_launcher.dart`、`lib/services/android_update_bridge.dart`。
- 删除 `lib/widgets/app_update_dialog.dart`。
- `lib/router/main_shell.dart` 删除启动与回到前台时的版本检查、更新结果监听与弹窗展示。
- `lib/screens/settings_screen.dart` 删除手动「检查更新」入口。
- `lib/services/app_update_migration.dart` 保留：它承担本地启动迁移，仍被 `lib/main.dart` 与本地备份服务使用，不属于升级检查入口。

## 4. 行为变化对照

| 能力 | 改造前 | 本 fork |
|---|---|---|
| 账号登录 | Supabase 邮箱 / Apple / Google 登录，多处功能要求登录 | 删除登录页与路由，登录门禁恒放行 |
| 订阅与权益 | RevenueCat / Paddle / 后端权益裁决，AI 额度 402 门禁 | 删除订阅入口与门禁，全部功能免费 |
| AI 翻译 / 解析 / 查词 / 意群 | 自建 `/api/v1/stream/*` NDJSON | BYOK 直连 `/chat/completions` |
| AI 学习助手 | 自建 NDJSON 聊天 + 登录/订阅/试用门禁 | BYOK 直连，保留聊天 UI 与历史会话控制器 |
| AI 口语 | 原版没有自由口语练习 | 新增 BYOK 直连；实时 ASR + LLM + TTS |
| 云端字幕转录 | 自建上传 / 提交转录任务 | 下线 AI 转录入口，保留本地离线转录 |
| 社区合集 | 自建 `/api/v2/collections` | 删除发现入口与详情同步 |
| 精选播客 | 自建 `/api/v1/featured-podcasts` | 删除精选列表，保留搜索与 RSS 导入 |
| 百度网盘 | 自建 OAuth 与文件接口 | 恢复导入入口；应用内简化模式 OAuth（用户自填 AppKey），文件列表/下载客户端直连百度 API，不经过自建后端 |
| 远程配置 / 埋点 / 地区探测 | 启动期依赖 Supabase / Firebase / RevenueCat 等 | 移除第三方启动链路，保留本地默认配置 |
| 本地备份 | `.elbak` 导出/恢复 | 保留，不提供云同步 |
| 应用内升级 | 启动/前台/设置页检查版本并弹窗 | 全部移除 |

## 5. 文件级变更

### 5.1 新增

- `docs/ai-speaking-implementation-plan.md`：AI 口语实现级计划。
- `docs/on-device-architecture-plan.md`：Android 纯端侧改造方案。
- `docs/fork-dev-log.md`：本文档。
- `lib/features/ai_speaking/`：AI 口语完整功能域（模型、凭据、Provider、服务、页面、组件）。
- `lib/features/baidu_netdisk/data/baidu_implicit_oauth.dart`：百度 OAuth 简化模式授权 URL、state 与回调解析。
- `lib/features/baidu_netdisk/data/baidu_app_key_store.dart`：用户自填 AppKey 的本地存取。
- `lib/features/baidu_netdisk/models/baidu_oauth_result.dart`：授权成功/失败/取消三态。
- `lib/features/baidu_netdisk/screens/baidu_oauth_webview_screen.dart`：应用内授权 WebView。
- `lib/services/byok_ai_service.dart`：统一 BYOK AI 服务。
- `test/features/ai_speaking/`：AI 口语模型、设置、会话控制器、页面与语音客户端测试。
- `test/services/byok_ai_service_test.dart`：BYOK 模型列表、请求头与排序测试。

### 5.2 修改

- 应用启动与路由：`lib/main.dart`、`lib/router/app_router.dart`、`lib/router/main_shell.dart`、`lib/providers/startup_bootstrap_provider.dart`、`lib/widgets/app_startup_gate.dart`、`lib/features/user_region/user_region_providers.dart`。
- 页面与入口：`lib/screens/settings_screen.dart`、`lib/screens/study_screen.dart`、`lib/screens/library_screen.dart`、`lib/screens/collection_detail_screen.dart`、`lib/screens/retell_player_screen.dart`。
- AI 能力：`lib/services/sentence_ai_api_client.dart`、`lib/providers/sentence_ai_provider.dart`、`lib/services/dictionary/ai_dictionary_source.dart`、`lib/features/chatbot/services/chat_api_client.dart`、`lib/features/chatbot/providers/chat_api_client_provider.dart`、`lib/features/chatbot/providers/chat_session_controller.dart`、`lib/providers/retell_review_evaluation_provider.dart`、`lib/widgets/practice/sentence_explanation_view.dart`。
- 入口收敛：`lib/features/podcast/screens/podcast_discovery_screen.dart`、`lib/widgets/import_audio_sheet.dart`、`lib/widgets/manage_subtitles_sheet.dart`。
- 账号与权益：`lib/features/auth/sign_in_required_dialog.dart`、`lib/features/auth/supabase_startup_gate.dart`、`lib/features/subscription/providers/feature_access_provider.dart`、`lib/features/subscription/widgets/feature_gate.dart`。
- 网络边界：`lib/services/backend_dio.dart`（更新接口用途注释，保留旧接口兼容）。
- 本地化：`lib/l10n/app_en.arb`、`lib/l10n/app_zh.arb`、`lib/l10n/app_localizations.dart`、`app_localizations_en.dart`、`app_localizations_zh.dart`。
- 百度网盘 OAuth：`lib/features/baidu_netdisk/data/baidu_credential_repository.dart`、`models/baidu_credential_bundle.dart`、`providers/baidu_netdisk_providers.dart`、`providers/baidu_netdisk_import_controller.dart`、`lib/widgets/import_audio_sheet.dart` 及本地化文件改为纯端侧简化模式。
- 依赖与忽略：`pubspec.yaml` 新增 `record: ^6.2.1`；`pubspec.lock` 更新；`.gitignore` 新增 `/Releases/`。
- 生成文件：`linux/flutter/generated_plugin_registrant.cc`、`linux/flutter/generated_plugin_registrant.h`、`linux/flutter/generated_plugins.cmake`、`macos/Flutter/GeneratedPluginRegistrant.swift`、`windows/flutter/generated_plugin_registrant.cc`、`windows/flutter/generated_plugin_registrant.h`、`windows/flutter/generated_plugins.cmake` 因新增 `record` 依赖注册插件；这些是合法的生成结果。
- 项目文档：`PLAN.md`、`TASKS.md`、`README.md`、`README.en.md`、`docs/troubleshooting.md`。

### 5.3 删除

- 登录/账号页面：`lib/features/auth/screens/account_screen.dart`、`check_email_screen.dart`、`email_sign_in_screen.dart`、`login_screen.dart`、`password_sign_in_screen.dart`。
- 应用升级：`lib/models/app_update_info.dart`、`lib/providers/app_update_provider.dart`、`lib/providers/app_update_provider.g.dart`、`lib/services/app_update_checker.dart`、`lib/services/app_update_launcher.dart`、`lib/services/android_update_bridge.dart`、`lib/widgets/app_update_dialog.dart`。
- 百度网盘后端 OAuth：`lib/features/baidu_netdisk/data/baidu_oauth_api.dart`、`lib/features/baidu_netdisk/services/baidu_oauth_launcher.dart`、`lib/features/baidu_netdisk/models/baidu_oauth_session.dart`、`lib/features/baidu_netdisk/models/baidu_oauth_session_status.dart`、`lib/features/baidu_netdisk/models/baidu_netdisk_error.dart`。
- 旧测试（完整列表）：
  - `test/features/auth/auth_flow_screens_test.dart`、`auth_providers_test.dart`、`google_services_availability_test.dart`、`password_sign_in_screen_test.dart`、`sign_in_required_dialog_test.dart`
  - `test/features/chatbot/services/chat_api_client_test.dart`
  - `test/features/subscription/paywall_screen_test.dart`、`subscription_availability_test.dart`
  - `test/main_user_region_lifecycle_test.dart`
  - `test/models/app_update_info_test.dart`
  - `test/providers/app_update_provider_test.dart`、`retell_review_evaluation_provider_test.dart`、`startup_bootstrap_provider_test.dart`
  - `test/screens/collection_detail_community_refresh_test.dart`
  - `test/services/app_update_checker_test.dart`、`app_update_launcher_test.dart`、`sentence_ai_api_client_test.dart`
  - `test/widgets/app_update_dialog_test.dart`、`sentence_explanation_view_auth_test.dart`
  - `test/features/baidu_netdisk/data/baidu_oauth_api_test.dart`、`test/features/baidu_netdisk/models/baidu_oauth_models_test.dart`、`test/features/baidu_netdisk/services/baidu_oauth_launcher_test.dart`
- 说明：删除的是自建后端/登录/付费/升级相关入口与用例，不删除本地学习、离线转录、播放器、词典、备份等主流程。

### 5.4 测试调整

- 新增 `test/features/ai_speaking/`：覆盖 AI 口语设置、凭据存储、会话控制器、页面、聊天客户端、ASR WebSocket 协议与 TTS 客户端。
- 新增 `test/services/byok_ai_service_test.dart`：覆盖 `/models` 请求、Bearer 头与模型排序。
- 修改 `test/helpers/mock_providers.dart`：清理登录、订阅、Supabase、应用升级等旧依赖。
- 修改 `test/screens/settings_screen_test.dart`、`test/screens/study_screen_test.dart`、`test/screens/learning_plan_screen_test.dart`、`test/screens/retell_player_screen_test.dart`、`test/widgets/import_audio_sheet_test.dart`、`test/widgets/manage_subtitles_sheet_test.dart`、`test/widgets/audio_list_tile_test.dart`、`test/widgets/app_startup_gate_test.dart`，移除已下线入口与登录门禁断言。
- 恢复 `test/widgets/import_audio_sheet_test.dart` 的网盘入口覆盖：断言“从网盘导入”可见、三个入口的纵向顺序，以及点击后进入网盘来源页。
- 新增 `test/features/baidu_netdisk/data/baidu_implicit_oauth_test.dart`（授权 URL、state、回调解析与错误分支）与 `baidu_app_key_store_test.dart`（读写与空值）；修改 `baidu_credential_repository_test.dart`、`baidu_credential_bundle_test.dart`、`baidu_netdisk_import_controller_test.dart` 与 `test/widgets/import_audio_sheet_test.dart` 适配简化模式。
- 修改 `test/features/chatbot/feature_access_ai_chat_test.dart`、`test/features/chatbot/providers/chat_session_controller_test.dart`、`test/features/chatbot/widgets/chat_view_test.dart`、`test/features/podcast/podcast_discovery_screen_test.dart`、`test/features/subscription/feature_access_provider_test.dart`、`test/features/user_region/user_region_override_test.dart`、`test/providers/sentence_ai_provider_test.dart`、`test/services/client_info_test.dart`、`test/services/dictionary/ai_dictionary_source_test.dart`，使测试与新 BYOK/纯端侧行为一致。

## 6. 文档更新

- `PLAN.md`：产品目标改为 Android-only、无账号/订阅/自建后台、BYOK；当前状态与里程碑移除订阅体系，新增纯端侧与 AI 口语状态。
- `TASKS.md`：新增 AI 口语、升级检查移除、纯端侧改造完成记录。
- `README.md` / `README.en.md`：平台徽章改为 Android；下载/试用、快速开始、开发命令、环境要求改为 Android + APK；FAQ 移除会员额度、百度网盘、云端 AI 描述；Roadmap 标记 AI 口语完成与纯端侧清理。
- `docs/troubleshooting.md`：新增 7.42 ASR 协议、7.43 测试输入时序、7.44 纯端侧旧测试清理、7.45 Gradle/APK 构建、7.46 `retell_recording_controller_test` 顺序敏感记录。
- `docs/ai-speaking-implementation-plan.md`：AI 口语实现级计划，记录决策、接口、状态机、文件清单与验收项。
- `docs/on-device-architecture-plan.md`：纯端侧能力对照、架构决策、兼容性与验证计划；补充百度网盘 OAuth 简化模式、AppKey 存储与目录限制风险。
- 2026-11-06 文档同步：`PLAN.md`、`TASKS.md`、`README.md`、`README.en.md`、`docs/fork-dev-log.md` 与 `docs/on-device-architecture-plan.md` 均改为“百度网盘 OAuth 走应用内简化模式、用户自填 AppKey、不再依赖自建后端”。

## 7. 数据、安全与兼容性

- 不修改本地数据库 schema；原素材、字幕、收藏、单词/意群、学习记录可继续读取。
- 旧 Supabase 会话、订阅状态不再读取，也不会主动删除用户设备上的旧数据。
- API Key 只存 `flutter_secure_storage`，不写入 SharedPreferences、日志、错误上报或备份文件。
- 百度网盘 AppKey 不是机密，存 SharedPreferences（`baidu_netdisk_app_key_v1`）；access token 存既有凭据存储；应用不内置 SecretKey，也不复用上游应用。
- AI 口语对话只保存在内存，退出页面即丢弃。
- 本地备份继续使用既有 `.elbak` 导出/恢复流程，不提供云同步。
- `pubspec.yaml` 中仍保留 Supabase、Firebase、RevenueCat 等依赖；本 fork 已在运行时移除其初始化路径。后续若要彻底减小包体，可单独清理这些死依赖与兼容层。
- `lib/features/auth/providers/`、`lib/services/transcription_api_client.dart`、`lib/features/user_preferences/` 等仍有旧接口/旧 Provider 代码，但当前无登录 token、无自建后端入口可达；后续可继续做死代码清理。

## 8. 验证结果

- `flutter analyze lib test`：**0 error**；215 条为仓库既有 warning/info。
- 2026-11-06 网盘入口修复：`dart format` 两个改动文件 0 changed；`flutter test test/widgets/import_audio_sheet_test.dart` 21 项全部通过；改动文件 `flutter analyze` 无问题；`git diff --check` 通过。
- 2026-11-06 纯端侧 OAuth：`flutter test test/features/baidu_netdisk test/widgets/import_audio_sheet_test.dart` 为 **110 passed**（同时修复 `baidu_netdisk_import_service_test.dart` 两项既有 Windows 路径分隔符断言，改用 `p.join`）；控制器测试单独 11 项全部通过；`flutter analyze lib test` 为 **0 error / 10 warning / 197 info**，本改动仅 8 条 `prefer_initializing_formals` info。
- 定向测试：**187 passed / 2 skipped**，覆盖 AI 口语、BYOK、设置页、学习页、句子详情、收藏复习与字幕相关流程。
- 全量 `flutter test`：**5671 passed / 11 skipped / 25 failed**；25 项均为改造前既有、与本 fork 功能无关的套件失败：
  `ios_release_script`、`audio_import`、`baidu_netdisk`、`community_download`、`media_engine`、`transcription_task`、`favorites_prewarm`、`log_viewer`、`media_playback`、`app_logger`、`backup_service`、`orphan_file_cleanup`、`tts_cache_store`。
- `test/providers/retell_recording_controller_test.dart` 存在既有的整文件顺序敏感问题：前 5 项通过后第 6 项卡住，单独运行该用例通过；该文件与控制器本轮未修改，已记录到 `docs/troubleshooting.md` 7.46。
- `dart format`：76 个变更 Dart 文件复检 0 changed；`git diff --check` 通过。

## 9. Android APK

- 产物：`android/app/release/app-dev-release.apk`（由 `build/app/outputs/flutter-apk/app-dev-release.apk` 复制）
- 大小：113,968,078 bytes
- SHA-256：`cbaeddccff000a488356e5553731de3dacc68856b7270e2d58c09467a030be81`（2026-11-11 合并上游 v1.0.46 后重新构建；上一版为 `b135a1fe08b13b4fbe7a2d1d61ec538bb936e662c4223a115205dbe02665962e`）
- 包名：`app.echoloop.dev`
- versionCode / versionName：`1` / `1.0`
- minSdk / targetSdk：`24` / `36`
- 签名：APK Signature Scheme v2 通过；1 个签名者
- 压缩完整性：ZIP 完整性校验通过（727 个条目）
- 构建命令：

```bash
cd /e/Echo-Loop
JAVA_HOME=F:/devtools/jdk/jdk-17 \
GRADLE_USER_HOME=F:/devtools/gradle-home \
GRADLE_OPTS='-Djava.net.preferIPv4Stack=true -Dhttps.protocols=TLSv1.2' \
/f/devtools/gradle/gradle-8.14.3/bin/gradle -p android :app:assembleDevRelease \
  --max-workers=2 --no-daemon -I /e/pin-runner.gradle
```

- 本机构建补充：`:integration_test` 依赖动态版本 `androidx.test:runner:1.2+`，当前网络无法读取 Maven 动态版本元数据；本次用临时 Gradle init script 将版本固定为本地缓存已有的 `1.3.0` 后构建成功。该脚本仅用于本机构建，未提交到仓库；正常网络环境可直接使用上述命令。
- 当前缺少 `android/key.properties`，因此只能构建 `dev` flavor 并使用 Android Debug 签名；正式发布需补充 release keystore 后构建 `prod`。
- `/Releases/` 与 `android/app/release/` 已被忽略，不进入 Git 提交。

## 10. 已知限制与后续

1. 仅支持 Android；其他平台未验证，入口在非 Android 平台隐藏或提示不支持。
2. 真机验收尚未完成：需要手动验证冷启动、本地音频导入、AI 口语麦克风/ASR/TTS、BYOK AI 讲解、聊天与本地备份恢复。
3. 原 Android 离线 ASR 在部分机型结束录音后触发 native 崩溃，与本 fork 改动无关，仍需单独定位。
4. BYOK 需要用户自行申请供应商 API Key；不同供应商对 `/models` 与 JSON 输出的支持程度不同，错误提示需要持续打磨。
5. 本地备份是唯一数据保全方式，换机前必须手动导出。
6. 依赖包与部分旧接口代码尚未彻底清理；当前以「运行时不初始化、入口不可达」为边界。
7. 全量测试仍有既有失败，详见第 8 节；这些失败不代表本 fork 新增功能回归。
8. 百度网盘 OAuth 简化模式不支持刷新令牌，access token 约 30 天过期，用户需重新授权；用户需自行在百度网盘开放平台创建应用并填写 AppKey，个人应用默认限 10 个用户；2026-06-03 之后创建的应用受 `/apps/{appname}` 目录限制，可能无法浏览或下载该目录之外的文件。真机尚未验证百度登录、回调拦截与授权后目录浏览。

## 11. 上游 v1.0.46 合并（2026-11-11）

- 分叉基线：`5df50638`（上游 v1.0.45 之后）；目标版本：`v1.0.46` = `cf26dc43`。
- 已合并 7 个提交：
  1. `0101fb09`：查词自动发音在本地 TTS 模型缺失时静默跳过，不再弹下载提示；`promptIfModelMissing` 沿统一朗读入口透传，词典面板自动发音传 `false`，用户主动点喇叭行为不变。
  2. `20f0b418`：单词发音改为「本地缓存 → CDN → TTS」，删除约 41MB 离线发音库与旧 `pronunciation_repository`；新增 `word_audio_identity` / `word_audio_repository`，升级迁移 v10 删除旧 `pronunciation` 目录。
  3. `c6ba1922`：单词音频仓库补充缓存命中与下载完成日志。
  4. `5a603c96`：意群生成或切换粒度时不再打断正在播放的整句。
  5. `a4e7fc9b`：精听讲解页重听时工具栏不再提前显示播放图标。
  6. `6cc7045e`：中国区模型 CDN 域名切换为 `static-cdn.echo-loop.cn`。
  7. `cf26dc43`：模型 CDN 命名统一为静态资源 CDN（`staticCdn`），与 `static-cdn` 域名一致。
- 未合并：
  - `0e013a98` 会员 VIP 角标：fork 已移除订阅模块。
  - `49854753` 在线词典：上游依赖自建后端 `/api/v1/dictionary/{dict}`，fork 保留本地 SQLite 离线词典。
  - `04de0cfd` 强制所有用户默认 TTS 切换 Edge：与 fork 端侧优先、默认 Kokoro 冲突。
  - Edge TTS 系列 `bbf916d3` / `cd7b9571` / `e0ffd6f1` / `b88297a5`：`flutter_edge_tts 0.0.3` 依赖 `audio_decode 1.3.5` 的原生资源钩子，在 Windows 构建机需要 MSVC C++ 工具链；关闭 native assets 又会让 `sqlite3` 无法运行。且 Edge 为在线 TTS，与端侧优先定位不符。
  - `a422827e`：仅上游 `TASKS.md` 文档更新。
- 适配：词典下载的 `modelCdnUri` 调用改为 `staticCdnUri`；`integration_test` 中旧 `TtsEngineKind.echoLoop` 改为 `kokoro`，复习集成测试改用 `createTestAudioItem()`。未新增依赖，默认 TTS 仍为 Kokoro。
- 验证：`flutter analyze` 0 error（211 条既有 warning/info）；定向测试 102 + 226 项通过；全量 `flutter test` 为 5715 passed / 11 skipped / 23 failed，其中 `favorites_prewarm` 2 项与 `tts_cache_store` 1 项已在 `main` 基线复现，其余为既有 Windows/环境相关失败。
- 构建：`gradle -p android :app:assembleDevRelease` 成功，产物 `build/app/outputs/flutter-apk/app-dev-release.apk`（113,968,078 bytes，SHA-256 `cbaeddccff000a488356e5553731de3dacc68856b7270e2d58c09467a030be81`），APK Signature Scheme v2 通过，727 个条目 ZIP 完整性通过；已复制到 `android/app/release/app-dev-release.apk`。
