# Android 后台/锁屏媒体控件 —— 独立验收报告

- 验收人: verifier（AgentTeams 独立验收与代码审查，非实现者）
- 任务: t2 — 独立验收 Android 后台媒体控件
- 验收时间: 2026-11-22
- 仓库: dart_simple_live；应用包: simple_live_app
- 工具链: Flutter 3.38.3 / Dart 3.10.1
- 结论: **通过 (PASS)**。所有可自动化验收项均通过；真机锁屏与蓝牙/耳机媒体键为诚实边界，未在本次范围内执行（详见第 7 节）。

## 1. 需求与验收范围

依据团队目标与 t2 契约，媒体控件需满足：

1. 使用平台 MediaSession + Notification.MediaStyle 通知。
2. 通知提供 播放/暂停 切换、停止 动作。
3. 点击通知回到 App（MainActivity）。
4. 通知显示主播头像作为封面（METADATA_KEY_ALBUM_ART）。
5. 仅单房间生效；多开（embedded）路径不受影响。
6. 同时交付包含此前多开/反馈改动的 Android APK。

范围: 仅新增独立验收测试与本文档，不修改生产代码（lib/、android/app/src/main/ 为 out of scope）。

## 2. 验证命令与结果（可复现）

工作目录: simple_live_app。Flutter 可执行文件: /e/Enviroment/sdk383/flutter/bin/flutter.bat。

命令 1 — 单元测试 + 独立验收测试:

    flutter.bat test --no-pub --concurrency=2 test/background_playback_test.dart test/background_playback_acceptance_test.dart

结果: exit 0，All tests passed! 共 20 个用例（5 个既有单元测试 + 15 个独立验收用例）。

命令 2 — 改动范围静态分析:

    flutter.bat analyze --no-pub lib/services/background_playback.dart lib/modules/live_room/live_room_controller.dart test/background_playback_test.dart test/background_playback_acceptance_test.dart

结果: exit 0，No issues found!（Analyzing 4 items，零诊断）。

命令 3 — 调试 APK 构建:

    flutter.bat build apk --debug --no-pub

结果: exit 0，Built build/app/outputs/flutter-apk/app-debug.apk。

## 3. 独立验收测试覆盖（test/background_playback_acceptance_test.dart）

该测试为独立编写、只读校验，不依赖实现者内部结构，运行于 Flutter 测试环境（mock MethodChannel/EventChannel + dart:io 读取源码做契约核对）。共 15 个用例，分三组：

### A. EventChannel -> commands 命令映射（4 例）
- 原生 play/pause/stop 事件依次映射为命令流，顺序正确。
- 空串/无效事件被过滤，仅保留有意义的命令。
- 命令流为广播流，多个监听者均能收到同一命令。
- 非 Android 平台 commands 为空流且不订阅原生。

### B. Dart -> 原生 状态回写（6 例）
- updateState 对 playing/paused/buffering 逐项回写正确参数。
- updateMetadata 携带直播标题、主播名与头像字节。
- updateMetadata 无头像时仍回传标题与主播名。
- start 携带标题、artist 与头像字节。
- stop 触发 stop 方法调用。
- 非 Android 平台不调用任何通道方法（no-op 边界）。

### C. 源码契约核对（设计一致性，5 例）
- PlaybackService.kt 含 MediaSession / MediaStyle / 播放暂停停止 / 封面(ALBUM_ART) / 释放(release)。
- MainActivity.kt 暴露 EventChannel(background_playback_events) 回传，并处理 updateState/updateMetadata，cleanUpFlutterEngine 清理。
- live_room_controller.dart 双向同步（commands.listen、case play/pause/stop、updateState('playing')、syncBackgroundPlayback），并对 embedded 多开路径守卫（if (!embedded) BackgroundPlayback.stop(); 与 if (isClosed || _roomClosing || embedded) return;）。
- AndroidManifest.xml 声明 foregroundServiceType mediaPlayback、.PlaybackService 服务及 FOREGROUND_SERVICE_MEDIA_PLAYBACK / POST_NOTIFICATIONS 权限。
- pubspec.yaml 版本号为 1.11.8+11108。

补充说明: 首轮运行曾因静态断言误用 onCommand?.invoke("play") 失败（原生 play/pause 实际经 dispatchCommand 分派，仅 stop 走 onCommand?.invoke）。更正为 dispatchCommand("play")/dispatchCommand("pause") 后全部通过；此为测试自身错误修正，不涉及生产代码。

## 4. 设计逐项核对（原生 + Dart 实现）

