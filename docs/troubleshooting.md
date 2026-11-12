# 踩坑记录（Troubleshooting）

记录已修复的典型问题和设计约束，防止同类问题再次出现。

本文件原为根目录 `CLAUDE.md` 第 7 节，已迁移至此。编号沿用原 §7 编号（如 §7.12），既有的引用仍可对应。

## 使用约定

- **查询**：按关键词搜索（如 `grep -n "锁屏" docs/troubleshooting.md`），或按下方索引定位。
- **记录**：修复典型问题或确立设计约束后，在文件末尾追加新条目，编号顺延。条目结构为：现象 / 根因 / 解法 / 规则 / 相关代码 / 修复时间，按需取舍。
- **未解决**的问题在标题中标注（**未解决**），解决后去掉标注并补充解法。
- **不写入 `CLAUDE.md`**：`CLAUDE.md` 只保留开发规范，踩坑记录统一放在本文件。

## 索引

- 7.1 iOS 语音识别：异步回调破坏新 session
- 7.2 flutter_tts：快速 stop→speak 导致 awaitSpeakCompletion 失效
- 7.3 Android versionCode 必须全局单调递增，与 versionName 解耦
- 7.4 离线 ASR：sherpa-onnx Silero VAD native 推理在部分机型 abort（**未解决**）
- 7.5 清除缓存误删系统 URLCache 导致 disk I/O error
- 7.6 just_audio：整篇循环依赖 completed 事件做反应式计数不可靠
- 7.7 锁屏：向系统上报 `completed` 导致整篇循环进度条偶发卡在结尾
- 7.8 release 资源压缩删掉通知图标，锁屏/通知栏媒体控件整体消失（仅 release）
- 7.9 录音类任务抑制锁屏的三个坑（iOS MediaItem/position 通道 + Android「先 load 后 suppress」时序）
- 7.10 学习任务后台播放：静音保活音量必须 1.0；锁屏切句回调每任务绑一次
- 7.11 录音类任务仍显示锁屏：suppress(false) 在 idle 时重发 MediaItem 贴出无法清除的残留卡片
- 7.12 媒体引擎 / 前台引擎分离：把「是否上锁屏」做成结构性属性而非运行时开关
- 7.13 段落播放：position 追踪订阅早于 seek(0) 落定 → 高亮乱跳、断点被覆盖成首句
- 7.14 盲听会话内中断用 stop（idle）反复拆/重建系统媒体会话 → 锁屏控件失效
- 7.15 段落分段播放（clip）锁屏进度每切句归零：必须上报「绝对位置 + 全曲时长」
- 7.16 停顿倒计时锁屏进度条仍前进、下一段又回退：必须上报 `speed=0` 冻结
- 7.17 合集内详情路由拍平在顶层 → 返回后自动多退一层（学习计划页 → 资源库）
- 7.18 统一 TTS：嵌入式发音组件不可在 provider build 期触碰平台/数据库（惰性化）
- 7.19 macOS flutter_tts：synthesizeToFile 不设 voice，英/美音合成产物完全相同
- 7.20 Echo Loop TTS（Kokoro / sherpa-onnx）接入要点（设计约束，详见 PLAN.md ADR-9）
- 7.21 Kokoro 归档若用 macOS tar 打包，PAX 扩展头令 archive 解压抛 FormatException
- 7.22 TTS 音色试听/预热：音色经 config 显式传入 synthesize，统一 render 主干（设计约束）
- 7.23 平台 TTS 口音试听：engine.stop() 打断在途 synthesizeToFile 致复用方挂起
- 7.24 macOS 平台 TTS 自实现 synthesizeToFile（原生通道）→ 三端合成行为一致
- 7.25 词典交互：非 modal 常驻面板 + 词组选区手柄（设计约束）
- 7.26 流式 AI 词典（NDJSON 部分对象快照）：设计约束与踩坑
- 7.27 流式 AI 词典：帧协议由「累计完整快照」改为「字段级增量」
- 7.28 选区能力三层化：自有 selection model + 平台手柄画笔（取代 SelectableText）
- 7.29 长期分支落地覆盖主干英文文案：`app_en.arb` 256 个 key 静默回退，且被后续测试"修复"坐实
- 7.30 跟读实时 VAD：固定 RMS 门槛把小声用户判成静音 → 说话中途被自动结束录音
- 7.31 复述重听本段：清理录音置 idle 触发自动录音，抢在原文播放前启动 → 原音被录进去
- 7.32 media_kit 区间播放：软停止越过句尾带出下一句；seek 未落定就起播
- 7.33 共享合集 / 播客未下载材料进入学习计划页：入口判断分散 → 进入逐句精听报 `file unavailable`
- 7.37 同一资源多入口下载：查找再登记导致重复任务，取消需绑定具体任务
- 7.38 Riverpod 3 暂停无监听 StreamProvider：启动会话永久挂起，登录后仍提示未登录
- 7.41 百度网盘批量导入：下载时才取 dlink，切后台后队列无法接力下一个文件
- 7.42 阿里云 Qwen-Audio 实时 ASR：finish-task 必须带 streaming=duplex，心跳包需过滤
- 7.43 Widget 测试：tester.enterText 后不 pump，按钮仍处于旧的可点击状态
- 7.44 纯端侧改造：删除登录/订阅后，旧测试要按功能边界删除而不是伪造登录态
- 7.45 Android APK 构建：Gradle 9 不兼容，Gradle 8 需显式禁用 IPv6 与启用 TLSv1.2
- 7.46 retell_recording_controller_test 整文件顺序敏感：前序用例残留状态会让第 6 项 did not complete
- 7.47 AI 口语第二轮点话筒无反应：单例录音器被每轮 dispose 后再也起不来

---

## 条目

### 7.1 iOS 语音识别：异步回调破坏新 session

- **现象**：录音播放不正确、卡在"分析中"~5 秒、评级却显示很棒
- **根因**：`SFSpeechRecognitionTask.cancel()` 的回调是**异步**的（排入主队列下一轮事件循环）。若新 session 已启动，旧回调读到新 session 状态并破坏它（`isRecording = false` + 取消新识别任务）
- **解法**：generation counter 模式 — 每次新 session 递增计数器，闭包捕获当前值，回调中校验不匹配则丢弃
- **规则**：识别回调的 error 分支**不做资源清理**，资源清理统一由 stop/cancel/shutdown 发起
- **相关代码**：`ios/Runner/AppDelegate.swift` → `IOSSpeechPracticeHandler`
- **修复时间**：2026-03-27

### 7.2 flutter_tts：快速 stop→speak 导致 awaitSpeakCompletion 失效

- **现象**：闪卡快速切换单词时，TTS 在 3-9ms 内"完成"（实际还在朗读），倒计时和 TTS 声音同时出现
- **根因**：`_tts.stop()` 触发平台两个响应：① method channel result（解除 await）② cancel handler（异步到达）。cancel handler 在新 `speak()` 的 Completer 创建后才到达，错误地完成了新的 Completer。平台层报错 `Message responses can be sent only once`
- **解法**：不依赖 `awaitSpeakCompletion`，改用自管理 Completer + `setStartHandler` 标志。start handler 到达前的 completion/cancel 回调视为 stale 直接忽略。method channel FIFO 保证顺序：旧 cancel → 新 start → 新 completion
- **规则**：TTS 的 stop 和 speak 之间不能依赖 flutter_tts 内部的完成信号隔离，必须自行管理
- **相关代码**：`lib/services/tts_service.dart`
- **修复时间**：2026-04-06

### 7.3 Android versionCode 必须全局单调递增，与 versionName 解耦

- **现象**：已装 1.0.10+4 的设备无法安装 1.0.11+1/+2，系统提示「已存在更高版本」
- **根因**：Android 升降级**只看 versionCode（整数）**，不看 versionName。Flutter `pubspec.yaml` 的 `+N` 直接映射到 Android versionCode。minor 升级时把 buildNumber 重置回 1，导致 versionCode 倒退（4 → 1）
- **解法**：
  - Git tag 改用纯 SemVer 格式 `v1.0.11`（**不带 `+N`**）
  - versionCode 由 CI 用 `git rev-list --count <tag>` 自动生成，全局单调递增
  - App 内"关于"页只显示 versionName，buildNumber 不暴露给用户
  - 同 versionName 内需重新构建时：加空 commit (`git commit --allow-empty`) → commit count +1
