# 多开长期稳定性审计与修复记录

## 结论边界

日志和 Windows Application Error 事件显示，构建版本 **1.11.7.11107** 在 2026-11-21 20:56、21:01、21:15 时间段发生过异常退出。但现有信息不能证明这些原生异常由本次审计的 Dart 缺陷触发：该时间窗查询未发现 1002（Application Hang）事件；未取得崩溃转储或符号化调用栈。因此本文记录的是已由代码和可控回归证实的资源/并发缺陷，不把它们冒称为用户实机崩溃根因。需要原生根因时应取得对应时刻的 dump、精确二进制和符号。

## 当次运行日志与系统事件（脱敏摘要）

只读快照位于用户配置目录的三份应用日志，未复制消息正文、凭据或带签名媒体地址。日志头部报告版本 1.11.7+11107；不含 Git SHA。

| 日志文件时间 | 快照时间范围 | 行数 | INFO / DEBUG / ERROR / WARNING | FormatException | 播放打开开始/结束/关闭记录 |
|---|---|---:|---|---:|---|
| 20:56:52.log | 20:56:52–21:01:53 | 904 | 630 / 218 / 1 / 5 | 1 | 9 / 9 / 5 |
| 21:02:10.log | 21:02:10–21:15:10 | 1,583 | 1,148 / 308 / 3 / 5 | 3 | 9 / 9 / 5 |
| 21:15:36.log | 21:15:36–22:34:46（读取时仍在增长） | 7,312 | 5,336 / 1,425 / 17 / 5 | 17 | 14 / 14 / 5 |

FormatException 记录说明解析异常，不能单独解释原生崩溃。打开开始/结束计数在快照中成对；它们不证明所有底层原生生命周期均安全，也未显示资源泄漏测量。

只读查询 Windows Application Error 1000，下表应用版本均为 1.11.7.11107。异常码是事件字段，不能据此推断唯一故障机制。

| 时间 | 异常模块 / 版本 | 异常码 | 模块偏移 |
|---|---|---|---|
| 20:56:39 | permission_handler_windows_plugin.dll / 0.0.0.0 | c0000005 | 0000000000004cc9 |
| 20:56:44 | permission_handler_windows_plugin.dll / 0.0.0.0 | c000041d | 0000000000004cc9 |
| 20:56:50 | coremessaging.dll / 10.0.19041.5486 | c0000602 | 0000000000073346 |
| 21:01:53、21:15:11 | ucrtbase.dll / 10.0.19041.3636 | c0000409 | 000000000007286e |

Windows Error Reporting 1001 查询到 20:56:41、20:56:47、20:56:52 的 APPCRASH 及 21:01:56、21:15:13 的 BEX64；该时间窗未查询到 1002（Application Hang）事件。现无 dump、模块偏移对应符号或可确认的异常调用链；模块名/异常码只能作为时间关联证据。

## 已确认并修复的代码机制

1. **弹幕绘制反复产生未显式释放的原生句柄。** 密集滚动/特殊弹幕每帧创建 batch Picture，创建后绘制但不 dispose；异常中途结束记录时也可能遗留 recorder。文本测量与屏幕构建每次新建 TextPainter；弹幕过期、隐藏、清空、配置变化和屏幕卸载会丢弃 Paragraph / 特殊布局缓存，而没有一致的所有权释放。特殊弹幕内容对象可复用，不能将共享内容上的 painter 缓存简单销毁。修复把特殊布局缓存放在每条活动 DanmakuItem 上；在过期/隐藏/清除/卸载时释放对应资源，选轨后才创建 Paragraph，拒绝的消息不分配段落；测量/构建和 Picture 录制在 finally 路径清理；配置变化清除旧段落；使用一个受控周期清理计时器，暂停取消、恢复不重复创建并读取最新时长。
2. **突发设置操作会积压到会话串行队列。** 音量/静音/弹幕可见性在慢驱动上为每次变更各排一个 Future 操作；改为一个 drain 合并中间状态并最终应用最新值，任一房间最多一个原生设置调用进行中。每类设置最多保留一个待处理 Completer，另有正在执行调用的结果；不同设置分别返回成功或原始错误，一次音量失败仍继续处理可见性及后续最新目标，不自动重试。第二轮修复了第一轮共享 Future 与预先清除 dirty 标记导致的跨设置故障传播；详见返修验证。媒体发送租约和序列化器未改。
3. **同房间媒体列表快速更新可重复启动原生打开。** 现在通过运行修订号合并列表刷新；播放器打开仍在原生边界运行时超时不代表取消，失败/过期路径会等待实际 open Future 结束后再继续生命周期关闭，避免并行 open 与销毁竞争。代际校验保留，过期结果不应用音频状态。
4. **每条聊天消息安排一个 post-frame 滚动回调。** 四路消息突发时产生 40,000 个重复滚动安排。改为每个房间最多一个待执行回调，回调执行时再验证房间已关闭、嵌入式模式、滚动状态和客户端；单房间保留每帧滚动行为。

