# AI 口语自由练习 — 实现级详细计划

> 版本：v1（2026-11-05）
> 目标仓库：Echo Loop Flutter App（工作目录 E:/Echo-Loop，version 1.0.46）
> 状态：已确认并实施完成（2026-11-05，仅 Android）。
>
> 本文档按仓库既有 implementation-plan 规范编写，目标是可以直接按任务拆解落地。若确认，后续实现以本文档为唯一需求/接口基线；实现过程中发现与仓库事实冲突，先更新本文档再改代码。

---

## 1. Context（为什么做）

Echo Loop 已经具备精听、跟读、盲听、复述、复习闭环，以及 AI 翻译/解析/词典等一问一答式能力；README Roadmap 中「AI 口语陪练」仍未实现。现有 AI 请求全部经过 Echo Loop 自建后端（Supabase Bearer token + 配额），客户端没有任何第三方模型 API Key，也没有可配置的模型供应商。

本次新增一个独立的 AI 口语自由练习功能：

- 用户点击麦克风说英语，实时显示识别字幕；
- 识别结束后，大模型用英语回复，并自动用 TTS 朗读；
- 支持在设置中自由选择大模型供应商、模型、温度；
- 语音识别默认使用阿里云百炼 qwen-audio-3.1-asr-flash-streaming；
- 语音合成默认使用阿里云百炼 qwen-audio-3.1-tts-plus；
- 大模型原生支持 DeepSeek，同时支持阿里云百炼、OpenAI 与自定义 OpenAI 兼容接口。

### 1.1 范围定义（v1）

做：

- 半双工自由对话：点按开始说话 → 实时字幕 → 点按结束 → AI 回复 → 自动朗读。
- 文字兜底输入（键盘输入同样可发送）。
- 大模型供应商 / Base URL / 模型 / 温度设置。
- 阿里云 ASR / TTS 的 API Key、Workspace ID、TTS 模型与音色设置。
- API Key 本地安全存储。
- 学习页入口、设置页入口、独立全屏页。
- 关键错误提示、重试、重新开始对话。

不做（v1 明确边界）：

- 不做全双工 / 自动打断 / VAD 自动轮次。
- 不做发音评分、语法评分报告、口语考试。
- 不做对话历史持久化、跨设备同步。
- 不做后端代理、平台代付、配额计费。
- 仅支持 Android；其他平台（Web / Linux / iOS / macOS / Windows）隐藏入口或显示不支持提示。
- 不改造现有 chatbot、TTS、离线 ASR 的任何行为。

---

## 2. 已拍板决策

1. 客户端 BYOK 直连：不新增后端。原因：仓库没有后端代码；现有后端 AI 链路只接受 Echo Loop 自己的 token 与配额；用户要求自由设置第三方供应商，客户端直连是唯一在仓库范围内可交付的方案。
2. 独立功能域：新增 lib/features/ai_speaking/，不改现有 lib/features/chatbot/、lib/services/tts/、lib/services/asr/ 的职责边界。
3. LLM 使用 OpenAI 兼容协议：DeepSeek、阿里云百炼兼容模式、OpenAI、自定义接口统一走 POST /chat/completions + SSE 流式解析；不为每个供应商写一套客户端。
4. 语音服务固定走阿里云百炼 DashScope：ASR/TTS 共用一条 DashScope API Key；Workspace ID 可选（为空时使用 dashscope.aliyuncs.com 旧域名）。
5. 首版半双工：录音时暂停 TTS/回复；TTS 播放时不可录音。比全双工更可靠，也避免回声被麦克风录进去。
6. 对话历史仅内存：页面销毁/新建对话即清空；不做数据库迁移。
7. 支持平台：仅 Android。其他平台（Web / Linux / iOS / macOS / Windows）隐藏入口或显示不支持提示。
8. 安全：API Key 只存 flutter_secure_storage，不写 SharedPreferences、不写日志、不进入错误上报。
9. 默认值：
   - LLM：DeepSeek / https://api.deepseek.com/v1 / deepseek-chat / temperature 0.7。
   - ASR：qwen-audio-3.1-asr-flash-streaming。
   - TTS：qwen-audio-3.1-tts-plus / longanlingxin_v3.1 / rate 1.0。
   - 自动朗读：开启。

---

## 3. 复用的现有基建（已核对路径）

| 用途 | 现有文件 / 符号 |
|---|---|
| 设计 token | lib/theme/app_theme.dart → AppSpacing（.xs/.s/.m/.l/.xl = 4/8/16/24/32）、AppTextStyles；颜色使用 Theme.of(context).colorScheme |
| 麦克风权限（Android） | lib/services/speech_permission_service.dart → speechPermissionServiceProvider、SpeechPermissionService.request({required bool onlyMic})、openAppSettings() |
| 短音频播放 | lib/services/pronunciation/local_audio_clip_player.dart → LocalAudioClipPlayer.playFile(path, {playbackKey})；共享 provider lib/providers/short_audio_player_provider.dart → shortAudioPlayerProvider |
| 临时目录 | path_provider → getTemporaryDirectory() |
| 安全存储范式 | lib/features/baidu_netdisk/data/baidu_credential_store.dart → FlutterSecureStorage + 单 JSON key + 明确错误枚举 |
| 设置 Provider 范式 | lib/providers/tts/tts_settings_provider.dart → initialTtsSettingsProvider + TtsSettings.fromPrefsSync + NotifierProvider + _persist |
| 设置页交互范式 | lib/screens/settings_screen.dart 的 _buildStudySection（TTS ListTile 401-418 行）→ Card + ListTile + Navigator.push(MaterialPageRoute) |
| 路由范式 | lib/router/app_router.dart → AppRoutes 常量 66 行起；顶级全屏 GoRoute 546 行起，parentNavigatorKey: rootNavigatorKey |
| 学习页插入点 | lib/screens/study_screen.dart 主列表 210-283 行、全部完成态 _buildAllDoneContent 289-312 行；均以 StudyStatsHeader 为锚点 |
| 本地化 | lib/l10n/app_en.arb（模板）、lib/l10n/app_zh.arb；l10n.yaml 输出 AppLocalizations |
| 日志 | lib/services/app_logger.dart → AppLogger.log(tag, message)；密钥必须脱敏 |
| 测试脚手架 | test/helpers/test_app.dart、test/helpers/mock_providers.dart；mocktail |

