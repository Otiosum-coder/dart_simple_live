import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_app/modules/mine/account/douyu/douyu_login_sheet.dart';
import 'package:simple_live_app/modules/mine/account/douyin/douyin_login_sheet.dart';
import 'package:simple_live_app/modules/mine/account/huya/huya_login_sheet.dart';
import 'package:simple_live_app/services/douyu_account_service.dart';
import 'package:simple_live_app/services/huya_account_service.dart';

class AccountController extends GetxController {
  void bilibiliTap() async {
    if (BiliBiliAccountService.instance.logined.value) {
      var result = await Utils.showAlertDialog("确定要退出哔哩哔哩账号吗？", title: "退出登录");
      if (result) {
        BiliBiliAccountService.instance.logout();
      }
    } else {
      //AppNavigator.toBiliBiliLogin();
      bilibiliLogin();
    }
  }

  void bilibiliLogin() {
    Utils.showBottomSheet(
      title: "登录哔哩哔哩",
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Visibility(
            visible: Platform.isAndroid || Platform.isIOS,
            child: ListTile(
              leading: const Icon(Icons.account_circle_outlined),
              title: const Text("Web登录"),
              subtitle: const Text("填写用户名密码登录"),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Get.back();
                Get.toNamed(RoutePath.kBiliBiliWebLogin);
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.qr_code),
            title: const Text("扫码登录"),
            subtitle: const Text("使用哔哩哔哩APP扫描二维码登录"),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Get.back();
              Get.toNamed(RoutePath.kBiliBiliQRLogin);
            },
          ),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text("Cookie登录"),
            subtitle: const Text("手动输入Cookie登录"),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Get.back();
              doBiliBiliCookieLogin();
            },
          ),
        ],
      ),
    );
  }

  void doBiliBiliCookieLogin() async {
    var cookie = await Utils.showEditTextDialog(
      "",
      title: "请输入Cookie",
      hintText: "请输入Cookie",
    );
    if (cookie == null || cookie.isEmpty) {
      return;
    }
    BiliBiliAccountService.instance.setCookie(cookie);
    await BiliBiliAccountService.instance.loadUserInfo();
  }

  void douyuTap() async {
    if (DouyuAccountService.instance.logined.value) {
      var result = await Utils.showAlertDialog("确定要退出斗鱼账号吗？", title: "退出登录");
      if (result) {
        DouyuAccountService.instance.logout();
        SmartDialog.showToast("已退出斗鱼账号");
      }
    } else {
      douyuLogin();
    }
  }

  /// 登录方式选择（扫码 / 手动填 Cookie），与播放页提示共用同一实现
  void douyuLogin() {
    showDouyuLoginSheet();
  }

  void douyinTap() async {
    if (DouyinAccountService.instance.logined.value) {
      var result = await Utils.showAlertDialog("确定要退出抖音账号吗？", title: "退出登录");
      if (result) {
        DouyinAccountService.instance.logout();
        SmartDialog.showToast("已退出抖音账号");
      }
    } else {
      douyinLogin();
    }
  }

  /// 登录方式选择（扫码 / Web / 自定义 ttwid）
  void douyinLogin() {
    showDouyinLoginSheet();
  }

  void huyaTap() async {
    if (HuyaAccountService.instance.logined.value) {
      var result = await Utils.showAlertDialog("确定要退出虎牙账号吗？", title: "退出登录");
      if (result) {
        HuyaAccountService.instance.logout();
        SmartDialog.showToast("已退出虎牙账号");
      }
    } else {
      huyaLogin();
    }
  }

  /// 登录方式选择（扫码 / Web / Cookie）
  void huyaLogin() {
    showHuyaLoginSheet();
  }
}
