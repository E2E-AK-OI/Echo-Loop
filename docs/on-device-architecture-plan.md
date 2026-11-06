# Echo Loop 纯端侧改造方案（Android）

> 状态：已实施并通过全量静态分析；功能相关测试通过；APK 已构建并校验（`android/app/release/app-dev-release.apk`），待 Android 真机验收。2026-11-06 按用户要求恢复百度网盘导入入口，OAuth 仍依赖原后端
> 日期：2026-11-05（2026-11-06 更新）
> 关联需求：用户 m01930（移除登录限制、AI 口语模型刷新）、m01948（改造成纯端侧项目）、m01980（同意推荐方案并开始实施）

## 1. 背景与目标

Echo Loop 原版依赖自建后端提供账号登录、订阅权益、AI 讲解、云端转录、社区合集、精选播客与百度网盘导入。本 fork 的目标是交付一个**端侧优先、学习数据只存设备**的 Android 版本；除百度网盘 OAuth 桥接外不依赖自建后台：

- 不要求注册、登录或订阅，不设任何额度与付费门禁。
- 主学习闭环、收藏复习、本地转录、本地备份全部在本机完成。
- AI 能力保留，但改为 BYOK：用户自填 OpenAI 兼容供应商的 API Key，设备直连供应商。
- 社区合集与精选播客等依赖自建服务的入口下线；保留本地文件、音频直链、百度网盘导入与用户自行添加的播客源。百度网盘导入的 OAuth 仍由原项目后端桥接，文件列表与下载由客户端直连百度 API。
- 当前发布平台仅 Android。

“端侧优先”不等于完全离线：AI 讲解、AI 口语和在线播客仍需要网络，但请求不经过本项目自建服务器；百度网盘 OAuth 是唯一例外。

## 2. 能力对照

| 能力 | 改造前 | 改造后 |
|---|---|---|
| 账号与登录 | Supabase 邮箱 / Apple / Google 登录，多处功能要求登录 | 删除登录页与路由，登录门禁恒放行 |
| 订阅与权益 | RevenueCat / Paddle / 后端权益裁决，AI 额度 402 门禁 | 删除订阅入口与门禁，全部功能免费 |
| AI 翻译 / 解析 / 查词 / 意群 | 自建 /api/v1/stream/* NDJSON | BYOK 直连 /chat/completions，本地拼装结果 |
| AI 学习助手 | 自建 NDJSON 聊天 + 登录/订阅/试用门禁 | BYOK 直连，保留聊天 UI 与历史会话控制器 |
| AI 口语 | 已是 BYOK 直连 | 保留，并新增模型刷新 + 下拉选择 |
| 云端字幕转录 | 自建上传 / 提交转录任务 | 下线 AI 转录入口，保留本地离线转录 |
| 社区合集 | 自建 /api/v2/collections | 删除发现入口与详情跳转 |
| 精选播客 | 自建 /api/v1/featured-podcasts | 删除精选列表，保留用户自行添加播客源 |
| 百度网盘 | 自建 OAuth 与文件接口 | 恢复导入入口；账号入口仍隐藏，OAuth 依赖原后端，文件列表/下载客户端直连百度 API |
| 远程配置 / 埋点 / 地区探测 | 启动期依赖 Supabase / Firebase / RevenueCat 等 | 移除第三方启动链路，保留本地默认配置 |
| 本地备份 | 已有 .elbak 导出/恢复 | 保留，不提供云同步 |

## 3. 关键架构决策

### 3.1 BYOK 单入口

新增 lib/services/byok_ai_service.dart，统一读取 AI 口语设置中的供应商、Base URL、模型、温度与安全存储中的 API Key，提供：

- listModels()：GET /models，兼容 data 与 models 两种返回结构。
- completeText()：POST /chat/completions，非流式。
- completeJson()：从模型输出中截取 JSON 对象并解析，供句子解析等结构化场景使用。
- streamText()：POST /chat/completions + SSE，供翻译与聊天增量输出。

错误统一收敛为 ByokAiException：missingConfig / unauthorized / rateLimited / badRequest / network / server / invalidResponse / cancelled。

### 3.2 保留旧接口形状，缩小上层改动

SentenceAiApiClient 与 ChatApi 的公开方法签名尽量保持不变，只替换内部实现：

- lib/services/sentence_ai_api_client.dart：翻译、解析、查词、意群改为 BYOK；复述评估暂不支持。
- lib/features/chatbot/services/chat_api_client.dart：streamChat 改为 BYOK 流式输出。
- lib/features/chatbot/providers/chat_session_controller.dart：删除登录、订阅与试用门禁。

这样句子讲解页、AI 词典源、聊天页不需要理解供应商细节。

### 3.3 账号与权益从边界处拆除

- 删除 lib/features/auth/screens/ 下 5 个登录/账号页面。
- ensureSignedInForAction 与 featureAccess 恒返回 true，避免遗留调用点在 UI 层弹登录框。
- 删除 lib/router/app_router.dart 中的登录、账号与 paywall 路由及重定向。
- 设置页删除账号与订阅分组。

### 3.4 启动链路本地化

lib/main.dart、lib/providers/startup_bootstrap_provider.dart、lib/widgets/app_startup_gate.dart 与 lib/router/main_shell.dart 不再初始化 Supabase、RevenueCat、Paddle、Firebase 或地区端点探测；启动只等待 localStartupProvider。AI 口语设置仍在首帧前预读，保证进入页面时配置就绪。

### 3.5 AI 口语模型选择

lib/features/ai_speaking/screens/ai_speaking_settings_screen.dart 的模型区域增加刷新按钮与下拉选择：

- 刷新调用 byokAiServiceProvider.listModels()。
- 列表按名称排序；失败时保留当前模型并提示错误，不写坏设置。
- 仍允许手动输入自定义模型名（自定义供应商场景）。

## 4. 数据与兼容性

- 不修改本地数据库 schema；原有素材、收藏、学习记录保持可读。
- 旧订阅状态、Supabase 会话等数据不再读取，但不会主动删除用户设备文件。
- API Key 继续仅存 flutter_secure_storage，不写入 SharedPreferences、日志或备份。
- 对话内容只保存在内存中，退出页面即丢弃；学习数据仍通过既有本地备份导出/恢复。

## 5. 验证计划

1. flutter analyze lib test：0 error；仅保留仓库既有 warning/info。
2. 定向测试：AI 口语、BYOK AI 服务、句子 AI provider、聊天、设置页、导入弹窗。
3. 全量 flutter test：记录通过与失败清单，失败需确认均为既有无关套件。
4. 构建 Android APK，校验包名、版本、签名、压缩完整性。
5. 真机手动验收：冷启动、导入本地音频、AI 口语录音/识别/朗读、BYOK AI 讲解、本地备份恢复。

## 6. 风险与后续

- BYOK 依赖用户自行申请 Key，且不同供应商对 /models 与 JSON 输出支持程度不同，需要错误提示清晰。
- 本地备份是唯一数据保全方式，换机前必须手动导出。
- 原 Android 离线 ASR 闪退与本次改造无关，仍需单独定位。
- 百度网盘 OAuth 依赖原项目后端 `https://www.echo-loop.top`，后端不可用或接口变更时无法新增授权；已授权账号的文件列表与下载仍直连百度 API。
- 下线入口的旧文案与旧测试可能继续出现，需在后续回归中清理。