- **规则**：所有平台（Android/iOS/macOS）的发布脚本和 CI workflow 都按"tag = 纯 SemVer，versionCode = commit count"约定走。打 tag 前必须先升级 `pubspec.yaml` 的 version 字段（workflow 会强制校验一致）
- **相关代码**：`scripts/lib/build_number.sh`、`scripts/release_*.sh`、`.github/workflows/release.yml`、`lib/screens/settings_screen.dart`
- **修复时间**：2026-05-20

### 7.4 离线 ASR：sherpa-onnx Silero VAD native 推理在部分机型 abort（**未解决**）

- **现象**：OnePlus Ace 6T / Android 16 (ColorOS) 跟读/复述点"结束录音"后闪退
- **排查过程（重要方法论）**：拿不到 logcat/tombstone，靠**落盘日志 + 崩溃面包屑**定位。先按"最可能是 NNAPI"把 `_platformProvider()` 由 `nnapi` 改 `cpu`（兜底，保留）；但真机日志显示 `provider=cpu` 后**仍崩**，且 worker 日志里 `VAD input` 打出、紧随的 `VAD: segments` 未打出——锁定崩在 `_extractSpeechWithVad`，即 **Silero VAD 的 native 推理**，与 NNAPI/whisper 无关
- **真因**：sherpa-onnx 的 Silero VAD 在该机型 native abort（进程被杀）。在 sherpa-onnx native 层，本地无法复现、改不动
- **失败的修复尝试（均未解决）**：
  - ① AudioRecord 并发串行（commit `bbbf1c37`）——误判，真因不在录音
  - ② NNAPI → cpu provider（commit `0174ee80`）——误判，cpu 后仍崩
  - ③ 自适应跳过 VAD（崩一次后置位 `offline_asr_skip_vad`、整段直送 whisper）——真机**连续崩多次**，标记未触发自愈或绕开 VAD 后 whisper decode 同样崩，已**撤销**
- **现状**：崩溃**未解决**。保留诊断设施（落盘日志 / `_workerLog` / 崩溃面包屑 / `asr_inference_crash_suspected` 上报）与两个独立合理的防御改动（cpu provider、AudioRecord 串行）继续排查；确诊需真机 **logcat + `/data/tombstones`**
- **规则**：
  - native SIGABRT/SIGSEGV/被杀**不可 catch**——"兜底不崩"只能靠避开崩溃路径（跳过该 native 调用），不能靠包 try-catch；但避开 VAD 后本例仍崩，说明绕开单点不一定够
  - 面包屑只能证明"进程在某 native 段被终止"，**证明不了信号类型**（SIGABRT/SIGSEGV/OOM-SIGKILL 都会残留 marker），也证明不了"绕开该段就不崩"；要确诊信号/栈仍需 logcat + `/data/tombstones`
  - 排查 native 崩溃必须**落盘日志 + 调用前同步 flush**：内存日志（`AppLogger` 环形缓冲）崩溃即丢；Worker isolate 的日志写各自 isolate 单例、到不了主 isolate 日志页，需在 isolate 内自行写文件（`_workerLog`）
- **相关代码**：`lib/services/asr/sherpa_onnx_engine.dart`（崩溃面包屑 / `_workerLog` / cpu provider）、`lib/providers/offline_asr_settings_provider.dart`（`_reportPreviousAsrCrashIfAny`）、`lib/services/app_logger.dart`、`lib/utils/app_data_dir.dart`
- **更新时间**：2026-06-10（暂记，待真机定位）

### 7.5 清除缓存误删系统 URLCache 导致 disk I/O error

- **现象**：点「清除缓存」后日志反复 `error-message=disk I/O error`，`DB=.../Library/Caches/<bundleId>/Cache.db`，`BEGIN IMMEDIATE TRANSACTION` 失败、`cannot commit - no transaction is active`。每次 app resume 触发原生网络请求就报一次（与磁盘空间无关）
- **根因**：`cleanupAllTempFiles` 把 `getTemporaryDirectory()`（= iOS/macOS 的 `Library/Caches`）**整个根目录**一级条目逐个 `delete(recursive:true)`。`Library/Caches` 是系统/框架共享目录，其中 `<bundleId>/Cache.db`(+`-wal`/`-shm`) 是 `URLSession.shared`(NSURLCache) 正在打开的 SQLite 缓存库。文件被 unlink 后 URLSession 再写缓存即 SQLITE_IOERR(error-code=10)
- **解法**：清缓存只清 app 自己的产物——
  - `Library/Caches` 只删 app 自建导出/导入临时目录（前缀白名单 `audio_export_` / `echoloop_export_` / `echoloop_import_`），系统/框架缓存一律跳过
  - 网络图片缓存走 `flutter_cache_manager` 的 `AppNetworkImageCache.instance.emptyCache()`（API 同时清文件+json 索引）
  - 沙盒 `tmp/`（NSTemporaryDirectory）仍可全量清（私有、语义可丢）
- **规则**：**禁止用文件系统直接删 `Library/Caches` 根目录**。网络缓存清理必须走对应库/系统的 API（如 `URLCache.shared.removeAllCachedResponses()`、`flutter_cache_manager.emptyCache()`），不能 unlink 它正在打开的文件
- **相关代码**：`lib/services/temp_cleanup_service.dart`（前缀白名单 + `nameFilter`）、`lib/screens/settings_screen.dart`（`_clearNetworkImageCache`）
- **修复时间**：2026-06-17

### 7.6 just_audio：整篇循环依赖 completed 事件做反应式计数不可靠

- **现象**：Free Player 整篇循环重复设 3 遍只播 2 遍就停；播完后播放/暂停按钮仍显示「暂停」图标；播完后点两下按钮却从最后一句开始播
- **根因**：整篇连续播放（gapless）此前监听 `playerStateStream` 的 `ProcessingState.completed` 做「计数 +1 后 seek 回开头重播」。just_audio 有两个与该设计冲突的语义——
  - **`AudioPlayer.playing` 在自然播完（completed）后仍为 `true`**：播放/暂停按钮直接读 `engine.isPlaying`(=`_audioPlayer.playing`)，播完瞬间就误显「暂停」
  - **`completed` 事件可能重复/滞后到达**：重启后到达的陈旧 completed 会让计数多 +1，`shouldLoopWhole` 提前返回 false → 提前停止。`_handlingWholeCompletion` 闸门只挡得住「处理中重入」，挡不住「重启后到达的滞后事件」
  - 连带 bug③：图标错显「暂停」→ 首击触发 `pause()`（清掉 `_awaitingReplayFromStart`）→ 次击 `play()` 不再从头重播，而从当前（末）句起播
- **解法**：放弃反应式 completed 计数，改为与单句循环一致的**确定性 await-完成循环**——
  - 新增引擎原语 `AudioEngine.playToEnd(sid)`：`play()` 后 `await playerStateStream.firstWhere(completed || 失效)`，每个自然结束只解析一次 await，对重复/滞后 completed 天然免疫
  - `_playWholeDriven` 协程里循环 `await playToEnd` → 遍数 +1 → `shouldLoopWhole` 判停/回卷；暂停续播、模型交接、seek 续播都重新拉起该协程
  - 图标改由 controller 持有的**逻辑播放态** `ListeningPracticeState.isPlaying`（在起播/暂停/停止/自然播完入口显式维护）驱动，**不读** just_audio 的 `playing`
- **规则**：
  - **「播 N 遍后停」「播完该停」这类有限循环不要监听 `completed` 事件反应式推进**，要用 `await playToEnd/playClipOnce` 的确定性协程循环计数（同 §7.1/§7.2「不依赖音频库回调隔离 session」）
  - **播放/暂停按钮图标的真相源是 controller 的逻辑播放意图，不是音频库的瞬时 `playing` 标志**（completed 后 `playing` 仍为 true）
