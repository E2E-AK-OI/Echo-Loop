# AI 口语练习四档升级 — 实现级计划（v2）

> 版本：v2（2026-11-13）
> 目标仓库：Echo Loop Flutter App（工作目录 E:/Echo-Loop）
> 状态：代码与单元测试已完成，待 Android 真机验收
> 上游 v1 规格：[ai-speaking-implementation-plan.md](./ai-speaking-implementation-plan.md)（半双工按键说话，v1 明确不做 VAD/打断）

---

## 1. 背景与目标

v1 只有一种交互：按住说话、松开提交，AI 回复时不能插话。这适合零基础用户，但对中高级练习者不够真实。本次把口语练习按交互难度拆成四档，逐档放宽限制、提高对延迟的要求，同时保持"用户自选本地/云端模型、BYOK 客户端直连"的既有架构。

四档共享同一套会话页（`lib/features/ai_speaking/screens/ai_speaking_screen.dart`）、同一套消息模型与同一套 BYOK 凭据存储；差异集中在"录音怎么开、轮次怎么切、AI 说话时能不能打断、用哪些模型"。

## 2. 四档定义

| 档位 | 交互 | 轮次判停 | 模型 | 延迟要求 |
| --- | --- | --- | --- | --- |
| 初级（现有） | 按键说话、按键提交；AI 说话不可插话 | 用户手动结束 | ASR/TTS 本地或云端均可 | 不敏感 |
| 中级 | 点话筒开始会话、再点停止；用户与 AI 自由对话，不可插话 | 本地 VAD：尾静音 EOS + 长时间静默退出 | ASR/TTS 本地或云端均可 | 不敏感 |
| 高级 | 同中级，但用户可随时开口打断 AI（barge-in） | 本地 VAD 判停，不做语义判停 | 必须云端实时 ASR + 云端 TTS | 敏感 |
| 特级 | 点话筒开始/结束；端到端语音模型，用户可插话 | 服务端自带判停（语义判停 `smart_turn_v2` 或静音判停 `server_vad`） | 仅 `qwen-audio-3.1-realtime-flash`（可选 plus） | 最敏感 |

档位能力集中在 `AiSpeakingLevel`（`lib/features/ai_speaking/models/ai_speaking_level.dart`）：`usesPushToTalk`、`usesVoiceActivityDetection`、`allowsBargeIn`、`requiresRealtimeAsr`、`requiresCloudTts`、`usesSpeechToSpeech`、`allowsLocalEngines`、`usesContinuousSession`。档位选择持久化在 SharedPreferences（`ai_speaking_level`），未识别的历史值回退初级。

## 3. 各档链路

### 3.1 初级（保持 v1 行为）

`startListening` → 录音 + 实时 ASR（或本地识别）→ `stopListening` → `_sendUserTurn` → LLM → TTS。行为未改动，仅把公共的"平台/设置/凭据/权限"校验抽成 `_prepareVoiceStart()`。

### 3.2 中级（VAD 免提会话）

`startSession()`：

1. `_prepareVoiceStart()` 校验平台、设置、DashScope Key（仅在用到云端 ASR/TTS 时要求）、本地识别模型与麦克风权限。
2. 用 `SpeakingDialogSettings` 构造 `VadTurnDetector(endOfSpeech, idleTimeout)`。
3. 云端 ASR：`pcmRecorderProvider.start()` **只启动一次**，PCM 流持续送 `_onSessionPcm`；VAD 只决定何时 `asrSession.finish()`，避免"先等 VAD 确认再开 ASR"丢掉起始音。
4. 本地 ASR：`RecordingService` 逐轮录音，VAD 用其 `audioLevel` 事件驱动（`_feedLocalSessionVad`）。

轮次切分：开始听音/恢复听音时立即 `_ensureCloudAsr()` 建连并持续 `appendPcm`，服务端从开口前就收到连续音频；`speechStarted` 只标记轮次开始（本地逐轮录音/整段上传模型在此开始收集），不再承担建连；`speechEnded` → `finish()` 取最终转写 → 走 LLM/TTS；AI 朗读期间 `_vad.mute()`，外放回声不会触发新一轮（因此中级天然不允许插话）；朗读结束 `_resumeSessionListening()` 重新建连并开听。

### 3.3 高级（插话打断）

在中级基础上：