说明：现有 lib/services/tts/tts_engine.dart 是为「本地/平台 TTS + 文件缓存」设计的，不适合云 TTS 的 HTTP 请求与签名 URL 下载；本次不强行塞进 TtsEngine，而是在 AI 口语功能域内新增 AiTtsClient，仅复用播放器与缓存思路。

---

## 4. 产品交互

### 4.1 入口

1. 学习 Tab（StudyScreen）：
   - 在主列表 StudyStatsHeader 之后插入 AiSpeakingEntryCard；
   - 在全部完成态 _buildAllDoneContent 的 StudyStatsHeader 之后同样插入；
   - 卡片文案：AI 口语练习 / 和 AI 自由聊英语，实时转写 + 语音回复。
2. 设置页：
   - 学习分组中、TTS 设置之后新增「AI 口语练习」ListTile；
   - trailing 显示当前供应商 + 模型摘要，例如 DeepSeek · deepseek-chat；未配置时显示「未配置」。
3. 路由：
   - AppRoutes.aiSpeaking = '/ai-speaking'；
   - 顶级 GoRoute + parentNavigatorKey: rootNavigatorKey，全屏进入。

### 4.2 页面状态

AiSpeakingScreen 由 AiSpeakingSessionController 驱动，状态机：

~~~text
idle
  → 点击麦克风
  → listening（录音 + 实时字幕）
  → 点击结束
  → finalizing（等待 ASR 最终结果）
  → thinking（LLM 流式回复）
  → speaking（TTS 合成 + 播放）
  → idle

任意阶段失败 → error（展示错误 + 重试 / 去设置）
用户取消录音 → idle（不产生消息）
用户点击重新开始 → 清空当前对话
~~~

### 4.3 页面结构

- AppBar：标题「AI 口语练习」；actions：新建对话、设置。
- 空态欢迎区：
  - 图标 + 标题 + 一句说明；
  - 3 个 starter chips（Talk about my day / Practice a job interview / Plan a weekend trip）；点击后作为用户文本消息发送；
  - 隐私提示：API Key 仅保存在本机；语音与文本会直接发送给所选供应商。
- 消息列表：
  - 用户消息右对齐，显示识别最终文本；
  - AI 消息左对齐，流式显示；完成后显示朗读按钮（重播）；
  - 流式中显示光标/思考中；错误消息内联显示重试。
- 底部输入区：
  - 文字输入框 + 发送按钮（文字兜底）；
  - 麦克风主按钮：idle 时显示「点击说话」；listening 时显示计时 + 完成 + 取消；
  - thinking 时可停止生成；speaking 时可停止朗读。
- 页面销毁或路由退出：停止录音、ASR、TTS；保留当前会话文本（controller keepAlive），下次进入仍可看到，直到新建对话。

### 4.4 设置页结构

AiSpeakingSettingsScreen：

1. 大模型
   - 供应商：DeepSeek / 阿里云百炼 / OpenAI / 自定义（OpenAI 兼容）
   - Base URL：预设只读；自定义可编辑，必须 http/https
   - API Key：密码框 + 显示/隐藏 + 保存；每个供应商独立保存
   - 模型：预设常用模型可点选，也允许手动输入
   - 温度：0.0–2.0，步长 0.1，默认 0.7，展示当前值
2. 语音服务（阿里云百炼）
   - DashScope API Key：密码框 + 保存
   - Workspace ID：可选，提示「留空则使用 dashscope.aliyuncs.com」
   - ASR 模型：只读展示 qwen-audio-3.1-asr-flash-streaming
   - TTS 模型：qwen-audio-3.1-tts-plus（默认）/ qwen-audio-3.1-tts-flash
   - 音色：按模型联动；plus 默认 longanlingxin_v3.1；flash 提供英文音色
   - 语速：0.5–2.0，默认 1.0
   - 自动朗读：开关，默认开
   - 试听：用当前音色合成一句示例并播放
3. 隐私与费用说明
   - API Key 只保存在本机安全存储；
   - 请求直接发往所选供应商，费用由供应商账户结算；
   - Echo Loop 不代管、不转售、不记录 API Key。

注：qwen-audio-3.1-tts-plus 的旗舰音色以中文为主；如果用户希望更自然的英文音色，可在设置中切换 qwen-audio-3.1-tts-flash + Bella / Emily 等英文音色。该说明写入设置页帮助文案。

---

## 5. 数据模型与设置

### 5.1 供应商枚举与预设

lib/features/ai_speaking/models/ai_llm_provider.dart

~~~dart
enum AiLlmProvider { deepSeek, aliyunBailian, openAi, custom }

class AiLlmPreset {
  const AiLlmPreset({
    required this.provider,
    required this.baseUrl,
    required this.defaultModel,
    required this.models,
  });

  final AiLlmProvider provider;
  final String baseUrl;
  final String defaultModel;
  final List<String> models;
}
~~~

预设：