- **相关代码**：`lib/providers/audio_engine/audio_engine_provider.dart`（`playToEnd` / `processingState`）、`lib/providers/listening_practice/listening_practice_provider.dart`（`_playWholeDriven` / `_startWholeDriven` / `_setLogicalPlaying`）、`lib/models/listening_practice_state.dart`（`isPlaying`）、`lib/widgets/playback_controls.dart`
- **修复时间**：2026-06-23
- **补充（2026-06-25）：恢复进入时存档位置停在结尾被误判为「续播」**
  - **现象**：上次播到结尾的音频再次进入 player，无字幕需点两次播放才从头播（首次从结尾起播立即结束）；有字幕首次点击从最后一句起播而非音频开头
  - **根因**：`_restorePlaybackState` 把引擎 `seek` 到存档位置（=结尾）。此时 `processingState` 是 `ready`（**非 `completed`**——completed 只在本 session 内真正播到尾才触发），且 `_awaitingReplayFromStart` 为 false。「续播 vs 从头」启发式 `processingState != completed && position > 0` 据此误判为续播
  - **解法**：新增 `AudioEngine.totalDuration` getter 与 `_isAtAudioEnd()`（`currentPosition` 接近总时长即视作已播完）。无字幕 `_startNoTranscriptPlayback` 续播判定加 `!_isAtAudioEnd()`；有字幕 `play()` 的「已播完重播」分支条件改为 `_awaitingReplayFromStart || _isAtAudioEnd()`，结尾态统一走 `_restartFromPlayableBeginning`
  - **规则**：`completed` 事件只反映「本 session 播到尾」，**不能**用来识别「恢复进入时存档位置就在结尾」——后者必须用 `位置 ≈ 总时长` 判断。读实时 `currentPosition` 而非依赖标志位，天然兼容「拖动进度条到中间后再播」

### 7.7 锁屏：向系统上报 `completed` 导致整篇循环进度条偶发卡在结尾

- **现象**：整篇循环时，锁屏 Now Playing 进度条偶发卡在「上一遍结束位置」（满格、暂停图标=系统认为在播），但音频已开始播下一遍。大部分正常，无固定触发条件
- **根因**：锁屏进度完全由 `audio_service` 的 `playbackState` 驱动（无自定义 `MPNowPlayingInfoCenter`）。`_broadcastState()` 在每个 just_audio `playbackEvent` 上把 `_player.position/playing/processingState` 原样广播。一遍自然播完时 just_audio 进入 `completed` 且 `playing` 仍为 true（见 §7.6），广播出 `position≈end + playing=true + processingState=completed`。`completed`（已结束）标志让 iOS 把曲目当作播完、进度条钉在结尾；随后 `_playWholeDriven` 回卷 `seek(0)` 时 just_audio 仍停在 `completed`（要等下一遍 `play()` 才转 ready），系统在「已结束」态下忽略 position=0 更新，进度条继续卡结尾。能否纠正取决于 completed→ready 转换与 stale 终结事件的到达时序——故偶发（同 §7.1/§7.2/§7.6：不可依赖音频库事件顺序跨 session/循环边界）
- **解法**：`_mapProcessingState` 把 `ja.ProcessingState.completed` 映射为 `AudioProcessingState.ready`。本 app 是循环播放器，对系统从不真正「结束」——系统永远看不到 completed 标志，回卷 seek/下一遍 position 更新都在 ready 态下被正常接受
- **规则**：锁屏/系统媒体会话**不上报 `completed`**。app 内部所有 `completed` 判定（循环计数、`_isAtAudioEnd`、续播 vs 从头）都读**原始 `_handler.player.processingState`**，不读 audio_service 广播态，故该映射对内部逻辑零副作用
- **相关代码**：`lib/services/background_audio_handler.dart`（`_mapProcessingState`）
- **修复时间**：2026-06-25

### 7.8 release 资源压缩删掉通知图标，锁屏/通知栏媒体控件整体消失（仅 release）

- **现象**：`flutter run`（debug）锁屏/通知栏媒体控件正常；GitHub CI 编出的 release 包播放时**不显示媒体通知**，取而代之是系统通用前台服务占位通知「"Echo Loop"正在运行 / 点按即可了解详情或停止应用」。影响所有播放场景（不止 Free Player），small icon 是全局媒体通知图标
- **排查方法论（重要）**：症状先验证机制——读 audio_service Android 源码确认媒体通知只在 `playing` false→true 经 `enterPlayingState()` → `startForeground(buildNotification())` 创建；系统占位通知 = `startForegroundService()` 调了但紧接的 `startForeground(媒体通知)` 没成功（抛异常）。**纯静态分析定位不到**（Dart 侧推演不出），最终靠 `unzip -p APK resources.arsc | strings | grep 资源名` 对比 debug/release 包资源表锁定：release 的 arsc 里**没有 `ic_stat_logo` 资源名**（对照 `audio_service_*`、`ic_launcher` 都在）。验证用的是 CDN/CI 实际产物，不是本地旧包（旧包早于改动会误判）
- **根因**：`androidNotificationIcon: 'drawable/ic_stat_logo'` 这个 small icon **只在 Dart 里以字符串运行时引用**（audio_service 内部 `getResources().getIdentifier()` 动态查找），无任何代码/XML 静态引用。release 的 R8 资源压缩器（`shrinkResources`，本项目 release 默认开启，资源还被混淆成 `res/XX.png`）据此判定「未使用」并从 APK 删除 → 运行时 `getIdentifier` 返回 **0** → `setSmallIcon(0)` → `startForeground` 抛 "Bad notification: Couldn't create icon" → 媒体通知建不起来。debug 不压缩资源故无此问题
- **解法**：新建 `android/app/src/main/res/raw/keep.xml`，用 `tools:keep="@drawable/ic_stat_logo"` 把图标加入资源压缩白名单，使其在 release 包保留、`getIdentifier` 可解析
- **规则**：**任何只通过运行时字符串名（`getIdentifier`/插件配置）引用、无静态引用的 Android 资源，都必须在 `res/raw/keep.xml` 里 `tools:keep`**，否则 release 资源压缩会删掉它。这类问题 debug 永远不复现，必须用 release 包 + 查 `resources.arsc` 资源表验证
- **相关代码**：`android/app/src/main/res/raw/keep.xml`、`lib/services/background_audio_handler.dart`（`androidNotificationIcon`）、`android/app/build.gradle.kts`（release R8）
- **修复时间**：2026-06-25

### 7.9 录音类任务抑制锁屏的三个坑（iOS MediaItem/position 通道 + Android「先 load 后 suppress」时序）

> **已被 §7.12 引擎拆分架构性取代（2026-06-27）**：`setMediaSessionSuppressed` 整套已删除，录音/复习类任务改用不接 `audio_service` 的前台引擎，物理上不弹卡片。本节保留为历史教训：运行时 suppress 开关对抗系统两条通道+事件时序极脆弱。