- `_allowsBargeIn = true`，AI 朗读期间 VAD 不再 mute，而是 `raiseThreshold(bargeInThreshold)` 抬高门限抑制外放回声。
- `speechStarted` 且 `phase == speaking` → `_bargeIn()`：取消 TTS 播放（`_ttsCancelToken` + `_stopTtsPlayback()`）、丢弃旧回复、立即转入新一轮识别。
- 要求云端实时 ASR（`qwen-audio-3.1-asr-flash-streaming`）；若「口语引擎」里把语音识别切成本地，直接提示"高级档位需要云端实时语音识别"。
- TTS 使用 WebSocket 流式 PCM（Android 走 `PcmStreamPlayer` 边收边播）；文本按句送入同一个 TTS task（多条 `continue-task`），首句不必等大模型全文生成；正常结束调用 `finish()` 等 AudioTrack 排空后再收尾，打断/停止仍立即 `stop()`，并同时取消仍在生成的大模型回复；非 Android 平台回退为逐句合成到文件再播放，打断响应取决于播放器停止延迟。

### 3.4 特级（语音到语音）

`QwenAudioRealtimeClient`（`services/qwen_audio_realtime_client.dart`）直连阿里云 Realtime WebSocket：

- URL：`wss://{workspace}.cn-beijing.maas.aliyuncs.com/api-ws/v1/realtime?model=<model>`，未填 Workspace 时回退 `wss://dashscope.aliyuncs.com/...`；`Authorization: Bearer <DashScope Key>` 走握手头。
- 首帧发 `session.update`（`modalities: ['text','audio']`、`voice`、`input_audio_format/output_audio_format: 'pcm'`、`instructions`、`turn_detection`），等待 `session.created/updated` 后进入会话。
- 麦克风 16kHz PCM 以 `input_audio_buffer.append` 持续上行；下行 `response.audio.delta` 是 24kHz/16bit 单声道裸 PCM，交给 `PcmStreamPlayer` 边收边播。
- 用户开口时服务端自动取消当前回复（`response.done.status = cancelled`）；客户端收到 `input_audio_buffer.speech_started` 立即 `flush()` 清空排队音频，并按 `response_id` 丢弃旧回复的迟到分片。
- 空闲退出：`_s2sIdleTimer` 每秒检查，非 speaking/thinking 且超过「长时间不说话退出」阈值即 `stopSession()`。

流式播放：仓库原有的 just_audio / media_kit 只能播放完整文件，因此新增原生 `AudioTrack` 实现（`android/app/src/main/kotlin/app/echoloop/PcmStreamPlayerHandler.kt` + `services/pcm_stream_player.dart`，MethodChannel `top.echo-loop/pcm_stream_player`，方法 `start/write/flush/finish/stop`）。写线程按 20ms 小块推进并记录已写入帧数；`flush` 靠 generation 丢弃旧代数据并在同一 AudioTrack 上重启写线程。正常结束调用 `finish`：排空线程先等队列空、join 写线程，再轮询 `playbackHeadPosition` 追上帧数，留 100ms 尾音后释放；`start/flush/stop` 会取消排空并递增 generation，避免旧操作回写。

### 3.5 分句流式 TTS（所有档位）

大模型回复本来就是 SSE 流式，但旧链路要等全文结束才启动 TTS，首句延迟被绑到整段生成时间。现在改为边生成边朗读：

1. `SpeechSentenceSplitter` 从增量的 `delta.content` 里切句：中英文句末标点即切，英文缩写、小数、连续省略号不误切；首句在逗号/分号处且英文至少 12 词或中文至少 24 字时提前切，让第一句尽快进入合成；超长文本按 220 字符兜底。
2. 云端：`AliyunTtsStreamClient.synthesizeChunks` 先建连并发送第一条 `continue-task`，之后随文本流继续发送，文本流结束才发 `finish-task`；音频 PCM 与文本发送并行，Android 端边收边写 `PcmStreamPlayer`。
3. 本地：`_speakLocalSentences` 用队列逐句 `speak`，每收到一句就 `prewarm` 预合成；当前句播放时后续句已在后台合成，避免整段渲染的停顿。
4. 三档默认 `qwen-audio-3.1-tts-flash` + `Emily_v3.1`（低延迟），plus 保留为高音质选项；设置页在 TTS 模型下拉里给当前档位的推荐模型加「推荐」标签。
5. 停止/插话时取消 `_ttsCancelToken`、停止 PCM 播放器，并取消仍在生成的大模型回复、结算未完成的 streaming 消息，避免「声音停了但回复还在后台生成」。