| provider | Base URL | 默认模型 | 常用模型 |
|---|---|---|---|
| deepSeek | https://api.deepseek.com/v1 | deepseek-chat | deepseek-chat、deepseek-reasoner |
| aliyunBailian | https://dashscope.aliyuncs.com/compatible-mode/v1 | qwen-plus | qwen-plus、qwen-max、qwen-turbo、qwen3-max |
| openAi | https://api.openai.com/v1 | gpt-4o-mini | gpt-4o-mini、gpt-4.1-mini、gpt-4o |
| custom | 空 | 空 | 用户输入 |

### 5.2 设置值对象

lib/features/ai_speaking/models/ai_speaking_settings.dart

~~~dart
class AiLlmConfig {
  const AiLlmConfig({
    required this.provider,
    required this.baseUrl,
    required this.model,
    required this.temperature,
  });

  final AiLlmProvider provider;
  final String baseUrl;
  final String model;
  final double temperature;

  factory AiLlmConfig.defaultsFor(AiLlmProvider provider);
  AiLlmConfig copyWith({AiLlmProvider? provider, String? baseUrl, String? model, double? temperature});
}

class AiSpeechConfig {
  const AiSpeechConfig({
    required this.asrModel,
    required this.ttsModel,
    required this.ttsVoice,
    required this.ttsRate,
    required this.autoPlay,
    required this.workspaceId,
  });

  final String asrModel;
  final String ttsModel;
  final String ttsVoice;
  final double ttsRate;
  final bool autoPlay;
  final String workspaceId;

  AiSpeechConfig copyWith({String? ttsModel, String? ttsVoice, double? ttsRate, bool? autoPlay, String? workspaceId});
}

class AiSpeakingSettings {
  const AiSpeakingSettings({required this.llm, required this.speech});
  final AiLlmConfig llm;
  final AiSpeechConfig speech;

  static const defaults = AiSpeakingSettings(
    llm: AiLlmConfig(
      provider: AiLlmProvider.deepSeek,
      baseUrl: 'https://api.deepseek.com/v1',
      model: 'deepseek-chat',
      temperature: 0.7,
    ),
    speech: AiSpeechConfig(
      asrModel: 'qwen-audio-3.1-asr-flash-streaming',
      ttsModel: 'qwen-audio-3.1-tts-plus',
      ttsVoice: 'longanlingxin_v3.1',
      ttsRate: 1.0,
      autoPlay: true,
      workspaceId: '',
    ),
  );

  factory AiSpeakingSettings.fromPrefsSync(SharedPreferences prefs);
  AiSpeakingSettings copyWith({AiLlmConfig? llm, AiSpeechConfig? speech});
}
~~~

SharedPreferences keys（抽象类 AiSpeakingSettingsKeys）：

~~~text
ai_speaking_llm_provider
ai_speaking_llm_base_url
ai_speaking_llm_model
ai_speaking_llm_temperature
ai_speaking_tts_model
ai_speaking_tts_voice
ai_speaking_tts_rate
ai_speaking_tts_auto_play
ai_speaking_workspace_id
~~~

ASR 模型常量放 AiSpeechConfig.asrModel，默认固定 qwen-audio-3.1-asr-flash-streaming；v1 不在 UI 修改。

### 5.3 凭据存储

lib/features/ai_speaking/data/ai_speaking_credential_store.dart

~~~dart
enum AiSpeakingCredentialErrorKind {
  unavailable,
  readFailed,
  writeFailed,
  deleteFailed,
  parseFailed,
}

class AiSpeakingCredentialStoreException implements Exception {
  const AiSpeakingCredentialStoreException(this.kind, this.message, [this.cause]);
  final AiSpeakingCredentialErrorKind kind;
  final String message;
  final Object? cause;
}

class AiSpeakingSecretStatus {
  const AiSpeakingSecretStatus({
    required this.hasLlmApiKey,
    required this.hasDashscopeApiKey,
  });
  final bool hasLlmApiKey;
  final bool hasDashscopeApiKey;
}

class AiSpeakingCredentialStore {
  Future<String?> readLlmApiKey(AiLlmProvider provider);
  Future<void> writeLlmApiKey(AiLlmProvider provider, String apiKey);
  Future<void> deleteLlmApiKey(AiLlmProvider provider);

  Future<String?> readDashscopeApiKey();
  Future<void> writeDashscopeApiKey(String apiKey);
  Future<void> deleteDashscopeApiKey();

  Future<AiSpeakingSecretStatus> readStatus(AiLlmProvider provider);
}
~~~

存储实现：

- FlutterSecureStorage 单 key：ai_speaking_credentials_v1；
- 值为 JSON：{"llm":{"deepSeek":"...","aliyunBailian":"..."},"dashscope":"..."}；
- 捕获 MissingPluginException / PlatformException，Linux/Web 视为 unavailable；
- 日志绝不输出 key，仅输出 provider 与成功/失败状态。

### 5.4 设置 Provider

lib/features/ai_speaking/providers/ai_speaking_settings_provider.dart

~~~dart
final initialAiSpeakingSettingsProvider = Provider<AiSpeakingSettings>(
  (ref) => AiSpeakingSettings.defaults,
);

class AiSpeakingSettingsNotifier extends Notifier<AiSpeakingSettings> {
  @override
  AiSpeakingSettings build() => ref.read(initialAiSpeakingSettingsProvider);

  Future<void> setProvider(AiLlmProvider provider);
  Future<void> setBaseUrl(String baseUrl);
  Future<void> setModel(String model);
  Future<void> setTemperature(double value);
  Future<void> setTtsModel(String model);
  Future<void> setTtsVoice(String voice);
  Future<void> setTtsRate(double value);
  Future<void> setAutoPlay(bool value);
  Future<void> setWorkspaceId(String workspaceId);
}

