# Android 后台媒体控件 —— 独立代码审查报告（round 1）

- 审查人: verifier（独立验收与代码审查，非实现者）
- 被审任务: t1 — 实现 Android 后台媒体控件(MediaSession+MediaStyle)
- 审查任务: t3（round 1），attempt a13aaac6-36b7-4827-86e3-d47ea592ae45
- 审查对象: PlaybackService.kt、MainActivity.kt、lib/services/background_playback.dart、lib/modules/live_room/live_room_controller.dart、live_room_page.dart、AndroidManifest.xml、pubspec.yaml
- 结论: **PASS**（无 high/blocker 未解决项；仅 3 条 low 级防御性改进建议，非阻断）

## 1. 审查范围与方法

以只读方式逐行核对实现与团队需求（MediaSession + MediaStyle 通知：播放/暂停、停止、点击回 App、主播头像封面、仅单房间）及工程质量维度：
MediaSession 生命周期与释放、通知动作正确性、命令并发/幂等、播放器状态同步、多开隔离、异常与权限边界。
审查为静态代码审查；设备级动态行为（真机锁屏、蓝牙媒体键）不在本次审查可执行范围内（见第 4 节）。

## 2. 逐项审查

### 2.1 MediaSession 生命周期与释放
- PlaybackService.kt:104-109 onCreate 设置 instance 并 createMediaSession()；createMediaSession 内 setFlags(FLAG_HANDLES_MEDIA_BUTTONS|FLAG_HANDLES_TRANSPORT_CONTROLS) 并 setCallback，isActive=true。
- PlaybackService.kt onDestroy: mediaSession?.isActive=false; release(); mediaSession=null; instance=null —— 释放完整，无泄漏。
- stopPlayback()（PlaybackService.kt:392-403）先 isActive=false 再 stopForeground(STOP_FOREGROUND_REMOVE)+stopSelf，onDestroy 再次 release，幂等。
- 结论: 生命周期与释放正确。

### 2.2 通知动作正确性
- buildNotification（PlaybackService.kt:292-360）使用 Notification.MediaStyle().setMediaSession(sessionToken).setShowActionsInCompactView(0,1)，挂载 播放/暂停切换 + 停止 两个 Action。
- 切换按钮按当前状态选择 ACTION_PAUSE / ACTION_PLAY（PlaybackService.kt:311-328），停止按钮 ACTION_STOP；动作以 PendingIntent.getService 指向本服务，请求码不同（1/2/3）。
- contentIntent 为 PendingIntent.getActivity 指向 MainActivity（FLAG_ACTIVITY_NEW_TASK|SINGLE_TOP）——点击回 App 正确。
- MediaSession.Callback onPlay/onPause/onStop 同步映射到 dispatchCommand/stopPlayback，覆盖媒体键路径。
- 结论: 播放/暂停、停止、点击回 App 三类动作均正确。

### 2.3 命令并发 / 幂等
- 命令回传采用单例回调 PlaybackService.onCommand（@Volatile），由 MainActivity EventChannel onListen 注册（MainActivity.kt:66-70），onCancel/cleanUpFlutterEngine 清空。EventChannel 底层单一 EventSink，Dart 侧 receiveBroadcastStream 多监听共享同一原生订阅。
- start() 幂等：重复调用仅 onStartCommand ACTION_START 更新内容，isForeground 时走 notify 更新而非重复 startForeground（PlaybackService.kt:264-273）。
- dispatchCommand 采用乐观状态 + 回传命令，player.play/pause/stop 本身幂等；通知按钮与 MediaSession 回调不构成同一按键双路径（前者走显式 PendingIntent，后者仅硬件/车机媒体键）。
- stopPlayback 重复调用安全（stopForeground+stopSelf 幂等）。
- 结论: 命令并发与幂等满足要求。

### 2.4 播放器状态同步
- 双向同步：Dart player.stream.playing（live_room_controller.dart:204）在非 embedded 时回写 updateState('playing'/'paused')（:219/:223），并在开始播放时 syncBackgroundPlayback() 启动/更新服务（:218）。
- 通知/锁屏命令经 BackgroundPlayback.commands.listen（:228）驱动 player.play/pause/stop（switch 分支），generation 守卫防陈旧订阅。
- 原生 pushPlaybackState 依据 playbackState 设置 ACTION_PLAY|PAUSE|PLAY_PAUSE|STOP，通知按钮随真实状态翻转。
- 观察（非阻断）: Dart 仅回写 playing/paused，从未回写 buffering；原生虽支持 STATE_BUFFERING 但不会被触发。需求仅要求播放/暂停/停止，故不影响验收。
- 结论: 播放器状态双向同步正确；缓冲态未回写属可选增强。

