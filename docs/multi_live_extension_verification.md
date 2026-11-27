# 多开四项扩展独立验收

## 第二轮 · 2026-11-21 · 最终判定

**通过（pass），可进入打包。** 在 t4 修复后独立重跑完整指定回归：**278 项通过，0 失败，退出 0**。包含 9 项独立生产路由用例，第一轮的失败复现保持原样；本轮未修改测试或生产代码。t4 报告的 227 项多开通过是上游记录；本轮放行以独立执行的完整套件为准。

### MV-EXT-1 已复验关闭

- [原独立复现](../simple_live_app/test/multi_live/extension_acceptance_route_test.dart#L440-L468)通过：第一条送到离线驱动后卡住回执，Esc 关框并重新打开，第二次 Enter 不送驱动；原回执失败时草稿仍在，随后显式重试只派发一次，成功才清稿和关框。
- [侧栏入口](../simple_live_app/lib/modules/multi_live/multi_live_controller.dart#L119-L125)和[快捷框入口](../simple_live_app/lib/modules/multi_live/integration/multi_live_route.dart#L102-L121)到达同一个 [Controller 发送路径](../simple_live_app/lib/modules/multi_live/multi_live_controller.dart#L463-L489)。同步占用键为会话对象和提交文本，发生在首个 `await` 之前，只有占用者的 `finally` 释放；重复请求不等待租约，也不抵达驱动。目标 epoch、会话身份、租约、弹框撤销仍在驱动调用前复核；[已接收的驱动回执](../simple_live_app/lib/modules/multi_live/session/multi_live_room_session.dart#L156-L164)未被改写。
- 本轮也执行了修复方的补充覆盖：快捷框未获取租约时关闭，侧栏重复提交被拒绝且旧请求撤销；已派发待回执时，从侧栏重复提交被拒绝，不同文本可提交，旧成功不清新草稿，完成后可按需再发。[等待租约与替换](../simple_live_app/test/multi_live/production_route_test.dart#L405-L438) · [跨入口窗口](../simple_live_app/test/multi_live/production_route_test.dart#L440-L478)。不以这些补充用例替代独立复现。

### 四项功能的独立回归

| 扩展 | 第二轮通过的生产边界 |
|---|---|
| 整窗全屏 | 使用实际 `MyApp` 的键盘祖先，以工作区外的 Esc 作为正向对照；工作区内 Esc 按快捷框 → 单 pane 临时放大 → 整窗逐层消费。通过方法通道模拟初始化和恢复，退出路由等待恢复完成。[层级和恢复](../simple_live_app/test/multi_live/extension_acceptance_route_test.dart#L335-L382) |
| Enter 快捷弹幕 | 正常 Enter、数字键盘逻辑键和真实输入焦点；长按重复与 IME 确认不派发；选择器输入不触发快捷框；失败留稿、成功仅清当前原稿，切换、替换和路由移除撤销尚未交给驱动的请求；旧成功不碰新草稿。[按键与草稿](../simple_live_app/test/multi_live/extension_acceptance_route_test.dart#L384-L438) · [撤销与旧回执](../simple_live_app/test/multi_live/extension_acceptance_route_test.dart#L521-L614) |
| 批量添加 | 实际选择器按桌面 4 路和 Android 2 路限制容量，显示重复/满额，取消不建房也不写盘；等待最后一房时保有原唯一 sender，完成后仅最终房有租约，只保存一次。房间初始化中关闭后，迟到项被清理，不取得租约、不写盘。[容量和租约](../simple_live_app/test/multi_live/extension_acceptance_route_test.dart#L470-L519) · [批量晚到](../simple_live_app/test/multi_live/extension_acceptance_route_test.dart#L616-L637) |
| 主播名 | 恢复旧 v1 存档的音量与静音，不把旧 `title` 当主播名；待异步 `detail.userName` 返回后，裁边名称同步更新画面、聊天、快捷框和音量面板，直播标题为次要信息，存档不因元数据更新被重写。[旧档与异步更新](../simple_live_app/test/multi_live/extension_acceptance_route_test.dart#L639) |

### 本轮执行命令与结果

仍使用下方固定 SDK 与环境（Flutter 3.38.3 / Dart 3.10.1）。除了明确标出的 core/Git 命令，均从 `simple_live_app` 运行。

| 命令（固定路径前缀见第一轮） | 结果 |
|---|---|
| `flutter.bat --suppress-analytics test --no-pub --concurrency=2 --reporter expanded test/multi_live test/{douyu_room_status,bounded_chat_buffer,emoji_image_cache,log_sanitizer,http_log_redaction}_test.dart` | **退出 0，278/278 通过**；`bash-a04df3b158104cea`。 |
| `dart.exe analyze --fatal-infos` 加下方第一轮列出的完整 app scope | 退出 0，零诊断；`bash-c921b68f3b0e4114`。 |
| 在 `simple_live_core`：`dart.exe analyze --packages=../simple_live_app/.dart_tool/package_config.json --fatal-infos lib/src/{interface/live_danmaku_sender_control,common/log_sanitizer,model/live_room_status}.dart` | 退出 0，零诊断；`bash-5d509e6a5afc449b`。 |
| `flutter.bat --suppress-analytics analyze --no-pub --no-fatal-infos` | 退出 0，只有旧 17 条范围外 info，无 warning/error；`bash-c05180e8ea4a4c14`。未加 `--no-fatal-infos` 的探针退出 1，但诊断集相同（`bash-08cb950c90484436`）。 |
| `dart.exe format --output=none --set-exit-if-changed lib/modules/multi_live test/multi_live` | 退出 0，45 个文件无变化。 |
| 仓库根目录：`git -c core.whitespace=cr-at-eol diff HEAD --check`，并对未跟踪的多开源码、app 测试、本报告及相关 core 文件执行 `git -c core.whitespace=cr-at-eol diff --no-index --check -- /dev/null "$f"` | 校验脚本退出 0，无空白诊断；no-index 单文件退出 1 仅表示与空文件不同。 |

### 最终源码与未测边界

生产范围仍为下方第一轮列出的六个生产路径及其命名路由、祖先键盘、全屏、选择器、存档等集成边界；本次实现修复只改[多开控制器](../simple_live_app/lib/modules/multi_live/multi_live_controller.dart#L463-L489)和[实现方回归](../simple_live_app/test/multi_live/production_route_test.dart#L440-L478)，未改 core。六个生产路径和两个实现测试的 SHA-256 与第二轮开始快照一致；[原独立用例](../simple_live_app/test/multi_live/extension_acceptance_route_test.dart)也未改变。本轮只更新本报告，未提交或暂存任何文件。

发送和窗口生命周期是 Flutter 组件、方法通道及离线驱动层的验收，不代表实机通过。未启动原生应用、未使用真实账号或发送真实弹幕、未测真实输入法/多屏/音频/平台窗口系统、未构建或验收 ZIP，也未升级 SDK 或依赖。

## 第一轮 · 2026-11-21 · 历史记录

**需修复（needs_revision），不放行打包。** 完整指定回归共 **277 项：276 通过、1 失败，退出 1**。旧多开、斗鱼状态、缓存和日志脱敏用例共 268 项全部通过；新增独立验收 9 项，8 项通过、1 项实质失败。实现任务所报的 217 项多开通过是依赖结果，不作为独立放行依据。

### MV-EXT-1 · 高 · 同一份尚在发送的草稿可由重开的快捷框再次交给驱动

1. 打开生产多开路由，按 Enter 打开房间 101 的快捷框，输入“一条弹幕”，再次按 Enter。离线驱动收到一次调用，故意不完成回执。
2. 按 Esc 关闭快捷框，再按 Enter 打开同一房间的快捷框。原草稿仍在；回执仍未完成时再按 Enter。
3. **期望**驱动调用仍是 `["一条弹幕"]`；**实际**成为 `["一条弹幕", "一条弹幕"]`。完整套件和首次隔离探针均复现。[独立断言](../simple_live_app/test/multi_live/extension_acceptance_route_test.dart#L440-L466)

根因：发送中状态只存在于 [_MultiLiveDanmakuComposerState._sending](../simple_live_app/lib/modules/multi_live/integration/multi_live_quick_danmaku.dart#L29-L35)，[_submit](../simple_live_app/lib/modules/multi_live/integration/multi_live_quick_danmaku.dart#L87-L119) 只能阻止同一组件实例中的重复提交。Esc [撤销并移除弹框](../simple_live_app/lib/modules/multi_live/multi_live_page.dart#L67-L119)，重开后获得新的状态；[侧栏](../simple_live_app/lib/modules/multi_live/integration/multi_live_chat.dart#L39-L43) 也单独创建 composer。[Controller](../simple_live_app/lib/modules/multi_live/multi_live_controller.dart#L462-L480) 和 [Session](../simple_live_app/lib/modules/multi_live/session/multi_live_room_session.dart#L150-L164) 只核对租约和目标，不共享在途标记。真实单开底层的[通用限流](../simple_live_app/lib/modules/live_room/live_room_controller.dart#L575-L596) 允许最多两条在途且不能代替同草稿去重。本次证据是两次驱动调用，不是两条真实弹幕已上屏。

**requiredFix：** 在同一会话中为快捷框、重开后的快捷框及侧栏共享在途发送保护，调度前原子占用；不能通过关框／重建解除，只有原请求完成，或在未交给驱动前确认撤销后才释放。重复请求不得到达驱动。保持发送租约和选择 epoch 检查：换目标、关闭、替换时撤销未派发请求，已交给驱动的请求保留原回执，不得清除新目标或新编辑草稿；失败留稿，完成后可显式重试。保留上面的失败复现并重跑完整套件。

### 实测四项交互

| 扩展 | 独立证据 |
|---|---|
| 整窗全屏 | 用实际 [MyApp 祖先 KeyboardListener](../simple_live_app/lib/main.dart#L275-L290)，先在工作区外验证 Esc 确实触达 window_manager。然后由生产路由捕获初始窗口状态，以按钮进入，Esc 依次关快捷框、退出单 pane 临时放大、退出整窗，前两次的通道调用不增加。再次按 F11 进入后点返回；延迟原生撤销响应，确认房间已关闭但路由等待，随后恢复初始窗口边界再退出。[路由用例](../simple_live_app/test/multi_live/extension_acceptance_route_test.dart#L335-L382) |
| Enter 快捷弹幕 | 常规 Enter、逻辑数字键盘 Enter 与真实文本焦点；开框按键的 repeat 不发送；同帧 IME 组合提交和 send action 不发送；失败显示原因并保存草稿，旧结果不会清掉发送后新编辑的草稿，下一次当前草稿成功才关闭。生产选择器输入使用自己的 action，不弹快捷框。目标切换、替换和路由移除的未交驱动请求撤销；已派发的旧成功回执不改新弹框草稿。唯一失败是 MV-EXT-1。[焦点、IME 与草稿](../simple_live_app/test/multi_live/extension_acceptance_route_test.dart#L384-L438) · [目标切换、替换和关闭](../simple_live_app/test/multi_live/extension_acceptance_route_test.dart#L521-L614) |
| 批量添加 | 生产命名路由的实际选择器：桌面 4 路、Android 2 路；已打开链接不会进入待选，满额拒绝额外加入；取消不创建驱动、不写盘；延迟最后一房时旧租约唯一，批量完成后仅最终房间取得租约并只保存一次。初始化中关闭后，迟到房间与其他驱动均释放、没有新租约和写盘。[容量和最终租约](../simple_live_app/test/multi_live/extension_acceptance_route_test.dart#L470-L519) · [批量晚到关闭](../simple_live_app/test/multi_live/extension_acceptance_route_test.dart#L616-L637) |
| 主播名 | 旧 version 1 存档带 title、音量、静音仍恢复；不把旧标题当主播名，初始显示房号占位。异步 detail.userName 去掉首尾空白后更新画面、聊天、弹框和音量面板，直播标题作为次要信息；元数据变化未重写原存档。[旧档与异步名称](../simple_live_app/test/multi_live/extension_acceptance_route_test.dart#L639) |

### 源码快照与边界

- 工作区以 Git HEAD `47a4ce0` 为跟踪差异基准，另核对未跟踪的多开源码/测试；未暂存。独立验收只新增[本测试](../simple_live_app/test/multi_live/extension_acceptance_route_test.dart)和本报告，生产只读。
- 实现任务的六个生产改动路径：[composer](../simple_live_app/lib/modules/multi_live/integration/multi_live_quick_danmaku.dart)、[聊天侧栏](../simple_live_app/lib/modules/multi_live/integration/multi_live_chat.dart)、[多开路由](../simple_live_app/lib/modules/multi_live/integration/multi_live_route.dart)、[工作区页](../simple_live_app/lib/modules/multi_live/multi_live_page.dart)、[控制器](../simple_live_app/lib/modules/multi_live/multi_live_controller.dart)和[会话](../simple_live_app/lib/modules/multi_live/session/multi_live_room_session.dart)。生产集成也核对 [AppPages](../simple_live_app/lib/routes/app_pages.dart#L118-L124)、[单开移交](../simple_live_app/lib/routes/app_navigation.dart#L109-L131)、[全屏控制](../simple_live_app/lib/modules/multi_live/integration/multi_live_fullscreen.dart#L104-L220)、[批量选择器](../simple_live_app/lib/modules/multi_live/integration/multi_live_picker.dart#L117-L236)、[房间名回退](../simple_live_app/lib/modules/multi_live/session/multi_live_room_spec.dart#L15-L21)与[工作区存档](../simple_live_app/lib/modules/multi_live/storage/multi_live_workspace_store.dart#L24-L33)。
- 独立测试使用生产命名路由的参数解析、实际 MyApp builder、生产 composer、picker、Controller/Session 和 window_manager MethodChannel；替身只用于宿主通道、磁盘、关注数据和媒体/收发驱动等外部边界。Windows/Android 为 Flutter 组件变体，数字键盘 Enter 用 GTK 映射注入同一 Flutter 逻辑键；没有真机输入法/原生窗口实测。
- 未启动本应用或安装应用，未测试真实账号、线上登录提示交互、真实直播/弹幕发送/服务端回执、系统音频/多屏或原生窗口行为，未构建或打包。没有升级 SDK 或依赖。

### 实际命令和退出码

固定 Flutter 3.38.3、Dart 3.10.1；Bash 中使用 `/e/Enviroment/sdk383/flutter/bin/flutter.bat` 和 `/e/Enviroment/sdk383/flutter/bin/cache/dart-sdk/bin/dart.exe`。Flutter 进程内设置 `PATH=/e/Enviroment/Git/cmd:/e/Enviroment/sdk383/flutter/bin:$PATH FLUTTER_SUPPRESS_ANALYTICS=true DART_SUPPRESS_ANALYTICS=true`，Dart 严格分析和格式检查设置 `DART_SUPPRESS_ANALYTICS=true`。以下 Flutter/Dart 命令默认在 simple_live_app 下运行；Git 在仓库根目录。

| 命令（省略已列出的固定路径前缀） | 实际结果 |
|---|---|
| `flutter.bat --suppress-analytics test --no-pub --concurrency=2 --reporter expanded test/multi_live test/{douyu_room_status,bounded_chat_buffer,emoji_image_cache,log_sanitizer,http_log_redaction}_test.dart` | **退出 1，276 通过／1 失败**（MV-EXT-1）；`bash-46c1b7a8d4664dfa`。 |
| `dart.exe analyze --fatal-infos` 加下列完整 app scope | 退出 0，零诊断；`bash-8f9926c1fbba498a`。 |
| 在 simple_live_core：`dart.exe analyze --packages=../simple_live_app/.dart_tool/package_config.json --fatal-infos lib/src/{interface/live_danmaku_sender_control,common/log_sanitizer,model/live_room_status}.dart` | 退出 0，零诊断；`bash-80bc8b7532b04547`。 |
| `flutter.bat --suppress-analytics analyze --no-pub --no-fatal-infos --no-fatal-warnings` | 最终退出 0，仅旧 17 条范围外 info；`bash-e5f80e5722154b74`（改进夹具前 `bash-3541cc582d004f09` 同结果）。 |
| `dart.exe format --output=none --set-exit-if-changed lib/modules/multi_live test/multi_live` | 退出 0，45 文件无变化。 |
| `git -c core.whitespace=cr-at-eol diff HEAD --check` | 退出 0，无输出（跟踪差异）。 |
| 对 `git ls-files --others --exclude-standard -- simple_live_app/lib/modules/multi_live simple_live_app/test` 的逐条路径执行 `git -c core.whitespace=cr-at-eol diff --no-index --check -- /dev/null "$f"` | 检查脚本退出 0，无诊断；单文件 no-index 的退出 1 表示内容有差异，不作为空白失败。 |

```bash
lib/modules/multi_live test/multi_live test/{douyu_room_status,bounded_chat_buffer,emoji_image_cache,log_sanitizer,http_log_redaction}_test.dart lib/main.dart lib/routes lib/modules/live_room/live_room_{controller,page}.dart lib/modules/live_room/player/{player_controller,player_wakelock_coordinator}.dart lib/app/controller/app_settings_controller.dart lib/models/{db/follow_user,db/follow_user.g,live_start_tracker}.dart lib/modules/follow_user lib/modules/mine/account/bilibili/{qr_login,web_login}_controller.dart lib/modules/mine/account/douyu/douyu_login_sheet.dart lib/modules/settings/follow_settings_page.dart lib/requests/custom_log_interceptor.dart lib/services/{db,follow,local_storage,live_notification}_service.dart lib/utils/bounded_chat_buffer.dart lib/widgets/{follow_user_item,follow_management_sheet}.dart third_party/canvas_danmaku/lib/utils/emoji_image_cache.dart
```

17 条 info 与[上一轮项目基线](multi_live_ui_refinement_verification.md#L40-L49)分布一致：应用日志 1、旧虎牙账户代码 3、旧账号服务导入 2、弹幕长度工具 1、旧弹幕输入栏 3、第三方 canvas_danmaku 7。额外的非门禁 core 全库探查，在 simple_live_core 用 `dart.exe analyze --fatal-infos lib` 及指定 app package 映射后再试均退出 2（如旧适配器的 dead_code、unused_import；`bash-03942529f4ce4419`、`bash-e916046f255342a4`）；不能据此宣称整个 core 零诊断。生产扩展未改变 core，相关接口、状态和脱敏文件在上表通过严格分析。

早期独立探针和完整运行分别退出 1（`bash-520b94a7743341cb` 3 通过／2 失败；`bash-490d999ae2834144` 273 通过／3 失败）。其中恢复界面持续动画使全 settle 超时、测试 SDK 的 Windows legacy 数字键盘映射以及夹具异步断言是探针问题，已修正；作用域分析最初发现独立测试两处字符串拼接 info（退出 1，`bash-c1039336071e48bc`），已修正并在最终范围重验。只保留最终复现的 MV-EXT-1 为生产问题。