final aiSpeakingSettingsProvider =
    NotifierProvider<AiSpeakingSettingsNotifier, AiSpeakingSettings>(
  AiSpeakingSettingsNotifier.new,
);

final aiSpeakingCredentialStoreProvider = Provider<AiSpeakingCredentialStore>(
  (ref) => const AiSpeakingCredentialStore(),
);

final aiSpeakingSecretStatusProvider =
    FutureProvider<AiSpeakingSecretStatus>((ref) async {
  final settings = ref.watch(aiSpeakingSettingsProvider);
  return ref.read(aiSpeakingCredentialStoreProvider).readStatus(settings.llm.provider);
});
~~~

main.dart 需要新增：

- 在 runApp 前已有的 prefs 上构造 initialAiSpeakingSettings = AiSpeakingSettings.fromPrefsSync(prefs)；
- ProviderScope overrides 增加 initialAiSpeakingSettingsProvider.overrideWithValue(initialAiSpeakingSettings)。

设置保存策略：

- 非敏感设置：setter 更新 state + SharedPreferences.getInstance().setString/setDouble/setBool；
- API Key：设置页显式调用 credential store，写成功后 ref.invalidate(aiSpeakingSecretStatusProvider)；
- provider 切换：若旧 provider 的 baseUrl/model 仍等于旧预设默认值，则自动切换为新预设默认值；若用户手动改过，保留自定义值并只切换 provider。

---

## 6. 服务层契约

### 6.1 LLM 客户端

lib/features/ai_speaking/services/ai_chat_client.dart

~~~dart
enum AiChatErrorKind {
  unauthorized,
  rateLimited,
  badRequest,
  network,
  server,
  invalidResponse,
  cancelled,
}

class AiChatException implements Exception {
  const AiChatException(this.kind, this.message, {this.statusCode});
  final AiChatErrorKind kind;
  final String message;
  final int? statusCode;
}

abstract interface class AiChatClient {
  Stream<String> streamReply({
    required AiLlmConfig config,
    required String apiKey,
    required List<AiSpeakingMessage> history,
    CancelToken? cancelToken,
  });
}

class HttpOpenAiCompatibleChatClient implements AiChatClient {
  HttpOpenAiCompatibleChatClient({Dio? dio});
}
~~~

请求：

~~~http
POST {baseUrl}/chat/completions
Authorization: Bearer {apiKey}
Content-Type: application/json

{
  "model": "{model}",
  "messages": [
    {"role": "system", "content": "{systemPrompt}"},
    {"role": "user", "content": "..."},
    {"role": "assistant", "content": "..."}
  ],
  "temperature": 0.7,
  "stream": true
}
~~~

- Base URL 统一去掉末尾 /，再拼 /chat/completions。
- 历史只取最近 20 条 user/assistant 消息；system prompt 单独拼在最前，不进入持久化。
- 响应 SSE：逐行解析 data: {...}；提取 choices[0].delta.content；收到 data: [DONE] 正常结束；HTTP 非 2xx 先读小 JSON 错误体再映射；流结束但未收到 [DONE] 视为 invalidResponse（不能伪装成功）。
- 401/403 → unauthorized；429 → rateLimited；400 → badRequest；5xx → server；Dio 网络异常 → network；CancelToken 取消 → cancelled。
- 超时：connect 15s，receive 60s。

System prompt（lib/features/ai_speaking/services/ai_speaking_prompts.dart）：

~~~text
You are a friendly English speaking partner for a Chinese learner.
Rules:
- Reply in natural, conversational English only.
- Keep each reply to 2-4 short sentences.
- Always end with one simple follow-up question to keep the conversation going.
- If the learner makes a clear grammar or word-choice mistake, gently recast the correct sentence once, then continue.
- Do not use markdown, bullet points, emojis, or stage directions; your reply will be read aloud.
- Adjust your vocabulary to the learner's level; if they seem stuck, use simpler words.
~~~

### 6.2 阿里云实时 ASR

lib/features/ai_speaking/services/aliyun_realtime_asr_client.dart

~~~dart
class AsrTranscriptEvent {
  const AsrTranscriptEvent({required this.text, required this.isFinal});
  final String text;
  final bool isFinal;
}

abstract interface class RealtimeAsrSession {
  Stream<AsrTranscriptEvent> get events;
  Future<void> appendPcm(Uint8List pcm);
  Future<String> finish();
  Future<void> cancel();
}

abstract interface class RealtimeAsrClient {
  Future<RealtimeAsrSession> start({
    required AiSpeechConfig config,
    required String apiKey,
  });
}

class AliyunRealtimeAsrClient implements RealtimeAsrClient {
  AliyunRealtimeAsrClient({WebSocketConnector? connector});
}
~~~

端点：

- workspaceId 非空：wss://{workspaceId}.cn-beijing.maas.aliyuncs.com/api-ws/v1/inference
- workspaceId 为空：wss://dashscope.aliyuncs.com/api-ws/v1/inference

连接头：

~~~text
Authorization: Bearer {dashscopeApiKey}
X-DashScope-WorkSpace: {workspaceId}   // 仅 workspaceId 非空时
~~~

run-task 消息：

~~~json
{
  "header": {
    "action": "run-task",
    "task_id": "<uuid>",
    "streaming": "duplex"
  },
  "payload": {
    "task_group": "audio",
    "task": "asr",
    "function": "recognition",
    "model": "qwen-audio-3.1-asr-flash-streaming",
    "parameters": {
      "format": "pcm",
      "sample_rate": 16000,
      "language_hints": ["en"],
      "max_sentence_silence": 800,
      "vad_model": "near_meeting_16k"
    },
    "input": {}
  }
}
~~~

流程：

