# Echo Loop 项目规划

> 最后更新：2026-11-15（修复高级档外放 duck 判别每次被误关闭：duck 收敛后的残留峰值不再回写参考基线，新增 180ms 收敛窗口与「残留达到参考峰值 70% 则关闭插话」判断；AI 口语高级档外放插话改为平台 AEC + duck 判别：外放时切换通话音频路由，VAD 保持静音，PCM 电平先压低 TTS 到 12%，180ms 收敛后观察 250ms，确认持续人声后才打断；平台 AEC 不可用时降级手动停止，耳机继续走 VAD 插话；此前已完成分句流式 TTS、三档默认 `qwen-audio-3.1-tts-flash`、高级档连续送流、TTS 排空与免提断句兜底）
> 当前焦点：端侧优先版本已完成回归与 Android APK 构建，1.03.9 修复外放 duck 判别误关闭，待真机验收；上游 v1.0.46 的单词发音 CDN、查词静默发音、意群播放修复与 staticCdn 命名已合入；Edge 在线 TTS 已作为可选项加入（默认仍为本地 Kokoro）；AI 讲解与 AI 口语共用「设置 › AI 设置」的 BYOK 配置，口语练习的 ASR/TTS 可在「设置 › 口语引擎」中切换本地或 AI；历史遗留 Android 离线 ASR 结束录音闪退仍待定位；推理强度只对支持 reasoning_effort 的 OpenAI 兼容供应商生效；AI 口语四档、四项增强与分句 TTS 已完成（`test/features/ai_speaking` 全部通过），高级档从开始听音即连续送流修复开口丢词，TTS plus/flash 已支持 Android 流式 PCM，并在正常结束后等待 AudioTrack 排空（修复约 1 秒截断），新增非实时 ASR 与 SenseVoice Small perfect 伪流式；免提会话已补 2s 自适应硬上限、原生静音断句、云端句末收尾与 ASR 失败回退（受影响测试 250 项通过），待 Android 真机验收回声消除、EOS 手感、特级打断延迟与消息顺序；三档默认 TTS 已切到 flash，云端按句多 `continue-task`、本地逐句预合成，首句可在大模型生成中开始朗读；高级档外放插话改为平台 AEC + duck 判别：外放切通话音频路由，PCM 电平先压低 TTS 到 12%，180ms 收敛后仍有人声才确认打断，AEC 实际未压住回声时关闭插话，耳机继续走 VAD；分句只由首句启动一个 TTS 会话；非 Android 的云端 TTS 仍回退文件播放；iOS 未在 Windows 环境编译

## 产品目标

Echo Loop 是一个围绕“音频输入 + 句子级学习 + 间隔复习 + AI 辅助”的英语学习应用。核心目标：

- 让用户围绕真实音频材料完成首次学习与后续复习。
- 学习闭环与本地能力完全免费，不设账号、订阅或额度；不依赖自建后台。
- AI 能力采用 BYOK（用户自填供应商 Key）客户端直连，学习数据与凭据只留在本机。
- 优先保证播放器、学习流转与状态一致性；当前发布平台为 Android。

## 当前状态

已稳定上线的能力：

- 音频导入、字幕管理、字幕编辑、自由播放器。
- 首次学习主流程：全文盲听、逐句精听、难句跟读、段落复述。
- 收藏体系：句子、单词、意群、收藏复习。
- 词典体系：本地词典、网页词典、多源切换、非 modal 面板。
- 本地能力：离线转录、学习统计、PDF 笔记导出、本地备份与恢复。
- AI 能力（BYOK 直连）：翻译、句子解析、单词/意群解析、AI 学习助手、AI 口语自由练习。
- 端侧优先架构：无账号与登录、无订阅与权益门禁，AI/转录/聊天不经过自建后端；启动链路不依赖 Supabase / RevenueCat / Paddle。百度网盘 OAuth 改为应用内简化模式，由用户填写自建应用 AppKey，不再经过自建后端。
- 导入范围：保留本地文件、音频直链、百度网盘导入与用户自行添加的播客源；社区合集与精选播客入口已下线。

当前主要风险：

