# 当前工作树测试、构建与工具链证据核验

审计任务：t4；执行者：validation-auditor；审计日期：2026-11-22。审计包含已修改和未跟踪的主 App、多开直播、开播通知和原生桥接代码。本任务仅人工写入本报告和 validation-logs；没有修复、格式化或提交生产代码，没有 pub upgrade、远端 CI、发布、交付程序安装或启动，也没有使用真实账号发送弹幕或通知。

**主 App 现有离线测试为 328 项通过、1 项失败；静态分析返回 10 条 info；两条命令均以 exit 1 结束。本轮没有任何 OS 的原生构建或真机通过证据。** 失败来自过时的计数器模板测试缺少启动依赖，不能据此推断正常生产入口启动失败。现有测试对多开状态和 Flutter 交互有较多覆盖，但不能证明 Apple 平台的原生媒体、通知、窗口或生命周期已通过。

## 1. 实际执行的检查

主 App 命令在 E:/Project/simple_live/dart_simple_live/simple_live_app 执行，明确选用现有项目 SDK。本任务独占协调了共享 test/analyze，其他审计成员避免重复慢命令。

| 命令 | 实际结果 | 证据与边界 |
| --- | --- | --- |
| `FLUTTER_SUPPRESS_ANALYTICS=true /e/Enviroment/sdk383/flutter/bin/flutter.bat --version --machine` | exit 0；Flutter 3.38.3 stable；Dart 3.10.1 | 与现有 package_config 的生成器和 Flutter 根匹配。框架 revision 19074d12f7eaf6a8180cd4036a430c1d76de904e。 |
| `FLUTTER_SUPPRESS_ANALYTICS=true /e/Enviroment/sdk383/flutter/bin/flutter.bat test --no-pub` | **exit 1**；`00:38 +328 -1: Some tests failed.` | 主 App 37 个测试文件，31 个位于多开目录。唯一失败为 [widget_test.dart:14](../../simple_live_app/test/widget_test.dart#L14)。原始 stdout 超过工具返回预算，只保留关键摘录；没有为补日志重跑。见 [测试摘录](validation-logs/test-summary.txt)。 |
| `FLUTTER_SUPPRESS_ANALYTICS=true /e/Enviroment/sdk383/flutter/bin/flutter.bat analyze --no-pub` | **exit 1**；10 issues，全为 info；无 error/warning；87.7 秒 | 未把非零退出码表述为通过。位置见 [分析记录](validation-logs/analyze-summary.txt)。 |
| `FLUTTER_SUPPRESS_ANALYTICS=true /e/Enviroment/sdk383/flutter/bin/flutter.bat --no-version-check doctor -v` | exit 0；19.7 秒；仍有 2 类警告 | PATH 指向旧 Flutter；Android 部分许可证未接受。doctor 返回0不表示构建全部可用。见 [主机记录](validation-logs/toolchain-summary.txt)。 |

测试使用现有解析和缓存，没有运行 pub get。没有观察到测试因缺失生成资产或原生资产失败；这只适用于本机现有工作树和缓存，不能证明全新检出可构建。Flutter 可能更新工具缓存和测试产物；主 App 和 core 的 pubspec 与锁文件在检查前后 SHA-256 相同，见第8节。

## 2. 工具链与本机边界

| 项目 | 本机事实 | 影响 |
| --- | --- | --- |
| 主机 | Windows 10 Pro 64 位22H2，10.0.19045.5608 | Flutter 测试在 Windows 测试引擎运行，不能换算为五种 OS 程序运行。 |
| PATH Flutter / 独立 Dart | Flutter3.32.2 / 内含Dart3.8.1；独立Dart3.9.0-123.0.dev | 低于当前 core/锁文件要求；未用于 test/analyze。 |
| 项目 SDK | Flutter3.38.3 / Dart3.10.1 | [local.properties:2](../../simple_live_app/android/local.properties#L2) 与 package_config 指向 E:/Enviroment/sdk383/flutter。 |
| Android | SDK E:/Enviroment/Android_SDK；doctor检出 android-36.1、build-tools36.1.0；Java Microsoft17.0.15+6-LTS；部分许可证未接受 | 未运行 Gradle 或 APK 构建，未自动接受许可证。 |
| Windows | VS Community2022 17.14.0（17.14.36109.1），WindowsSDK10.0.26100.0 | doctor识别工具链；未构建、安装或播放桌面程序。 |
| Apple | Windows主机；xcodebuild / pod 未在 PATH 找到 | 无本地iOS/macOS构建、签名、设备生命周期或通知证据；没有触发远端CI。 |
| Linux | 无本轮Linux主机/运行时验证 | workflow的runner和依赖安装只是定义。 |

最低 SDK 不能只看 [主App pubspec:6](../../simple_live_app/pubspec.yaml#L6) 的 Dart>=3.0.5。它直接依赖的 [core pubspec:7](../../simple_live_core/pubspec.yaml#L7) 要求Dart>=3.10.0，[主锁文件:1676](../../simple_live_app/pubspec.lock#L1676) 要求Dart>=3.10.0、Flutter>=3.38.0。[README:92](../../README.md#L92) 的Flutter>=3.38与锁一致。本轮通过显式SDK避开了PATH差异。

## 3. 五平台验证证据矩阵

这是验证证据矩阵；各原生/共享功能报告负责完整用户功能矩阵。B=只有构建定义，S=静态代码/配置，T=本机Dart/Flutter测试。没有任何平台在本轮达到原生构建或运行通过。

| 证据层级 | Android | iOS / iPadOS | Windows | macOS | Linux |
| --- | --- | --- | --- | --- | --- |
| 主App Dart/Flutter逻辑 | T：Windows主机；未运行Android程序 | T：仅Dart策略/尺寸模拟 | T：Windows测试引擎；未构建桌面程序 | T：仅Dart策略模拟 | T：仅Dart策略模拟 |
| 原生配置/桥接 | S：manifest、Gradle、Kotlin FGS/权限桥 | S：依赖与CI；Apple细项见iOS报告 | S：doctor工具链 | S：依赖与CI；细项见桌面报告 | S：CI依赖定义 |
| CI构建定义 | B：手动默认开；tag构建 | B：仅手动；默认关；允许失败；未签名 | B：手动默认开；tag构建 | B：仅手动；默认关；允许失败；arm64/x64 | B：手动默认关；tag构建 |
| 本轮原生构建 | 未执行 | 未执行 | 未执行 | 未执行 | 未执行 |
| 本轮交付程序/设备/真实媒体 | 未执行 | 未执行 | 未执行 | 未执行 | 未执行 |

## 4. 现有测试的实际覆盖

- **主App清单完整**：37文件=31多开+6根测试（聊天缓冲、斗鱼状态、图片缓存、日志清洗/脱敏、模板启动测试）。没有主App integration_test目录；Android app/src完整枚举中没有本项目androidTest/test原生用例。
- **平台上限是Dart策略**：[workspace_controller_test.dart:200](../../simple_live_app/test/multi_live/workspace_controller_test.dart#L200) 枚举Windows/macOS/Linux=4、Android/iOS=2，用替身断言槽位/driver数。TargetPlatform值不会改变实际OS。
- **播放器/生命周期是替身**：[lifecycle_embedded_media_test.dart:22](../../simple_live_app/test/multi_live/lifecycle_embedded_media_test.dart#L22) 的PlatformPlayer手动改playing状态；[同文件:45](../../simple_live_app/test/multi_live/lifecycle_embedded_media_test.dart#L45) 的VideoController notifier为空；[同文件:97](../../simple_live_app/test/multi_live/lifecycle_embedded_media_test.dart#L97) 明示无native media backend；[同文件:100](../../simple_live_app/test/multi_live/lifecycle_embedded_media_test.dart#L100) 人工派发生命周期。另见 [repair_embedded_playback_test.dart:19](../../simple_live_app/test/multi_live/repair_embedded_playback_test.dart#L19)。这些验证Dart暂停/释放顺序，无法验证真实libmpv、AVAudioSession、纹理、音频路由、系统PiP、AppDelegate和窗口生命周期。
- **会话测试抑制native初始化**：[session_lifecycle_test.dart:9](../../simple_live_app/test/multi_live/session_lifecycle_test.dart#L9) 的FakeRoomDriver记录计数/音量；[同文件:55](../../simple_live_app/test/multi_live/session_lifecycle_test.dart#L55) 明确suppress native media creation；[同文件:63](../../simple_live_app/test/multi_live/session_lifecycle_test.dart#L63) 用future模拟关闭。
- **路由名称不代表原生后端**：[production_route_test.dart:32](../../simple_live_app/test/multi_live/production_route_test.dart#L32) 是Windows TargetPlatformVariant；[同文件:69](../../simple_live_app/test/multi_live/production_route_test.dart#L69) 起替换settings/account/follows/window/player。[extension_acceptance_route_test.dart:225](../../simple_live_app/test/multi_live/extension_acceptance_route_test.dart#L225) mock窗口MethodChannel；[feedback_acceptance_route_test.dart:187](../../simple_live_app/test/multi_live/feedback_acceptance_route_test.dart#L187) mock剪贴板/窗口；[feedback_stability_regression_test.dart:144](../../simple_live_app/test/multi_live/feedback_stability_regression_test.dart#L144) mock wakelock消息。它们验证Flutter消息契约，不能证明native实现响应。
- **orientation文件仍是widget测试**：[integration_mobile_orientation_test.dart:4](../../simple_live_app/test/multi_live/integration_mobile_orientation_test.dart#L4) 导入FakeModel；[同文件:19](../../simple_live_app/test/multi_live/integration_mobile_orientation_test.dart#L19) 改tester.view.physicalSize。没有真实旋转、iPad分屏、方向锁或Android targetSdk36行为证据。
- **HTTP/弹幕保持离线**：[douyu_room_status_test.dart:12](../../simple_live_app/test/douyu_room_status_test.dart#L12) 用HttpClientAdapter；[同文件:43](../../simple_live_app/test/douyu_room_status_test.dart#L43) 对未知端点抛错；[同文件:104](../../simple_live_app/test/douyu_room_status_test.dart#L104) 注入fixture。[sender_lease_test.dart:5](../../simple_live_app/test/multi_live/sender_lease_test.dart#L5) 的FakeSocket将connect/send改为计数/内存列表；[同文件:61](../../simple_live_app/test/multi_live/sender_lease_test.dart#L61) 注入factory。通过不能证明当前网站接口、账号登录或真实弹幕已验证。
- **开播通知无直接测试**：完整检索这37文件，LiveNotificationService、Permission.notification无匹配。生产 [live_notification_service.dart:54](../../simple_live_app/lib/services/live_notification_service.dart#L54) 初始化插件、[同文件:130](../../simple_live_app/lib/services/live_notification_service.dart#L130) 请求OS权限；没有通知允许/拒绝、冷启动点击和原生前后台测试。

## 5. 确定问题、合理推断与验证缺口

P1=高、P2=中、P3=低；缺口严重度表示对“已适配”结论的影响，不代表已复现用户故障。

| ID / 类型 / 严重度 | OS / 功能 | 触发条件、精确证据与因果链 | 建议 | 验证边界 |
| --- | --- | --- | --- | --- |
| V-01 确定测试缺陷 / P2 | 全OS共用 / 启动冒烟 | [widget_test.dart:16](../../simple_live_app/test/widget_test.dart#L16) 直接pump MyApp，跳过 [main.dart:45](../../simple_live_app/lib/main.dart#L45) 起的初始化；[main.dart:185](../../simple_live_app/lib/main.dart#L185) 立即读AppSettingsController。实际报controller not found；随后 [widget_test.dart:19](../../simple_live_app/test/widget_test.dart#L19) 找不到计数器0；全套exit1。 | 维护隔离真实启动依赖的smoke fixture，断言产品UI，移除过时计数器假设。 | 本轮复现；未修复。不能推断生产main()启动失败。 |
| V-02 确定验证缺口 / P1 | 全OS，重点Apple / 原生媒体与生命周期 | [lifecycle_embedded_media_test.dart:97](../../simple_live_app/test/multi_live/lifecycle_embedded_media_test.dart#L97) 无native backend；[session_lifecycle_test.dart:55](../../simple_live_app/test/multi_live/session_lifecycle_test.dart#L55) 抑制native创建；[extension_acceptance_route_test.dart:225](../../simple_live_app/test/multi_live/extension_acceptance_route_test.dart#L225) mock窗口。Windows测试引擎不能提供各OS原生通过证据。 | 对应OS补native构建和真实媒体/生命周期验收；优先iPhone/iPad/macOS音频、后台、多开释放与通知。 | 缺口确定；本轮未运行具体native故障场景。 |
| V-03 确定CI保障缺口 / P1 | iOS/iPadOS/macOS / 构建与交付可信度 | [workflow:293](../../.github/workflows/build-manual.yml#L293)、[workflow:366](../../.github/workflows/build-manual.yml#L366) 仅手动选择；[workflow:294](../../.github/workflows/build-manual.yml#L294)、[workflow:367](../../.github/workflows/build-manual.yml#L367) continue-on-error。默认关闭且tag不执行Apple job；[workflow:403](../../.github/workflows/build-manual.yml#L403) ios --no-codesign，之后仅打包Payload。workflow没有test/analyze步骤。 | 把受支持Apple构建设为可见门禁；单独记录签名安装/设备验收；纳入test/analyze。 | 只读定义，未查/触发/声称历史run成败；未签名定义不提供安装或签名通过证据。 |
| V-04 确认本机工具差异 / P2 | 验证环境 / SDK与Android最低版本判断 | [local.properties:2](../../simple_live_app/android/local.properties#L2) 指3.38.3，PATH却3.32.2；[core pubspec:7](../../simple_live_core/pubspec.yaml#L7)/[主锁:1676](../../simple_live_app/pubspec.lock#L1676) 要求Dart3.10/Flutter3.38；[Gradle:19](../../simple_live_app/android/app/build.gradle.kts#L19)、[Gradle:38](../../simple_live_app/android/app/build.gradle.kts#L38) 委托SDK默认值。 | 明确固定正确SDK并记录版本；对齐主App有效SDK声明。 | 本轮已避开；不是交付二进制故障。 |
| V-05 确认静态诊断 / P3 | 共享Dart / 分析门禁 | analyze实际exit1，10 info。含 [danmaku_limit.dart:1](../../simple_live_app/lib/utils/danmaku_limit.dart#L1)、[danmaku_input_bar.dart:1](../../simple_live_app/lib/widgets/danmaku_input_bar.dart#L1) 直接导入未直接声明的characters；另有implementation_imports/样式诊断；位置见日志。 | 按维护策略处理依赖声明、内部导入与lint；分别记录零error/warning与命令成功。 | 无analyzer error/warning；不证明功能故障；未修复。 |
| V-06 确定权限分支，影响待真机核验 / P2 | Android / 文件导入导出 | [utils.dart:482](../../simple_live_app/lib/app/utils.dart#L482) 在sdkInt>=33改请求manageExternalStorage；拒绝则 [utils.dart:497](../../simple_live_app/lib/app/utils.dart#L497) 返回false；[follow_service.dart:548](../../simple_live_app/lib/services/follow_service.dart#L548)、[follow_service.dart:577](../../simple_live_app/lib/services/follow_service.dart#L577) 在picker前退出。拒绝该授权一定无法走文件流程。 | 核验所选文件/目录的实际权限，评估减少宽权限门槛；覆盖拒绝重试、API32/33+、document provider。 | 代码门槛确定；权限是否多余、scoped storage和返回路径可写性缺本轮官方/真机证据，未升级为已证实OS故障。 |
| V-07 确定验证缺口 / P2 | Android / 通知与FGS | [MainActivity.kt:42](../../simple_live_app/android/app/src/main/kotlin/com/xycz/simple_live/MainActivity.kt#L42) request后立即success(true)；[MainActivity.kt:60](../../simple_live_app/android/app/src/main/kotlin/com/xycz/simple_live/MainActivity.kt#L60) 异步requestPermissions，无结果回传；[background_playback.dart:57](../../simple_live_app/lib/services/background_playback.dart#L57) 仅桥调用；开播通知另在 [live_notification_service.dart:140](../../simple_live_app/lib/services/live_notification_service.dart#L140) 请求权限。桥成功不能证明授权成功。 | 验证拒绝/允许、对话框与服务顺序、后台恢复/进程回收；记录native回调和用户结果。 | 不声称拒绝POST_NOTIFICATIONS必然使FGS启动失败；未执行native通知/服务。 |

## 6. Android权限、目标SDK与原生范围

[AndroidManifest:2](../../simple_live_app/android/app/src/main/AndroidManifest.xml#L2) 至第12行声明 INTERNET、FOREGROUND_SERVICE、FOREGROUND_SERVICE_MEDIA_PLAYBACK、POST_NOTIFICATIONS、WAKE_LOCK、READ/WRITE/MANAGE_EXTERNAL_STORAGE。[同文件:22](../../simple_live_app/android/app/src/main/AndroidManifest.xml#L22) 声明PiP；[同文件:45](../../simple_live_app/android/app/src/main/AndroidManifest.xml#L45) 注册non-exported、stopWithTask的mediaPlayback服务。相机等插件最终权限以合并manifest为准，本轮未生成/验证。

[Gradle:19](../../simple_live_app/android/app/build.gradle.kts#L19)、[Gradle:38](../../simple_live_app/android/app/build.gradle.kts#L38)、[Gradle:39](../../simple_live_app/android/app/build.gradle.kts#L39) 委托compile/min/target。选中的Flutter3.38.3本地FlutterExtension.kt默认compileSdk=36、minSdk=24、targetSdk=36、NDK=28.2.13676358；这是选定SDK配置推导，**不是已构建APK最终元数据**。[settings.gradle.kts:22](../../simple_live_app/android/settings.gradle.kts#L22) 为AGP8.9.1、Kotlin2.1.0；[wrapper:5](../../simple_live_app/android/gradle/wrapper/gradle-wrapper.properties#L5) 为Gradle8.12。Java/Kotlin目标11、desugaring和desugar_jdk_libs2.1.4有静态配置；未执行Gradle编译/运行。

[PlaybackService.kt:40](../../simple_live_app/android/app/src/main/kotlin/com/xycz/simple_live/PlaybackService.kt#L40) 走startForegroundService；[同文件:64](../../simple_live_app/android/app/src/main/kotlin/com/xycz/simple_live/PlaybackService.kt#L64) 用mediaPlayback类型startForeground。[background_playback.dart:21](../../simple_live_app/lib/services/background_playback.dart#L21) 只走Android；[player_controller.dart:453](../../simple_live_app/lib/modules/live_room/player/player_controller.dart#L453) 的PiP对非Android返回。这是预期平台分支；Windows widget测试不能验证Android12+服务时机、通知拒绝、PiP、锁屏/OEM回收或Android16大屏方向行为。

截图 [player_controller.dart:403](../../simple_live_app/lib/modules/live_room/player/player_controller.dart#L403) 经player.screenshot/ImageGallerySaverPlus；成功UI没有验证插件返回结果。相册/存储权限与真实保存缺native验证；iOS授权功能问题由iOS报告定性。

外部核对边界：尝试读取 [Android通知权限官方文档](https://developer.android.com/develop/ui/views/notifications/notification-permission)、[文档/文件访问官方文档](https://developer.android.com/training/data-storage/shared/documents-files)，web_fetch均报TypeError: fetch failed；web_search报HTTP402 Insufficient Balance。这两个URL是待核对来源，未将未读内容当作证据。

## 7. 主App、core、TV、console范围

[README:119](../../README.md#L119) 将simple_live_app定义为五OS主客户端；TV和console是原始辅助客户端，主App测试结果不能分配给它们。

| 项目 | 现有测试/范围 | 本轮处理 |
| --- | --- | --- |
| 主App | 37个测试文件，主审计五OS | 完整运行一次test和analyze。 |
| core | [simple_live_core_test.dart:7](../../simple_live_core/test/simple_live_core_test.dart#L7) 起请求真实站点；[同文件:123](../../simple_live_core/test/simple_live_core_test.dart#L123) 接真实弹幕并等待30秒；[同文件:136](../../simple_live_core/test/simple_live_core_test.dart#L136) 枚举四站 | 未作为离线用例运行，避免真实站点/弹幕流量。主App fixture仅覆盖部分共享逻辑。 |
| TV | Android/Windows目录；[widget_test.dart:14](../../simple_live_tv_app/test/widget_test.dart#L14) 仍是计数器模板；[pubspec:12](../../simple_live_tv_app/pubspec.yaml#L12) 依赖core | 未跑TV测试或构建；无遥控器/焦点/电视布局/媒体通过证据。 |
| console | [all_live_console_test.dart:4](../../simple_live_console/test/all_live_console_test.dart#L4) 仅空calculate测试 | 未执行；空测试不能证明CLI/站点功能，不计入主App功能通过率。 |

## 8. 依赖不变核验与后续验收

检查前后摘要一致：

| 文件 | 前后共同SHA-256 |
| --- | --- |
| [主App pubspec](../../simple_live_app/pubspec.yaml) | f75e445bacd38e468f0f189cb22746b840d68bd34c69e2bf2d6fea719d06435f |
| [主App lock](../../simple_live_app/pubspec.lock) | 812ddc297c91db1669371735199b54a12d2b942c387bd3e2ece499470ca838dc |
| [core pubspec](../../simple_live_core/pubspec.yaml) | e111950a0ca25d7d5445685e891863d1bcb412cd998007dd8d10f1948b3b85e8 |
| [core lock](../../simple_live_core/pubspec.lock) | c91c1b6ad7f4899c1c92cc2275ee687faad2c617f96bf471a380949848865cb6 |

后续先恢复启动冒烟测试，建立各OS构建证据；优先iPhone/iPad/macOS真实流、单路/多路、后台恢复、横竖屏/iPad多任务、音频路由、关闭释放、通知拒绝/允许/冷启动点击、分享/文件/相册；Android补API24、32、33+、36权限/FGS/PiP/大屏；各桌面补真实媒体库、窗口/托盘/退出。以上是待执行项目，本轮未宣称通过。