1. IOWebSocketChannel.connect（带 headers），连接超时 15s；
2. 发送 run-task；
3. 等待 task-started（超时 15s；task-failed 直接抛 AliyunAsrException）；
4. 返回 RealtimeAsrSession，controller 启动录音并逐块 appendPcm；
5. 服务端 result-generated：解析 payload.output.sentence.text、sentence_end；发 AsrTranscriptEvent；sentence_end 时追加 final 文本；
6. 用户结束时：先停止录音，再调用 finish() 发送 finish-task；
7. 等待 task-finished（超时 10s），返回 final buffer；没有 final 文本则使用最后 partial；
8. 关闭 WebSocket。

错误：

- task-failed 的 header.error_code / error_message 映射为 AliyunAsrException；
- 连接失败/超时 → 说明「无法连接阿里云语音服务，请检查 API Key、Workspace ID 与网络」；
- 服务端无响应 → 8–10s 超时，允许重试。

注入点：AliyunRealtimeAsrClient 内部使用一个可替换的 WebSocketConnector typedef，便于单测模拟；生产实现使用 IOWebSocketChannel.connect。

### 6.3 阿里云 TTS

lib/features/ai_speaking/services/aliyun_tts_client.dart

~~~dart
enum AiTtsErrorKind {
  unauthorized,
  badRequest,
  network,
  server,
  invalidResponse,
  cancelled,
}

class AiTtsException implements Exception {
  const AiTtsException(this.kind, this.message, {this.statusCode});
  final AiTtsErrorKind kind;
  final String message;
  final int? statusCode;
}

abstract interface class AiTtsClient {
  Future<String> synthesizeToFile({
    required String text,
    required AiSpeechConfig config,
    required String apiKey,
    CancelToken? cancelToken,
  });
}

class AliyunTtsClient implements AiTtsClient {
  AliyunTtsClient({Dio? dio, Future<Directory> Function()? tempDirProvider});
}
~~~

端点：

- workspaceId 非空：https://{workspaceId}.cn-beijing.maas.aliyuncs.com/api/v1/services/audio/tts/SpeechSynthesizer
- workspaceId 为空：https://dashscope.aliyuncs.com/api/v1/services/audio/tts/SpeechSynthesizer

请求体：

~~~json
{
  "model": "qwen-audio-3.1-tts-plus",
  "input": {
    "text": "Hello! How was your day?",
    "voice": "longanlingxin_v3.1",
    "format": "mp3",
    "sample_rate": 24000,
    "volume": 50,
    "rate": 1.0,
    "pitch": 1.0,
    "language_hints": ["en"],
    "instruction": "Speak in natural, clear American English for an English learner."
  }
}
~~~

流程：

1. POST JSON；validateStatus 允许手动处理非 2xx；
2. 解析 output.audio.url（非流式返回）；
3. 用 Dio GET 下载字节；
4. 计算 sha256(text + model + voice + rate + instruction) 作为缓存文件名；
5. 写入 getTemporaryDirectory()/ai_speaking_tts/{hash}.mp3；
6. 若文件已存在且大小 > 0，直接复用；
7. 返回本地路径，由 controller 用 shortAudioPlayerProvider 播放。

错误：

- 401/403 → unauthorized（API Key 无效）；
- 400 → badRequest（模型/音色不匹配、参数错误）；
- 无 output.audio.url → invalidResponse；
- 下载失败 / 超时 → network。
- 文本长度保护：超过 1000 字符截断或直接报错（AI 回复限制在 2–4 句，正常不会触发；实现取 1000 字符上限保护）。

### 6.4 PCM 录音

lib/features/ai_speaking/services/pcm_recorder.dart

~~~dart
abstract interface class PcmRecorder {
  Future<bool> hasPermission();
  Future<Stream<Uint8List>> start({
    int sampleRate = 16000,
    int numChannels = 1,
  });
  Future<void> stop();
  Future<void> dispose();
}

class RecordPcmRecorder implements PcmRecorder {
  RecordPcmRecorder({AudioRecorder? recorder});
}
~~~

实现：

- 使用 package:record 的 AudioRecorder；
- RecordConfig(encoder: AudioEncoder.pcm16bits, sampleRate: 16000, numChannels: 1, autoGain: true, echoCancel: true, noiseSuppress: true)；
- startStream 返回 Stream<Uint8List>；
- stop() 后 stream 关闭；
- dispose() 只释放 recorder，不重复 stop。

### 6.5 麦克风权限

lib/features/ai_speaking/services/ai_speaking_permission_service.dart

~~~dart
abstract interface class AiSpeakingPermissionService {
  bool get isSupported;
  Future<bool> ensurePermission();
  Future<void> openSettings();
}

class PlatformAiSpeakingPermissionService implements AiSpeakingPermissionService {
  const PlatformAiSpeakingPermissionService();
}
~~~

行为：

- Android：调用 speechPermissionServiceProvider.request(onlyMic: true)，检查 microphone == granted；失败时 openAppSettings()。
- 其他平台：isSupported=false，不展示入口（含 Web / Linux / iOS / macOS / Windows）。

### 6.6 会话模型与状态

lib/features/ai_speaking/models/ai_speaking_message.dart

~~~dart
enum AiSpeakingRole { user, assistant }

enum AiSpeakingMessageStatus { streaming, done, error }

class AiSpeakingMessage {
  const AiSpeakingMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.status,
    required this.createdAt,
    this.audioPath,
  });

  final String id;
  final AiSpeakingRole role;
  final String content;
  final AiSpeakingMessageStatus status;
  final DateTime createdAt;
  final String? audioPath;

  AiSpeakingMessage copyWith({String? content, AiSpeakingMessageStatus? status, String? audioPath});
}
~~~

lib/features/ai_speaking/models/ai_speaking_session_state.dart