- **现象**：难句跟读 / 段落复述等录音强交互任务进任务时已调 `setMediaSessionSuppressed(true)`，但锁屏/通知栏 now-playing 卡片仍显示。三处根因独立，需逐一修；难句跟读修完前两处即好，段落复述还需第三处
- **排查方法论**：读 audio_service iOS 源码（`AudioServicePlugin.m`）确认锁屏卡片由**两条独立通道**驱动——① playbackState（`setState`→`updateControls`/`updateNowPlayingInfo`）；② MediaItem（`setMediaItem`→`updateNowPlayingInfo`→`MPNowPlayingInfoCenter.nowPlayingInfo=…`）。iOS 清卡片的**唯一**入口是 native `stopService`（把 `nowPlayingInfo` 置 nil），而 Dart 侧（`audio_service.dart` `_observePlaybackState`）**只在 `processingState` 发生 `非idle→idle` 跳变那一次**才调 `stopService`；`setMediaItem` 本身**从不清卡片，只会重新填充**
- **根因（两处，需同时修）**：
  - **① MediaItem 通道未抑制**：`background_audio_handler.dart` 两处 `mediaItem.add`（`loadFile` 设标题/封面、构造函数 duration 监听回填）未受抑制约束。进录音任务时音频经共享 handler 加载 → native `setMediaItem` 把卡片填回锁屏；即使 playbackState 是 idle（按钮被禁用），卡片本体照样可见。**先修这处，难句跟读（播完一句即等录音、position 不持续变）即好**
  - **② 抑制广播透传实时 position（iOS）**：`_broadcastState` 抑制分支原样发 `updatePosition: _player.position`。iOS `setState`（`AudioServicePlugin.m`）在「playing/speed/position 任一变化」时调 `updateNowPlayingInfo` → 用插件**本地仍存的**标题/封面把 `nowPlayingInfo` 写回系统（`stopService` 只清系统侧、不清本地字典）→ **连续播放（段落复述整段连播）时卡片随 position 反复复活**
  - **③「先 load 后 suppress」时序（Android 尤其明显）**：`enterRetellMode` 原本先 `_ensureAudioLoaded`（loadFile 此时 suppress 还是 false → 走非抑制广播：ready/playing:false/position 0/controls[play,stop] + setMediaItem 设标题）再 `initialize` 才 suppress。Android `AudioService.java` 的 `setState` 仅在 `notificationCreated && processingState!=idle && notificationChanged` 时 `updateNotification()` 贴通知 → loadFile 那次非抑制广播把通知贴出。后续 suppress 的 idle 广播在多数路径能靠 `非idle→idle` 跳变触发 `stop()`→`cancel`，但此时序下通知已贴出且不稳定移除。**难句跟读没这问题，因为它 `initialize` 开头第一行就 suppress、早于任何 load**
- **解法**：抑制态下把会触发系统重绘的来源**全部挡住**，且**抑制必须早于音频加载**——
  - gate 两处 `mediaItem.add`（`if (!_mediaSessionSuppressed)`）
  - 抑制广播发**恒定** `updatePosition: Duration.zero` / `bufferedPosition: Duration.zero` / `speed: 1.0`（不透传实时值），让系统认为「无变化」不再 `updateNowPlayingInfo`
  - **`enterRetellMode` 把 `setMediaSessionSuppressed(true)` 提到 `_ensureAudioLoaded` 之前**，与难句跟读「先 suppress 再 load」对齐；provider `initialize` 内的 suppress 保留为幂等兜底
  - `setMediaSessionSuppressed(false)` 退任务时重发当前 MediaItem，把被 `stopService` 置 nil 的 native `nowPlayingInfo` 为后续任务恢复（下一次 `playing:true` 广播会重新激活 commandCenter）
- **规则**：
  - **「隐藏锁屏」要堵死所有会写系统媒体会话的通道**——iOS：`setMediaItem`（mediaItem.add）+ `setState` 的 position/playing/speed 变化；Android：`setState` 在非 idle 时的 `updateNotification`。缺一不可
  - **录音类任务必须「先 suppress 再 load 音频」**，否则 loadFile 会以非抑制态把卡片/通知贴出；事后再抑制不一定能干净移除（尤其 Android）
  - app 共用单个全局 handler/player，「播音不上锁屏」做不到「不碰媒体会话」，只能靠主动抑制；抑制对 app 内部零副作用（内部读原始 `_player` 状态，不读广播态，同 §7.7）
- **相关代码**：`lib/services/background_audio_handler.dart`（`setMediaSessionSuppressed` / `_broadcastState` 抑制分支 / `loadFile` / 构造函数 duration 监听）、`lib/providers/learning_session/learning_session_provider.dart`（`enterRetellMode` 先 suppress 再 load）、`lib/providers/listen_and_repeat/listen_and_repeat_controller.dart`（`initialize` 开头即 suppress）；参照 `audio_service-0.18.18` 的 `AudioServicePlugin.m`（iOS）/ `AudioService.java`（Android setState→updateNotification/stop）/ `audio_service.dart`（`_observePlaybackState` idle 跳变才 stopService）
- **修复时间**：2026-06-27

### 7.10 学习任务后台播放：静音保活音量必须 1.0；锁屏切句回调每任务绑一次

- **现象**：Free Player / 逐句精听 / 全文盲听 锁屏后暂停（不再自动推进到下一句/下一段）；锁屏「上一句/下一句」有时不起作用。3228c91f 时正常
- **根因（两处独立）**：
  - **① iOS 静音保活 `setVolume(0)` 无效**：句间/段间停顿由 `CountdownController` 的 Dart `Timer` 计时。iOS 锁屏后 app 被挂起则 `Timer` 冻结 → 停顿结束不推进 → 表现为「锁屏后暂停」。为此引入「停顿期循环播静音轨保活」让 app 不挂起，但 `startKeepAlive` 把保活轨设成 `setVolume(0)` —— **iOS 把「零输出」视作「未在播放」仍会挂起 app**，保活失效。Android 不受影响（靠前台服务 + 广播 `playing:true` 保活，定时器照跑）
  - **② 锁屏切句回调「按活跃 phase 条件 bind」留空窗**：精听/盲听原本在 `_onBlindFlowStateChanged` 里「仅活跃 phase 调 `bindLockScreen`」，非活跃瞬间回调槽状态不稳定 → 锁屏切句偶发失灵
- **解法**：
  - **保活音量 `0 → 1.0`**：静音内容本身无声、用户听不到，但「会话持续渲染音频」才能让 iOS 不挂起、Dart 倒计时在后台照常推进，实现「整个会话锁屏后自动跑完」。保活生命周期由 `setSessionActive(active)` 维护：自动推进（播放中或停顿倒计时）期间 `active=true` 跑保活，暂停/完成 `active=false` 停保活（省电）
  - **锁屏回调每任务绑一次**：`bindLockScreen` 移到 `initialize`/`initializeParagraphs` 调一次（回调是稳定的 notifier 方法），整段任务期间切句始终可用；`_onBlindFlowStateChanged` 只留 `setSessionActive(active)` 管保活+图标
- **录音类任务（跟读/复述/补练）**：进任务 `setMediaSessionSuppressed(true)` 隐藏锁屏（§7.9），且**不**绑锁屏、**不**起保活 → 不进后台、不上锁屏。补练（`review_difficult_practice`）此前在盲听子流程里会 `bindLockScreen`+`setSessionActive`，§7.10 一并去掉（音量改 1.0 后它会让补练意外后台保活）
- **规则**：
  - **iOS 后台保活的静音轨音量必须 > 0**（用静音内容、非零音量），`setVolume(0)` 不阻止挂起
  - 「整个会话后台自动跑完」靠：iOS = 持续渲染的保活轨让 app 不挂起；Android = 前台服务 + 广播 `playing:true`。停顿仍由 Dart `Timer` 计时，保活只保证它在后台照跑
  - 锁屏控制回调按**任务生命周期**绑定（进任务绑、离任务清），不按播放 phase 频繁切换
  - 保活双 player 与 §7.1/7.2/7.6 的「双 player 跑内容/事件竞态」不同：它是被动的会话持有者，不接入媒体会话、锁屏只反映主 player
  - **iOS 后台挂起行为本机/CI 测不到，必须真机验证**「停顿跨锁屏能否自动推进到下一句」
- **相关代码**：`lib/services/background_audio_handler.dart`（`startKeepAlive` 音量 1.0）、`lib/providers/learning_session/study_background_playback_mixin.dart`（`setSessionActive`/`bindLockScreen`/`unbindLockScreen`）、`intensive_listen_player_provider.dart` / `blind_listen_player_provider.dart`（bind 移到 initialize）、`review_difficult_practice_provider.dart`（盲听子流程去 bind/保活）
- **修复时间**：2026-06-27

### 7.11 录音类任务仍显示锁屏：suppress(false) 在 idle 时重发 MediaItem 贴出无法清除的残留卡片

> **已被 §7.12 引擎拆分架构性取代（2026-06-27）**：suppress 已删除，本节保留为历史教训。

