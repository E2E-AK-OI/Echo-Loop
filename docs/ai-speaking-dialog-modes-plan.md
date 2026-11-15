# AI 口语练习四档对话能力实施计划

> 创建：2026-11-13
> 关联规格：[ai-speaking-implementation-plan.md](./ai-speaking-implementation-plan.md)（v1 按键说话版，本计划在其之上扩展）
> 状态：P1 进行中

## 1. 目标

把现有单一的「按键说话」口语练习拆成四档，档位之间共享会话、消息与 LLM 配置，只在「语音输入 / 语音输出 / 轮次控制」上分层：

| 档位 | 触发方式 | 轮次判定 | 允许打断 | 语音识别 | 语音合成 | 大模型 |
| --- | --- | --- | --- | --- | --- | --- |
| 初级 | 按住/点按说话，再点完成提交（现有实现） | 按键 | 否 | 云端实时 ASR 或本地/平台 ASR | 云端 HTTP TTS 或本地 TTS | 对话 LLM |
| 中级 | 点话筒开始会话，再点停止 | 本地能量 VAD + EOS 尾静音 | 否（AI 朗读期间抑制判停） | 同上 | 同上 | 对话 LLM |
| 高级 | 点话筒开始会话，再点停止 | 本地 VAD + 云端流式 ASR 判停 | 是（barge-in） | 仅云端实时 ASR | 仅云端 TTS（分句流水线） | 对话 LLM |
| 特级 | 点话筒开始会话，再点停止 | 服务端 VAD（`server_vad` / `smart_turn_v2`） | 是 | 由 qwen-audio-3.1-realtime-flash 内置 | 由模型内置输出 PCM | 由模型内置 |

设计约束（来自需求）：

- 延迟容忍度：初/中级不敏感，高级敏感（靠流式 ASR + 分句 TTS 缩短首字时间），特级最低。
- 中级必须有 VAD 与回声消除，且**不允许插话打断**。
- 高级使用云端实时 ASR/TTS，**不做语义判停**（只看声学活动）。
- 特级必须可在「AI 设置」中配置模型；允许重构整条链路。

## 2. 现状与复用点

已实现（v1）：

- `AiSpeakingSessionController`（878 行）：按键会话 + ASR/LLM/TTS 三段链路，含 `_turnId` 竞态守卫、本地/云端 ASR 分流、本地/云端 TTS 分流。
- `RecordPcmRecorder`：16k/单声道/PCM16 流，已开启 `echoCancel`/`noiseSuppress`/`autoGain`。
- `AliyunRealtimeAsrClient`：DashScope `/api-ws/v1/inference` 的 `run-task`/`finish-task` 双工协议。
- `AliyunTtsClient`：非实时 HTTP 合成 + 磁盘缓存。
- `shortAudioPlayerProvider`（just_audio）：文件播放，可 stop，是当前唯一的播放入口。
- `speakingEngineSettingsProvider` / `SpeechEngineSettingsScreen`：ASR/TTS 来源切换。

复用策略：

- **初/中级共享同一条链路**：中级只是把「人按按钮」换成「VAD 自动按按钮」，`_sendUserTurn` → `_requestAssistantReply` → `_speakAssistant` 完全复用，回归面最小。
- **高级在链路两端替换**：ASR 改为长连接流式，LLM 输出改为按句切分后流水线合成，播放入口仍走 `LocalAudioClipPlayer`（避免引入原生 PCM 播放能力）。
- **特级独立成链路**：语音到语音模型自带 ASR/LLM/TTS，不复用现有三段式，单独控制器与页面状态。

## 3. 新增模块

```
lib/features/ai_speaking/
  models/
    ai_speaking_level.dart          # 档位枚举 + 能力矩阵（纯数据，可测）
    speaking_dialog_settings.dart   # EOS / 空闲退出 / 打断灵敏度 + 边界钳制
    ai_speaking_dialog_state.dart   # 中级及以上会话状态机（arming/userSpeaking/...）
  providers/
    ai_speaking_level_provider.dart
    speaking_dialog_settings_provider.dart
    vad_conversation_provider.dart      # 中级：VAD 驱动的自动对话循环
    realtime_speaking_controller.dart   # 特级：语音到语音会话
  services/
    voice_activity_detector.dart        # 纯 Dart 能量 VAD（帧 RMS + 噪声底 + 起止判定）
    pcm_capture_pipeline.dart           # 共享麦克风采集，多订阅者，引用计数开关
    vad_conversation_loop.dart          # 不依赖 Flutter 的对话循环状态机（可注入时钟）
    aliyun_realtime_tts_client.dart     # 实时 TTS WebSocket（高级）
    sentence_tts_pipeline.dart          # LLM 流式文本 → 逐句合成 → 顺序播放（高级）
    aliyun_realtime_speech_client.dart  # 语音到语音 WebSocket（特级）
    pcm_segment_player.dart             # PCM 增量 → WAV 片段 → just_audio 连播（特级）
```