~~~dart
enum AiSpeakingPhase { idle, listening, finalizing, thinking, speaking, error }

enum AiSpeakingErrorKind {
  missingConfig,
  permissionDenied,
  asrFailed,
  llmFailed,
  ttsFailed,
  unsupportedPlatform,
}

class AiSpeakingSessionState {
  const AiSpeakingSessionState({
    this.messages = const [],
    this.phase = AiSpeakingPhase.idle,
    this.partialTranscript = '',
    this.errorMessage,
    this.errorKind,
  });

  final List<AiSpeakingMessage> messages;
  final AiSpeakingPhase phase;
  final String partialTranscript;
  final String? errorMessage;
  final AiSpeakingErrorKind? errorKind;

  AiSpeakingSessionState copyWith({
    List<AiSpeakingMessage>? messages,
    AiSpeakingPhase? phase,
    String? partialTranscript,
    String? errorMessage,
    AiSpeakingErrorKind? errorKind,
    bool clearError = false,
  });
}
~~~

### 6.7 会话控制器

lib/features/ai_speaking/providers/ai_speaking_session_controller.dart

~~~dart
@Riverpod(keepAlive: true)
class AiSpeakingSessionController extends _$AiSpeakingSessionController {
  @override
  AiSpeakingSessionState build() => const AiSpeakingSessionState();

  Future<void> startListening();
  Future<void> stopListening();
  Future<void> cancelListening();
  Future<void> sendText(String text);
  Future<void> retryLastTurn();
  Future<void> stopSpeaking();
  Future<void> newConversation();
  Future<void> stopActiveAudio();
}
~~~

关键流程：

startListening：

1. 检查当前 LLM provider 与 DashScope 的 Key 是否存在；缺失 → error + errorKind.missingConfig。
2. 权限服务 ensurePermission()；拒绝 → error + errorKind.permissionDenied，提供 openSettings。
3. 读取设置与 Key；打开 RealtimeAsrSession（await task-started）。
4. 订阅 asrSession.events：partial → state.partialTranscript；final → 暂存最终文本。
5. 启动 RecordPcmRecorder.startStream；逐块 appendPcm。
6. phase = listening。
7. 任一步失败：关闭 recorder / asr，phase=error，保留可重试状态。

stopListening：

1. phase = finalizing；停止录音（await recorder.stop()）。
2. await asrSession.finish() 取 finalText（超时/失败 → error）。
3. finalText.trim() 为空 → phase=idle + 提示「没有识别到语音，请再说一次」；不产生消息。
4. 追加 user message；清空 partialTranscript；调用 _requestAssistantReply()。

_requestAssistantReply：

1. 读取设置和 LLM Key。
2. phase=thinking；插入 assistant streaming 占位消息（id 用 uuid）。
3. 监听 chatClient.streamReply(history: 最近 20 条 + 当前 user 文本)。
4. 每个 delta 追加到占位消息；用 _turnId 丢弃旧流回调。
5. 完成：status=done；若 autoPlay 开启且文本非空 → phase=speaking；调用 ttsClient.synthesizeToFile → shortAudioPlayerProvider.playFile(path, playbackKey: 'ai-speaking-tts')；播放完成 phase=idle。
6. LLM/TTS 失败：assistant 消息 status=error（保留已生成文本），phase=error，展示重试。
7. 用户 stopSpeaking / stopAssistant：CancelToken.cancel + player.stop，phase=idle，保留已生成文本。

sendText：跳过 ASR，直接追加 user 消息 → _requestAssistantReply。

retryLastTurn：删除最后一条 assistant 消息（若 error），用最后一条 user 文本重新请求；无 user 文本则忽略。

newConversation：取消所有进行中的录音/ASR/LLM/TTS，清空 messages 与状态。

并发与生命周期：

- _turnId 或 _generation 递增，所有异步回调先检查 token；
- 页面离开屏幕只 stopActiveAudio，不清消息；
- provider keepAlive:true，避免设置页覆盖时 autoDispose 丢失对话；
- ref.onDispose 释放 recorder、asr、tts、player 引用。

---

## 7. 目录结构与文件清单

新增：

~~~text
lib/features/ai_speaking/
  models/
    ai_llm_provider.dart
    ai_speaking_settings.dart
    ai_speaking_message.dart
    ai_speaking_session_state.dart
  data/
    ai_speaking_credential_store.dart
  services/
    ai_chat_client.dart
    ai_speaking_prompts.dart
    aliyun_realtime_asr_client.dart
    aliyun_tts_client.dart
    pcm_recorder.dart
    ai_speaking_permission_service.dart
  providers/
    ai_speaking_settings_provider.dart
    ai_speaking_session_controller.dart
  screens/
    ai_speaking_screen.dart
    ai_speaking_settings_screen.dart
  widgets/
    ai_speaking_entry_card.dart
    ai_speaking_message_bubble.dart
    ai_speaking_composer.dart
    ai_speaking_welcome.dart
~~~

修改：

- pubspec.yaml：新增 record: ^6.2.1、web_socket_channel: ^3.0.3。
- lib/main.dart：构造 initialAiSpeakingSettings 并 override。
- lib/router/app_router.dart：AppRoutes.aiSpeaking + GoRoute。
- lib/screens/study_screen.dart：两处插入 AiSpeakingEntryCard。
- lib/screens/settings_screen.dart：学习分组 TTS 后新增 ListTile。
- lib/l10n/app_en.arb、lib/l10n/app_zh.arb：新增文案。
- docs/ai-speaking-implementation-plan.md：本文档。
- PLAN.md / TASKS.md：完成时更新。
- README.md：Roadmap 的 AI 口语陪练可选勾选（完成时）。

