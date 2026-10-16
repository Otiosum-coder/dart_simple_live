import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/account/bilibili_user_info_page.dart';
import 'package:simple_live_app/requests/http_client.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class BiliBiliAccountService extends GetxService {
  static BiliBiliAccountService get instance =>
      Get.find<BiliBiliAccountService>();

  var logined = false.obs;

  var cookie = "";
  var uid = 0;
  var name = "未登录".obs;

  @override
  void onInit() {
    cookie = LocalStorageService.instance
        .getValue(LocalStorageService.kBilibiliCookie, "");
    logined.value = cookie.isNotEmpty;
    // 先把已保存的 cookie 应用到站点，避免校验接口偶发失败时接口层还用着旧 cookie
    setSite();
    loadUserInfo();
    super.onInit();
  }

  Future loadUserInfo() async {
    if (cookie.isEmpty) {
      return;
    }
    try {
      var result = await HttpClient.instance.getJson(
        "https://api.bilibili.com/x/member/web/account",
        header: {
          "Cookie": cookie,
        },
      );
      if (result["code"] == 0) {
        var info = BiliBiliUserInfoModel.fromJson(result["data"]);
        name.value = info.uname ?? "未登录";
        uid = info.mid ?? 0;
        setSite();
      } else {
        SmartDialog.showToast("哔哩哔哩登录已失效，请重新登录");
        logout();
      }
    } catch (e) {
      SmartDialog.showToast("获取哔哩哔哩用户信息失败，可前往账号管理重试");
    }
  }

  void setSite() {
    var site = (Sites.allSites[Constant.kBiliBili]!.liveSite as BiliBiliSite);
    site.userId = uid;
    site.cookie = cookie;
  }

  void setCookie(String cookie) {
    this.cookie = cookie;
    LocalStorageService.instance
        .setValue(LocalStorageService.kBilibiliCookie, cookie);
    logined.value = cookie.isNotEmpty;
    // 关键：立刻应用到站点。以前只在 loadUserInfo 成功后 setSite()，
    // 而 WebView / 二维码登录只调 setCookie()，导致登录成功但站点仍用旧 cookie
    // （重启后才生效）—— 移动端"登录了却像掉登录"就是这么来的
    setSite();
    loadUserInfo();
  }

  void logout() async {
    cookie = "";
    uid = 0;
    name.value = "未登录";
    setSite();
    LocalStorageService.instance
        .setValue(LocalStorageService.kBilibiliCookie, "");
    logined.value = false;

    if (Platform.isAndroid || Platform.isIOS) {
      CookieManager cookieManager = CookieManager.instance();
      await cookieManager.deleteAllCookies();
    }
  }
}
