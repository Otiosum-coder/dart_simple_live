import 'dart:io';

import 'package:flutter/services.dart';
import 'package:simple_live_app/app/log.dart';

/// 「允许后台播放」用的 Android 前台服务桥接。
///
/// 为什么必须要它：Android 8.0 起，后台长时任务必须运行在前台服务里并显示一条
/// 通知；没有前台服务的进程会被系统降级成缓存进程，随时可以被省电策略回收。
/// realme / ColorOS 这类 ROM 还会用 o-stop、bgLimit（热限、CPU 超限）额外清理
/// 没有前台服务的后台应用 —— 现象就是「后台播放十几分钟被杀，再打开回到首页」。
///
/// 桌面端窗口一直存在，不需要这套东西，所以只在 Android 上调用。
class BackgroundPlayback {
  BackgroundPlayback._();

  static const MethodChannel _channel =
      MethodChannel('com.xycz.simple_live/background_playback');

  /// 是否支持（只有 Android 有前台服务）
  static bool get isSupported => Platform.isAndroid;

  /// 启动（或更新）前台服务；[title] 会显示在通知里
  ///
  /// 注意：必须在 App 还处于前台时调用 —— Android 12+ 禁止从后台启动前台服务。
  static Future<void> start(String title) async {
    if (!isSupported) {
      return;
    }
    try {
      await _channel.invokeMethod('start', {'title': title});
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