## 4. 设置项（按档位隔离）

「设置 › 口语引擎」页面顶部与练习页一致，使用初级/中级/高级/特级四个标签；切换标签只改变本页正在编辑的档位，不改变当前练习档位。每档位独立保存一份 `SpeakingLevelConfig`（`models/speaking_level_config.dart`）：识别来源、合成来源、TTS 模型/音色/语速/自动播放、实时模型/音色/判停方式、尾静音 EOS、空闲退出与插话灵敏度。

存储键为既有键名追加 `_<level>`（如 `ai_speaking_tts_model_advanced`、`speaking_dialog_end_of_speech_ms_expert`）。读取顺序：档位键 → 旧全局键 → 默认值，老用户升级不丢配置；写入只写当前档位键。控制器通过 `_levelConfigFor(level)` 读取当前练习档位，并用 `_speechConfigFor(level)` 合并账号级的 Workspace。

- 全局项（所有档位共享）：「AI 设置」中的大模型供应商/模型/温度、DashScope Key 与工作空间。口语引擎页顶部只读展示当前大模型，并可跳转「AI 设置」。
- 非特级档：语音识别来源（AI/本地）与语音合成来源（AI/本地）；AI 识别时显示模型（qwen-audio-3.1-asr-flash-streaming、qwen-audio-3.0-asr-flash-streaming、qwen-audio-3.1-asr-flash 非实时整段上传），AI 合成时显示模型（plus/flash，默认推荐 flash）、音色、语速、自动播放。高级档选择本地识别时提示需要云端实时 ASR。
- 特级档：隐藏 ASR/TTS 来源，改为实时语音卡片（`qwen-audio-3.1-realtime-flash`（默认）/ `-plus`、`longanqian_v3.1` 等音色、判停 `smart_turn_v2`（推荐）/ `server_vad` 800ms）；切换模型时自动回退到合法音色。
- 会话参数：尾静音 EOS 400–2000ms（默认 800、硬兜底 2000）、空闲退出 10–60s（默认 30）、插话灵敏度（低/中/高 → 朗读期间 VAD 门限 0.06/0.045/0.03 RMS）。初级不显示会话卡片，中级/高级显示 EOS，高级/特级显示插断灵敏度。

## 5. 关键实现细节

- `VadTurnDetector`（`services/vad_turn_detector.dart`）：纯 Dart、可注入时间戳。能量门限 = max(基础门限, 底噪 × 3)；底噪在静音态按 0.98/0.02 指数平滑；`minSpeech = 180ms` 防抖；尾静音 ≥ EOS 触发 `speechEnded`；静默 ≥ idleTimeout 触发 `idleTimeout`；`hardLimit`（默认 2000ms）按本轮峰值 × 0.7 判断持续有声是否仍像人声，低于强门限满 2s 强制断句；`mute()/unmute()/raiseThreshold()/reset()` 支持 AI 朗读期间的门控。
- 断句兜底：本地识别同时消费原生 `silenceProgress`（`AdaptiveVadThreshold` 比 Flutter 0.02 更灵敏），原生静音达到当前档位 EOS 即收尾；云端识别收到 `sentence_end`（`isFinal`）即收尾；`idleTimeout` 与 `speechEnded` 只在 listening 阶段生效，ASR `finish()`/`waitForTranscript` 慢时优先用已显示的 partial 继续，只有完全无文本才报错。
- 回声消除：录音侧 `RecordConfig(echoCancel: true, noiseSuppress: true, autoGain: true)`；中级在 AI 朗读期间断开 ASR 并 mute VAD，停止/播完后先等播放器真正停止，再留 300ms 静默窗口才恢复听音与 ASR；高级档朗读前查询 `AudioTrack.routedDevice`，内置扬声器外放时关闭语音插话并保持 VAD 静音，仅耳机/外接设备启用 VAD 插话；特级由服务端判停 + 本地 flush。
- 预录缓冲（preroll）：会话开始/恢复听音时立即建 ASR 并连续送流，开口前的 PCM 也进入服务端；建连握手期间 `_isAsrStarting` 为 true，预录上限放宽到 5s（160000 字节），建连成功后按时间顺序 `_flushPreroll()` 补发并清空，仅作为握手兜底。
- 非实时 ASR：`qwen-audio-3.1-asr-flash` 走 `AliyunFileAsrClient` 整段上传 WAV（44 字节 RIFF 头 + PCM base64 data URI，SSE 接收累积文本），按键说话在停止后上传，免提会话在 VAD `speechEnded` 后上传。
- 本地伪流式：`SenseVoice Small`（`sense-voice-small-int8`）录音期间由 `LocalAsrStreamingTranscriber` 每 1.2s 复制当前 WAV、回填 RIFF/data 长度后离线解码并更新 partialTranscript；停止录音后仍以完整 WAV 的最终识别为准。
- 状态：`AiSpeakingSessionState.isSessionActive` 表示免提会话进行中，UI 据此在"点话筒开始/结束对话"与"按住说话"之间切换。
- 错误与清理：`_setError` 先 `_abortSessionOnError()`；`newConversation` / `stopActiveAudio` / `stopSession` 统一走 `_clearSessionFields()`，避免录音、ASR、实时连接与播放器泄漏。

