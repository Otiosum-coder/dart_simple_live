import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/modules/mine/account/web_login_helper.dart';
import 'package:simple_live_app/services/huya_account_service.dart';

/// 虎牙 Web 登录（账号密码 / 手机验证码 / 网页扫码都能用）
///
/// 用 `i.huya.com`（个人中心）而不是 `aq.huya.com/p/udb_login.html`：
/// 后者是给 iframe 用的登录组件，单独打开时 JS 会判断 `window.parent === window`
/// 而直接不渲染（实测 body 为空、输入框 0 个）。个人中心会自动把登录浮层弹出来，
/// 左边是二维码，右边是「密码登录 / 短信登录」两个页签。
///
/// 登录成功不换域名，所以靠轮询 Cookie `udb_uid` 判断。
class HuyaWebLoginController extends BaseController {
  InAppWebViewController? webViewController;

  static const String loginUrl = "https://i.huya.com/";

  static const String userAgent =
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

  static const List<String> cookieUrls = [
    "https://i.huya.com",
    "https://www.huya.com",
    "https://udblgn.huya.com",
    "https://huya.com",
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
      keys: const ["udb_uid"],
      urls: cookieUrls,
      onSuccess: logined,
    );
  }

  /// 有些机型 WebView 的 Cookie 同步有延迟，页面加载完再补一次检查
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
    if ((map["udb_uid"] ?? "").isNotEmpty) {
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
      Log.i("虎牙Web登录：抓到的 Cookie 字段 [${cookies.keys.join(',')}]");
      HuyaAccountService.instance.setCookie(cookieStr);
      if (!HuyaAccountService.instance.logined.value) {
        _handled = false;
        _startWatch();
        return;
      }
      SmartDialog.showToast(
          "虎牙登录成功：${HuyaAccountService.instance.name.value}");
      Get.back();
    } catch (e) {
      Log.logPrint(e);
      _handled = false;
      _startWatch();
    }
  }

  @override
  void onClose() {
    _timer?.cancel();
    super.onClose();
  }
}