- **MediaSession 创建与释放**: PlaybackService onCreate 创建 MediaSession("SimpleLivePlayback")；onDestroy 置 isActive=false 并 release()、实例置 null，无泄漏。
- **MediaStyle 通知**: Notification.MediaStyle().setMediaSession(sessionToken)，addAction(播放/暂停切换) + addAction(停止)，setShowActionsInCompactView(0,1)，category=TRANSPORT，setVisibility(PUBLIC)。
- **播放/暂停动作**: 媒体键回调 onPlay->dispatchCommand("play", true) / onPause->dispatchCommand("pause", false)；通知动作经 ACTION_PLAY/ACTION_PAUSE 分派，含 ACTION_PLAY_PAUSE 状态位。
- **停止动作**: onStop / ACTION_STOP 调用 onCommand?.invoke("stop") 并 stopPlayback()（stopForeground 移除 + stopSelf）。
- **点击回 App**: contentIntent 为 PendingIntent.getActivity 指向 MainActivity。
- **主播头像封面**: pushMetadata 将头像 Bitmap 写入 METADATA_KEY_ALBUM_ART；标题/主播名分别写入 TITLE/ARTIST/ALBUM。
- **状态回写**: Dart BackgroundPlayback.updateState(state) -> 原生 setStateInternal 映射 playing/paused/buffering 至 PlaybackState 状态，通知随状态刷新。
- **元数据回写**: Dart updateMetadata(title, artist, avatarBytes) 与 start(...) -> 原生 updateMetadata/start，落地通知标题与封面。
- **命令回传**: 原生 EventChannel(background_playback_events) onListen 注册 PlaybackService.onCommand 推送命令；Dart commands 订阅转 broadcast 流，空/非 Android 安全降级。
- **控制器双向同步**: live_room_controller 监听 player.stream.playing（generation 守卫防陈旧回调）回写状态；监听 commands 驱动 play/pause/stop；syncBackgroundPlayback 拉取头像并启动/更新服务；closeRoom 增量 generation 并在非 embedded 时 stop 服务。
- **仅单房间**: 启动/更新/停止均由非 embedded 的单房间控制器路径触发，多开见第 5 节。

结论: 设计要求的动作与状态均被实现覆盖，无遗漏动作或状态。

## 5. 多开（embedded）路径核对

- multi_live_room_session.dart:267 以 LiveRoomController(pSite: site, pRoomId: spec.roomId, embedded: true) 构造多开会话控制器。
- 守卫: syncBackgroundPlayback() 在 embedded 时直接 return；player.stream.playing 监听仅在 !embedded 时触发同步与状态回写；closeRoom 仅在 !embedded 时调用 BackgroundPlayback.stop()。
- 因此 embedded（多开）房间不会启动/更新/停止后台媒体服务，多开功能不受影响。
- 残留观察（低风险，非阻断）: embedded 控制器仍会无条件订阅 BackgroundPlayback.commands 流；但在仅多开模式下媒体服务从不启动，不会有命令下发，故无实际副作用。正常导航退出单房间时会 stop 服务并清理订阅。

## 6. 改动范围与版本

- pubspec.yaml 版本: 1.11.8+11108（已升版）。
- AndroidManifest.xml: 声明 .PlaybackService（exported=false, stopWithTask=true, foregroundServiceType=mediaPlayback）及 FOREGROUND_SERVICE / FOREGROUND_SERVICE_MEDIA_PLAYBACK / POST_NOTIFICATIONS / WAKE_LOCK 权限。
- 受影响生产文件（复核，不在本次改动内）: PlaybackService.kt、MainActivity.kt、lib/services/background_playback.dart、lib/modules/live_room/live_room_controller.dart、live_room_page.dart、app_settings_controller.dart。
- 本任务新增: test/background_playback_acceptance_test.dart、docs/android_media_controls_verification.md。

## 7. 诚实边界（本次未执行的验证）

- **未做真机/模拟器锁屏实测**：通知在真实锁屏界面的展示与交互未在物理设备上验证。
- **未做蓝牙/耳机媒体键硬件实测**：硬件按键事件到命令的端到端链路仅在代码与单测层面验证。
- **未做 Android 13+ 通知运行时权限的交互式授权测试**：仅确认 ensureNotificationPermission 代码路径存在（请求 POST_NOTIFICATIONS）。
- **未做 instrumentation/集成测试**：本次为单元测试 + Flutter 通道 mock + 源码契约静态核对；原生服务运行期行为（前台服务生命周期、通知渲染）依赖构建与静态证据，未做设备级动态验证。
- APK 构建为 debug 变体，未做 release 签名与混淆验证。

上述边界已如实记录，自动化可验证部分全部通过。

## 8. 发现（Findings）

- 阻断项: 无。
- 观察项（低风险）: 见第 5 节——embedded 控制器无条件订阅命令流，属防御性冗余，非缺陷；建议后续可在 embedded 时跳过订阅以进一步收敛，但不影响本次验收通过。

## 9. 结论

独立验收测试、静态分析、调试 APK 构建三项验证命令均以 exit 0 通过；设计动作/状态逐项核对无遗漏；多开（embedded）路径确认不受影响；版本号已升。媒体控件实现满足既定需求与边界。**验收通过**，并已如实标注真机锁屏/蓝牙等未执行边界。