每文件行数目标：≤ 500 行；单函数 ≤ 50 行；中文文档注释；禁止 dynamic / as / ! 滥用。

---

## 8. l10n 文案键（新增）

建议至少包含：

~~~text
aiSpeakingTitle
aiSpeakingEntryTitle
aiSpeakingEntrySubtitle
aiSpeakingWelcomeTitle
aiSpeakingWelcomeBody
aiSpeakingPrivacyNotice
aiSpeakingStarterDaily
aiSpeakingStarterInterview
aiSpeakingStarterWeekend
aiSpeakingTapToSpeak
aiSpeakingListening
aiSpeakingTapToFinish
aiSpeakingCancel
aiSpeakingFinalizing
aiSpeakingThinking
aiSpeakingSpeaking
aiSpeakingInputHint
aiSpeakingSend
aiSpeakingStop
aiSpeakingRetry
aiSpeakingReplay
aiSpeakingNewConversation
aiSpeakingSettingsTitle
aiSpeakingLlmSection
aiSpeakingProviderLabel
aiSpeakingBaseUrlLabel
aiSpeakingApiKeyLabel
aiSpeakingModelLabel
aiSpeakingTemperatureLabel
aiSpeakingSpeechSection
aiSpeakingDashscopeKeyLabel
aiSpeakingWorkspaceIdLabel
aiSpeakingAsrModelLabel
aiSpeakingTtsModelLabel
aiSpeakingVoiceLabel
aiSpeakingRateLabel
aiSpeakingAutoPlayLabel
aiSpeakingPreview
aiSpeakingPrivacyTitle
aiSpeakingPrivacyBody
aiSpeakingUnsupportedPlatform
aiSpeakingPermissionDenied
aiSpeakingOpenSettings
aiSpeakingMissingConfig
aiSpeakingNoSpeech
aiSpeakingErrorUnauthorized
aiSpeakingErrorRateLimited
aiSpeakingErrorNetwork
aiSpeakingErrorServer
~~~

中英文都要有；英文是模板。

---

## 9. 任务拆解

### T0 基线核对（本文档）

- 读取 AGENTS.md、PLAN.md、TASKS.md、关键现有文件；
- 确认无同名功能目录；
- 产出本文档。
- 验收：文档评审通过；不改业务代码。

### T1 依赖、模型、凭据与设置 Provider

