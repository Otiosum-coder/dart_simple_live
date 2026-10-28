import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/modules/mine/account/web_login_helper.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/douyu_account_service.dart';

/// 斗鱼 Web 登录（账号密码 / 手机验证码）
///
/// 用 `passport.douyu.com/member/login`：页面上同时有
/// 「斗鱼APP扫码登录」「密码登录」「验证码登录」三种方式，
/// 扫码已有纯 API 实现，这里主要补账号密码和手机验证码。
///
/// 登录成功不换域名，靠轮询 Cookie `acf_uid` 判断。
class DouyuWebLoginController extends BaseController {
  InAppWebViewController? webViewController;

  static const String loginUrl = "https://passport.douyu.com/member/login";

  /// 用移动端 UA：passport.douyu.com/member/login 会渲染成 H5 登录页
  /// （手机号+密码 / 手机快捷登录），而不是桌面整页
  static const String userAgent =
      "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1";

  static const List<String> cookieUrls = [
    "https://passport.douyu.com",
    "https://www.douyu.com",
    "https://douyu.com",
  ];

  final WebLoginCookieHelper _helper = WebLoginCookieHelper();
  Timer? _timer;
  bool _handled = false;

  void onWebViewCreated(InAppWebViewController controller) async {
    webViewController = controller;
    // 先清掉上次的登录态，避免退出账号后重新打开时自动登录旧账号
    await _helper.clear(cookieUrls);
    webViewController!.loadUrl(
      urlRequest: URLRequest(url: WebUri(loginUrl)),
    );
    _startWatch();
  }

  void _startWatch() {
    _timer?.cancel();
    _timer = _helper.watch(
      keys: const ["acf_uid"],
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
    if ((map["acf_uid"] ?? "").isNotEmpty) {
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
      Log.i("斗鱼Web登录：抓到的 Cookie 字段 [${cookies.keys.join(',')}]");
      DouyuAccountService.instance.setCookie(cookieStr);
      if (!DouyuAccountService.instance.logined.value) {
        _handled = false;
        _startWatch();
        return;
      }
      SmartDialog.showToast(
          "斗鱼登录成功：${DouyuAccountService.instance.name.value}");
      Get.back();
    } catch (e) {
      Log.logPrint(e);
      _handled = false;
      _startWatch();
    }
  }

  void toQRLogin() async {
    await Get.toNamed(RoutePath.kDouyuQRLogin);
    Get.back();
  }

  @override
  void onClose() {
    _timer?.cancel();
    super.onClose();
  }
}
