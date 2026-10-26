import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/modules/mine/account/web_login_helper.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';

/// 抖音 Web 登录（手机验证码 / 密码 / 网页扫码都能用）
///
/// 直接带 `?modal_id=login` 打开首页，登录弹窗会自动弹出（实测有效），
/// 弹窗里有「扫码登录」和「验证码登录 / 密码登录」两个页签。
///
/// 登录成功不换域名，靠轮询 Cookie `sessionid` 判断。
class DouyinWebLoginController extends BaseController {
  InAppWebViewController? webViewController;

  static const String loginUrl = "https://www.douyin.com/?modal_id=login";

  static const String userAgent =
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

  static const List<String> cookieUrls = [
    "https://www.douyin.com",
    "https://douyin.com",
    "https://sso.douyin.com",
    "https://live.douyin.com",
  ];

  final WebLoginCookieHelper _helper = WebLoginCookieHelper();
  Timer? _timer;
  bool _handled = false;

  void onWebViewCreated(InAppWebViewController controller) {
    webViewController = controller;
    webViewController!.loadUrl(
      urlRequest: URLRequest(url: WebUri(loginUrl)),
    );
    _startWatch();
  }

  void _startWatch() {
    _timer?.cancel();
    _timer = _helper.watch(
      keys: const ["sessionid", "sessionid_ss"],
      urls: cookieUrls,
      onSuccess: logined,
    );
  }

  void onLoadStop(InAppWebViewController controller, Uri? uri) {
    if (uri == null || _handled) {
      return;
    }
    checkLogin();
  }

  Future checkLogin() async {
    if (_handled) {
      return;
    }
    var map = await _helper.collect(cookieUrls);
    if ((map["sessionid"] ?? "").isNotEmpty ||
        (map["sessionid_ss"] ?? "").isNotEmpty) {
      await logined(map);
    }
  }

  Future logined(Map<String, String> cookies) async {
    if (_handled) {
      return;
    }
    _handled = true;
    _timer?.cancel();
    try {
      var cookieStr = WebLoginCookieHelper.toHeader(cookies);
      Log.i("抖音Web登录：抓到的 Cookie 字段 [${cookies.keys.join(',')}]");
      DouyinAccountService.instance.setLoginCookie(cookieStr);
      if (!DouyinAccountService.instance.logined.value) {
        _handled = false;
        _startWatch();
        return;
      }
      SmartDialog.showToast("抖音登录成功");
      Get.back();
    } catch (e) {
      Log.logPrint(e);
      _handled = false;
      _startWatch();
    }
  }

  void toQRLogin() async {
    await Get.toNamed(RoutePath.kDouyinQRLogin);
    Get.back();
  }

  @override
  void onClose() {
    _timer?.cancel();
    super.onClose();
  }
}