文件：pubspec.yaml、lib/features/ai_speaking/models/*、data/ai_speaking_credential_store.dart、providers/ai_speaking_settings_provider.dart、lib/main.dart。

内容：

- 新增 record / web_socket_channel；
- 实现 AiLlmProvider / AiLlmPreset / AiLlmConfig / AiSpeechConfig / AiSpeakingSettings / keys / fromPrefsSync / copyWith / ==；
- 实现凭据存储与错误枚举；
- 实现设置 Notifier 与 initial override；
- 单元测试：默认值、fromPrefsSync、provider 切换默认值、凭据读写（fake FlutterSecureStorage）、密钥不出现在 toString/日志。

验收：dart format、flutter analyze 无 error；相关单测通过。

### T2 LLM 客户端

文件：services/ai_chat_client.dart、services/ai_speaking_prompts.dart；测试 test/features/ai_speaking/services/ai_chat_client_test.dart。

内容：

- OpenAI 兼容请求 + SSE 解析；
- 错误映射、取消、未收到 [DONE] 的断流处理；
- 历史裁剪 20 条、system prompt 拼接；
- 用 mock Dio 响应流测试分片跨行、空 delta、错误 JSON、取消。

验收：单测覆盖正常流、断流、401、429、取消；analyze 无 error。

### T3 阿里云实时 ASR + 录音 + 权限

文件：services/aliyun_realtime_asr_client.dart、pcm_recorder.dart、ai_speaking_permission_service.dart；测试 aliyun_asr_event_parser_test.dart、ai_speaking_permission_service_test.dart。

内容：

- ASR 事件解析独立纯函数：task-started / result-generated（partial、final）/ task-failed / task-finished；
- WebSocket 会话生命周期、run-task/finish-task、超时、错误映射；
- record 封装；
- 权限服务：Android 复用现有 speechPermissionService；其他平台 unsupported；
- 单测用 FakeRealtimeAsrClient / FakePcmRecorder 验证 controller 前置逻辑（可在 T5 完成）。

验收：解析器测试覆盖 partial→final、task-failed、空 sentence；analyze 无 error；真机录音在 T7 手动验收。

### T4 阿里云 TTS + 缓存

文件：services/aliyun_tts_client.dart；测试 aliyun_tts_client_test.dart。

内容：

- 端点选择（workspace vs dashscope）；
- 请求体构造、voice/model 校验；
- output.audio.url 提取、下载、sha256 缓存、重复文本复用；
- 错误映射；
- 试听按钮复用。

验收：单测覆盖请求体、无 URL、下载失败、缓存命中；analyze 无 error。

### T5 会话控制器

文件：providers/ai_speaking_session_controller.dart、models/ai_speaking_message.dart、models/ai_speaking_session_state.dart；测试 ai_speaking_session_controller_test.dart。

内容：

- 状态机与所有方法；
- Fake AiChatClient / RealtimeAsrClient / AiTtsClient / PcmRecorder；
- 测试：start→partial→stop→user+assistant、空识别、权限拒绝、缺 Key、LLM 错误、TTS 错误、取消、重试、newConversation、旧回调丢弃。

验收：状态转换测试全部通过；无未捕获异常。

### T6 UI 与集成

文件：screens/ai_speaking_screen.dart、screens/ai_speaking_settings_screen.dart、widgets/*、router、study screen、settings screen、l10n。

内容：

- 欢迎态 / 消息列表 / 输入区 / 设置页；
- 入口卡片两处；
- 路由；
- 设置页 Key 保存、试听、供应商/模型/温度；
- 空态、加载态、错误态、无权限态、不支持平台态；
- 响应式布局、SafeArea、键盘遮挡处理；
- 组件测试：空态、消息渲染、麦克风按钮状态、权限错误、设置页字段联动。

验收：widget 测试通过；手动视觉检查 Android（可用设备）。

### T7 端到端验收与文档

内容：

- 用真实 DeepSeek + 阿里云 Key 走通：设置 → 录音 → 实时字幕 → LLM 流式 → TTS 播放；
- 切换供应商 / 模型 / 温度；
- 断网、错误 Key、错误模型、空语音；
- flutter analyze lib test、flutter test（全量或相关 + 说明）、flutter gen-l10n、build_runner；
- 更新 TASKS.md、PLAN.md、README.md；
- 记录 troubleshooting 踩坑（如 WebSocket/权限/模型兼容问题）。

验收：见第 10 节。

---

## 10. 测试与验收

### 10.1 自动化

- 单元测试：
  - 设置模型序列化/反序列化；
  - 凭据存储（mock FlutterSecureStorage）；
  - SSE 解析；
  - ASR 事件解析；
  - TTS 请求/缓存；
  - 会话状态机。
- Widget 测试：
  - AI 口语空态渲染；
  - 录音中状态与取消；
  - 消息气泡流式/错误/重播；
  - 设置页供应商切换、温度滑杆、Key 保存；
  - 不支持的平台展示提示。
- 命令：
  - flutter pub get
  - dart format [changed files]
  - flutter gen-l10n
  - dart run build_runner build --delete-conflicting-outputs
  - flutter analyze lib test
  - flutter test test/features/ai_speaking
  - flutter test（最终，记录通过数量；若环境限制则说明）

### 10.2 手动验收

1. 首次进入：学习页卡片可见，点击进入；未配置 Key 时显示引导。
2. 设置 DeepSeek Key + 阿里云 Key，保存后重启 App，设置仍在。
3. 点击麦克风，授权；说一句英语，页面实时出现部分字幕；点击结束，出现用户消息。
4. AI 回复流式显示，完成后自动朗读；朗读可停止、可重播。
5. 文字输入可发送并收到回复。
6. 切换 DeepSeek → 阿里云百炼 qwen-plus → 自定义 OpenAI 兼容接口，分别验证请求成功（用各自 Key）。
7. 温度 0.1 与 1.5 都能保存并用于请求（可通过日志/服务端参数确认）。
8. 错误 Key → 显示 API Key 无效；错误模型 → 显示模型不可用；断网 → 网络错误且可重试。
9. 拒绝麦克风权限 → 显示去设置；从设置返回后可重试。
10. 录音中点取消 → 不产生用户消息；新建对话清空消息。
11. 离开页面再回来，当前对话仍在；App 重启后对话清空（符合 v1）。
12. 非 Android 平台不展示入口（或显示不支持提示）。

### 10.3 完成定义

- 所有新增/修改文件通过 dart format；
- flutter analyze 无新增 error/warning；
- 相关测试全部通过，全量 flutter test 通过或明确说明未跑原因；
- 手动验收 1–12 在至少一个目标平台通过；
- API Key 不出现在日志、SharedPreferences、异常文案中；
- TASKS.md 记录完成时间；PLAN.md 如里程碑变化同步更新。

---

## 11. 风险与边界

1. 阿里云账号前置条件：需要在百炼控制台开通 qwen-audio-3.1-asr-flash-streaming / qwen-audio-3.1-tts-plus，并创建 API Key；模型未开通时会返回 403/InvalidParameter，本功能只能给出明确错误提示，不能代替用户开通。
2. TTS 英文音色：qwen-audio-3.1-tts-plus 的旗舰音色以中文为主，英文自然度可能不如 tts-flash 的英文音色；设置页提供切换说明。默认仍按用户要求使用 plus。
3. WebSocket 网络环境：部分企业代理/防火墙可能阻断 wss；v1 不实现代理配置，错误提示引导检查网络。
4. record 插件原生构建：新增原生依赖，需要重新构建；仅 Android 需验证，其他平台不支持。
5. API Key 客户端存储：FlutterSecureStorage 只能降低泄露面，无法防御已 root/jailbreak 设备；设置页明确告知 BYOK 风险与费用。
6. 延迟：v1 等 LLM 全文完成后再 TTS，首字延迟可能 1–3 秒；后续可做逐句 TTS 流式优化，不在本次范围。
7. 上下文长度：历史只取最近 20 条，长对话会丢失早期上下文；v1 可接受。
8. 无后端配额：费用直接由用户供应商账户承担；Echo Loop 不做额度校验。
9. Android 权限：需要在运行时申请麦克风权限；拒绝后引导用户到系统设置开启。
10. 回滚：功能独立；如需回滚，删除 lib/features/ai_speaking/、移除入口/路由/依赖/l10n 即可，不影响现有功能。

---

## 12. 已确认事项

1. 已确认客户端 BYOK 直连（不新增后端）。原因：仓库没有后端代码，且用户要求自由设置供应商。
2. 已确认平台范围为仅 Android；其他平台隐藏入口或显示不支持提示。
3. 已确认大模型供应商按 DeepSeek / 阿里云百炼 / OpenAI / 自定义 OpenAI 兼容四类。
4. 已确认 v1 对话只保留内存（不做历史持久化 / 云同步）。
5. 已确认 TTS 默认 qwen-audio-3.1-tts-plus + longanlingxin_v3.1，同时允许切换到 tts-flash 英文音色。

以上事项已确认，按 T1 → T7 实施；若后续需要调整，先改本文档再开工。
