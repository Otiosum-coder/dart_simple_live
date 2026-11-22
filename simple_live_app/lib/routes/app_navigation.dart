import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/sync_client_info_model.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/multi_live/session/multi_live_room_spec.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/modules/mine/account/douyu/douyu_login_sheet.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/douyu_account_service.dart';
import 'package:simple_live_app/services/sync_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// APP页面跳转封装
/// * 需要参数的页面都应使用此类
/// * 如不需要参数，可以使用Get.toNamed
class AppNavigator {
  /// 跳转至分类详情
  static void toCategoryDetail(
      {required Site site, required LiveSubCategory category}) {
    Get.toNamed(RoutePath.kCategoryDetail, arguments: [site, category]);
  }

  /// 单开和多开共享相同的平台登录提示。
  static Future<void> showLiveRoomLoginTip(Site site) async {
    if (site.id == Constant.kBiliBili &&
        !BiliBiliAccountService.instance.logined.value &&
        AppSettingsController.instance.bilibiliLoginTip.value) {
      var result = await Utils.showAlertDialog(
        "哔哩哔哩需要登录才能观看高清直播，是否前往登录？",
        title: "登录哔哩哔哩",
        actions: [
          TextButton(
            onPressed: () {
              AppSettingsController.instance.setBiliBiliLoginTip(false);
              Get.back(result: false);
            },
            child: const Text("不再提示"),
          ),
        ],
      );
      if (result == true) {
        await toBiliBiliLogin();
        if (!BiliBiliAccountService.instance.logined.value) {
          SmartDialog.showToast("未完成登录");
        }
      }
    }

    if (site.id == Constant.kDouyu &&
        !DouyuAccountService.instance.logined.value &&
        AppSettingsController.instance.douyuLoginTip.value) {
      var result = await Utils.showAlertDialog(
        "斗鱼更新了新的限制：未登录观看原画 / 蓝光4M 会在 10 分钟后被中断，超清不受影响。\n是否前往登录？",
        title: "登录斗鱼",
        actions: [
          TextButton(
            onPressed: () {
              AppSettingsController.instance.setDouyuLoginTip(false);
              Get.back(result: false);
            },
            child: const Text("不再提示"),
          ),
        ],
      );
      if (result == true) {
        await showDouyuLoginSheet();
        if (!DouyuAccountService.instance.logined.value) {
          SmartDialog.showToast("可稍后在「我的-账号管理」中登录斗鱼");
        }
      }
    }

  }

  /// 跳转至直播间
  static Future<void> toLiveRoomDetail(
      {required Site site,
      required String roomId,
      bool reuseActiveRoom = false}) async {
    await showLiveRoomLoginTip(site);
    if (reuseActiveRoom && Get.isRegistered<LiveRoomController>()) {
      var foundRoom = false;
      Get.until((route) {
        foundRoom = Uri.tryParse(route.settings.name ?? "")?.path ==
            RoutePath.kLiveRoomDetail;
        return foundRoom || route.isFirst;
      });
      if (foundRoom) {
        await Get.find<LiveRoomController>().resetRoom(site, roomId);
        return;
      }
    }
    Get.toNamed(RoutePath.kLiveRoomDetail, arguments: site, parameters: {
      "roomId": roomId,
    });
    // 等绑定完成后再处理下一次通知，不等待整个页面退出。
    await WidgetsBinding.instance.endOfFrame;
  }

  static bool _switchingToMultiLive = false;

  /// 先关闭单开路由拥有的播放器和发送资源，再替换路由。
  static Future<void> toMultiLive(
      BuildContext context, LiveRoomController room) async {
    final origin = ModalRoute.of(context);
    if (_switchingToMultiLive || room.isClosed || origin?.isCurrent != true) return;
    _switchingToMultiLive = true;
    final spec = MultiLiveRoomSpec(
      siteId: room.site.id,
      roomId: room.roomId,
      streamerName: room.detail.value?.userName,
      liveTitle: room.detail.value?.title,
      danmakuVisible: room.showDanmakuState.value,
    );
    try {
      await room.closeRoom();
      if (!context.mounted || origin?.isCurrent != true) return;
      Get.offNamed(RoutePath.kMultiLive, arguments: spec);
      await WidgetsBinding.instance.endOfFrame;
    } catch (_) {
      SmartDialog.showToast('无法切换到多开直播');
    } finally {
      _switchingToMultiLive = false;
    }
  }

  /// 跳转至哔哩哔哩登录
  static Future toBiliBiliLogin() async {
    if (Platform.isAndroid || Platform.isIOS) {
      await Get.toNamed(RoutePath.kBiliBiliWebLogin);
    } else {
      await Get.toNamed(RoutePath.kBiliBiliQRLogin);
    }
  }

  /// 跳转至同步设备
  static Future toSyncDevice(
      SyncClinet client, SyncClientInfoModel info) async {
    await Get.toNamed(
      RoutePath.kLocalSyncDevice,
      arguments: {
        "client": client,
        "info": info,
      },
    );
  }
}