关键取舍：

1. **不新增原生依赖**。特级的 PCM 输出按 ~500ms 切片段写成 WAV，用 just_audio 的连播队列追加，避免引入 `flutter_pcm_sound` 一类需要原生代码的插件。
2. **VAD 自己做**。云端 ASR 的 VAD（`vad_model`）只用于断句，不能控制「本轮何时结束、何时退出会话」，所以 EOS/空闲退出必须由本地 VAD 决定，这样设置页的 400–2000ms 才有意义。
3. **共享采集，不做双录音器**。中级同时需要「VAD 常开」和「ASR 取流」，两者必须订阅同一路 PCM，否则会争抢录音设备。

## 4. 分阶段实施

### P1 档位与设置（本轮完成）

- [ ] `AiSpeakingLevel`：`beginner`/`intermediate`/`advanced`/`expert`，带 `usesPushToTalk`、`usesVad`、`allowsBargeIn`、`requiresRealtimeTts`、`requiresSpeechToSpeech`、`allowsLocalEngines` 能力位。
- [ ] SharedPreferences 键 `ai_speaking_level`，未知值回退 `beginner`；跨档位切换保留消息与设置。
- [ ] `SpeakingDialogSettings`：`endOfSpeechMs`（400–2000，默认 800，2000 兜底）、`idleExitSeconds`（10–60，默认 30）、`bargeInSensitivity`（低/中/高）；构造与 `copyWith` 一律钳制，越界不抛异常。
- [ ] 「口语引擎」设置页新增「对话与会话」区块：EOS 滑杆、空闲退出滑杆、打断灵敏度（仅高级可见）。
- [ ] 「AI 设置」新增「实时语音对话（特级）」区块：模型名（固定 `qwen-audio-3.1-realtime-flash`，预留可编辑）、音色、轮次检测模式（`server_vad`/`smart_turn_v2`）。
- [ ] 口语页顶部档位切换器；切换后重置会话状态，输入区按档位渲染。

### P2 中级（VAD 自由对话，不可打断）

- [ ] `VoiceActivityDetector`：16k PCM16 帧（20ms/320 字节）→ RMS → 自适应噪声底 → `speechStarted` / `speechEnded`；含最小语音时长（默认 250ms）防误触、EOS 计时、2000ms 兜底强制断句。
- [ ] `PcmCapturePipeline`：单例持有 `RecordPcmRecorder`，暴露广播流与 `inputLevel`，引用计数保证多订阅者同时可用。
- [ ] `VadConversationLoop`：`arming`（等用户开口）→ `userSpeaking`（订阅 ASR）→ `eos`（finish ASR）→ `thinking` → `aiSpeaking`（VAD 挂起，防回声）→ 回到 `arming`；空闲计时达到 `idleExitSeconds` 自动结束会话并提示。
- [ ] 控制器接入 pipeline（仅 AI 云端 ASR 分支），本地 ASR 仍走原 `RecordingService`。
- [ ] UI：话筒按钮变为「开始/停止会话」，状态文案区分「正在聆听 / 思考中 / AI 朗读中 / 长时间无语音」。
- [ ] 测试：VAD 起止、EOS 边界（400/800/2000）、AI 朗读期间不提交、空闲退出。

### P3 高级（实时 ASR/TTS + 用户打断）

- [ ] `AliyunRealtimeTtsClient`：`/api-ws/v1/inference` 的 `run-task`（`task=tts`）→ `continue-task`（逐段文本）→ `finish-task`，二进制帧收集为 PCM；`directive=cancel` 用于打断。
- [ ] `SentenceTtsPipeline`：LLM 流式增量按句切分（`。！？.!?\n` + 长度兜底 120 字符）→ 逐句合成 → 顺序播放；首句到达即开播，缩短首字延迟。
- [ ] Barge-in：播放期间 VAD 用更高门限（`bargeInSensitivity` 映射 0.12/0.16/0.22）；触发后立刻 `stop()` + 清空未播队列 + 取消 TTS 任务 + 切回 `userSpeaking`。
- [ ] 打断后仍保留已播文本前缀，AI 回复标记 `interrupted`，下一轮 prompt 附带「用户打断了你的发言」提示。
- [ ] 测试：队列丢弃、打断后不重复播放、门限抬高后回声不误触发。