## 6. 测试与验收

- `test/features/ai_speaking`：175 项通过（含档位能力位、对话设置读写与钳制、VAD 切分/门限/空闲/硬上限、实时客户端协议映射与 response_id 过滤、中级会话、高级插话、特级一轮对话/插话丢弃迟到分片/缺 Key/平台不支持；2026-11-13 追加流式 ASR 增量/整句/跨句拼装、档位识别模型回退、消息顺序回归、高级档建连握手不丢开头词、preparing 阶段、非实时整段上传两条路径、TTS 流式播放与正常结束排空、云端句末收尾与 fallback、原生静音断句、本地预览文本回退；2026-11-14 追加分句器边界、首句未等大模型结束即合成、多段 `continue-task`、本地逐句队列与预热、停止首句时取消生成、中级朗读期间阻断回声并留停止静默窗口、VoiceBargeInGuard 候选/duck/确认/回声恢复/超时、EchoTextFilter 子串与英文词匹配、高级档外放 AEC 不可用时降级手动停止、AEC 可用时 duck 后确认插话）；`test/services/asr` 直链安装/SenseVoice、`test/screens/settings_screen_test.dart` 与 `test/screens/asr_settings_screen_test.dart` 合计 250 项通过。
- `flutter analyze lib/features/ai_speaking lib/l10n lib/main.dart lib/screens/settings_screen.dart test/features/ai_speaking`：0 error（仅 2 条既有 `prefer_initializing_formals` info）；`test/screens/settings_screen_test.dart` 24 项通过（独立语音识别/合成入口已删除，改为断言合并进口语引擎）。
- 未覆盖：Android 真机上的回声消除效果（含平台 AEC 在外放下的实际效果、duck 音量与 250ms 判别手感）、EOS 调参手感、特级下行音质与打断延迟、高级档连续送流的开头识别、分句 TTS 的首包延迟与长回复尾音、真实服务端对多条 `continue-task` 的韵律连续性、不同品牌设备的扬声器/耳机/蓝牙播放路由识别与 300ms 尾音窗口，以及 SenseVoice 伪流式滚动转写；iOS 无流式播放实现（`PcmStreamPlayer.isSupported` 仅 Android）。
- 1.03.8+57 构建：从 `/e/Echo-Loop/android` 执行 `GRADLE_USER_HOME=/f/devtools/gradle-home ./gradlew assembleDevRelease --offline --no-daemon --init-script ../build/pin-runner.gradle -Ptarget-platform=android-arm64`，3m 59s 构建成功；产物 `android/app/release/app-dev-release-1.03.8.apk`（114,295,918 bytes，SHA-256 `6f08f59009aaa0fdfda7671ec08a88bcfaa1e62e6ef90344a7af78d349444762`，versionCode 57 / versionName 1.03.8，727 条目 ZIP 校验通过，原生库仅 arm64-v8a，targetSdk 36）。该版本实现高级档外放语音插话：外放时切 `MODE_IN_COMMUNICATION` + 扬声器与 `USAGE_VOICE_COMMUNICATION`，平台 AEC 可用时 TTS 播放 300ms 后由 PCM 电平触发 duck 到 12%，持续 250ms 人声确认后打断，回声或静音则恢复音量；AEC 不可用降级手动停止；TTS 文本回声过滤丢弃误识别；打断保留完整回复并标记「已打断」。
- 1.03.7+56 构建：从 `/e/Echo-Loop/android` 执行 `GRADLE_USER_HOME=/f/devtools/gradle-home ./gradlew assembleDevRelease --offline --no-daemon --init-script ../build/pin-runner.gradle -Ptarget-platform=android-arm64`，5m 5s 构建成功；产物 `android/app/release/app-dev-release-1.03.7.apk`（114,230,350 bytes，SHA-256 `30d8dcc5a69214c4da1c1310bc3285cde13bf49e0a713a9f8e6e5a0ed0b2ce51`，versionCode 56 / versionName 1.03.7，727 条目 ZIP 校验通过，原生库仅 arm64-v8a）。该版本修复高级档外放朗读被自己的回声打断：按 `AudioTrack.routedDevice` 在内置扬声器时关闭语音插话，分句只由首句启动一个 TTS 会话，停止/自然结束后等待播放器真正停止并留 300ms 静默窗口再恢复 ASR。该版本的外放关闭语音插话已被 1.03.8+57 的平台 AEC + duck 方案替代。
- 1.03.6+55 构建：从 `/e/Echo-Loop/android` 执行 `./gradlew assembleDevRelease --offline --no-daemon --init-script <临时 init script> -Ptarget-platform=android-arm64`，并设置 `GRADLE_USER_HOME=/f/devtools/gradle-home`；未设置时离线解析 `kotlin-build-tools-api` 2.2.0 等依赖失败。产物 `android/app/release/app-dev-release-1.03.6.apk`（114,230,350 bytes，SHA-256 `6370d2e1688202789f799e11ade62b6830d3ff570c3baff337d1234bf9a10169`，versionCode 55 / versionName 1.03.6，727 条目 ZIP 校验通过，原生库仅 arm64-v8a）。该版本把 AI 口语 TTS 改为分句流式：三档默认 `qwen-audio-3.1-tts-flash`，云端逐句 `continue-task`、本地逐句队列 + 预合成，首句在 LLM 生成中即开始朗读；停止/插话同时取消生成与朗读。
- 1.03.5+54 构建：因 Google Maven TLS 中断，继续用 `./gradlew assembleDevRelease --offline --init-script <临时 init script> -Ptarget-platform=android-arm64` 通过；产物 `android/app/release/app-dev-release-1.03.5.apk`（114,164,814 bytes，SHA-256 `79d7db8f4fd10a9bbc40f80be74f73c97f62db24e0012889d321f7f921f05513`，versionCode 54 / versionName 1.03.5，727 条目 ZIP 校验通过，仅 arm64-v8a）。该版本修复免提会话说完不断句、未到空闲时间提前结束：VAD 2s 自适应硬上限、原生静音断句、云端句末收尾、ASR 失败回退 partial。
- 1.03.4+53 构建：因 Google Maven TLS 中断，继续用 `./gradlew assembleDevRelease --offline --init-script <临时 init script> -Ptarget-platform=android-arm64` 通过；改版本号后需同步 `android/local.properties` 的 `flutter.versionCode`/`flutter.versionName`，否则 Gradle 沿用旧值。产物 `android/app/release/app-dev-release-1.03.4.apk`（114,164,814 bytes，SHA-256 `82d717f875af756539412d1d8f542aa285f73d4e4e081cba79017dfb7f4fac6a`，versionCode 53 / versionName 1.03.4，727 条目 ZIP 校验通过，仅 arm64-v8a libapp.so）。该版本修复高级档流式 TTS 正常结束立即释放 AudioTrack 导致的约 1 秒截断。
- 1.03.3+52 构建：因 Google Maven TLS 中断，改用 `./gradlew assembleDevRelease --offline --init-script <临时 init script> -Ptarget-platform=android-arm64`（仅强制 integration_test 的 guava/androidx.test 解析版本，未改仓库文件）通过，产物 `android/app/release/app-dev-release-1.03.3.apk`（114,164,814 bytes，SHA-256 `1cfe1ec462cca524df075441c631c640201ef3c34ebd29f6324e2ff93e6277b5`，versionCode 52 / versionName 1.03.3，727 条目 ZIP 校验通过，仅 arm64-v8a libapp.so）。该版本包含四项增强：高级档开始听音即连续送流修复开口丢词并新增 preparing 阶段、TTS plus/flash 流式 PCM、非实时 qwen-audio-3.1-asr-flash、本地 SenseVoice Small perfect 伪流式。
- 1.03.2+51 构建（历史）：`flutter build apk --release --flavor dev --target-platform android-arm64` 通过，产物 `android/app/release/app-dev-release-1.03.2.apk`（113,191,822 bytes，SHA-256 `1d1b39a8cbfe05a92c1fd26795d796639caf368c9c740e094d96139f03ddc12e`，versionCode 51 / versionName 1.03.2，v2 签名通过，727 条目 ZIP 校验通过）。该版本修复高级档 ASR 建连握手期间丢失开口头几个词。
- 1.03.1+50 构建（历史）：`flutter build apk --release --flavor dev --target-platform android-arm64` 通过，产物 `android/app/release/app-dev-release.apk`（113,191,822 bytes，SHA-256 `e4d105bd4a028a16788317126fd6334865427ec8031156ffc500db283de3e1bd`，versionCode 50 / versionName 1.03.1，v2 签名通过，727 条目 ZIP 校验通过）。该版本包含五项修复：特级消息顺序、高级流式 ASR 整句拼装、特级隐藏大模型卡片、语音识别/合成设置页完整并入「口语引擎」、按档位选择 AI 识别模型与合成模型/音色。
- 1.03.0+49 构建（历史）：`flutter build apk --release --flavor dev --target-platform android-arm64` 通过，产物 `android/app/release/app-dev-release.apk`（113,191,818 bytes，SHA-256 `0e5330d79eb55174fdc75bc2834416b81c458208f0c103d86367c91361a2c998`，versionCode 49 / versionName 1.03.0，v2 签名通过，727 条目 ZIP 校验通过）。
- 1.02.0+48 构建（历史）：`flutter build apk --release --flavor dev --target-platform android-arm64` 通过，产物 `android/app/release/app-dev-release.apk`（113,191,818 bytes，SHA-256 `e0490f220884f330ba458dc5532cbd1acc3155ae511b54f4c5e3c43c3addf860`，versionCode 48 / versionName 1.02.0，v2 签名通过，727 条目 ZIP 校验通过）；debug 包 196,663,036 bytes 亦通过（`classes19.dex` 含 `PcmStreamPlayerHandler`）。`compileProdDebugKotlin`/`compileDevDebugKotlin`/`compileDevReleaseKotlin` 均产出 `app/echoloop/PcmStreamPlayerHandler.class`，确认新增 Kotlin 已实际编译。prod flavor 因缺 `android/key.properties` 在 `:app:packageProdDebug` 失败，属签名配置缺失而非代码问题（见 troubleshooting 7.54）。

