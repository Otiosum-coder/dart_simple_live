import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';

class BiliBiliWebLoginController extends BaseController {
  InAppWebViewController? webViewController;
  final CookieManager cookieManager = CookieManager.instance();
  void onWebViewCreated(InAppWebViewController controller) {
    webViewController = controller;
    webViewController!.loadUrl(
      urlRequest: URLRequest(
        url: WebUri("https://passport.bilibili.com/login"),
      ),
    );
  }

  void toQRLogin() async {
    await Get.toNamed(RoutePath.kBiliBiliQRLogin);
    Get.back();
  }

  void onLoadStop(InAppWebViewController controller, Uri? uri) async {
    if (uri == null) {
      return;
    }
    if (uri.host == "m.bilibili.com") {
      logined();
    }
  }

  Future<bool> logined() async {
    try {
      // 登录流程跨了 passport / www / 裸域，只查一个域容易漏掉 SESSDATA
      var cookieMap = <String, String>{};
      for (final url in const [
        "https://www.bilibili.com",
        "https://bilibili.com",
        "https://passport.bilibili.com",
      ]) {
        var cookies = await cookieManager.getCookies(url: WebUri(url));
        for (final e in cookies) {
          if (e.name.isNotEmpty && e.value.isNotEmpty) {
            cookieMap[e.name] = e.value;
          }
        }
      }
      if (cookieMap.isEmpty) {
        return false;
      }
      var cookieStr =
          cookieMap.entries.map((e) => "${e.key}=${e.value}").join(";");
      Log.i(cookieStr);
      BiliBiliAccountService.instance.setCookie(cookieStr);
      await BiliBiliAccountService.instance.loadUserInfo();
      Get.back();
      return true;
    } catch (e) {
      return false;
    }
  }
}