### 2.5 多开（embedded）隔离
- 多开会话以 LiveRoomController(..., embedded: true) 构造（multi_live_room_session.dart:267）。
- embedded 时：syncBackgroundPlayback 直接 return（live_room_controller.dart:496-497 含 embedded）；playing 监听仅 !embedded 才启动服务/回写状态（:216-224）；closeRoom 仅 !embedded 才 BackgroundPlayback.stop()（:2017）。因此多开不启动/更新/停止后台媒体服务。
- 需求明确“仅单房间”，多开不提供媒体控件符合设计。
- 改进建议（RV-1，low）: 命令监听守卫 live_room_controller.dart:229 为 if (isClosed || _roomClosing || bgGeneration != _bgSubscriptionGeneration)，未包含 embedded。当前不可达（embedded 从不启动服务，且退出单房间先 closeRoom 停服务并取消订阅 :2022-2023），故为低风险；建议加入 embedded 以彻底防御并发多开。
- 结论: 多开隔离在实际可达路径上成立；建议性加固见 RV-1。

### 2.6 异常与权限边界
- 权限: AndroidManifest 声明 FOREGROUND_SERVICE、FOREGROUND_SERVICE_MEDIA_PLAYBACK、POST_NOTIFICATIONS、WAKE_LOCK；服务 foregroundServiceType=mediaPlayback；MainActivity.ensureNotificationPermission 在 Android13+ 请求 POST_NOTIFICATIONS（MainActivity.kt:98-113）。
- 头像解码 decodeAvatar 包裹 try/catch，失败回退无图（PlaybackService.kt:252-258）；Dart 侧所有通道调用均 try/catch + 日志降级（background_playback.dart），非 Android 平台整体 no-op。
- 改进建议（RV-2，low）: startForegroundCompat（PlaybackService.kt:276-285）未 try/catch；Android 12+ 自后台启动 FGS 抛 ForegroundServiceStartNotAllowedException、Android 14 类型不匹配抛 SecurityException 时会崩溃服务线程。正常流程在 App 前台启动且 manifest 正确，故低风险；建议捕获并降级。
- 改进建议（RV-3，low）: 硬件媒体键依赖活跃 MediaSession + FLAG_HANDLES_MEDIA_BUTTONS，manifest 未声明 MediaButtonReceiver；现代 Android 通常经活跃 session 路由，个别 ROM/旧版本可能不路由。真机蓝牙/耳机键测试在验收边界外，建议真机验证后再决定是否补 MediaButtonReceiver。
- 结论: 异常与权限边界整体稳健；RV-2/RV-3 为低风险加固项。

## 3. Findings（结构化）

- RV-1（low，多开隔离防御性加固）: file=simple_live_app/lib/modules/live_room/live_room_controller.dart line=229；问题: 命令监听守卫未含 embedded；修复: 在守卫条件增加 embedded。当前不可达，非阻断。
- RV-2（low，前台服务启动异常边界）: file=simple_live_app/android/app/src/main/kotlin/com/xycz/simple_live/PlaybackService.kt line=276-285；问题: startForegroundCompat 未捕获异常；修复: try/catch 降级并日志。非阻断。
- RV-3（low，硬件媒体键路由）: file=PlaybackService.kt / AndroidManifest.xml；问题: 无 MediaButtonReceiver；修复: 真机验证后按需补充。非阻断。

无 high / blocker 级问题。

## 4. 诚实边界

- 本审查为静态代码审查，未执行真机/模拟器锁屏展示与交互实测。
- 未做蓝牙/耳机媒体键硬件实测；RV-3 相关路由行为未在设备上验证。
- 未做 Android 13+ 通知权限交互式授权测试；仅确认代码请求路径存在。
- 功能正确性另有独立验收测试与构建证据（见 t2 与 docs/android_media_controls_verification.md）。

## 5. 结论

实现满足既定需求与工程质量：MediaSession 生命周期与释放正确、通知三类动作正确、命令并发/幂等安全、播放状态双向同步、多开隔离在实际可达路径成立、异常与权限边界稳健。
仅存 3 条 low 级防御性改进建议（RV-1/RV-2/RV-3），均非阻断。**审查结论: PASS。**
