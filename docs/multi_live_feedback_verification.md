# 多开直播独立验收

**第二轮独立验收（t9）通过**。多开测试 272 项和扩展回归 323 项全过。首轮复现的两项设置故障在原独立测试未改动的情况下转为通过。Windows 原生异常根因尚未定位，四路实机长时测试仍缺。见[第二轮验收记录](<#第二轮独立验收t9>)。

## 第一轮独立验收（t4）

本轮验收未通过。用户反馈的界面交互通过 12 项独立生产路由用例。完整回归 316 项通过、2 项失败，两项都复现了音量操作出错时丢失弹幕显示切换。当前版本不能通过稳定性门禁。 [需求与基线](<multi_live_feedback_requirements.md>)

## 界面与保留行为

| 验收项 | 离线结果 |
| --- | --- |
| 聊天标题 | 桌面侧栏和移动聊天面板均无标题发送按钮，底部输入与发送保留。移动端点击底部发送，离线驱动收到一条。 |
| 复制 | 桌面左、右键单击均在点击位置开菜单，移动端单击开富文本预览卡片。两种复制格式均核对剪贴板完整文本。空正文、只打开和取消都不写入。菜单打开后发送 220 条后续消息，原消息从 200 条缓冲中移除，复制仍取最初点中的内容。 |
| Enter、焦点与 Esc | 按键覆盖无框打开并聚焦、纯空格隐藏、非空发送、失败保留和成功清理。两种 IME 确认顺序、KeyDown/Up/Repeat、合成或附带修饰键的事件均纳入回归。布局选择或取消、滑杆与静音、切换画面、关闭复制菜单、模拟应用失焦再恢复后，Enter 可以再次打开。Esc 依次退出快捷框、单画面放大、整窗全屏，菜单及选择器优先处理自己的按键。 |
| 紧凑顶栏 | 深、浅主题默认桌面顶栏及按钮为 32 逻辑像素。320×240 的桌面布局在 1.5、2 倍字号时所有按钮可命中，标题字形位于顶栏边界内。320×568 Android 的 2 倍字号下，顶栏为 56、按钮为 48×48，聊天和音量入口可操作。 |
| 发送与既有保护 | 快捷框关闭重开及底部输入同文只触发一次已在途发送，回执返回后可再发。旧独立用例继续校验选中房间变化、等待租约、报告晚到、替换和退出。完整回归包含桌面 4 路及移动 2 路、主播名、独立音量、保存恢复、Douyu 状态及租约、有界聊天、表情缓存、日志脱敏。稳定性门禁中的设置错误边界见下节。 |

独立路由用例使用单房间业务入口、实际命名路由参数解析、MyApp 构建器、房间控制器和会话。离线驱动承接播放器及网络，测试替换宿主剪贴板、窗口调用和存储，输入法及焦点用合成的 Flutter 事件。大字号用例在测试路由内显式注入 1.5/2 倍缩放，320×240 预览在已打开的生产路由执行 resize 并核对 Scaffold 尺寸。复跑既有独立用例时保留共享在途去重断言。 [新独立路由用例](<../simple_live_app/test/multi_live/feedback_acceptance_route_test.dart#L365>) · [既有独立路由用例](<../simple_live_app/test/multi_live/extension_acceptance_route_test.dart#L440>) · [合成键和选择器用例](<../simple_live_app/test/multi_live/production_route_test.dart#L381>)

## 阻塞发布的设置故障

初始化会话后令离线驱动在 setVolume(24) 上等待，然后分别在调用原生设置前的同一批次、原生设置已经等待时请求 setDanmakuVisible(false)。令音量 Future 以 StateError 结束，两种时序都能稳定复现。会话目标规格已为 false，驱动收到的可见性仍只有初始化时的 [true]，断言期望为 [true, false]。当前共享 Future 还会以音量异常结束弹幕显示请求。 [两种时序的独立测试](<../simple_live_app/test/multi_live/feedback_stability_acceptance_test.dart#L155>)

设置 drain 提取并清掉两个 dirty 标记，先等待音量再应用可见性。同批次的可见性标记会被清除，等待中到达的标记则随 drain 提前退出而停留，直到别的输入推进。控制器在等待之前保存新规格，实际叠加层由驱动的可见性状态决定，所以保存状态和画面可能不一致。修复验收要求在两种时序下均应用最新的可见性，不依赖后续用户操作，并让每项设置报告自己的结果。保留设置合并、关闭边界和各房间隔离。 [合并 drain](<../simple_live_app/lib/modules/multi_live/session/multi_live_room_session.dart#L134>) · [保存和设置派发](<../simple_live_app/lib/modules/multi_live/multi_live_controller.dart#L508>) · [实际叠加层更新](<../simple_live_app/lib/modules/multi_live/session/multi_live_room_session.dart#L244>)

## 稳定性证据和实机缺口

- 四个真实 MultiLiveMedia 挂载各自的 DanmakuScreen，共输入 960 条滚动弹幕并覆盖无空轨道的丢弃路径。复用同一个特殊弹幕内容，观察到 48 个独立 TextPainter。4 画面各绘制 5 次，记录 40 个 Picture（含测试外层记录器）全部释放。验证暂停时保留资源、恢复后到期释放、隐藏只清本屏、重挂载后旧控制器不影响新屏、卸载后所有已捕获 Paragraph 与特殊布局均释放。 [嵌入画面独立用例](<../simple_live_app/test/multi_live/feedback_stability_acceptance_test.dart#L191>)
- 两个实际 LiveRoomController 各收到 128 次被阻塞期间的替换。经过 13 秒超过原生 open 的 12 秒等待预算，两路仍各只有一个原生调用。迟到错误后保留房间只打开最新版本并应用一次音频，关闭房间等待原调用结束且不接受过期工作。替身的释放由测试负责。原生 open 如果一直不返回，关闭仍可能等待。 [迟到错误独立用例](<../simple_live_app/test/multi_live/feedback_stability_acceptance_test.dart#L337>) · [生产 open 屏障](<../simple_live_app/lib/modules/live_room/live_room_controller.dart#L1044>)
- 五次异常退出与 Windows 事件 1000/1001 对应。独立只读查询 2026-11-21 20:55–21:16（UTC+8）的 Application 日志返回 5 条 1000、5 条 1001 和 0 条 1002，关联应用版本 1.11.7.11107。20:56:39 和 20:56:44 的异常模块为 permission_handler_windows_plugin.dll，异常码 c0000005 和 c000041d。20:56:50 为 coremessaging.dll/c0000602。21:01:53、21:15:11 均为 ucrtbase.dll/c0000409，关联 BEX64。三份既有应用日志的脱敏统计记录了 FormatException。现有记录缺少转储和可归属该构建的符号化调用栈，尚无法确定实机原生根因。 [稳定性记录](<multi_live_stability_findings.md#L7>)
- Windows 实机四路长时间直播、真实系统输入法和窗口、播放器/插件竞态、真实账号发送及媒体资源峰值均待实测。本轮只运行离线测试和只读查询，核对应用日志时使用既有脱敏记录。

## 已运行的检查

Flutter 3.38.3 与 Dart 3.10.1，使用 E:/Enviroment/sdk383/flutter/bin 中的 flutter.bat 和 dart.bat。测试、分析和格式检查串行执行，测试固定 --no-pub --concurrency=2。历史完整集合 278 项通过。为保留同一回归范围，这轮带上 Douyu 状态、聊天缓冲、表情缓存、两类日志脱敏测试。稳定性实现阶段的 275 项使用较小的范围。 [历史基线](<multi_live_feedback_requirements.md#L33>)

| 检查 | 实际结果 |
| --- | --- |
| 独立路由 | 12 通过，退出 0。bash-33c059dae61b4907。 |
| 完整回归，加入设置错误探针前 | 316 通过，退出 0。bash-a0de2a64c3384bec。 |
| 两种设置错误复现 | 0 通过、2 失败，退出 1。每项均显示 Expected: [true, false] 和 Actual: [true]。bash-6b73c07219d1478b。 |
| 完整回归，加入设置错误探针后 | 316 通过、2 失败，退出 1。只有本页复现的两项设置边界失败。bash-bc52f4a6768c42fc。 |
| 多开、路由、相关聊天与渲染严格分析 | 退出 0，零诊断。bash-aaae3187d54c4f42。 |
| core 的租约、脱敏和状态文件严格分析 | 退出 0，零诊断。 |
| 全应用分析 | 退出 0。0 error、0 warning、10 条范围外旧 info。历史 17 条中的 7 条第三方画布 info 已消除。 |
| Dart 格式干跑 | 退出 0，57 个文件无变化。 |
| Git 跟踪文件空白检查 | 退出 0。无空白诊断，18 条常规 LF→CRLF 转换提示。 |
| Git 未跟踪文件空白检查 | 59 条相关路径逐项检查，脚本退出 0。仅显示常规 LF→CRLF 转换提示。 |

测试及格式/分析复验命令。Flutter 使用进程内 PATH 指向上述 SDK 及 Git。下列命令在 simple_live_app 目录运行。

```bash
export PATH=/e/Enviroment/Git/cmd:/e/Enviroment/sdk383/flutter/bin:$PATH
export FLUTTER_SUPPRESS_ANALYTICS=true DART_SUPPRESS_ANALYTICS=true
flutter.bat --suppress-analytics test --no-pub --concurrency=2 --reporter expanded test/multi_live test/{douyu_room_status,bounded_chat_buffer,emoji_image_cache,log_sanitizer,http_log_redaction}_test.dart
flutter.bat --suppress-analytics test --no-pub --concurrency=2 --reporter expanded --plain-name 'volume failure preserves visibility' test/multi_live/feedback_stability_acceptance_test.dart
flutter.bat --suppress-analytics analyze --no-pub --no-fatal-infos
dart.bat analyze --fatal-infos lib/modules/multi_live test/multi_live test/{douyu_room_status,bounded_chat_buffer,emoji_image_cache,log_sanitizer,http_log_redaction}_test.dart lib/main.dart lib/routes lib/modules/live_room/live_room_{controller,page}.dart lib/modules/live_room/player/{player_controller,player_wakelock_coordinator}.dart lib/utils/bounded_chat_buffer.dart lib/requests/custom_log_interceptor.dart third_party/canvas_danmaku/lib/{danmaku_screen.dart,models/danmaku_{content_item,item}.dart,scroll_danmaku_painter.dart,special_danmaku_painter.dart,utils/{utils,emoji_image_cache}.dart}
dart.bat format --output=none --set-exit-if-changed lib/modules/multi_live test/multi_live lib/modules/live_room/live_room_controller.dart third_party/canvas_danmaku/lib/{danmaku_screen.dart,models/danmaku_{content_item,item}.dart,scroll_danmaku_painter.dart,special_danmaku_painter.dart,utils/utils.dart}
```

在 simple_live_core 运行核心边界分析。在仓库根目录执行 Git 命令，每次调用只在进程内设置 safe.directory。未跟踪文件逐个以 --no-index --check 比较空输入，退出 1 且无诊断表示文件内容有差异。

```bash
/e/Enviroment/sdk383/flutter/bin/dart.bat analyze --packages=../simple_live_app/.dart_tool/package_config.json --fatal-infos lib/src/{interface/live_danmaku_sender_control,common/log_sanitizer,model/live_room_status}.dart
/e/Enviroment/Git/cmd/git.exe -c safe.directory=E:/Project/simple_live/dart_simple_live -c core.whitespace=cr-at-eol diff HEAD --check
/e/Enviroment/Git/cmd/git.exe -c safe.directory=E:/Project/simple_live/dart_simple_live -c core.whitespace=cr-at-eol diff --no-index --check -- /dev/null "$f"
```

## 本次验收输入 SHA-256

下列哈希对应本轮未通过验收的源码与需求文档。

```text
4e9a90904e3410f02b59011934678ea4623af8fbe183b5fd5427e4404f840f3a  docs/multi_live_feedback_requirements.md
c2ce9ec0572f7a6ab6a4eb850828d431e90e20d7d96605a93ba3850bf98bcd55  simple_live_app/lib/modules/multi_live/multi_live_page.dart
0751f189744af95840322f2214276a24df902d15547664bb80941fea9f2f2f92  simple_live_app/lib/modules/multi_live/integration/multi_live_chat.dart
499ba43f5f320aea726c771fab3d75104f1cb6ed99cf86b7d2c0ea8292d4e07f  simple_live_app/lib/modules/multi_live/integration/multi_live_quick_danmaku.dart
5e8ccbfd0302780aa866227984549e1f7976fd15eeccb3c11dd125c8e4be6eb8  simple_live_app/lib/modules/multi_live/integration/multi_live_route.dart
63d9a3d397c1922e9f257e7e360596f3e8376ffad81bdd8ce1a9a0aef66d3ee9  simple_live_app/lib/modules/multi_live/session/multi_live_room_session.dart
cca3bd11b8caa881a6c3677226ee759d3abfd033fe17bbe82e4d419cff7094fd  simple_live_app/lib/modules/live_room/live_room_controller.dart
990b48caaafdc04b178f51e2f0b06f1777484f572db7666c216261f4e6458634  simple_live_app/third_party/canvas_danmaku/lib/danmaku_screen.dart
f09407f2b2f7eacc16c55004cac6410e167f17009fd437733b18a0843f6cab04  simple_live_app/third_party/canvas_danmaku/lib/models/danmaku_content_item.dart
d00d1db579c2c0f51a77b245d5689857c115b5f52445658f8ac91ee255b183a5  simple_live_app/third_party/canvas_danmaku/lib/models/danmaku_item.dart
ebda83ef04c071e8f2f5ff6ab787de5119a642e3060046536cb4ab749a10594f  simple_live_app/third_party/canvas_danmaku/lib/scroll_danmaku_painter.dart
f638efca55cbd3631118dc473a5a09bb66c24374648b1996009ff40b09cdaed9  simple_live_app/third_party/canvas_danmaku/lib/special_danmaku_painter.dart
fe7209da8cbcb9fc9203071052a2fda8bc590c088498c16af26cbb4a6e7c7726  simple_live_app/third_party/canvas_danmaku/lib/utils/utils.dart
```

## 第二轮独立验收（t9）

### 设置错误复验

首轮两项复现用例未修改。分别在音量调用派发前的同一批次、音量 Future 等待期间请求隐藏弹幕，再令音量调用以 StateError 结束。两种时序中，音量调用继续报告自身异常，可见性调用成功完成，驱动都收到 [true, false]。可见性的结果无需下一次操作触发。原测试 SHA-256 与首轮一致。 [原样复验用例](<../simple_live_app/test/multi_live/feedback_stability_acceptance_test.dart#L155>)

复核修复版本的生产控制流。单个串行 drain 逐次派发设置，每类待派发请求持有独立完成对象。单次原生设置出错时，将异常交给该请求的调用方，循环仍能取出下一项。关闭时先结清尚未派发的请求，再等待活动调用到达边界和驱动关闭。整组回归覆盖反向的可见性错误、新目标与活动目标错误隔离、关闭等待和四房间快速设置合并。 [生产设置派发](<../simple_live_app/lib/modules/multi_live/session/multi_live_room_session.dart#L128>) · [关闭边界](<../simple_live_app/lib/modules/multi_live/session/multi_live_room_session.dart#L239>) · [设置回归用例](<../simple_live_app/test/multi_live/feedback_stability_regression_test.dart#L153>)

272 项多开测试包含第一轮所列 12 项独立生产路由检查、嵌入四屏资源释放和超时后迟到原生错误的两个独立控制器边界。323 项扩展回归同时复跑原有保留功能。首轮只读 Windows 事件与应用日志证据仍适用，现有记录缺少原生转储和符号化调用栈。实机长时四路、真实输入法和窗口切换、播放器或插件竞态仍需实测。 [界面与保留行为](<#界面与保留行为>) · [实机证据边界](<#稳定性证据和实机缺口>)

### 实际验证结果

执行环境沿用 Flutter 3.38.3、Dart 3.10.1 和首轮命令。测试与分析串行，测试固定 --no-pub --concurrency=2。

| 检查 | 实际结果 |
| --- | --- |
| `/e/Enviroment/sdk383/flutter/bin/flutter.bat test --no-pub --concurrency=2 test/multi_live` | 272 项通过，退出 0。 |
| `/e/Enviroment/sdk383/flutter/bin/flutter.bat analyze --no-pub lib/modules/multi_live test/multi_live` | 零诊断，退出 0。 |
| 扩展回归，多开加 Douyu 状态、聊天缓冲、表情缓存、两类日志脱敏 | 323 项通过，退出 0。与首轮 318 项同范围并新增 5 项设置边界测试。历史 278 项为旧版本参照。 |
| 两项独立设置错误复现，原测试原样运行 | 两项通过，退出 0。 |
| 相关应用与核心严格分析 | 分别退出 0，均为零诊断。 |
| 应用整体分析 | 退出 0，0 error、0 warning、10 条既有范围外 info。历史 17 条中的 7 条画布 info 已消除。 |
| Dart 格式干跑 | 退出 0，57 个文件无变化。 |
| CRLF 空白检查 | 跟踪差异及 59 个相关未跟踪文件检查退出 0。仅有 Git 的 LF→CRLF 提示。 |

测试、分析及格式记录见任务 bash-bdfcf540986742f9 和 bash-b48637d365dd4f22，回归复验命令同上。

### 第二轮验收输入 SHA-256

记录本轮 12 个变更生产文件、需求文档和关键用例。首轮至第二轮的生产指纹只在房间会话文件变化。

```text
4e9a90904e3410f02b59011934678ea4623af8fbe183b5fd5427e4404f840f3a  docs/multi_live_feedback_requirements.md
c2ce9ec0572f7a6ab6a4eb850828d431e90e20d7d96605a93ba3850bf98bcd55  simple_live_app/lib/modules/multi_live/multi_live_page.dart
0751f189744af95840322f2214276a24df902d15547664bb80941fea9f2f2f92  simple_live_app/lib/modules/multi_live/integration/multi_live_chat.dart
499ba43f5f320aea726c771fab3d75104f1cb6ed99cf86b7d2c0ea8292d4e07f  simple_live_app/lib/modules/multi_live/integration/multi_live_quick_danmaku.dart
5e8ccbfd0302780aa866227984549e1f7976fd15eeccb3c11dd125c8e4be6eb8  simple_live_app/lib/modules/multi_live/integration/multi_live_route.dart
3835b66d3d595c79819c90f504ee17a57c8ad1dd8fa1f591d59c97db149e7337  simple_live_app/lib/modules/multi_live/session/multi_live_room_session.dart
cca3bd11b8caa881a6c3677226ee759d3abfd033fe17bbe82e4d419cff7094fd  simple_live_app/lib/modules/live_room/live_room_controller.dart
990b48caaafdc04b178f51e2f0b06f1777484f572db7666c216261f4e6458634  simple_live_app/third_party/canvas_danmaku/lib/danmaku_screen.dart
f09407f2b2f7eacc16c55004cac6410e167f17009fd437733b18a0843f6cab04  simple_live_app/third_party/canvas_danmaku/lib/models/danmaku_content_item.dart
d00d1db579c2c0f51a77b245d5689857c115b5f52445658f8ac91ee255b183a5  simple_live_app/third_party/canvas_danmaku/lib/models/danmaku_item.dart
ebda83ef04c071e8f2f5ff6ab787de5119a642e3060046536cb4ab749a10594f  simple_live_app/third_party/canvas_danmaku/lib/scroll_danmaku_painter.dart
f638efca55cbd3631118dc473a5a09bb66c24374648b1996009ff40b09cdaed9  simple_live_app/third_party/canvas_danmaku/lib/special_danmaku_painter.dart
fe7209da8cbcb9fc9203071052a2fda8bc590c088498c16af26cbb4a6e7c7726  simple_live_app/third_party/canvas_danmaku/lib/utils/utils.dart
58ed52c6fe5cb715cee121f2d78a825818015e991466eb727bbc34a0ae716112  simple_live_app/test/multi_live/feedback_acceptance_route_test.dart
05a19dc0106b452a01a32da7b8b727cb036d75ee996a3cb58d39a770ffa90e7c  simple_live_app/test/multi_live/feedback_stability_acceptance_test.dart
ab6b50420b8c0b14602a637a70cf6fdcb2aed6800d565fe1eaa5cf549286508f  simple_live_app/test/multi_live/feedback_stability_regression_test.dart
ea746237b9ef8a92b7766ed8f5b681abfc870c7b7c6d4917ce8867afde3ce796  simple_live_app/test/multi_live/extension_acceptance_route_test.dart
3ff6f8131207e905ab73227670ca000896a886086ced5d2f37b9bc3f8d4114e4  simple_live_app/test/multi_live/production_route_test.dart
```

## 最终界面复审（t11）

### 快捷弹幕框标题点击

修复使用 `TextFieldTapRegion` 将快捷弹幕框的静态内容纳入编辑点击区域。点击目标标题后，文本输入保持原焦点。交互按钮仍按自身语义处理焦点和键盘。复审从生产多开路由打开框，以 Windows 测试变体的鼠标事件点击实际标题。普通 Enter 和小键盘 Enter 均验证空白收起、零派发及空白草稿保留，也验证非空只派发一次、去除首尾空白、发送成功后关闭并清空原稿。Tab 和 Shift+Tab 在输入、发送和关闭控件间移动焦点。焦点位于按钮时，点击标题后仍可用 Enter 激活相应按钮。首轮审查发现 `ML-FEEDBACK-ENTER-PROMPT-FOCUS` 已解决。 [页面实现](<../simple_live_app/lib/modules/multi_live/multi_live_page.dart#L528>) · [生产路由复验](<../simple_live_app/test/multi_live/production_route_test.dart#L299>)

同一次扩展回归复跑 12 项独立生产路由测试和原有守卫。桌面左右键弹出复制菜单、移动单击预览、32 逻辑像素顶栏及窄窗和大字回退均通过。Enter 三态、菜单及音量等操作后的焦点、模拟 IME 确认、重复键、发送目标切换、草稿和在途重复发送保护均通过。 [独立路由](<../simple_live_app/test/multi_live/feedback_acceptance_route_test.dart#L365>) · [共享发送和代际保护](<../simple_live_app/test/multi_live/extension_acceptance_route_test.dart#L440>)

### 最终输入验证结果

使用 Flutter 3.38.3 和 Dart 3.10.1 串行复验。扩展回归与第二轮使用相同范围，包含 5 项新焦点用例，覆盖全部多开、Douyu 状态、聊天缓冲、表情缓存和两类日志脱敏。

| 检查 | 实际结果 |
| --- | --- |
| `flutter.bat test --no-pub --concurrency=2 --reporter expanded --name=feedback.prompt.title test/multi_live/production_route_test.dart` | 5 项通过，退出 0。`bash-5a0140f309c5487a`。 |
| 扩展回归，同上方完整测试命令 | 328 项通过，退出 0。`bash-e2c55736dfc5410e`。 |
| 应用关联范围的严格 Dart 分析 | 零诊断，退出 0。`bash-79ff8126f3bb4664`。 |
| 核心关联范围严格分析及格式干跑 | 零诊断，57 个文件无变化，退出 0。`bash-1509352af6c94ca5`。 |
| CRLF 空白检查 | 跟踪差异退出 0。未跟踪页面和相关测试逐项检查仅有 Git 的 LF→CRLF 转换提示。 |

稳定性审查所覆盖的 8 个生产文件和对应测试的 SHA-256 与已审核版本一致。本轮继续采用首轮记录中的 Windows 事件与应用日志证据。实机四路长时运行、Windows 真实输入法和原生窗口切换仍待验证。现有崩溃记录缺少原生转储和符号化调用栈，原生根因尚待确定。 [稳定性证据和实机缺口](<#稳定性证据和实机缺口>)

### 最终验收输入 SHA-256

在复跑前后核对 20 个重点输入。与第二轮验收相比，生产页面及其实现测试两条 SHA-256 已更新。稳定性生产和测试、其余界面生产、独立测试和需求的摘要一致。复审判定对应下列内容。

```text
4e9a90904e3410f02b59011934678ea4623af8fbe183b5fd5427e4404f840f3a  docs/multi_live_feedback_requirements.md
e89cb8b70cf6686e0e650aaa2aae61096c226efc080b23002d13a47742abe3ec  simple_live_app/lib/modules/multi_live/multi_live_page.dart
0751f189744af95840322f2214276a24df902d15547664bb80941fea9f2f2f92  simple_live_app/lib/modules/multi_live/integration/multi_live_chat.dart
499ba43f5f320aea726c771fab3d75104f1cb6ed99cf86b7d2c0ea8292d4e07f  simple_live_app/lib/modules/multi_live/integration/multi_live_quick_danmaku.dart
5e8ccbfd0302780aa866227984549e1f7976fd15eeccb3c11dd125c8e4be6eb8  simple_live_app/lib/modules/multi_live/integration/multi_live_route.dart
3835b66d3d595c79819c90f504ee17a57c8ad1dd8fa1f591d59c97db149e7337  simple_live_app/lib/modules/multi_live/session/multi_live_room_session.dart
cca3bd11b8caa881a6c3677226ee759d3abfd033fe17bbe82e4d419cff7094fd  simple_live_app/lib/modules/live_room/live_room_controller.dart
990b48caaafdc04b178f51e2f0b06f1777484f572db7666c216261f4e6458634  simple_live_app/third_party/canvas_danmaku/lib/danmaku_screen.dart
f09407f2b2f7eacc16c55004cac6410e167f17009fd437733b18a0843f6cab04  simple_live_app/third_party/canvas_danmaku/lib/models/danmaku_content_item.dart
d00d1db579c2c0f51a77b245d5689857c115b5f52445658f8ac91ee255b183a5  simple_live_app/third_party/canvas_danmaku/lib/models/danmaku_item.dart
ebda83ef04c071e8f2f5ff6ab787de5119a642e3060046536cb4ab749a10594f  simple_live_app/third_party/canvas_danmaku/lib/scroll_danmaku_painter.dart
f638efca55cbd3631118dc473a5a09bb66c24374648b1996009ff40b09cdaed9  simple_live_app/third_party/canvas_danmaku/lib/special_danmaku_painter.dart
fe7209da8cbcb9fc9203071052a2fda8bc590c088498c16af26cbb4a6e7c7726  simple_live_app/third_party/canvas_danmaku/lib/utils/utils.dart
58ed52c6fe5cb715cee121f2d78a825818015e991466eb727bbc34a0ae716112  simple_live_app/test/multi_live/feedback_acceptance_route_test.dart
05a19dc0106b452a01a32da7b8b727cb036d75ee996a3cb58d39a770ffa90e7c  simple_live_app/test/multi_live/feedback_stability_acceptance_test.dart
ab6b50420b8c0b14602a637a70cf6fdcb2aed6800d565fe1eaa5cf549286508f  simple_live_app/test/multi_live/feedback_stability_regression_test.dart
ea746237b9ef8a92b7766ed8f5b681abfc870c7b7c6d4917ce8867afde3ce796  simple_live_app/test/multi_live/extension_acceptance_route_test.dart
48671eeb88941968f7407e11159a8398707d2565d292eac6291737dc19e298cb  simple_live_app/test/multi_live/production_route_test.dart
ca73aa8737f23d6820dd813de0a469b86a5f6b9a9d6b3e3c98afa09d3d80e217  simple_live_app/test/multi_live/feedback_danmaku_resources_test.dart
ef37c537c3a4a96b3fed16ea70b03188044b05b576767baedc0b66b65b09b3e8  docs/multi_live_stability_findings.md
```

## 交付集成记录（t7，2026-11-22）

本节在最终 ZIP 校验后追加。上方 190 行独立报告保留原字节，其审核时 SHA-256 为 `dcfb3165afc1777515c7061bd50ff9f704786d89535ed8291bd91c21c8970a22`；内部另存该审核文本，随包清单绑定此原始摘要。补充稳定性终版审查 t12 已正式通过：前后 20/20 重点输入和 8/8 稳定性生产指纹均与 t11 一致，无新增发现；沿用最终 328 项通过和严格分析零诊断的结论。

| 检查 | 实际结果 |
| --- | --- |
| 最终输入 | 20/20 独立审核指纹匹配。完整 725 文件构建快照摘要 `fdd17f6a3dfaafca76aacaadd6fbbf046f4dda49e62f0e5cd39be854c16075cc`，构建及打包期间保持一致。 |
| Windows Release | Flutter 3.38.3／Dart 3.10.1；`flutter.bat --suppress-analytics build windows --release --no-pub --dart-define=SIMPLE_LIVE_BUILD_ID=20261122-multiview-feedback-t7-d7cfd94b`；退出 0。构建 job `bash-e2f153c328ed4ccd` 已收集；Flutter 报告 95.8 秒，保留插件既有 CMP0175 开发提示。 |
| 新 AOT | `data/app.so` 15,106,992 字节，SHA-256 `f5eca1503e5d0fda5c08b08159b4c5d1ecb60cc132d57b4769bacfb631672341`。与本轮新编译 AOT 匹配；不同于旧包的 `6605df34a6896f3bbe6e6dd1211f54f8346565d85fc75099efac730f67a5e1b5`。 |
| 原生与依赖 | 27 个 x64 PE、69 项静态依赖通过；附带 msvcp140.dll、vcruntime140.dll、vcruntime140_1.dll。活动资产清单仅使用包内 basename，摘要 `a2ec0abbefbe79b5ae7abd523e0aaf59ed697732949158fe23de20dfeed772d8`。 |
| 便携依赖例外 | 延续原流程，逐项重新检查 Android 来源 JNI／可选 JVM 分类；Windows 注册独立路径实现且无活动资产或 Windows PE 引用 JNI。仅在包内排除未引用、依赖调试 CRT 的 ANGLE 附带 zlib.dll，以及旧测试用原生清单；未修改原始 Release。详情见包内 BUILD-MANIFEST.json。 |
| 打包与完整性 | 打包 job `bash-22ff74d96b094df5` 退出 0，已收集。476 运行时文件及 README／BUILD-MANIFEST 共 478 个成员，CRC、长度与全部成员 SHA-256 通过；无重复或越界路径，公开新目录仅一个 ZIP。 |
| 保留检查 | 旧交付目录的 1,920 个文件逐项摘要不变。原运行 Simple Live 的 PID 70504、EXE 路径与摘要一致；未安装、替换、启动、停止或重启应用。生产、测试及依赖输入未被集成阶段修改。 |
| 文档与空白 | 操作说明更新至 32 逻辑像素、两端原样复制与 Enter 三态；相关文档及 Git CRLF 空白检查通过。附加核验脚本首次将 Git 的 LF→CRLF 转换提示当作错误；改用进程局部 `core.autocrlf=false` 后保留 `core.whitespace=cr-at-eol` 进行相同检查。 |

唯一交付物：[SimpleLive-Windows-x64-portable.zip](<../simple_live_app/build/deliverables/20261122-multiview-feedback/SimpleLive-Windows-x64-portable.zip>)。大小 **45,325,966 字节**；SHA-256 **`abbe72ce16f1df39850479db91df8934a1d6b6637bce2db3560c3a612249a4f8`**。README 和 BUILD-MANIFEST.json 位于 ZIP 内部，构建日志、源码快照和校验收据留在内部辅助目录。

本包包含已复现机制的修复，不代表 Windows 原生崩溃根因已确定。实机四路长时、真实输入法及窗口焦点、真实账户和原生音视频/插件竞态仍待验证；永久 pending 的原生 Future 仍可延迟关闭。没有原生转储或符号化栈，不能声称长期崩溃已消除。
