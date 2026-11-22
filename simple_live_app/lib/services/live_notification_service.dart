import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart' as permission;
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/routes/app_navigation.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

/// 只在当前应用进程内检查并发送本地通知。
class LiveNotificationService extends GetxService
    with WidgetsBindingObserver, WindowListener {
  static LiveNotificationService get instance =>
      Get.find<LiveNotificationService>();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  final ready = false.obs;
  final permissionGranted = false.obs;
  final requestingPermission = false.obs;
  Future<void>? _initializing;
  bool _navigationReady = false;
  String? _pendingPayload;
  bool _openingRoom = false;

  bool get systemManagedPermission => Platform.isWindows || Platform.isLinux;
  bool get _isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  void onInit() {
    super.onInit();
    WidgetsBinding.instance.addObserver(this);
    if (_isDesktop) windowManager.addListener(this);
  }

  Future<LiveNotificationService> init() async {
    if (!ready.value) {
      await (_initializing ??= _initialize().whenComplete(() {
        _initializing = null;
      }));
    }
    return this;
  }

  Future<void> _initialize() async {
    try {
      final initialized = await _plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('ic_stat_playback'),
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
          macOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
          linux: LinuxInitializationSettings(defaultActionName: '打开直播间'),
          windows: WindowsInitializationSettings(
            appName: 'Simple Live',
            appUserModelId: 'OtiosumCoder.SimpleLive',
            guid: 'af59cce1-4176-4aa4-81a3-76ca89c182bc',
          ),
        ),
        onDidReceiveNotificationResponse: _onNotificationResponse,
      );
      ready.value = initialized ?? true;
      await refreshPermission();
    } catch (error, stackTrace) {
      ready.value = false;
      permissionGranted.value = false;
      Log.logPrint('系统通知初始化失败: $error\n$stackTrace');
    }
    if (!ready.value) return;
    try {
      final launch = await _plugin.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp == true) {
        _pendingPayload = launch?.notificationResponse?.payload;
        unawaited(_openPendingPayload());
      }
    } catch (error) {
      // 部分桌面环境不提供冷启动载荷，不影响进程内通知和点击。
      Log.logPrint('读取通知启动信息失败: $error');
    }
  }

  Future<void> refreshPermission() async {
    if (!ready.value) {
      permissionGranted.value = false;
      return;
    }
    try {
      if (Platform.isAndroid) {
        permissionGranted.value = await _plugin
                .resolvePlatformSpecificImplementation<
                    AndroidFlutterLocalNotificationsPlugin>()
                ?.areNotificationsEnabled() ??
            false;
      } else if (Platform.isIOS) {
        final state = await _plugin
            .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin>()
            ?.checkPermissions();
        permissionGranted.value = state?.isEnabled ?? false;
      } else if (Platform.isMacOS) {
        final state = await _plugin
            .resolvePlatformSpecificImplementation<
                MacOSFlutterLocalNotificationsPlugin>()
            ?.checkPermissions();
        permissionGranted.value = state?.isEnabled ?? false;
      } else {
        // 插件无法查询 Windows/Linux 的系统开关；设置页明确显示「由系统管理」。
        permissionGranted.value = systemManagedPermission;
      }
    } catch (error) {
      Log.logPrint('检查系统通知权限失败: $error');
      permissionGranted.value = false;
    }
  }

  Future<bool> requestPermission() async {
    if (requestingPermission.value) return permissionGranted.value;
    requestingPermission.value = true;
    try {
      await init();
      if (!ready.value) return false;
      if (Platform.isAndroid) {
        await _plugin
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
      } else if (Platform.isIOS) {
        await _plugin
            .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin>()
            ?.requestPermissions(alert: true, badge: true, sound: true);
      } else if (Platform.isMacOS) {
        await _plugin
            .resolvePlatformSpecificImplementation<
                MacOSFlutterLocalNotificationsPlugin>()
            ?.requestPermissions(alert: true, badge: true, sound: true);
      }
      await refreshPermission();
      return permissionGranted.value;
    } catch (error) {
      Log.logPrint('申请系统通知权限失败: $error');
      return false;
    } finally {
      requestingPermission.value = false;
    }
  }

  Future<void> showLiveStarted({
    required String siteId,
    required String roomId,
    required String userName,
    bool Function()? canShow,
  }) async {
    try {
      if (canShow?.call() == false || !ready.value) return;
      await refreshPermission();
      if (canShow?.call() == false || !permissionGranted.value) return;
      final site = Sites.allSites[siteId];
      if (site == null || roomId.isEmpty) return;
      final payload = jsonEncode({'siteId': siteId, 'roomId': roomId});
      await _plugin.show(
        '${siteId}_$roomId'.hashCode & 0x7fffffff,
        '$userName 开播了',
        '点击进入${site.name}直播间',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'special_follow_live',
            '特别关注开播提醒',
            channelDescription: '特别关注的主播开播时通知',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
          macOS: DarwinNotificationDetails(),
          linux: LinuxNotificationDetails(),
          windows: WindowsNotificationDetails(),
        ),
        payload: payload,
      );
    } catch (error) {
      Log.logPrint('显示开播通知失败: $error');
    }
  }

  void _onNotificationResponse(NotificationResponse response) {
    if (response.payload == null || response.payload!.isEmpty) return;
    _pendingPayload = response.payload;
    unawaited(_openPendingPayload());
  }

  void markNavigationReady() {
    _navigationReady = true;
    unawaited(_openPendingPayload());
  }

  Future<void> _openPendingPayload() async {
    if (!_navigationReady || _openingRoom) return;
    final payload = _pendingPayload;
    if (payload == null) return;
    _pendingPayload = null;
    _openingRoom = true;
    try {
      final data = jsonDecode(payload) as Map<String, dynamic>;
      final site = Sites.allSites[data['siteId']];
      final roomId = data['roomId'] as String?;
      if (site == null || roomId == null || roomId.isEmpty) return;
      if (_isDesktop) {
        if (await windowManager.isMinimized()) await windowManager.restore();
        await windowManager.show();
        await windowManager.focus();
      }
      await AppNavigator.toLiveRoomDetail(
          site: site, roomId: roomId, reuseActiveRoom: true);
    } catch (error) {
      Log.logPrint('打开开播通知失败: $error');
      SmartDialog.showToast('无法打开该直播间');
    } finally {
      _openingRoom = false;
      if (_pendingPayload != null) unawaited(_openPendingPayload());
    }
  }

  Future<void> openNotificationSettings() async {
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        await permission.openAppSettings();
      } else if (Platform.isWindows) {
        await launchUrl(Uri.parse('ms-settings:notifications'));
      } else if (Platform.isMacOS) {
        await launchUrl(Uri.parse(
            'x-apple.systempreferences:com.apple.Notifications-Settings.extension'));
      } else {
        SmartDialog.showToast('请在桌面系统的通知设置中启用 Simple Live');
      }
    } catch (error) {
      Log.logPrint('打开系统通知设置失败: $error');
      SmartDialog.showToast('请在系统设置中允许 Simple Live 发送通知');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(refreshPermission());
  }

  @override
  void onWindowFocus() => unawaited(refreshPermission());

  @override
  void onClose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_isDesktop) windowManager.removeListener(this);
    super.onClose();
  }
}
