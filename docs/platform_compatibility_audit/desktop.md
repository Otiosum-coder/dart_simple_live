# 桌面平台兼容性审计（当前工作树）

对象为主客户端 simple_live_app，重点 macOS，对照 Windows/Linux。检查包含已有修改和未跟踪的多开直播、通知；仅写本报告，不改生产代码，不构建/安装/启动交付程序，不读取凭据或触发真实账号弹幕/通知。共享测试由 validation-auditor 负责。TV/console 是独立入口，不等同于主客户端功能覆盖（[README.md:119](<E:/Project/simple_live/dart_simple_live/README.md#L119>)）。

这是先保存的证据草稿，尚待补充桌面矩阵。下文“接入”均指静态代码存在；插件注册、平台目录、CI 配置与 Dart 测试均不代表原生构建/设备通过。

## 原生约束与已排除的误判

- macOS Debug/Profile 与 Release 均开启 Sandbox、network.client、network.server、files.user-selected.read-write。Debug/Profile 另有 allow-jit。不能归因为 Release 缺服务器权限（[DebugProfile.entitlements:5](<E:/Project/simple_live/dart_simple_live/simple_live_app/macos/Runner/DebugProfile.entitlements#L5>)；[Release.entitlements:5](<E:/Project/simple_live/dart_simple_live/simple_live_app/macos/Runner/Release.entitlements#L5>)）。
- 主窗口注册插件，当前注册文件含通知、文件选择、media_kit、网络与分享（[MainFlutterWindow.swift:11](<E:/Project/simple_live/dart_simple_live/simple_live_app/macos/Runner/MainFlutterWindow.swift#L11>)；[GeneratedPluginRegistrant.swift:27](<E:/Project/simple_live/dart_simple_live/simple_live_app/macos/Flutter/GeneratedPluginRegistrant.swift#L27>)）。实际 flutter_local_notifications19.5.0 的 macOS Swift register(with:) 自行设置 UNUserNotificationCenter.delegate，不能将 AppDelegate 未额外设置代理判为缺陷。
- 工程仍写 10.14（[Podfile:1](<E:/Project/simple_live/dart_simple_live/simple_live_app/macos/Podfile#L1>)；[project.pbxproj:682](<E:/Project/simple_live/dart_simple_live/simple_live_app/macos/Runner.xcodeproj/project.pbxproj#L682>)）。当前 Flutter3.38.3 的 MacOSDeploymentTargetMigration 会在正常构建前将该格式的值迁移到10.15，FlutterMacOS pod最低10.15；因此工程值不等于实际支持10.14，也不直接证明构建失败。最低系统/迁移后工程需原生构建核验。
- 通知服务已实现 macOS权限查询/申请、所有桌面的展示及点击恢复窗口/导航（[live_notification_service.dart:54](<E:/Project/simple_live/dart_simple_live/simple_live_app/lib/services/live_notification_service.dart#L54>)、[live_notification_service.dart:114](<E:/Project/simple_live/dart_simple_live/simple_live_app/lib/services/live_notification_service.dart#L114>)、[live_notification_service.dart:221](<E:/Project/simple_live/dart_simple_live/simple_live_app/lib/services/live_notification_service.dart#L221>)）。Windows/Linux权限状态标作系统管理，不能视作真实授权状态。

## 初步功能矩阵

| 功能 | macOS | Windows | Linux | 证据/边界 |
|---|---|---|---|---|
| 直播播放与 FFI | media_kit + universal libmpv XCFramework | media_kit + DLL | 系统 libmpv依赖 | [main.dart:46](<E:/Project/simple_live/dart_simple_live/simple_live_app/lib/main.dart#L46>)；[player_controller.dart:35](<E:/Project/simple_live/dart_simple_live/simple_live_app/lib/modules/live_room/player/player_controller.dart#L35>)；尚无原生首帧/音视频证据 |
| 全屏/桌面小窗/置顶 | window_manager 接入 | 同左 | 同左，窗口管理器差异待验 | [player_controller.dart:285](<E:/Project/simple_live/dart_simple_live/simple_live_app/lib/modules/live_room/player/player_controller.dart#L285>)、[player_controller.dart:329](<E:/Project/simple_live/dart_simple_live/simple_live_app/lib/modules/live_room/player/player_controller.dart#L329>) |
| 多开整窗全屏与键盘 | F11/Esc/Enter，恢复原窗口状态 | 同左 | 同左 | [multi_live_fullscreen.dart:74](<E:/Project/simple_live/dart_simple_live/simple_live_app/lib/modules/multi_live/integration/multi_live_fullscreen.dart#L74>)；[multi_live_page.dart:133](<E:/Project/simple_live/dart_simple_live/simple_live_app/lib/modules/multi_live/multi_live_page.dart#L133>) |
| 托盘/全局快捷键 | 未发现托盘/全局注册；最后窗口关闭退出 | 关窗退出 | GTK窗口生命周期 | [AppDelegate.swift:5](<E:/Project/simple_live/dart_simple_live/simple_live_app/macos/Runner/AppDelegate.swift#L5>)；[main.cpp:33](<E:/Project/simple_live/dart_simple_live/simple_live_app/windows/runner/main.cpp#L33>)；无需求承诺，记作未实现边界 |
| 开播通知 | 接入，需授权/实机 | FFI 接入 | Dart/DBus，依赖通知服务器 | [live_notification_service.dart:32](<E:/Project/simple_live/dart_simple_live/simple_live_app/lib/services/live_notification_service.dart#L32>)、[live_notification_service.dart:54](<E:/Project/simple_live/dart_simple_live/simple_live_app/lib/services/live_notification_service.dart#L54>)；仅应用进程内轮询 |
| 账号 | Web入口仅手机；QR/Cookie独立可达 | 同左 | 同左 | [account_controller.dart:96](<E:/Project/simple_live/dart_simple_live/simple_live_app/lib/modules/mine/account/account_controller.dart#L96>)；[README.md:60](<E:/Project/simple_live/dart_simple_live/README.md#L60>)；未登录验证 |
| 截图保存 | 选择文件后写入；沙箱权限具备 | 接入 | 接入 | [player_controller.dart:403](<E:/Project/simple_live/dart_simple_live/simple_live_app/lib/modules/live_room/player/player_controller.dart#L403>) |
| 关注/配置JSON导入导出 | file_picker + 文件读写 | 同左 | 同左 | [follow_service.dart:541](<E:/Project/simple_live/dart_simple_live/simple_live_app/lib/services/follow_service.dart#L541>)；[other_settings_controller.dart:156](<E:/Project/simple_live/dart_simple_live/simple_live_app/lib/modules/settings/other/other_settings_controller.dart#L156>)；需系统对话框实测 |
| 链接/日志分享 | share_plus接入 | share_plus接入 | URI走mailto；文件分享不支持，设置页已隐藏 | [other_settings_page.dart:196](<E:/Project/simple_live/dart_simple_live/simple_live_app/lib/modules/settings/other/other_settings_page.dart#L196>)；调试日志漏分支见DSK-03 |
| LAN同步/发现 | TCP23234/UDP23235；隐私说明缺口 | 防火墙/网络类型待验 | 广播、防火墙待验 | [sync_service.dart:32](<E:/Project/simple_live/dart_simple_live/simple_live_app/lib/services/sync_service.dart#L32>)、[sync_service.dart:211](<E:/Project/simple_live/dart_simple_live/simple_live_app/lib/services/sync_service.dart#L211>) |

## 发现

### DSK-01 · 中 · macOS15+ LAN隐私用途说明缺失

分类：确定配置缺口，实际授权/恢复影响待真机。触发：首次发现/同步、拒绝后重试。完整 [Info.plist:23](<E:/Project/simple_live/dart_simple_live/simple_live_app/macos/Runner/Info.plist#L23>) 无 NSLocalNetworkUsageDescription；[sync_service.dart:43](<E:/Project/simple_live/dart_simple_live/simple_live_app/lib/services/sync_service.dart#L43>) 启动 UDP/HTTP，[sync_service.dart:97](<E:/Project/simple_live/dart_simple_live/simple_live_app/lib/services/sync_service.dart#L97>)、[sync_service.dart:126](<E:/Project/simple_live/dart_simple_live/simple_live_app/lib/services/sync_service.dart#L126>) 发送广播。Sandbox网络权限与 Local Network 隐私授权是独立层。

[Apple TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) 指出 macOS15起引入本地网络隐私、应增加用途说明，首次操作可能在用户回应前失败，须支持重试；macOS不要求iOS multicast entitlement。建议补充用途描述、拒绝后的设置引导及可重试流程。缺键本身不在此断言必崩溃/一律拒绝；需用实际分发.app验证首次提示、拒绝、授权后无需重启能否恢复。Apple还指出 unsigned/ad-hoc签名不能可靠保持LAN权限身份，当前未签名分发需专门验证。

### DSK-02 · 中 · Linux发布包运行依赖缺口

分类：合理推断，未运行发布包。触发：无系统libmpv的新Linux桌面直接解压zip。CI仅在构建机安装libmpv-dev（[build-manual.yml:245](<E:/Project/simple_live/dart_simple_live/.github/workflows/build-manual.yml#L245>)）后打包bundle（[build-manual.yml:269](<E:/Project/simple_live/dart_simple_live/.github/workflows/build-manual.yml#L269>)）；实际 media_kit_libs_linux1.2.1 的 bundled_libraries为空，使用系统libmpv。deb元数据无运行依赖（[make_config.yaml:1](<E:/Project/simple_live/dart_simple_live/simple_live_app/linux/packaging/deb/make_config.yaml#L1>)）；[main.dart:46](<E:/Project/simple_live/dart_simple_live/simple_live_app/lib/main.dart#L46>) 在runApp前初始化MediaKit。建议声明发行版和libmpv/GTK运行依赖，提供安装说明/可解析依赖的包，在干净系统验证；不把构建机装齐依赖视为用户可直接运行。

### DSK-03 · 低 · Linux Debug/Profile调试日志文件分享不支持

分类：确定代码缺陷，未动态复现。触发：DEBUG LOG -> 保存。入口 [main.dart:294](<E:/Project/simple_live/dart_simple_live/simple_live_app/lib/main.dart#L294>) 仅Debug/Profile可见，[debug_log_page.dart:29](<E:/Project/simple_live/dart_simple_live/simple_live_app/lib/modules/other/debug_log_page.dart#L29>) 无Linux分支直接SharePlus(files)。实际 share_plus12.0.2 的 SharePlusLinuxPlugin.share:20-23抛 UnimplementedError('Sharing files not supported on Linux')。设置页已隐藏分享按钮（[other_settings_page.dart:196](<E:/Project/simple_live/dart_simple_live/simple_live_app/lib/modules/settings/other/other_settings_page.dart#L196>)）。建议同样改为路径保存并捕获异步错误；Release此入口不可见，不扩大为所有日志导出失败。

## CI/README对照与待验证

macOS仅手动选中构建，continue-on-error=true；矩阵Apple Silicon/Intel；zip -y保留.app链接（[build-manual.yml:289](<E:/Project/simple_live/dart_simple_live/.github/workflows/build-manual.yml#L289>)、[build-manual.yml:343](<E:/Project/simple_live/dart_simple_live/.github/workflows/build-manual.yml#L343>)）。与README手动、未签名的边界一致（[README.md:64](<E:/Project/simple_live/dart_simple_live/README.md#L64>)、[README.md:81](<E:/Project/simple_live/dart_simple_live/README.md#L81>)），不能证明双架构已成功。Xcode步骤只选最新并打印版本，无26.1.1断言；当前connectivity_plus7.3.1文档要求Xcode>=26.1.1、macOS>=10.15。CODE_SIGN_IDENTITY为“-”，无Developer ID、公证、Gatekeeper/首次启动证据。

待补齐：Windows/Linux打包与原生注册详细对照、通知FFI/DBus限制、各平台账号方式、更新入口、Apple Intel/ARM原生FFI、最低系统与Xcode准确版本。待原生/设备验证：四站首帧/音视频/硬解/截图，多开资源压力及关闭重开，macOS Space/全屏/小窗/多显示器，X11/Wayland置顶和对话框，文件沙箱权限，LAN权限拒绝恢复/网络切换，通知前后台/点击/程序关闭边界。未执行这些验证，现阶段不作“各OS全功能通过”结论。