- Android 离线 ASR 在部分机型结束录音后触发 native 崩溃，仍未定位到最终 root cause。
- BYOK 需要用户自行申请供应商 API Key，Key 仅存本机安全存储且不随换机迁移；额度与计费由供应商侧管理。
- AI 解析依赖供应商模型遵循 JSON 输出约定，模型能力或返回格式变化可能导致单次解析失败。
- 本地备份是唯一的数据保全方式，设备丢失或卸载后无法从云端恢复。
- 社区合集、精选播客等入口下线后，旧页面与旧文案仍需持续回归，避免残留死链。
- 百度网盘 OAuth 改为简化模式后不再支持刷新令牌，access token 约 30 天过期，用户需重新授权；用户需自行在百度网盘开放平台创建应用并填写 AppKey，个人应用默认限 10 个用户。
- 百度网盘开放平台对 2026-06-03 之后创建的应用增加了目录限制：`download`、`filemanager`、`precreate`、`meta`、`move` 与 `multimedia.listall` 等接口仅能访问 `/apps/{appname}` 目录，可能影响浏览和下载用户网盘任意目录中的文件，需真机与真实应用验证。

## 当前里程碑

### ✅ Milestone 1：基础播放器

已完成。覆盖音频导入、全文/单句/收藏三种播放模式、字幕同步、收藏与基础播放控制。

### 🚧 Milestone 2：学习流程引擎

主体已完成，剩余收尾集中在录音识别稳定性：

- 已完成：首次学习流程、阶段状态流转、断点续学、难度驱动的训练编排。
- 已完成：难句补练、收藏复习、盲听与复述共享骨架。
- 未完成：Android 离线 ASR 闪退根因定位与修复；段落复述继续复用统一录音识别模块。

### ✅ Milestone 3：收藏与标注体系

已完成。覆盖 Favorites、句子/单词/意群收藏、收藏复习、词典联动与标注内容展示。

### 🚧 Milestone 4：体验优化与生产就绪

持续推进中：

- 性能与稳定性优化。
- Android 单平台体验对齐（当前仅发布 Android）。
- 播放、词典、PDF、字幕编辑等高频链路体验打磨。
- CI / Release / APK 构建与安装校验。
- AI 对话助手（通用 chatbot 组件）：多轮对话式 AI 助手，一套可插拔组件接入不同位置（首接入点为句子讲解页；逐句精听 / 难句跟读 / 难句复习 / 收藏复习 4 个句子级任务页 AppBar 共享 `SentenceChatButton` 单一入口来源）。2026-11-05 起改为 BYOK 直连，移除登录、订阅与后端额度门。
- 纯端侧改造（Android，2026-11-05）：移除账号/登录、订阅/权益、社区合集、精选播客与自建后端 AI/转录/聊天依赖；AI 讲解与 AI 口语改为 BYOK 直连；保留本地导入、本地学习、本地备份与 AI 口语。2026-11-06 恢复百度网盘导入入口，并将 OAuth 改为应用内简化模式（用户自填 AppKey），移除最后一个后端依赖。详见 [docs/on-device-architecture-plan.md](./docs/on-device-architecture-plan.md)。
- AI 口语自由练习（Android）：BYOK 直连的开放式英语口语对话，支持 DeepSeek / 阿里云百炼 / OpenAI / 自定义 OpenAI 兼容供应商，Base URL、模型与温度可配；语音使用阿里云实时 ASR `qwen-audio-3.1-asr-flash-streaming` 与 TTS `qwen-audio-3.1-tts-plus`；已在学习页与设置页接入，2026-11-05 完成代码与测试（待 Android 真机手动验收）。规格见 [docs/ai-speaking-implementation-plan.md](./docs/ai-speaking-implementation-plan.md)。
- AI 口语分档升级（2026-11-13）：初级保持按键说话；中级改为点话筒开始/结束的免提会话，本地 VAD 按尾静音 EOS 切分轮次（400–2000ms 可调，默认 800、兜底 2000），空闲 10–60s（默认 30）自动退出；高级允许用户插话打断，要求云端实时 ASR/TTS；特级使用阿里云语音到语音 `qwen-audio-3.1-realtime-flash`（服务端判停，模型/音色/判停方式在「AI 设置」配置），下行 24kHz PCM 由 Android AudioTrack 流式播放。2026-11-13 起「口语引擎」按四档标签隔离配置（识别/合成来源、TTS 模型与音色、实时语音参数、EOS 与空闲退出等），存储键追加档位后缀并回退旧全局键。2026-11-13 继续合并设置入口：设置页不再保留独立「语音识别」「语音合成」入口，两页完整内嵌到口语引擎页；AI 识别可选 3.0/3.1 实时流式与 qwen-audio-3.1-asr-flash 非实时模型，AI 合成可选模型与音色，均按档位持久化；同时修复特级消息顺序与高级流式 ASR 整句丢失。2026-11-13 四项增强：高级档改为开始听音即建连并连续送流，新增麦克风准备阶段；TTS plus/flash 改 WebSocket 流式 PCM（Android 边收边播）；新增非实时 ASR 整段上传；本地新增 SenseVoice Small perfect 伪流式。2026-11-13 修复流式 TTS 自然收尾：新增 `PcmStreamPlayer.finish()` 与原生 AudioTrack 排空线程，正常结束等播放头追上已写入帧数再释放，插话/停止仍立即 stop；版本 1.03.4+53。规格见 [docs/ai-speaking-levels-plan.md](./docs/ai-speaking-levels-plan.md)。

