# 多开界面独立验收

## 第三轮结论（2026-11-21）

**独立验收通过。MV-REF-1、MV-REF-2、MV-REF-3 均已闭环，可以进入 Windows 便携包构建。** 最终完整回归 **200 项全部通过**，退出 0：107 项既有回归（27 斗鱼状态、56 多开、24 缓存与日志脱敏）、82 项实现/修复用例、11 项独立用例。多开生产代码及全部测试的严格分析零诊断；全项目仍仅有原有的 17 条范围外 info。

本轮仅补充[独立视口测试](../simple_live_app/test/multi_live/refinement_integration_viewports_test.dart#L328)并更新此报告；生产文件只读。此前的[独立会话测试](../simple_live_app/test/multi_live/refinement_integration_sessions_test.dart#L46)继续参与全量回归。未构建或安装原生应用。

## 已验证的交互与渲染

- **直播关注与密度。** 使用实际生产选择器，在 1280×800 的 Flutter Widget 视口中打开含 1,000 位直播关注及非直播/未知状态/不支持平台条目的列表。严格保留 `liveStatus == 2` 和支持平台。列表视口为 `(296,184)–(984,564)`；第一和第八张卡片分别为 `(296,184)–(636,252)` 与 `(644,412)–(984,480)`。两列八张完整卡片及各自 40×40 头像占位均处于视口内并可命中，第 1,000 张未实例化。图片正常加载和失败回退由共同运行的本地图片替身用例覆盖。[独立几何用例](../simple_live_app/test/multi_live/refinement_integration_viewports_test.dart#L140) · [头像与筛选用例](../simple_live_app/test/multi_live/picker_dialog_test.dart)
- **链接取代平台/房号表单。** 生产对话框仅提供直播间链接输入，未关注也可添加。非法链接留在原对话框并显示行内错误；修改输入可清除错误。独立用例经真实键盘 action 启动异步解析，确认加载时禁用输入，取消只返回一次 null；重开后旧结果不会关闭新对话框。默认解析器成功返回虎牙直链的 `huya:456`。共同运行的用例覆盖四平台直链、可信短链替身、域名/路径验证、重复提交、超时和晚到失败。[独立取消与重开](../simple_live_app/test/multi_live/refinement_integration_viewports_test.dart#L176) · [默认解析器用例](../simple_live_app/test/multi_live/room_link_resolver_test.dart)
- **大列表与键盘入口，MV-REF-1 已关闭。** 保留原 Android 320×568、1.5 倍文字、1,000 位直播关注用例。输入入口无需滑过整张关注列表；聚焦后注入 210 逻辑像素键盘占位，实际点“取消”并断言对话框关闭。修复方用例还覆盖 2 倍文字、纠错和滑至末位时的操作入口。[原独立复现](../simple_live_app/test/multi_live/refinement_integration_viewports_test.dart#L219) · [修复方键盘用例](../simple_live_app/test/multi_live/picker_repair_accessibility_test.dart)
- **短视口，MV-REF-3 已关闭。** 原 280×280 桌面 1/2 倍文字、568×320 Android 默认文字加 180 像素键盘的独立用例均通过，不再有 RenderFlex overflow。布局使用与关注数量无关的有界短表单及独立关注浏览，操作栏固定保留取消和返回链接路径。1,000 位关注的浏览、草稿保留、错误显示、按钮/IME 成功提交和取消迟到任务均有共同回归；没有把操作区放回完整关注网格之后。[原最小桌面复现](../simple_live_app/test/multi_live/refinement_integration_viewports_test.dart#L252) · [原横屏复现](../simple_live_app/test/multi_live/refinement_integration_viewports_test.dart#L292) · [修复方短屏交互](../simple_live_app/test/multi_live/picker_repair_short_viewport_test.dart)
- **旋转与默认抖音解析。** 本轮新增独立用例：320×568 Android、1,000 位关注，保持编辑器和 210 像素键盘占位，旋转到 568×320 并改为 180 像素键盘占位。TextEditingController、FocusNode 身份、草稿、焦点和测试 IME 连接仍保持；表单滚动距离小于 200，取消可命中。通过原有连接继续输入及 IME done 后，未注入解析器的生产选择器一次返回 `douyin:416144012050`。核对适配器：长度不超过 16 的 ID 走 webRid 查询；这里只验证身份契约，不验证该房间存在或真实播放。[独立旋转提交](../simple_live_app/test/multi_live/refinement_integration_viewports_test.dart#L328) · [默认解析器](../simple_live_app/lib/modules/mine/parse/parse_controller.dart#L141) · [抖音适配器](../simple_live_core/lib/src/douyin_site.dart#L252)
- **紧凑工具栏，MV-REF-2 已关闭。** 普通桌面保持 40 像素顶栏。原嵌套路由 Windows 320×240、1.5/2 倍文字用例均通过，标题与所有五个入口位于顶栏内且可命中。放大文字放不下时，标题使用自适应底部行。Android 320×568、2 倍文字也通过；共同回归检查深浅主题、常规移动 56 像素顶栏和主要 48 像素触控目标。[独立窗口用例](../simple_live_app/test/multi_live/refinement_integration_viewports_test.dart#L97) · [字形和目标检查](../simple_live_app/test/multi_live/controls_repair_toolbar_test.dart)
- **逐路音量与播放器身份。** 独立用例挂载生产 MultiLivePage、真实 Controller/Session 和逐路假驱动，以实际指针拖动生产音量面板滑杆；只有对应驱动音量和显示百分比改变，另一路保持 100。选择、左右切上下及临时放大保留两路 Widget 状态和驱动身份。面板打开时替换或关闭房间后，旧滑杆/静音回调不影响其他或新会话。共同回归覆盖 Windows 四路、Android 双路、独立静音记忆、全部静音/恢复以及窄 pane 快捷音量入口。[独立手势与身份用例](../simple_live_app/test/multi_live/refinement_integration_sessions_test.dart#L46) · [四路与双路](../simple_live_app/test/multi_live/controls_refinement_session_test.dart) · [窄窗入口](../simple_live_app/test/multi_live/controls_refinement_interaction_test.dart)

### 原短视口的最终几何

以下是实际 Flutter RenderBox 测得的逻辑坐标；“添加”和“取消”列为按钮内文字边界，不作为完整触控目标的测量值。

| 场景 | 链接输入字段 | 添加文字 | 取消文字 |
|---|---|---|---|
| 280×280 桌面，2 倍文字 | (24,68)–(256,140) | (111.5,224)–(252,264) | (43.3,224)–(99.5,264) |
| 568×320 Android，180 键盘占位；可用 y<140 | (24,16)–(544,64) | (469.5,94)–(540,114) | (415.4,94)–(443.6,114) |

两项原用例均实际输入非法链接、确认错误、取消并断言路由只返回一次 null；最小桌面还纠正链接。成功提交、错误文字滚动可见与关注浏览由短屏修复用例及新增独立旋转用例补齐。

## 最终实际命令

Flutter 固定为 **3.38.3**，Dart 为 **3.10.1**。测试/分析工作目录均为 `simple_live_app`；Git 检查在仓库根目录。未升级 SDK/依赖，未改全局 PATH，所有 Flutter 测试使用 --no-pub。

执行文件：

- Flutter：`E:/Enviroment/sdk383/flutter/bin/flutter.bat`
- Dart：`E:/Enviroment/sdk383/flutter/bin/cache/dart-sdk/bin/dart.exe`
- Flutter 进程内设置：`PATH=/e/Enviroment/Git/cmd:/e/Enviroment/sdk383/flutter/bin:$PATH FLUTTER_SUPPRESS_ANALYTICS=true DART_SUPPRESS_ANALYTICS=true`。

| 命令（上表固定 SDK 入口） | 实际结果 |
|---|---|
| `flutter.bat --suppress-analytics test --no-pub --concurrency=2 --reporter expanded test/multi_live test/douyu_room_status_test.dart test/bounded_chat_buffer_test.dart test/emoji_image_cache_test.dart test/log_sanitizer_test.dart test/http_log_redaction_test.dart` | **退出 0，200 项全部通过**，最终 job `bash-774ae4e6cf8c474e`；本轮新增旋转用例之前，同命令退出 0、199 项通过，`bash-f98378ce4afa4033`。 |
| `flutter.bat --suppress-analytics test --no-pub --concurrency=1 --reporter expanded --name=rotation test/multi_live/refinement_integration_viewports_test.dart` | 退出 0、1 项通过，`bash-2c6a7ec1bb294773`。 |
| `dart.exe analyze --fatal-infos lib/modules/multi_live test/multi_live` | 退出 0，零诊断，包含新增独立用例；`bash-977cb0ea294141cc`。 |
| `flutter.bat --suppress-analytics analyze --no-pub --no-fatal-infos --no-fatal-warnings` | 退出 0，仍是 17 条既有范围外 info；`bash-3ee2f6fe7a4f4676`。其后新增独立用例已由上行严格分析覆盖。 |
| `dart.exe format --output=none --set-exit-if-changed test/multi_live/refinement_integration_viewports_test.dart test/multi_live/refinement_integration_sessions_test.dart` | 最终退出 0，2 文件均无变化。 |
| `git diff --check`；`git -c core.whitespace=cr-at-eol diff --check` | 原始退出 2（已有 CRLF 被标记）；按 CRLF 识别后退出 0。此命令检查 Git 已跟踪差异，未跟踪的多开 Dart 文件另由严格分析与实现方格式检查覆盖。 |

17 条 info 分布：app/log 1 条、旧虎牙账户字符串 3 条、账户服务 implementation_imports 2 条、danmaku_limit 依赖 1 条、旧 danmaku_input_bar 3 条、第三方 canvas_danmaku 7 条；没有多开目录诊断。精确最终分析输出由以上 job 保留。

本轮新增用例的首次探查曾因把输入框内部 Scrollable 也算作外层列表，报 `Bad state: Too many elements`，退出 1（`bash-17bd61ea177845e2`）。修正为读取 CustomScrollView 自身公开 controller 后，隔离测试及最终全套均通过；这是验收夹具错误。格式干跑也曾退出 1，执行固定 Dart formatter 后复查为 0。这两项未更改生产代码。

## 已修复问题历史

| 编号 | 原复现与影响 | 当前状态 |
|---|---|---|
| MV-REF-1，高 | Android 320×568、1.5 倍文字、1,000 关注，两次 320px 滑动后链接与取消仍在整张网格之后，滚动位置 600/95,802 | 原独立用例及 210 像素键盘分支通过 |
| MV-REF-2，中 | Windows 320×240、1.5/2 倍文字，40px 顶栏内标题 y=-6.5 越界 | 原嵌套路由用例全部通过，正常桌面仍约 40px |
| MV-REF-3，高 | Android 568×320、默认字号、180px 键盘占位，RenderFlex 向下溢出 108px；280×280、2 倍组件文字时溢出 88px | 原两项独立复现均通过，新增旋转焦点及默认解析用例通过 |

首轮完整回归 166 通过/3 失败；第二轮最后回归 185 通过/2 失败。两次均保留 107 项旧回归，均明确阻止构建；本轮 200 项全过后才正式放行。

## 证据边界

证据来自真实 Flutter Widget 布局、RenderBox 几何、hit-test、指针拖动、路由及测试 IME，播放器使用逐路假驱动。没有截图/golden，没有启动替代 Web 服务器；未做原生 Windows/移动端播放、真实直播网络和账号、系统音频混音或真机软键盘实测。多路驱动同时保有独立音量、全局静音可还原，不能据此宣称原生多路同时出声或系统混音已验证。

应用外层目前固定文字缩放为 1.0，因此 1.5/2 倍用例属于组件压力测试；键盘尺寸与旋转由 WidgetTester 注入。Android 的实际入口声明 adjustResize 并允许方向变化，但本报告不将模拟占位等同真机键盘。[应用文字策略](../simple_live_app/lib/main.dart#L228) · [最小桌面尺寸](../simple_live_app/lib/main.dart#L109) · [Android 配置](../simple_live_app/android/app/src/main/AndroidManifest.xml#L20)
