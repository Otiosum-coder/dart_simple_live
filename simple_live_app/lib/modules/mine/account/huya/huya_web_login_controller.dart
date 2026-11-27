import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/modules/mine/account/huya/huya_web_login_support.dart';
import 'package:simple_live_app/modules/mine/account/web_login_helper.dart';
import 'package:simple_live_app/services/huya_account_service.dart';

/// 虎牙移动端手机号（短信）登录。
///
/// 内嵌虎牙官方登录页，启动时通过 postMessage 让页面以短信模式打开并适配
/// 手机屏幕；登录成功后官方页会把登录态写进 .huya.com 的 Cookie，这里轮询
/// [udb_uid] 抓取整套 Cookie 并接回 [HuyaAccountService]。
class HuyaWebLoginController extends BaseController {
  InAppWebViewController? webViewController;

  final WebLoginCookieHelper _helper = WebLoginCookieHelper();
  Timer? _timer;
  bool _handled = false;

  void onWebViewCreated(InAppWebViewController controller) async {
    webViewController = controller;
    // 只清虎牙域名的 Cookie，避免把其它平台的登录态一起清掉
    await _helper.clear(HuyaWebLoginSupport.cookieUrls, deep: false);
    controller.loadUrl(
      urlRequest: URLRequest(url: WebUri(HuyaWebLoginSupport.loginUrl)),
    );
    _startWatch();
  }

  void _startWatch() {
    _timer?.cancel();
    _timer = _helper.watch(
      keys: const ["udb_uid"],
      urls: HuyaWebLoginSupport.cookieUrls,
      onSuccess: logined,
    );
  }

  void onLoadStop(InAppWebViewController controller, Uri? uri) {
    if (_handled) {
      return;
    }
    // 每次加载完成都重新初始化短信模式并适配手机屏幕（官方模块可能重载）
    _preparePage(controller);
    checkLogin();
  }

  Future<void> _preparePage(InAppWebViewController controller) async {
    try {
      await controller.evaluateJavascript(
        source: HuyaWebLoginSupport.initSms,
      );
      await Future.delayed(const Duration(milliseconds: 900));
      await controller.evaluateJavascript(
        source: HuyaWebLoginSupport.fitMobile,
      );
      Log.i("虎牙Web登录：已初始化为短信登录并适配手机屏幕");
    } catch (e) {
      Log.logPrint(e);
    }
  }

  Future<void> checkLogin() async {
    if (_handled) {
      return;
    }
    var map = await _helper.collect(HuyaWebLoginSupport.cookieUrls);
    if (HuyaWebLoginSupport.isLogined(map)) {
      await logined(map);
    }
  }

  Future<void> logined(Map<String, String> cookies) async {
    if (_handled) {
      return;
    }
    _handled = true;
    _timer?.cancel();
    try {
      var cookieStr = HuyaWebLoginSupport.cookieHeader(cookies);
      Log.i("虎牙Web登录：抓到的 Cookie 字段 [${cookies.keys.join(',')}]");
      HuyaAccountService.instance.setCookie(cookieStr, freshLogin: true);
      if (!HuyaAccountService.instance.logined.value) {
        _handled = false;
        _startWatch();
        return;
      }
      SmartDialog.showToast("虎牙登录成功：${HuyaAccountService.instance.name.value}");
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
