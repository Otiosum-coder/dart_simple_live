import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/sync_client_info_model.dart';
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

  /// 跳转至直播间
  static void toLiveRoomDetail(
      {required Site site, required String roomId}) async {
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
        showDouyuLoginSheet();
        if (!DouyuAccountService.instance.logined.value) {
          SmartDialog.showToast("可稍后在「我的-账号管理」中登录斗鱼");
        }
      }
    }

    Get.toNamed(RoutePath.kLiveRoomDetail, arguments: site, parameters: {
      "roomId": roomId,
    });
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
