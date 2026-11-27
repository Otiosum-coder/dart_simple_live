# 多开直播反馈验收准则

依据任务转述的用户截图和反馈（m00171）及复制入口补充（m00208），在实际多开直播路由验收。测试挂载生产页面和路由，使用离线播放器、发送驱动、剪贴板与输入法事件替身观测交互及实际派发次数。[生产路由绑定](../simple_live_app/lib/modules/multi_live/integration/multi_live_route.dart#L75)

## 界面与交互

| 项目 | 通过条件 |
| --- | --- |
| 聊天标题 | 侧栏及窄屏聊天面板均移除标题上的铅笔图标、快捷发送按钮和对应可交互入口。继续显示对应房间的主播和直播信息，聊天底部输入框和发送按钮仍可发送。 |
| 复制弹幕 | 桌面左键单击或右键单击弹幕，均在鼠标点击位置打开复制菜单。移动端单击弹幕即打开带该条弹幕预览的底部卡片。选中“复制弹幕”和“复制「昵称：内容」”时，分别写入 `message.message.trim()` 和 `"${message.userName}：${message.message}".trim()`。单击打开菜单或取消均不写剪贴板，移动端无需长按。文本 trim 后为空时沿用原处理，不提供复制。保留富文本和表情渲染。菜单打开期间收到新弹幕、列表重排或刷新，仍复制最初点中的消息。 |
| 桌面 Enter 三态 | 多开工作区在前台、已有发送目标且无快捷框时，独立按一次 Enter（含小键盘 Enter）打开当前选中房间的快捷框，并聚焦文本输入。快捷框打开且文本 trim 后为空时（含纯空格）再按 Enter，收起框且零派发。非空时尝试发送一次。成功且当前原稿未变时清对应草稿并关闭该框，失败显示反馈并保留草稿。无选中房间时沿用原有提示。 |
| 焦点恢复 | 连续开合快捷框、点击画面或切换所选房间、操作音量按钮或滑杆、关闭布局/画面/复制菜单或选择器、窗口失焦再返回后，工作区回到前台时按 Enter 可打开快捷框并直接输入，无须先点画面。其他可编辑控件、打开的菜单、模态路由或应用内其他页面拥有焦点时，各自的键盘行为优先。保留 Tab 导航与组合键行为。 |
| 紧凑顶栏 | 桌面默认字号测量多开工具栏内容行，高度由 40 降到 **32 逻辑像素**（不含系统安全区域）。深浅主题均检查。Windows 320×240、1.5/2 倍字体验证标题和原有操作入口位于可用范围、可命中、无布局溢出，必要时允许自适应标题行。移动端常规顶栏 **56 逻辑像素**，主要触控目标 **48×48 逻辑像素**，以 320×568 Android、2 倍字体验证仍可操作。 |

独立用例分别用桌面主键、次键、移动触摸触发复制入口，点击两种选项核对实际剪贴板载荷，并在关闭菜单后再按 Enter 检查焦点。单房间原实现规定了复制格式和空文本处理。[单房间原行为](../simple_live_app/lib/modules/live_room/live_room_page.dart#L1003) · [当前多开聊天列表](../simple_live_app/lib/modules/multi_live/integration/multi_live_chat.dart#L25)

当前工作区由页面焦点树接收按键，快捷框为独立对话框路由，旧版提交遇到空白会直接返回。聊天头部铅笔当前有独立入口，桌面顶栏和桌面按钮默认均为 40。[工作区键盘](../simple_live_app/lib/modules/multi_live/multi_live_page.dart#L129) · [聊天头部按钮](../simple_live_app/lib/modules/multi_live/multi_live_page.dart#L627) · [输入提交](../simple_live_app/lib/modules/multi_live/integration/multi_live_quick_danmaku.dart#L87) · [顶栏尺寸](../simple_live_app/lib/modules/multi_live/multi_live_page.dart#L244)

### 按键和发送边界

- **IME。** 组合态及用于确认该次组合的 Enter 或 IME action 由输入法处理，快捷框保持打开且零派发。分别验证按键先于组合清除、组合先提交再收到对应按键或 action。组合结束后新的一次明确 Enter 按三态执行。保留聊天底部输入和移动软键盘的已有发送路径。
- **重复键。** 从无框状态按住 Enter 只打开一次，即便房间已有草稿也不会在本次按住期间发送或收起。空框时按住只隐藏一次，非空时按住至多派发一次。验证 KeyUp、KeyRepeatEvent、窗口切换时的合成按键和同次硬键后跟随的 IME action，并确认随后独立按键仍能正常响应。
- **Esc 分层。** 菜单、选择器等当前浮层优先消费 Esc。多开自身的层次为快捷框 → 单画面临时放大 → 整窗全屏，每次只处理最上面适用的一层。保留 F11 与工作区之外的按键行为。
- **共享在途去重。** 复跑 MV-EXT-1。用离线驱动卡住发送回执，Esc 关闭并重开快捷框，或转从聊天底部提交同一会话同文，驱动只收到第一条。在途占用结束后可显式再发。切换草稿后，旧回执不可清除新草稿或关闭之后打开的框。补测先等待 Douyu 租约与已派发等待回执的区别。[原独立复现](../simple_live_app/test/multi_live/extension_acceptance_route_test.dart#L440)
- **目标切换。** 切换选中房间、替换或关闭会话、关闭快捷框或退出工作区，应立即撤销仍未交给驱动的旧快捷框请求，保留会话尚可访问的原房间草稿。发送前再次检查选择代际、会话身份、路由和发送租约。已经交给原驱动的回执仍属原请求，不会变成另一房间的发送或影响新会话、新草稿。聊天底部和快捷框继续共用每房间草稿及同一控制器发送保护。[现有 Controller 保护](../simple_live_app/lib/modules/multi_live/multi_live_controller.dart#L463)

## 长时间多开卡死和崩溃

- 只读查看用户会话已有的应用日志 `%APPDATA%/com.xycz/simple_live_app/log` 和可用的 Windows Application Error、Application Hang、Windows Error Reporting 事件。关联发生时间、应用构建或版本、事件与异常模块或退出码。记录所查时间范围、关联程度和缺失项，只输出脱敏摘要，保护 Cookie、认证材料、带签名的直播 URL 和真实弹幕内容。
- 审计四路高流量消息、绘制和图片缓存、定时器/订阅及迟到回调、播放器销毁与重建、异步队列和磁盘日志积压。确认具体路径、触发条件和资源或并发机制后做定点修复。用可控消息量、重复开关/替换/关闭、阻塞或延迟的驱动边界验证修复前后差异。断言消息与缓存有界、关闭后资源释放、过期工作不生效，以及正常弹幕、播放和音量路径仍可用。
- 分别记录已复现并修复的机制、与用户当次失稳的关联程度、实机长时复验结果或缺口。归因于原生崩溃需要可归属该构建与事件的证据，Dart 错误栈与离线测试只支持它们直接覆盖的结论。现行任务只读接触已运行程序和现存记录，禁止启动、安装、停止、重启或覆盖正在使用的程序，禁止真实发送弹幕。

## 回归基线与复验命令

- 2026-11-21 本轮 Git 基线为 `dev` / `47a4ce0`，较 `origin/dev` 超前 1。`status --porcelain=v1 --branch --untracked-files=all` 显示 41 个已跟踪修改、无暂存，83 个未跟踪文件（app 56、core 3、文档 5、团队状态与档案 19）。已有改动涉及 app/core 的播放、弹幕、路由、设置、关注、存储、日志及平台文件。多开生产源码、测试和部分报告虽未跟踪，同属工作区基线。所有任务在各自路径内定点修改，保留已有编辑且不提交。
- 既有独立全套为 **278 项通过、0 失败、退出 0**，含 9 项独立生产路由用例。相关分析零诊断，全应用仅有 17 条旧的范围外 info、无 warning 或 error。这是历史参照，本轮需独立重跑。回归保留桌面 4 路/移动 2 路、逐路音量与静音、主播名、保存恢复、布局/全屏、代际守卫、Douyu 发送租约、共享在途去重、有界聊天缓冲、表情缓存、日志脱敏。[历史结果与退出状态](multi_live_extension_verification.md#L24)
- 固定 Flutter **3.38.3** / Dart **3.10.1**，SDK 缓存版本已核对。以 `E:/Enviroment/sdk383/flutter/bin/flutter.bat` 与同目录 `dart.bat` 为入口，Bash 使用 `/e/Enviroment/sdk383/flutter/bin`。从 `simple_live_app` 执行命令，同一时段只运行一个 Flutter 测试、分析或构建进程，测试固定 `--no-pub --concurrency=2`。沿用现有 SDK 和依赖，必要的 PATH 仅在进程内设置。

```bash
export PATH=/e/Enviroment/Git/cmd:/e/Enviroment/sdk383/flutter/bin:$PATH
export FLUTTER_SUPPRESS_ANALYTICS=true DART_SUPPRESS_ANALYTICS=true
/e/Enviroment/sdk383/flutter/bin/flutter.bat --suppress-analytics test --no-pub --concurrency=2 --reporter expanded test/multi_live test/{douyu_room_status,bounded_chat_buffer,emoji_image_cache,log_sanitizer,http_log_redaction}_test.dart
/e/Enviroment/sdk383/flutter/bin/flutter.bat --suppress-analytics analyze --no-pub --no-fatal-infos
/e/Enviroment/sdk383/flutter/bin/dart.bat analyze --fatal-infos lib/modules/multi_live test/multi_live
```

其余实际触及的生产文件和测试同样纳入严格分析与 Dart 格式干跑，记录退出状态和新增诊断。Git 命令在仓库根运行，仅在各次进程设置 `safe.directory`。下列已跟踪差异检查在本轮开始时退出 0，stderr 仅有既有 LF→CRLF 转换提示。对本轮涉及的未跟踪文件逐个运行第二条命令，`--no-index --check` 退出 1 且无诊断表示文件与空输入不同。

```bash
/e/Enviroment/Git/cmd/git.exe -c safe.directory=E:/Project/simple_live/dart_simple_live -c core.whitespace=cr-at-eol diff --check
/e/Enviroment/Git/cmd/git.exe -c safe.directory=E:/Project/simple_live/dart_simple_live -c core.whitespace=cr-at-eol diff --no-index --check -- /dev/null "$f"
```

## 并行写入范围

- **界面实现（controls）** 生产范围为 `lib/modules/multi_live/` 中的 `multi_live_page.dart` 和 `integration/` 下的 `multi_live_chat.dart`、`multi_live_quick_danmaku.dart`、`multi_live_route.dart`。对应 `test/multi_live/` 实现测试为 `chat_entry_shortcuts_test.dart`、`production_route_test.dart`、`fullscreen_page_interaction_test.dart`、`controls_repair_toolbar_test.dart`、`controls_refinement_interaction_test.dart`、`page_interaction_test.dart`、`feedback_chat_copy_test.dart`、`feedback_enter_focus_test.dart`。以上路径均相对 `simple_live_app`。
- **稳定性实现（stability）** 在 `simple_live_app` 内负责 `lib/modules/multi_live/{multi_live_controller.dart,session/multi_live_room_session.dart,integration/multi_live_media.dart}`、`lib/modules/live_room/{live_room_controller.dart,player/player_controller.dart}`、`lib/utils/bounded_chat_buffer.dart`、`lib/app/log.dart`、`third_party/canvas_danmaku/lib/utils/emoji_image_cache.dart`。测试限 `test/multi_live/{feedback_stability_regression,session_lifecycle,lifecycle_embedded_media,controls_refinement_session}_test.dart` 及 `test/{bounded_chat_buffer,emoji_image_cache}_test.dart`，报告为仓库根的 `docs/multi_live_stability_findings.md`。列外生产修改须由 captain 先调整契约。
- **独立验收（verifier）** 需求阶段只写本页。验收阶段仅写 `simple_live_app/test/multi_live/{feedback_acceptance_route,feedback_stability_acceptance,extension_acceptance_route}_test.dart` 和 `docs/multi_live_feedback_verification.md`，只读生产源码。旧独立用例仅更新因用户新需求失效的断言并注明原因，例如标题入口或空 Enter 行为。保留原复现和实质断言，生产修复由对应实现者处理。
- 两项独立代码审查通过后才进入构建与包完整性校验。集成只打包通过审查的生产输入。Windows x64 交付放入新版本目录，对外只放一个便携 ZIP，保留现有程序和历史包。