主要入口：[会话设置 drain](../simple_live_app/lib/modules/multi_live/session/multi_live_room_session.dart#L134)、[聊天帧合并](../simple_live_app/lib/modules/live_room/live_room_controller.dart#L284)、[播放列表修订 drain](../simple_live_app/lib/modules/live_room/live_room_controller.dart#L1004)、[活动项所有权](../simple_live_app/third_party/canvas_danmaku/lib/models/danmaku_item.dart#L34)、[画布移除清理](../simple_live_app/third_party/canvas_danmaku/lib/danmaku_screen.dart#L79)、[周期计时器](../simple_live_app/third_party/canvas_danmaku/lib/danmaku_screen.dart#L486)。

有界聊天缓冲区、表情图片缓存、日志脱敏实现均保留。审计还核对了会话关闭等待初始化/队列/驱动关闭、播放器原生操作集合、媒体订阅和生命周期定时器的关闭路径；既有代际守卫、Douyu 租约与共享在途去重保持不变。日志单次写入截断为 4,000 字符，debugLogs 仅在非 release 模式累计，IOSink 写入未暴露队列深度。现有日志没有磁盘积压、release 内存峰值或 OOM 指标，未发现足以证明 release 日志队列或全局缓存是此次崩溃原因的证据；未进行盲目全局缓存上限变更。

原生 open 的 Dart 超时不能取消底层调用。修复保证后续打开和销毁等待该调用结束；如果原生 Future 永远不返回，关闭仍可能等待。这一边界不能通过 Dart 超时安全地强制回收，需要原生超时/取消能力及对应实机证据。

## 可控回归证据

第一轮稳定性专项测试（当时与资源测试合计 12 项）通过：慢驱动屏障下洪泛 40,000 次音量和可见性更新，证明并行原生设置调用不超过 1、最终状态正确并能从一次失败恢复；四个播放器分别进行 1,000 次快速媒体替换，且覆盖过期初始化与原生 open 超时后 close 必须等待边界结束；4 房间各接收 10,000 条聊天事件，验证每房间缓冲仍限 200 条、正常四路弹幕仍全部投递、独立房间每帧仅排一个滚动回调，关闭后迟到消息无效。

资源测试覆盖 4 个高密度画布、200 帧、滚动及特殊绘制，观测并验证 2,400 个 Picture（含测试记录器）全部 debugDisposed；绘制异常仍释放已完成/未完成记录器；5,000 次测量对应的 TextPainter 创建和释放事件相等；4 个屏幕合计 24,000 条输入且活动轨道低于 100，配置重建、隐藏、清除、卸载后存留 Paragraph 显示已释放；同一特殊内容可跨屏复用而活动项各自持有布局；100 次暂停/恢复只保留一个周期计时器，卸载后归零。

这些是确定性 Dart/Flutter 测试中的可控工作量与资源释放断言，不等价于长时间真实桌面多路播放，也不覆盖 Windows 原生播放器/插件的真实竞争。

## 第一轮验证记录

以下命令从 simple_live_app 执行，Flutter 3.38.3 / Dart 3.10.1；所有 Flutter/Dart 分析与测试串行运行。

```bash
/e/Enviroment/sdk383/flutter/bin/flutter.bat test --no-pub --concurrency=2 test/multi_live test/bounded_chat_buffer_test.dart test/emoji_image_cache_test.dart test/log_sanitizer_test.dart test/http_log_redaction_test.dart
/e/Enviroment/sdk383/flutter/bin/flutter.bat analyze --no-pub --no-fatal-infos
/e/Enviroment/sdk383/flutter/bin/dart.bat analyze --fatal-infos lib/modules/multi_live test/multi_live lib/modules/live_room/live_room_controller.dart third_party/canvas_danmaku/lib/danmaku_screen.dart third_party/canvas_danmaku/lib/models/danmaku_content_item.dart third_party/canvas_danmaku/lib/models/danmaku_item.dart third_party/canvas_danmaku/lib/scroll_danmaku_painter.dart third_party/canvas_danmaku/lib/special_danmaku_painter.dart third_party/canvas_danmaku/lib/utils/utils.dart
/e/Enviroment/sdk383/flutter/bin/dart.bat format --output=none --set-exit-if-changed lib/modules/multi_live/session/multi_live_room_session.dart lib/modules/live_room/live_room_controller.dart third_party/canvas_danmaku/lib/danmaku_screen.dart third_party/canvas_danmaku/lib/models/danmaku_content_item.dart third_party/canvas_danmaku/lib/models/danmaku_item.dart third_party/canvas_danmaku/lib/scroll_danmaku_painter.dart third_party/canvas_danmaku/lib/special_danmaku_painter.dart third_party/canvas_danmaku/lib/utils/utils.dart test/multi_live/feedback_stability_regression_test.dart test/multi_live/feedback_danmaku_resources_test.dart
```

第一轮合同测试为 **275 项通过，退出 0**；新增两个测试文件共 12 项均包含在内。全应用分析退出 0，**0 error、0 warning，10 条范围外旧 info**，相较历史 17 条 info 没有增加错误或警告，本次触及文件内的提示已清理。多开源码与测试、全部本次触及生产文件的严格分析退出 0、No issues found。Dart 格式干跑及仓库 CRLF/空白检查结果附于任务结构化验证记录；未跟踪报告、会话文件与新测试的 no-index 检查返回 1（与空文件不同），没有空白诊断，仅有正常 LF→CRLF 转换提示。

重复清理活动项两次验证不会二次释放 native handle；每次暂停/恢复均重复调用，仍只有一个清理 Timer，卸载后 0。聊天 callback 的“至少一次清理”仅覆盖可重复调用的 clear 回调，未放松原生句柄的 dispose 断言。

## 第二轮设置错误隔离返修验证

独立验收发现：同批或在音量调用等待期间请求可见性更新，音量抛错后，可见性没有应用却接收到音量错误；第一轮的 275 项通过记录没有覆盖此交错，不能替代独立验收。原样重跑独立的两项复现，修改前 2 失败（退出 1）、修改后 2 通过（退出 0）；独立验收测试文件未编辑。

现在音量与可见性各有自己的完成结果。取出待处理结果后才派发该设置；错误只完成本次设置，drain 继续处理另一类设置和等待中的最新目标。每房间最多一个原生调用，最多两个待处理结果及一个执行中结果；40,000 次设置洪泛仍复用每类一个待处理 Future。关闭立即结清尚未派发的设置；已派发调用仍等待原生边界并保留自身错误，重复 close 只关闭驱动一次。初始化失败会结清两类结果；没有自动重试或新建无界重试队列。

作者测试新增反向可见性失败的同批/进行中交错、关闭时活动调用失败、初始化失败及同类更新目标不继承前次错误，共 5 项；四路洪泛、媒体打开屏障、聊天投递、资源所有权以及租约/代际/去重/脱敏相关既有回归均保留。返修后的完整集合 **323 项通过，退出 0**；作用域严格分析 **No issues found、退出 0**；两份修改的 Dart 文件格式检查 **0 changed、退出 0**。这些是作者验证证据，等待第二轮独立验收。

下列命令在 simple_live_app 串行执行：

```bash
/e/Enviroment/sdk383/flutter/bin/flutter.bat test --no-pub --concurrency=2 test/multi_live test/douyu_room_status_test.dart test/bounded_chat_buffer_test.dart test/emoji_image_cache_test.dart test/log_sanitizer_test.dart test/http_log_redaction_test.dart
/e/Enviroment/sdk383/flutter/bin/dart.bat analyze --fatal-infos lib/modules/multi_live test/multi_live
/e/Enviroment/sdk383/flutter/bin/dart.bat format --output=none --set-exit-if-changed lib/modules/multi_live/session/multi_live_room_session.dart test/multi_live/feedback_stability_regression_test.dart
```

已跟踪差异的 CRLF/空白检查退出 0；返修三份未跟踪文件另作 no-index 检查，差异存在返回 1但无空白诊断。第二轮只修改会话实现、作者稳定性回归和本报告；未更改独立验收、界面、共享发送保护或用户运行中的程序。

## 尚需的实机验证

Windows 本机多路长时间播放、显卡/解码器资源计量、异常现场 dump 与原生调用栈均未在本任务中验证；未启动、终止、重启或覆盖用户程序。需要后续取得相同异常时刻的转储、精确构建和符号，并在独立验收后验证真实四路稳定运行。不要据此宣称原生崩溃根因已修复。

## 第三轮：多开稳定性补充修复与媒体通知直播时长（2026-11-25）

本轮针对用户反馈的「多开偶发卡死/崩溃」继续审计，修复以下可由代码证实的机制；这些仍是可控回归证据，不等价于证明某一原生崩溃现场，实机长时间验证仍需后续完成。

1. **WebSocket 连接/关闭竞态。** 旧实现中握手 Future 在 `stop()` 之后完成仍可能重新注册流监听和心跳；重连定时器可在关闭后重新连接；共享 socket 会被新连接复用；平台 `stop()` 未清理 `onReady`。重写 `simple_live_core/lib/src/common/web_socket_util.dart` 为代际守卫 + 单次重连定时器：每次尝试递增 `_generation`，流回调、心跳、重连都校验 `_owns(generation, channel)`；先监听再等待 ready；`_clearTransport()` 先摘除 identity 再 cancel/close，清理异常被吞掉不打断生命周期。
2. **多开聊天栏超级留言（SC）列表无界。** 单房间靠 SC 卡片组件触发过期清理，多开嵌入式房间没有该组件，`superChats` 只增不减。`live_room_controller.dart` 增加 `_addSuperChat` / `removeSuperChats`，由统一的 1 秒计时器同时清理画面 SC 与聊天栏 SC；隐藏或未挂载聊天栏时仍按平台 `endTime` 过期；进房全量 SC 也走同一入口。
3. **斗鱼高能弹幕 vrid 去重集合无界。** 原 `Set<String> _voiceIds` 在长时间多开中永久驻留。改为 `LinkedHashMap<String, Duration>`，10 分钟窗口、最多 2048 条，重复包不续期；`start()`/`stop()` 清空；改为完成来源/正文校验并建卡后才占用 ID，避免无效消息挡住后续有效报文。
4. **后台播放元数据回写竞态。** 切台/关房后旧的头像读取 Future 仍可能把旧房间元数据写入系统通知。新增 `_bgMetadataGeneration`，头像与图标异步读取后校验 `isCurrent()`（未关闭、未关房、generation 相同、`identical(room, detail.value)`、后台播放开关仍开）；头像缓存只在成功后写入；删除重复的第二次 `updateMetadata`。
5. **嵌入式房间误收原生媒体命令。** 多开房间不再订阅系统媒体通知/锁屏按钮命令，避免一个通知命令驱动多个播放器。

### 媒体通知直播时长

用户要求时长以时间形式实时更新在系统媒体进度条中，而不是拼进标题文本。新增 `simple_live_app/android/app/src/main/kotlin/com/xycz/simple_live/LivePlaybackTiming.kt`：

- `elapsedMillis(start, now)`：开播时间未知（<=0）返回 null，否则 `max(0, now-start)`；
- `durationMillis(start, now) = elapsed + 3,600,000`，为直播提供一小时的滚动余量，避免进度条瞬间填满；
- `nextRefreshDelayMillis(start, now) = 3,600,000 - elapsed % 3,600,000`，只在整点边界重新发布一次。

`PlaybackService.kt` 的 `publish()` 使用 `SystemClock.elapsedRealtime()` 计算位置，并通过 `PlaybackState.setState(..., elapsed, speed=1f, updateTime)` 让系统在两次发布之间按 1 倍速自行推进；元数据 `METADATA_KEY_DURATION` 写入 `durationMillis/1000`。标题保持纯主播名，不追加“已播”文本。未前台播放时移除时长刷新任务，`onDestroy`/`stopPlayback` 均取消回调。

### 第三轮验证

- `flutter test simple_live_app`：**382 项通过**；`flutter analyze simple_live_app`：**0 error、0 warning，12 条 info**。
- 新增核心定向测试 `simple_live_core/test/web_socket_lifecycle_test.dart`、`test/douyu_voice_dedup_test.dart`、`test/douyu_passport_test.dart`：**30 项全部通过**。
- Kotlin 单元测试 `LivePlaybackTimingTest`：**5 项全部通过**（Gradle 报告 `tests=5 failures=0 errors=0`）。
- `flutter build apk --debug`：见本轮构建记录。
- 未连接 Android 实机，系统媒体横幅/灵动岛、蓝牙按键及多开长时间运行仍需实机验证。
