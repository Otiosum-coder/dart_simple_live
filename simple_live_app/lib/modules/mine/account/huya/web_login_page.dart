import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/modules/mine/account/huya/web_login_controller.dart';

class HuyaWebLoginPage extends GetView<HuyaWebLoginController> {
  const HuyaWebLoginPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("虎牙账号登录"),
      ),
      body: InAppWebView(
        onWebViewCreated: controller.onWebViewCreated,
        onLoadStop: controller.onLoadStop,
        initialSettings: InAppWebViewSettings(
          userAgent: HuyaWebLoginController.userAgent,
          javaScriptEnabled: true,
          thirdPartyCookiesEnabled: true,
          domStorageEnabled: true,
          useShouldOverrideUrlLoading: false,
        ),
      ),
    );
  }
}
