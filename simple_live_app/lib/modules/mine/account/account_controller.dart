import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/modules/mine/account/douyin/douyin_login_sheet.dart';
import 'package:simple_live_app/modules/mine/account/douyu/douyu_login_sheet.dart';
import 'package:simple_live_app/modules/mine/account/huya/huya_login_sheet.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_app/services/douyu_account_service.dart';
import 'package:simple_live_app/services/huya_account_service.dart';

class AccountController extends GetxController {
  /// 已登录平台点击后的操作面板：复制 Cookie / 重新登录 / 退出登录
  void showAccountActions({
    required String siteName,
    required String cookie,
    required VoidCallback onRelogin,
    required VoidCallback onLogout,
  }) {
    var value = cookie.trim();
    Utils.showBottomSheet(
      title: siteName,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.copy_all),
            title: const Text("复制 Cookie"),
            subtitle: Text(
              value.isEmpty
                  ? "本机没有保存 Cookie"
                  : "复制后在另一台设备的「Cookie登录」里粘贴",
            ),
            enabled: value.isNotEmpty,
            trailing: const Icon(Icons.chevron_right),
            onTap: value.isEmpty
                ? null
                : () {
                    Get.back();
                    Utils.copyToClipboard(value);
                    SmartDialog.showToast("已复制，去另一台设备「Cookie登录」粘贴");
                  },
          ),
          ListTile(
            leading: const Icon(Icons.swap_horiz),
            title: const Text("重新登录"),
            subtitle: const Text("换一个账号或刷新登录凭证"),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Get.back();
              onRelogin();
            },
          ),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text("退出登录"),
            subtitle: const Text("只清本机登录态，不会去服务端注销"),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Get.back();
              onLogout();
            },
          ),
        ],
      ),
    );
  }

  void bilibiliTap() async {
    if (BiliBiliAccountService.instance.logined.value) {
      showAccountActions(
        siteName: "哔哩哔哩账号",
        cookie: BiliBiliAccountService.instance.cookie,
        onRelogin: bilibiliLogin,
        onLogout: () {
          BiliBiliAccountService.instance.logout();
          SmartDialog.showToast("已退出哔哩哔哩账号");
        },
      );
    } else {
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
      hintText: "粘贴 www.bilibili.com 的完整 Cookie（需含 SESSDATA）",
      maxLines: 5,
    );
    if (cookie == null || cookie.isEmpty) {
      return;
    }
    cookie = Utils.extractCookieFromText(cookie);
    BiliBiliAccountService.instance.setCookie(cookie);
    await BiliBiliAccountService.instance.loadUserInfo();
  }

  void douyuTap() async {
    if (DouyuAccountService.instance.logined.value) {
      showAccountActions(
        siteName: "斗鱼账号",
        cookie: DouyuAccountService.instance.cookie,
        onRelogin: douyuLogin,
        onLogout: () {
          DouyuAccountService.instance.logout();
          SmartDialog.showToast("已退出斗鱼账号");
        },
      );
    } else {
      douyuLogin();
    }
  }

  /// 登录方式选择（扫码 / 手动填 Cookie），与播放页提示共用同一实现
  void douyuLogin() {
    showDouyuLoginSheet();
  }

  void huyaTap() async {
    if (HuyaAccountService.instance.logined.value) {
      showAccountActions(
        siteName: "虎牙账号",
        cookie: HuyaAccountService.instance.cookie,
        onRelogin: huyaLogin,
        onLogout: () {
          HuyaAccountService.instance.logout();
          SmartDialog.showToast("已退出虎牙账号");
        },
      );
    } else {
      huyaLogin();
    }
  }

  /// 登录方式选择（扫码 / Web / Cookie）
  void huyaLogin() {
    showHuyaLoginSheet();
  }

  void douyinTap() async {
    if (DouyinAccountService.instance.logined.value) {
      showAccountActions(
        siteName: "抖音账号",
        cookie: DouyinAccountService.instance.copyableCookie,
        onRelogin: douyinLogin,
        onLogout: () {
          DouyinAccountService.instance.logout();
          SmartDialog.showToast("已退出抖音账号");
        },
      );
    } else {
      douyinLogin();
    }
  }

  /// 抖音只保留 Cookie 登录与 ttwid 配置（扫码 / 手机号 / 网页登录已移除）
  void douyinLogin() {
    showDouyinLoginSheet();
  }
}