### ⛔ Milestone 5：支付订阅（已下线）

2026-11-05 纯端侧改造已移除账号、订阅、权益门禁及 RevenueCat / Paddle / 后端配额链路，应用不再包含付费入口。原订阅实现与文档仅作历史记录保留，不再作为发布范围。

## 近阶段工作重点

1. 完成纯端侧版本全量回归，清理下线功能的旧测试、入口与文案残留。
2. 构建并校验 Android APK，真机验证 AI 口语、BYOK 讲解、导入与本地备份。
3. 解决 Android 离线 ASR 闪退。
4. 继续收敛录音识别模块复用边界。

## 架构约束（精简版）

- 单向数据流：UI 触发动作，provider / controller 改状态，UI 被动渲染。
- 页面负责组装，组件负责展示，复杂流程下沉到可测试的纯 Dart 编排层。
- 副作用通过 service / repository 注入，不把网络、文件、平台调用散落到 UI。
- 异步流程必须带 session / token / generation guard，防止旧回调污染新状态。
- 学习统计新写入链路用于全部学习任务（随心听、收藏复习、逐句精听、难句跟读、全文盲听、段落复述和难句补练）：
  页面 → Provider → StudySessionTimer → StudyTimeService FIFO 队列 → StudyStatisticsDao 单事务；
  计时器按页面生命周期创建/销毁，播放完成事件写入输入统计，录音完成事件写入输出统计，用户无活动超过
  2 分钟才暂停总学习时长。学习任务不再保留独立的 StudyEventRecorder、StudyStatisticsRecorder 或旧式 add* 增量写入链路。
- 新链路使用的日统计、阶段统计和词形事务能力保持集中实现，避免新增调用方绕过
  统一写入口。
- 新增能力优先补状态流转测试与关键回归测试。

## 关键 ADR 索引

- 媒体引擎与前台引擎分离：避免锁屏媒体会话与前台试听互相污染。
- 统一 TTS 架构：合成 → 文件 → 缓存 → 播放，支持平台 TTS、Kokoro 与 Piper 本地 TTS，以及 Edge 在线 TTS（可选，默认 Kokoro）。
- 离线转录与本地模型：复用统一音频处理与模型下载能力。
- 端侧优先与 BYOK：不设账号与订阅，AI 通过用户自填 Key 客户端直连；百度网盘 OAuth 使用应用内简化模式，不依赖自建后台；学习数据与凭据只存本机。
- 通用记忆调度基础设施：以独立调度快照与只追加复习事件建模；上层依赖应用自有接口，FSRS 仅限 adapter 内部，按逐项固定 Profile 保障可迁移与可审计性（见 [memory-scheduler-infrastructure-plan.md](./docs/memory-scheduler-infrastructure-plan.md)）。

详细历史与旧版长文档已归档：

- [2026-07-12 全量规划快照](./docs/plan-archive/plan-2026-07-12-full.md)

日常执行请结合：

- [TASKS.md](./TASKS.md)
- [AGENTS.md](./AGENTS.md)