- **现象**：难句跟读 / 段落复述虽已先 suppress 再 load（§7.9），锁屏 now-playing 卡片仍显示。学习计划里「跟读 → 复述」背靠背时尤为明显
- **根因**：iOS 清卡片唯一入口是 audio_service 在 `processingState` **非idle→idle 跳变那一次**调 `stopService`（`audio_service.dart:1132`，置 `nowPlayingInfo=nil`）。而 `setMediaSessionSuppressed(false)` **无条件**重发 MediaItem——录音任务退出（`disposeSession`/`disposePlayer`）时主 player 已被 `stopSession()` 停成 **idle**，此时 `mediaItem.add` 经 native `setMediaItem` 立刻贴出卡片（`AudioServicePlugin.m:222` 必定 `updateNowPlayingInfo`），但此后 player 长期停在 idle，**再无 非idle→idle 跳变**，卡片无法被清除。下一个录音任务 `suppress(true)` 广播 idle 时 `previousState` 已是 idle → 不触发 stopService → 卡片继续显示
- **解法**：`suppress(false)` 仅当主 player **非 idle**（音频仍已加载/活跃、将来停止会产生可清除跳变）时才重发 MediaItem；idle 时跳过——native 仍保留 mediaItem 静态值（`stopService` 不清它，`AudioServicePlugin.m:230-241`），下一次真正播放的 `playing:true` 广播会经 `setState`→`updateNowPlayingInfo` 自动回填卡片
- **规则**：**每一次 `mediaItem.add`（创建卡片）都必须配对一个将来必然到来的 非idle→idle 跳变**，否则卡片无法清除。退抑制重发卡片要 gate 在「player 非 idle」，不能无条件重发
- **相关代码**：`lib/services/background_audio_handler.dart`（`setMediaSessionSuppressed` 非 idle gate）；测试 `test/services/background_audio_handler_test.dart`（idle 不重发 / 非 idle 重发 / 录音→录音背靠背无残留）
- **修复时间**：2026-06-27

### 7.12 媒体引擎 / 前台引擎分离：把「是否上锁屏」做成结构性属性而非运行时开关

- **背景**：§7.7–7.11 全部锁屏 bug 同源——所有播放场景共用同一个接入 `audio_service` 的 `AudioPlayer`，靠运行时开关 `setMediaSessionSuppressed` 决定录音类任务是否隐藏锁屏。这个开关要同时对抗系统两条独立通道（playbackState + MediaItem）和跨 session/循环边界的事件时序，地鼓打不完
- **解法（ADR-7）**：拆成两套**不共享 player** 的引擎，把「是否绑定系统媒体会话」变成**用哪个引擎**的物理属性：
  - **媒体引擎** `AudioEngine` → `echoLoopAudioHandler._player`，接 `audio_service`（锁屏/后台/静音保活/逻辑播放态）。用户：逐句精听、全文盲听、Free Player
  - **前台引擎** `ForegroundAudioEngine`，自持裸 `ja.AudioPlayer`，**从不注册到 `audio_service`**，物理上碰不到 `MPNowPlayingInfoCenter`/前台通知。用户：难句跟读、段落复述、难句补练、收藏句复习、收藏词复习
  - 前台引擎逐方法照抄媒体引擎的播放子集（session 守卫 / setClip→seek(0)→play / await-完成），仅把 `_handler.xxx` 换成裸 `_player.xxx`，保证录音类任务播放/录音功能行为不变
  - 进前台任务时调一次**媒体引擎 `stop()`**（`非idle→idle` 跳变 → audio_service `stopService` 清锁屏卡片），取代旧 suppress
  - `setMediaSessionSuppressed` 及 handler 的 `_mediaSessionSuppressed` 整套删除
- **规则**：
  - **「某类任务要不要上锁屏」应由「用哪个引擎」表达，不要用运行时 flag 抑制共享 player** —— 后者必然要追着系统多通道+事件时序打补丁（§7.9/7.11 的反复）
  - 录音"采集"（`RecordingService`/`SpeechRecordingController`）与"回放用户录音"（`AudioPlaybackService`，独立 player）本就独立于引擎，不受本次影响
  - 无需 `PlaybackEngine` 接口：不存在「被媒体任务和前台任务按同一引擎类型共用」的编排代码（`SentencePlaybackEngine`/`StudyTaskControllerMixin` 的消费者全在前台侧），直接改类型/改调用点
- **相关代码**：`lib/providers/audio_engine/foreground_audio_engine_provider.dart`（新）、`sentence_playback_engine.dart`/`study_task_controller_mixin.dart`（改类型）、`learning_session_provider.dart`（`_ensureAudioLoaded(foreground:)` + 进任务 stop 媒体引擎）、5 个前台任务 provider（改引擎 + 去 suppress/bind/保活/mixin）、`audio_engine_provider.dart` + `background_audio_handler.dart`（删 suppress）
- **风险（待真机验证）**：iOS `AVAudioSession` 进程级共享，两个 player + 录音器对 category（playAndRecord）的争用本机/CI 测不到
- **修复时间**：2026-06-27

### 7.13 段落播放：position 追踪订阅早于 seek(0) 落定 → 高亮乱跳、断点被覆盖成首句

- **现象**：段落复述 / 全文盲听打开一段时偶发——当前选中（高亮）句突然乱跳，最终回到第一句起播（预期应从断点恢复处起播，已播完才从首句起播）
- **根因**：段落级 `_playCurrentParagraph` 先**同步**订阅 `absolutePositionStream`（`_startPositionTracking`），之后才 `await playRangeOnce`。而 `playRangeOnce` 内部按序做 `copyWith(clipStart=start)` → `setClip` → `seek(0)` → `play`，`absolutePositionStream = positionStream.map((rel) => clipStart + rel)`。在「订阅完成」到「seek(0) 落定」这段窗口里，位置流发出陈旧 position（旧 clipStart+旧 rel、或新 start+旧 rel），被 `_findSentenceIndex` 反查成错误句号 → ① 反复改写 `playingSentenceIndex`（乱跳）② 每次改写都 `_persistCurrentSentenceIndexAsync()` 写盘，陈旧 0 落在本段首句之前被 clamp 成 index 0 → **把断点覆盖成首句**（下次打开真从首句起播）③ 若开静音跳过，陈旧 position 经 `_maybeSkipSilence` 触发 `seekToAbsolute` 把音频 seek 走。竞态码自 578f8829 未变，§7.12 引擎拆分把复述切到 keepAlive 前台引擎（跨任务留旧 position + `_ensureAudioLoaded` 对同一音频跳过重载）后从潜在转为高频复现
- **解法**（同 §7.6「确定性 await，不依赖音频库回调时序」）：
  - 两个引擎 `playRangeOnce` 加 `onClipReady` 回调，在 `seek(0)` 落定、`play()` 之前回调一次；调用方此刻才 `_startPositionTracking`——位置流此后发出的是 seek 后的新位置（rel≈0 → 绝对位置≈start），从源头消除陈旧窗口
  - 监听器开头加越界丢弃兜底：position 落在 `[首句.start, 末句.end]` 外直接 return，绝不改高亮 / 写断点 / 触发静音跳过（防 seek 后仍残留一次旧 emission）
- **规则**：**段落/区间播放的 position 追踪必须等 `seek(0)` 落定后才订阅**（用 `onClipReady` 回调时机，不在 `playRangeOnce` 之前订阅）；监听器对越界 position 一律丢弃，不可让其改高亮或写断点
- **相关代码**：`lib/providers/audio_engine/foreground_audio_engine_provider.dart` / `audio_engine_provider.dart`（`playRangeOnce` 的 `onClipReady`）、`lib/providers/learning_session/retell_player_provider.dart` / `blind_listen_player_provider.dart`（`_playCurrentParagraph` 订阅后移 + `_startPositionTracking` 越界丢弃）
- **修复时间**：2026-06-27

### 7.14 盲听会话内中断用 stop（idle）反复拆/重建系统媒体会话 → 锁屏控件失效