## 7. 已知限制

1. Android 高级档 TTS 已为 WebSocket 分句流式 PCM，非 Android 平台仍回退"逐句合成 → 文件 → 播放"，打断响应依赖播放器停止延迟。服务端对同一 task 多条 `continue-task` 的韵律连续性尚未用真实 Key 验收。
2. 特级档依赖 Android 原生 AudioTrack；桌面/iOS 会提示"当前平台不支持实时语音播放，请改用初级或中级档位"。
3. `turn_detection` 与 `input_audio_format` 只能在首帧音频前修改，切换判停方式需重连会话（当前实现即"下次开始会话生效"）。
4. 实时语音的 `voice` 只在首次 `session.update` 生效，会话中途改设置不会热切换。
5. 高级档朗读前用 `AudioTrack.routedDevice` 判断实际输出：内置扬声器时关闭语音插话，只保留手动停止；耳机/外接设备才靠抬高门限判断 VAD 插话。无法查询路由或查询异常时按外放保守处理。不同品牌设备的设备类型上报、蓝牙 A2DP/SCO 切换仍需真机验收，强回声环境仍可能误触发。
6. 服务端若对某一轮返回空转写或直接丢弃该轮，控制器会把状态退回听音态；若既无转写也无回复且思考态没有进行中的回复，空闲计时继续生效，按阈值退出会话。
7. 档位配置按档位隔离后，切换练习档位会同时切换该档位的模型/音色/会话参数；旧全局配置只作为首次读取的回退来源，不会在档位间同步。