### P4 特级（qwen-audio-3.1-realtime-flash 语音到语音）

- [ ] `AliyunRealtimeSpeechClient`：`wss://{workspace}.cn-beijing.maas.aliyuncs.com/api-ws/v1/realtime?model=...`；`session.update`（`modalities`、`voice`、`instructions`、`input_audio_format=pcm`、`output_audio_format=pcm`、`turn_detection`）→ `input_audio_buffer.append`（base64 PCM16 16k）→ 接收 `response.audio.delta`（base64 PCM 24k）。
- [ ] `PcmSegmentPlayer`：累积 ~500ms → 写 `wav` 片段 → `ConcatenatingAudioSource.add` → 顺序播放；`cancel` 时清空队列并停止。
- [ ] 特级控制器：连接态、聆听态、AI 说话态、错误态；用户说话时断开播放缓冲（打断由服务端 `server_vad` / `smart_turn_v2` 触发，客户端做兜底清缓冲）。
- [ ] 消息记录：`conversation.item.input_audio_transcription.completed` 与 `response.audio_transcript.done` 写入现有消息模型，复用气泡组件。
- [ ] 「AI 设置」中的实时模型配置生效；未配置时提示前往设置。
- [ ] 测试：事件解析、片段拼接、取消清理、错误事件映射。

### P5 验收与文档

- [ ] `dart format` / `flutter analyze` / 定向 `flutter test` / 全量 `flutter test` 基线对比。
- [ ] Android 真机清单：四档各自的开麦、回声、打断、超时退出。
- [ ] 更新 `PLAN.md`、`TASKS.md`、`docs/troubleshooting.md`。

## 5. 风险与未决点

| 风险 | 说明 | 应对 |
| --- | --- | --- |
| 回声自激 | 外放时 TTS 声音被 VAD 当成用户语音，导致自我打断 | 中级：朗读期间挂起 VAD；高级：门限抬高 + 250ms 最短语音 + 播放停止后 300ms 冷却 |
| 云端实时 ASR 断句不可调 | `qwen-audio-3.1-asr-flash-streaming` 用 `vad_model` 断句，没有 `max_sentence_silence` | 轮次边界统一由本地 VAD + `finish-task` 决定，EOS 设置有实际意义 |
| PCM 连播间隙 | just_audio 追加片段可能有毫秒级空隙 | 片段取 500ms，观察真机；若明显再考虑原生 PCM 播放 |
| 特级模型上下文 | 音频上限 50 轮 / 300 秒，超限丢弃最早历史 | 会话超过 40 轮或 4 分钟主动重建 session，并保留文本摘要 |
| 打断语义差异 | 服务端 `server_vad` 是否自动取消进行中的 response 需确认 | P4 前用真实 Key 验证，客户端始终做「清缓冲 + response.cancel」兜底 |

## 6. 关键协议（已确认部分）

- 实时识别：`wss://dashscope.aliyuncs.com/api-ws/v1/inference`；`run-task` 的 `payload.task_group=audio`、`task=asr`、`function=recognition`、`parameters.format=pcm`、`sample_rate=16000`；3.1 系列通过 `vad_model`（`near_meeting_16k` / `far_field_meeting_16k`）选择断句模型。
- 实时合成：同一 `/api-ws/v1/inference`，`run-task` → `continue-task`（文本分段）→ `finish-task`；取消使用 `finish-task` 且 `input.directive=cancel`；同一连接可顺序复用，必须换新的 `task_id`。
- 语音到语音：`wss://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/api-ws/v1/realtime?model=qwen-audio-3.1-realtime-flash`；输入 PCM 16k/16bit/单声道，输出 PCM 24k/16bit/单声道；`session.update` 支持 `turn_detection.type` = `server_vad` / `smart_turn` / `smart_turn_v2` / `manual`；模型音频上下文 50 轮 / 300 秒，`max_history_turns` 默认 20。