- **现象**（iOS + Android 都有）：① 盲听锁屏「上一句/下一句」按钮可见但点击**无反应**；② 锁屏媒体控件有时不显示——冷启动后正常，用一段时间后就不再出现。精听无此问题
- **根因（单一根因，两处表现）**：锁屏卡片/控件的销毁由 **`processingState` 跳到 `idle`** 驱动——audio_service 监听到 `非idle→idle` 跳变即调 `stopService`（`audio_service.dart:1132`）→ iOS 把 `MPRemoteCommandCenter` 置 nil、移除全部命令 target、清 `nowPlayingInfo`（`AudioServicePlugin.m:230`）；Android 撤前台服务通知。`EchoLoopAudioHandler.stop()` 内 `_player.stop()`→idle→`_broadcastState()` 广播 idle，`AudioEngine.stopPlayback()/stop()` 都走它。**关键不对称**：精听每次中断走 `engine.pause()`→`pausePlayer()`（**非 idle**，不拆会话）；盲听每次暂停/切段/seek/改设置都走 `engine.stopPlayback()`（**idle→stopService**），于是每中断一次就把整个系统媒体会话拆掉再重建——拆掉后命令 target 被移除 → prev/next 死按钮（Bug②）；反复拆建、恢复依赖随后非 idle 广播精确落地、时序不稳 → 卡片偶发不再出现（Bug①，冷启动尚未拆除故正常）
- **解法**：盲听「会话内中断」与精听对齐——`engine.stopPlayback()` 改 `engine.pauseKeepSession()`（=`pausePlayer`，非 idle、不拆会话；session 已由调用点 `newSession()` 自行失效，故用不再 bump 的 `pauseKeepSession`）。共 4 处：`pause()` / `enterWaitingForUser()` / `updateSettings()` 模式切换 / `_cancelAll()`（被 seek/切段/重听共用）。**真正退出**（exitLearningMode → `practice.stop()` → idle）仍负责清卡片，不受影响
- **规则**：**接 audio_service 的媒体引擎，会话内的暂停/切句/seek 一律用 pause（非 idle），不能用 stop（idle）**——stop 只留给「真正退出该播放会话」。否则每次中断都触发 stopService 拆/重建系统媒体会话，锁屏控件失灵。录音类前台引擎不接 audio_service，不受此约束
- **相关代码**：`lib/providers/learning_session/blind_listen_player_provider.dart`（4 处 `stopPlayback`→`pauseKeepSession`）；对照 `intensive_listen_player_provider.dart`+`blind_practice_flow_engine.dart`（`callbacks.pauseAudio`→`engine.pause`）；`audio_engine_provider.dart`（`pauseKeepSession`/`stopPlayback`/`stop`）
- **修复时间**：2026-06-29
- **真机验证**：iOS/Android 锁屏点上一句下一句应正确切段；多次暂停/切段 + 长时使用后卡片仍显示；录音任务卡片仍消失、退出回 Free Player 正常

### 7.15 段落分段播放（clip）锁屏进度每切句归零：必须上报「绝对位置 + 全曲时长」

- **现象**：全文盲听点上一句/下一句，锁屏 now-playing 进度条总被清零
- **根因**：盲听每段用 `playRangeOnce` → `setClip(start,end)` 播放。just_audio 在 clip 下 `player.position` 是**相对 clip 起点**（切句重设 clip + `seek(0)` → 归零）、`player.duration` 是**clip 长度**。handler 此前直接广播 `updatePosition: _player.position` + duration 监听用 `player.duration` 覆盖 `mediaItem.duration` → 锁屏拿到「clip 相对位置 / clip 长度」，每切一段就归零
- **解法**：handler 记 `_clipStart`/`_clipActive`/`_fullDuration`——`setClip` 写入 clip 起点与激活态，`loadFile` 解析并复位全曲时长；`_broadcastState` 上报 `updatePosition = _clipStart + _player.position`（+ bufferedPosition 同理）；duration 监听在 clip 期间不让 clip 长度覆盖 `mediaItem.duration`，保持全曲时长。无 clip 时 `_clipStart=zero`，Free Player 整曲行为不变
- **规则**：**接 audio_service 的 clip 分段播放，锁屏进度必须上报「全曲绝对位置 + 全曲时长」，不能直接用 just_audio 的 clip 相对 position / clip 长度 duration**（否则切片即归零）。app 内进度走 `engine.absolutePositionStream`（已是 clipStart+rel），与本次锁屏修复同源不同通道
- **注意**：锁屏「拖动进度条」(`changePlaybackPositionCommand` → `handler.seek`) 仍是 clip 相对语义，与现上报的绝对位置不一致——盲听/精听未用此交互，属既有遗留，未在本次处理
- **相关代码**：`lib/services/background_audio_handler.dart`（`_clipStart`/`_clipActive`/`_fullDuration`、`setClip`/`loadFile`/`_durationSub`/`_broadcastState`）；测试 `test/services/background_audio_handler_test.dart`（clip 绝对位置 / 切段不归零 / clearClip 回退）
- **修复时间**：2026-06-29

### 7.16 停顿倒计时锁屏进度条仍前进、下一段又回退：必须上报 `speed=0` 冻结

- **现象**：全文盲听段落播完进入段间停顿倒计时期间，锁屏 now-playing 进度条仍持续往前走（越过段尾），下一段起播又回退
- **根因**：停顿期靠 `setSessionActive(true)` 保持 `_logicalPlaying=true`（锁屏图标显示「播放中」+ 静音保活让 Dart 倒计时后台推进）。`_broadcastState` 据此广播 `playing:true` + `speed:_player.speed`(>0)。iOS `MPNowPlayingInfoPropertyPlaybackRate = playing ? speed : 0`，rate>0 时系统按**墙钟时间外推** `elapsedPlaybackTime`（`AudioServicePlugin.m:288`），进度条自行前进；下一段 `setClip` 复位 `updatePosition` → 回退。问题本质是 iOS 端外推，主 player 实际已停在段尾
- **解法**：停顿期广播 `speed:0.0`（新增 `_progressFrozen` 开关），iOS rate=0 即不再外推，进度停在当前 `updatePosition`（段尾）；`playing` 仍读 `_effectivePlaying`(=true) 保持图标「播放中」——因 iOS 播放/暂停图标由 `center.playbackState`(读 `playing`，`AudioServicePlugin.m:294`) 驱动，与 rate 解耦。段落连续，下一段从段头(≈上段段尾)起播，无回退。`setProgressFrozen` 经 engine→mixin 暴露，provider 在 `_startPauseCountdown` 置 true、`_playCurrentParagraph`(实际起播) 置 false；`unbindLockScreen`/`loadFile` 复位 false 防泄漏到 Free Player
- **规则**：**「图标显示播放中但音频实际不前进」的场景（停顿倒计时）必须广播 `speed=0` 冻结锁屏进度**——iOS 进度外推只认 playbackRate，不能靠 `playing:false`（会误把图标切成暂停、且停保活）。图标真相源是 `playing`，进度外推真相源是 `speed`，二者要分别控制
- **相关代码**：`lib/services/background_audio_handler.dart`（`_progressFrozen`/`setProgressFrozen`/`_broadcastState` speed 分支）、`lib/providers/audio_engine/audio_engine_provider.dart` + `study_background_playback_mixin.dart`（passthrough + unbind 复位）、`lib/providers/learning_session/blind_listen_player_provider.dart`（`_startPauseCountdown` 冻结 / `_playCurrentParagraph` 解冻）；测试 `test/services/background_audio_handler_test.dart`（冻结 speed=0 / 图标不变 / 段尾位置不归零）
- **注意**：逐句精听（`intensive_listen_player_provider`）句间倒计时同属此类，本次未改；句子短、漂移小，如有反馈再按同法接 `setProgressFrozen`
- **修复时间**：2026-06-29
- **补充（2026-06-29）：Free Player 同源接入**
  - **现象**：Free Player（`ListeningPractice`）句间循环/整篇循环之间的停顿期间，锁屏进度条同样仍前进、下一遍起播又回退——与精听/盲听修复前同源。Free Player 走同一媒体引擎但从未调过 `setProgressFrozen`
  - **解法**：Free Player 所有停顿延迟唯一收敛到 `_delayInterval(interval)`（整篇/无字幕整篇/单句重播/跳句/gapless 交接 5 处调用点全经此）。在此单点包裹：延迟前 `_engine.setProgressFrozen(true)`、`finally` 中 `setProgressFrozen(false)`。`interval==0` 不触碰，`finally` 保证延迟异常/会话作废也不残留冻结态
  - **相关代码**：`lib/providers/listening_practice/listening_practice_provider.dart`（`_delayInterval`）；测试 `test/providers/listening_practice/free_player_playback_flow_test.dart`（「整篇循环间隔」用例断言停顿期 `progressFrozen==true`、起播后 `==false`）

