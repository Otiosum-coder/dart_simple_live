import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:simple_live_app/app/log.dart';

/// 「允许后台播放」用的 Android 前台服务 + 媒体控件桥接。
///
/// 为什么必须要它：Android 8.0 起，后台长时任务必须运行在前台服务里并显示一条
/// 通知；没有前台服务的进程会被系统降级成缓存进程，随时可以被省电策略回收。
/// realme / ColorOS 这类 ROM 还会用 o-stop、bgLimit（热限、CPU 超限）额外清理
/// 没有前台服务的后台应用 —— 现象就是「后台播放十几分钟被杀、再打开回到首页」。
///
/// 桌面端窗口一直存在，不需要这套东西，所以只在 Android 上调用。
class BackgroundPlayback {
  BackgroundPlayback._();

  static const MethodChannel _channel =
      MethodChannel('com.xycz.simple_live/background_playback');
  static const EventChannel _events =
      EventChannel('com.xycz.simple_live/background_playback_events');

  static Stream<String>? _commandsStream;

  /// 是否支持（只有 Android 有前台服务与媒体通知）
  static bool get isSupported =>
      defaultTargetPlatform == TargetPlatform.android;

  /// 媒体通知/锁屏按钮回传的命令流，"play" / "pause" / "stop" / "previous" / "next"
  static Stream<String> get commands {
    if (!isSupported) {
      return const Stream<String>.empty();
    }
    return _commandsStream ??= _events
        .receiveBroadcastStream()
        .map((event) => event?.toString() ?? '')
        .where((event) => event.isNotEmpty);
  }

  /// 启动（或更新）前台服务；[title] 是直播标题、[artist] 是主播名，
  /// [source] 是平台名，[startedAtMillis] 是开播时间（毫秒时间戳，0=未知），
  /// [avatarBytes] 是主播头像字节（原生 BitmapFactory 解码，失败回退无图）。
  ///
  /// 注意：必须在 App 还处于前台时调用 —— Android 12+ 禁止从后台启动前台服务。
  static Future<void> start(
    String title, {
    String artist = '',
    String source = '',
    int startedAtMillis = 0,
    Uint8List? avatarBytes,
    Uint8List? platformIconBytes,
  }) async {
    if (!isSupported) {
      return;
    }
    try {
      await _channel.invokeMethod('start', {
        'title': title,
        'artist': artist,
        'source': source,
        'startedAtMillis': startedAtMillis,
        'avatar': avatarBytes,
        'platformIcon': platformIconBytes,
      });
    } catch (e) {
      Log.logPrint('启动后台播放服务失败：$e');
    }
  }

  /// 停止前台服务并移除通知（没在跑时调用也是安全的）
  static Future<void> stop() async {
    if (!isSupported) {
      return;
    }
    try {
      await _channel.invokeMethod('stop');
    } catch (e) {
      Log.logPrint('停止后台播放服务失败：$e');
    }
  }

  /// 把真实播放状态回写原生，驱动 MediaSession/通知的播放/暂停按钮。
  /// [state] 取值：playing / paused / buffering
  static Future<void> updateState(String state) async {
    if (!isSupported) {
      return;
    }
    try {
      await _channel.invokeMethod('updateState', {'state': state});
    } catch (e) {
      Log.logPrint('更新后台播放状态失败：$e');
    }
  }

  /// 把媒体元信息回写原生（标题=直播标题，artist=主播名，source=平台名，
  /// startedAtMillis=开播时间，avatar=头像字节）
  static Future<void> updateMetadata({
    String title = '',
    String artist = '',
    String source = '',
    int startedAtMillis = 0,
    Uint8List? avatarBytes,
    Uint8List? platformIconBytes,
  }) async {
    if (!isSupported) {
      return;
    }
    try {
      await _channel.invokeMethod('updateMetadata', {
        'title': title,
        'artist': artist,
        'source': source,
        'startedAtMillis': startedAtMillis,
        'avatar': avatarBytes,
        'platformIcon': platformIconBytes,
      });
    } catch (e) {
      Log.logPrint('更新后台播放信息失败：$e');
    }
  }

  /// Android 13+ 申请通知权限
  ///
  /// 即使被拒绝，前台服务仍能运行，但通知不显示，OEM 更容易把它当普通后台应用回收。
  static Future<void> ensureNotificationPermission() async {
    if (!isSupported) {
      return;
    }
    try {
      await _channel.invokeMethod('ensureNotificationPermission');
    } catch (e) {
      Log.logPrint('申请通知权限失败：$e');
    }
  }
}
