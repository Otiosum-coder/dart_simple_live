# 多开独立验收（t5）：修复后通过自动化验收

## 第四次尝试：独立复验通过

- **移动横竖屏（MV-1）**：[分屏逻辑](../simple_live_app/lib/modules/multi_live/widgets/multi_live_viewport.dart#L38-L49) 改用整页 MediaQuery 方向，仍只调整双路移动布局的分割轴。[近方形测试](../simple_live_app/test/multi_live/integration_mobile_orientation_test.dart#L7-L25) 证实 590×600 竖屏上下、600×590 横屏左右，旋转前后两路播放器子树均仅创建一次，未销毁。
- **常亮和后台生命周期（MV-2、MV-3）**：[Video 配置](../simple_live_app/lib/modules/multi_live/integration/multi_live_media.dart#L221-L228) 显式禁用媒体组件自己的常亮及默认后台处理；[嵌入视图的观察者](../simple_live_app/lib/modules/multi_live/integration/multi_live_media.dart#L129-L218) 读取自动暂停偏好，跟踪每路播放状态并串行协调暂停与恢复。[修复方测试](../simple_live_app/test/multi_live/repair_embedded_playback_test.dart#L94-L167) 经独立运行通过，覆盖偏好开启/关闭、两条正在播放的流、手动暂停不复活、动态切换不重建 Video、前台先于原生暂停完成。另补[独立生命周期测试](../simple_live_app/test/multi_live/lifecycle_embedded_media_test.dart#L84-L158)：关闭底层 Video 常亮、偏好关闭保持播放、后台迟到开流能自动暂停且回前台恢复、关闭期间迟到暂停不会重新开播。生产关闭机制在 [player_controller.dart:919–939](../simple_live_app/lib/modules/live_room/player/player_controller.dart#L919-L939) 等待已登记的原生调用；回归以替身后端、非物理设备验证。
- **原有回归**：原七个文件保留。桌面以 Windows/macOS/Linux 策略验证四路限额，窄窗口仍保留四路，六预设、拖动调整、标题栏换位、临时放大/恢复保持身份；移动以 Android/iOS 策略验证双路限额、横竖屏、超容量存档只自动启动 seed，直接退出不覆盖四路原档；嵌套返回先恢复分屏，普通退出等待资源释放及 flush 只执行一次 pop。逐路音量、静音、清晰度/线路及发送目标隔离、原有缓存/日志脱敏、会话关闭和存档时序未发现新的阻塞问题。多路声音的验证仅表明替身能保持非零实例音量。
- **未测**：桌面和 Android/iOS 真机直播、真实账号弹幕、原生混音、原生常亮/系统后台行为与原生资源性能；通过仅指源码审查及 Flutter 单元/Widget 自动化，不构成真机验收。本次复验未改生产文件，仅调整独立测试和本报告。

| 最终独立验证 | 实际结果 |
|---|---|
| flutter.bat test --no-pub --reporter expanded test/multi_live test/bounded_chat_buffer_test.dart test/emoji_image_cache_test.dart test/log_sanitizer_test.dart test/http_log_redaction_test.dart | 80 通过（56 多开、24 既有缓存/脱敏），exit 0，bash-7baaff2594914eea。 |
| flutter.bat analyze --no-pub --no-fatal-infos --no-fatal-warnings | exit 0，17 条既有范围外 info，bash-df6703c408fa49d0。 |
| dart.bat analyze --fatal-infos lib/modules/multi_live test/multi_live | exit 0，无诊断，bash-5867600f9145441b。 |
| git diff --check / git -c core.whitespace=cr-at-eol diff --check | 原始 exit 2（既有 CRLF）；CRLF-aware exit 0。 |

## 第三次尝试：历史阻塞记录（现已修复）

早先的独立验收只新增独立回归用例与本报告，未改生产文件。以下三个原始失败保留供追溯；不是当前状态。

1. **移动端接近方形的竖屏窗口错误地左右分割（高）。** [multi_live_viewport.dart:39–45](../simple_live_app/lib/modules/multi_live/widgets/multi_live_viewport.dart#L39-L45) 用视频区域的宽高判断方向；工具栏、页脚和聊天面板会改变区域比例，不能代表设备窗口方向。移动双开用 **590×600** 窗口复现：第二路的顶部实际为 **66**，与第一路同高，而应大于第一路底部 **572**。[复现用例](../simple_live_app/test/multi_live/integration_mobile_orientation_test.dart#L7) 还会在修复后检查旋转为 600×590 时左右排列且不重建两路。修复：使用整页的 MediaQuery 方向，或由页面显式传方向；仅修改移动双开轴，不触发会话重建、不改桌面策略。
2. **真实嵌入视频启用了第二套常亮控制（高）。** [multi_live_media.dart:18](../simple_live_app/lib/modules/multi_live/integration/multi_live_media.dart#L18) 未传 wakelock；当前 media_kit_video 2.0.1 的 Video 在 video_texture.dart:131 默认启用它，:336–359 根据播放状态和销毁调用私有引用计数器，utils/wakelock.dart:19–50 独立调用 WakelockPlus.enable/disable。该计数器与应用的 [PlayerWakelockCoordinator](../simple_live_app/lib/modules/live_room/player/player_wakelock_coordinator.dart#L12-L24) 互不知情。比如仍播放的新会话已取得应用租约、其 Video 尚未挂载，此时旧 Video 销毁让插件计数归零，可在应用持有有效租约时又关闭全局常亮。实际生产 Widget、无原生后端的[回归用例](../simple_live_app/test/multi_live/lifecycle_embedded_media_test.dart#L68-L73) 断言应为 false、实为 true；竞态后果来自源码，不是设备实测。修复：对嵌入 Video 显式设 wakelock: false，延续[原单房间](../simple_live_app/lib/modules/live_room/live_room_page.dart#L304-L317) 的单一常亮所有权，不另开引用计数器。
3. **真实嵌入视频进入后台必暂停，回来不恢复（高）。** 同一 [Video 构造](../simple_live_app/lib/modules/multi_live/integration/multi_live_media.dart#L18) 还继承 media_kit_video 2.0.1 的 pauseUponEnteringBackgroundMode=true / resumeUponEnteringForegroundMode=false；video_texture.dart:281–297 实际调用暂停，不会恢复。即使设置关闭“进入后台自动暂停”，[替身播放后端 + 真实 Video 生命周期](../simple_live_app/test/multi_live/lifecycle_embedded_media_test.dart#L75-L97) 也得到（后台播放, 回前台播放）=(false,false)，预期 (true,true)。[房间观察者](../simple_live_app/lib/modules/live_room/live_room_controller.dart#L1800-L1815) 仅更新弹幕/后台标志，不能恢复播放。修复：显式采用一致的后台策略；若沿用既有 playerAutoPause 偏好，关闭时不得暂停，开启时仅恢复因后台事件而暂停的路。修复后同时验证偏好开/关，并覆盖两条正在播放的流。

### 第三次尝试的历史验证范围

- 桌面：窄窗仍允许四路，六种预设、比例分割拖动、标题栏交换、临时最大化/恢复均有模型和 Widget 覆盖；预设、交换、放大不重建播放器子树。Windows/macOS/Linux 三类并发申请在工厂前卡住第五路，替换等待旧会话释放再创建新会话。替身播放器证实四路可保留非零音量且每路静音保留设置值，未证明原生混音。
- 移动：Android/iOS 并发申请在工厂前卡住第三路；一般尺寸的竖/横布局及旋转身份通过；近方形竖屏不通过。读取桌面四路原档，只启动入口 seed，直接退出无写入，四路原档保留；有显式编辑才写可支持的快照。嵌套 PopScope 首次返回仅恢复分屏，正常退出等待会话关闭与存档 flush 后只 pop 一次；在读档期间返回不会迟到开流。见 [workspace_controller_test.dart:116–330](../simple_live_app/test/multi_live/workspace_controller_test.dart#L116-L330)。
- 接入与兼容：读回独立 embedded LiveRoomController、实际 Video/弹幕/聊天和单开默认路由；[导航交接](../simple_live_app/lib/routes/app_navigation.dart#L110-L129) 等待旧房间关闭，交接中离开不会迟到跳转。代码路径上的实例音量/画质/线路不写全局偏好。替身验证斗鱼发送连接按选中房间串行转交、停发保留接收、迟到预热/登录不夺回租约、在途发送固定目标；初始化失败、关页晚回调、替换等待、存档坏值及写入顺序原有回归通过。
- 未测：桌面和 Android/iOS 真实流播放、平台真账号弹幕、原生混音、原生常亮与系统后台行为、原生资源回收/性能。不得用上述替身结果代替实机验收。

### 第三次尝试的历史命令与退出码

使用已安装的 SDK /e/Enviroment/sdk383/flutter/bin，Flutter/Dart 命令在 simple_live_app 运行，Git 命令在仓库根目录运行。

| 命令 | 实际结果 |
|---|---|
| flutter.bat test --no-pub --reporter expanded test/multi_live test/bounded_chat_buffer_test.dart test/emoji_image_cache_test.dart test/log_sanitizer_test.dart test/http_log_redaction_test.dart | 加测试前 71 通过（47 多开 + 24 缓存/脱敏），exit 0，bash-0572128e89114b92；加入上述测试后 71 通过、3 失败，exit 1，bash-73e9dd09c8cc4553。 |
| flutter.bat test --no-pub --reporter expanded test/multi_live/integration_mobile_orientation_test.dart test/multi_live/lifecycle_embedded_media_test.dart | 三个独立断言如上，exit 1，bash-064a97f3a0604ae3。 |
| flutter.bat analyze --no-pub --no-fatal-infos --no-fatal-warnings | exit 0，17 条既有范围外 info，bash-baa0e14d54f24696。 |
| dart.bat analyze test/multi_live/integration_mobile_orientation_test.dart test/multi_live/lifecycle_embedded_media_test.dart | exit 0，bash-f8d2cb4c3c8845d2。 |
| git diff --check | exit 2，现有工作树 CRLF 被按尾随空白标记；git -c core.whitespace=cr-at-eol diff --check exit 0。 |