### 7.17 合集内详情路由拍平在顶层 → 返回后自动多退一层（学习计划页 → 资源库）

- **现象**（Android 16 / Honor MagicOS）：随心听播放器点返回，先短暂停在学习计划页，随即**自动**又退到资源库列表页（合集 tab 根）。期望停在学习计划页
- **根因**：`app_router.dart` 把合集内音频详情页（学习计划 / 各播放器）声明成 **`StatefulShellRoute` 的顶层兄弟路由**（带 `parentNavigatorKey: rootNavigatorKey`），但路径 `/collections/:c/:a/plan` 与 branch-0 的 `/collections` 前缀重叠。正常入栈 `[Shell(branch-0=合集详情), plan, player]` 里，「合集详情」这一层是 imperative push、**只存在于页面栈、不编码进 URI**。go_router 17 在 `restoreRouteInformation` 后把当前 URI 回报框架；框架以 **null state** 回灌时（Android 生命周期/前台播放服务窗口焦点抖动触发），parser 走「合成 go → `findMatch(uri)` 从零重建栈」，而 `/collections/:c/:a/plan` 只匹配到顶层 plan 路由，shell 分支被重置回初始 location（资源库根），合集详情丢失。随后那一次返回 pop 掉 plan 就落到资源库根
- **解法**：把 7 条 `/collections/:c/:a/*`（plan/player/blind-listen/intensive-listen/listen-and-repeat/retell/review-difficult-practice）下沉为 branch-0 里 `:collectionId` 的**相对路径子路由**（`:audioId/plan` 等），**保留各自 `parentNavigatorKey: rootNavigatorKey`** 继续全屏无 tab bar。这样 URI 经由 shell 匹配、合集详情是匹配链里的真实祖先，重解析/恢复能重建出 `/collections/c1`，分支不再塌回根。`AppRoutes.*` 生成的字符串一字不变 → 调用点零改动。`/audio/:audioId/*` 系列不与任何分支前缀重叠，保持顶层不动
- **规则**：**`StatefulShellRoute` 全屏子页（带 rootNavigatorKey）若路径与某分支前缀重叠，必须嵌套在该分支子树内、用相对路径**，不能拍平成顶层兄弟路由——否则 null-state 重解析会按 URI 重建而丢失 imperative push 的中间层，把分支重置回初始 location。「是否上 tab bar」由 `parentNavigatorKey` 表达，「属于哪个分支」由路由树嵌套表达，二者解耦
- **相关代码**：`lib/router/app_router.dart`（branch-0 `:collectionId` 的 `routes:` 子路由）；测试 `test/router/app_router_test.dart`（嵌套结构重解析后 pop 回合集详情 / 顶层平级结构复现分支塌回根）
- **修复时间**：2026-06-29

### 7.18 统一 TTS：嵌入式发音组件不可在 provider build 期触碰平台/数据库（惰性化）

- **背景**：统一 TTS 架构（详见 PLAN.md ADR-8）。发音按钮 `SpeakButton` 是 `ConsumerWidget`，`watch(ttsControllerProvider)`；词典例句 `_ExampleView` 改 `ConsumerWidget` 内嵌它。结果：**任何宿主页面渲染发音按钮就会触发 `ttsControllerProvider.build`**。
- **现象**：初版 `ttsControllerProvider.build` 里 ① `initialTtsSettingsProvider` 未 override 时 `throw`（仿 learning_settings）② `ref.read(ttsCacheDaoProvider)` 立即连库 ③ `configure()` 立即 `engine.initialize()`（flutter_tts method channel）④ `Future.delayed` 起清理定时器。导致**多个现有 widget 测试**（词典弹窗 resize、ai_dict_result_view 等只想渲染 UI）抛 `No ProviderScope found`/`UnimplementedError`/`MissingPluginException`/pending-timer，header 拖拽布局也被异常打乱（resize 测试 24 例炸）。
- **根因**：发音是**辅助功能**，但其 provider 把"重副作用（DB/平台/定时器/必需 override）"放在 build 期同步执行，使"渲染一个喇叭图标"硬依赖整条 TTS+DB+平台栈就绪。
- **解法**（让"渲染发音按钮"零副作用，副作用全部惰性到"真正发音"时）：
  - `initialTtsSettingsProvider` 返回 `const TtsSettings()` 默认值（**不 throw**）——发音功能缺 override 时优雅降级，不崩宿主页（与 learning_settings 的"强制 override"取舍不同：那是核心流程，TTS 是辅助）
  - `TtsCacheStore` 的 DAO 改**惰性解析** `TtsCacheDao Function()`，只在 lookup/store/cleanup 真正读写时才 `ref.read(ttsCacheDaoProvider)`
  - `TtsCoordinator` 引擎**惰性创建**：`configure()` 只记录目标 kind/config（引擎已存在才热更新），首次 `speak()` 才 `_ensureEngine()` 建引擎 + `initialize`（flutter_tts 调用）+ 连库
  - 缓存清理定时器从 provider build **移到 main.dart**（`Future.delayed` 用 `database.ttsCacheDao` 直接构造，独立于 provider，widget 测试不触发 pending-timer）
  - 宿主测试该补 `ProviderScope` 的补（`ai_dict_result_view_test` 等视图现在消费 Riverpod）
- **规则**：
  - **被广泛内嵌的 Consumer 组件，其 provider 的 `build` 不得做 DB/平台通道/定时器/必需 override 等重副作用**——否则该组件的每个宿主页（含其 widget 测试）都被迫提供完整依赖栈。把副作用惰性到首次真实交互
  - 辅助功能的 initial-settings provider 倾向"默认值降级"而非"未 override 即 throw"；强制 throw 只留给核心流程（router redirect / 启动同步路径）
  - flutter_tts 在 widget 测试里调 method channel 会 `MissingPluginException`；引擎惰性化后，不点发音的测试根本不会实例化引擎，天然规避
- **相关代码**：`lib/providers/tts/tts_controller_provider.dart`（惰性 dao + 无定时器）、`tts_settings_provider.dart`（initial 默认值）、`lib/services/tts/tts_coordinator.dart`（`_ensureEngine` 惰性）、`tts_cache_store.dart`（`resolveDao`）、`lib/main.dart`（延迟 cleanup）
- **修复时间**：2026-06-28

### 7.19 macOS flutter_tts：synthesizeToFile 不设 voice，英/美音合成产物完全相同

> **已被 §7.24 取代（2026-06-30）**：不再「macOS 放弃合成 → 降级 speakLive 不缓存」，改为自家原生通道 `MacosTtsSynthHandler` 合成（正确设 voice → macOS 也缓存且口音正确）。本节保留为根因记录。

- **现象**：macOS 上切换英音(en-GB)/美音(en-US)，发音听起来没区别；iOS/Android 正常

### 7.44 纯端侧改造：删除登录/订阅后，旧测试要按功能边界删除而不是伪造登录态

- 现象：把登录页、订阅页和 paywall 路由删除后，多个旧 Widget 测试仍 import 已删除的 auth / subscription 文件，或继续构造 `signedInSession()`、订阅状态覆盖，导致编译失败。
- 根因：这些测试验证的是「登录后才能用」「订阅后才解锁」的旧产品行为；功能边界已删除后，继续补假登录态只是在维护一个不存在的门禁，测试与实现会一起漂移。
- 解法：按功能归属裁剪测试：登录/账号/订阅/paywall 的专用测试整文件删除；共享页面测试只删除依赖登录态的用例与 import，保留与其它功能共用的 helper；仍被页面引用的 provider（如 subscriptionAvailability）保留其 override，避免误删导致构建失败。
- 规则：删除产品或架构边界时，先按「这个测试在验证哪条业务规则」分类；规则已下线的测试直接删除，不要用假状态让旧断言继续通过。
- 相关代码：`test/screens/settings_screen_test.dart`、`test/widgets/import_audio_sheet_test.dart`、`test/screens/learning_plan_screen_test.dart`、`test/widgets/audio_list_tile_test.dart`。
- 修复时间：2026-11-05。

### 7.45 Android APK 构建：Gradle 9 不兼容，Gradle 8 需显式禁用 IPv6 与启用 TLSv1.2

- 现象：使用系统 Gradle 9 构建时报 Plugin [id: 'org.gradle.kotlin.kotlin-dsl', version: '6.5.2'] was not found；联网构建又在 :umeng_common_sdk 的 jcenter() 处失败。换用 Gradle 8.14.3 后，:app_links:extractReleaseAnnotations 下载 lint 工件时报 The server may not support the client's requested TLS protocol versions: (TLSv1.2, TLSv1.3) ... Remote host terminated the handshake。
- 根因：Gradle 9 已移除 jcenter 且不兼容项目的 Kotlin DSL 插件版本；Gradle 8 默认的 JVM 网络栈在本机对 dl.google.com / Maven Central 的 TLS 协商不稳定，而 curl 可正常下载同样的 jar，说明不是网络不可达。
- 解法：使用项目 wrapper 对应的 Gradle 8.14.3，并设置 GRADLE_USER_HOME=/f/devtools/gradle-home、GRADLE_OPTS=-Djava.net.preferIPv4Stack=true -Dhttps.protocols=TLSv1.2；先跑一次 :app_links:extractReleaseAnnotations 预热 lint 依赖，再执行 :app:assembleDevRelease。
- 规则：不要用系统 Gradle 9 构建本项目；构建缓存目录独立，避免污染用户全局 Gradle 缓存；缺少 android/key.properties 时只能构建 dev flavor（debug 签名），prod release 必须补 release keystore。
- 相关命令：/f/devtools/gradle/gradle-8.14.3/bin/gradle -p android :app:assembleDevRelease --max-workers=2 --no-daemon。
- 修复时间：2026-11-05。

### 7.46 retell_recording_controller_test 整文件顺序敏感：前序用例残留状态会让第 6 项 did not complete

- 现象：整文件运行 `test/providers/retell_recording_controller_test.dart` 时前 5 项通过，第 6 项「RetellRecordingController 在停止录音后触发有效录音时长回调」停在 `partialTranscriptUpdated` 后不再前进，随后 6 项均报 did not complete；单独运行第 6 项或只运行 `--name 'RetellRecordingController'` 的用例全部通过。
- 根因：第 5 项「后台取消尚未完成时的新录音等待旧启动收尾后再开始」结束时残留的录音/计时器状态污染下一项；该文件与 `lib/providers/retell_recording_controller_provider.dart` 均非本次纯端侧改动引入，具体清理时序仍待单独排查。
- 规则：该文件的失败先按「整文件顺序敏感」与「单用例编译错误/真实断言失败」区分；不要把它归因于纯端侧 AI 或设置页改动，也不要在功能收尾时用假状态掩盖。
- 相关文件：`test/providers/retell_recording_controller_test.dart`、`lib/providers/retell_recording_controller_provider.dart`。
- 修复时间：待定（记录于 2026-11-05）。

### 7.47 AI 口语第二轮点话筒无反应：单例录音器被每轮 dispose 后再也起不来

- 现象：AI 口语练习第一轮语音输入与 AI 回复的 TTS 均正常；第二次点右下角话筒没有反应，无法进入录音。页面若显示错误，会进入「语音识别失败」而不是正常录音。
- 根因：`pcmRecorderProvider` 返回单例 `RecordPcmRecorder`，而 `_cleanupAsr()` 每轮结束都对它调用 `dispose()`。`record 6.2.1` 的 `AudioRecorder.dispose()` 会通知 Android 原生侧移除该 recorder；第二轮 `startListening()` 先启动 ASR，再对同一个已释放的录音器调用 `startStream()`，原生侧报 `Recorder has not yet been created or has already been disposed.`，被 catch 后进入 `asrFailed`。
- 解法：录音器生命周期交给 provider——创建时注册 `ref.onDispose(() => unawaited(recorder.dispose()))`；每轮只 `stop()`，不再 `dispose()`；启动失败分支也只尝试 `stop()`，避免二次释放并掩盖原始异常。回归测试用「dispose 后再 start 抛 StateError」的假录音器覆盖连续两轮输入。
- 规则：**能被多轮流程复用的平台资源（录音器、播放器、通道）不要在每个业务轮次 dispose；dispose 只放在 provider/页面所有者的生命周期收尾**。每轮只做 stop/reset，否则第二轮必然拿到已释放的原生句柄。
- 相关代码：`lib/features/ai_speaking/providers/ai_speaking_session_controller.dart`（`pcmRecorderProvider`、`startListening()`、`_cleanupAsr()`）；测试 `test/features/ai_speaking/providers/ai_speaking_session_controller_test.dart`（`_SingleUsePcmRecorder`、`连续两轮语音输入都能重新开始录音`）。
- 修复时间：2026-11-12。

### 7.48 Qwen TTS 切换 flash 后合成报「语音合成请求参数有误」：音色必须与模型匹配

- 现象：AI 设置中 `qwen-audio-3.1-tts-plus` + `longanlingxin_v3.1` 合成正常；切换到 `qwen-audio-3.1-tts-flash` 后，默认音色为 `Bella`，下拉框还有 `Emily`，合成请求返回「语音合成请求参数有误」。
- 根因：旧实现把 flash 音色写死为 `['Bella', 'Emily']`，既缺少 DashScope 要求的 `_v3.1` 后缀，`Bella` 也不是 flash 的精品英文音色——`Bella_v3.1` 属于精品中文音色，其 voice 参数是 `loongbella_v3.1`。切模型时还把 `voices.first` 写回设置，导致 `model=qwen-audio-3.1-tts-flash` 与 `voice=Bella` 一起提交，DashScope 以 `InvalidParameter` 拒绝。
- 解法：按官方文档把音色收敛为模型级目录：plus 提供 4 个旗舰音色（龙安灵心/许南川/龙安欢/龙安风悦）；flash 提供「精品英文音色」15 个（Emily、Luna、Eric、Luca、Abby、Annie、Ava、Beth、Betty、Cally、Cindy、Donna、Andy、Brian、David，均带 `_v3.1`）。新增 `AiSpeechConfig.normalizeTtsModel`（只保留 flash，其余回退 plus）、`voicesForModel`（返回对应目录）与 `resolveTtsVoice`（校验当前音色，非法时回退该模型首个）。`fromPrefsSync`、`setTtsModel`、`setTtsVoice` 统一走校验：历史 flash+Bella 自动迁移为 flash+`Emily_v3.1`；切换模型时同步修正音色并持久化。设置页下拉展示「中文名 (voice 参数)」，切换模型只调用 `setTtsModel`，由 notifier 完成模型与音色的原子更新。
- 补充（2026-11-12）：flash 下拉框在英文名与 voice 参数之间展示官方口音与性别（如「Emily · 英式女声 (Emily_v3.1)」），覆盖 15 个精品英文音色；plus 暂不展示口音。
- 规则：DashScope Qwen TTS 的 `voice` 必须属于当前 `model`，不能跨模型复用；模型切换时音色选择与持久化必须原子完成，不能只改 model 留下旧 voice。
- 相关代码：`lib/features/ai_speaking/models/ai_speaking_settings.dart`（`AiTtsVoice`/`voicesForModel`/`resolveTtsVoice`）、`lib/features/ai_speaking/providers/ai_speaking_settings_provider.dart`（`setTtsModel`/`setTtsVoice`）、`lib/features/ai_speaking/screens/ai_speaking_settings_screen.dart`；测试 `test/features/ai_speaking/models/ai_speaking_settings_test.dart`（音色目录、跨模型回退、切换持久化）。
- 修复时间：2026-11-12。
