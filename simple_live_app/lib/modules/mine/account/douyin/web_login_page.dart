import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/modules/mine/account/douyin/web_login_controller.dart';

class DouyinWebLoginPage extends GetView<DouyinWebLoginController> {
  const DouyinWebLoginPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("抖音账号登录"),
        actions: [
          TextButton.icon(
            onPressed: controller.toQRLogin,
            icon: const Icon(Icons.qr_code),
            label: const Text("扫码登录"),
          ),
        ],
      ),
      body: InAppWebView(
        onWebViewCreated: controller.onWebViewCreated,
        onLoadStop: controller.onLoadStop,
        initialSettings: InAppWebViewSettings(
          userAgent: DouyinWebLoginController.userAgent,
          javaScriptEnabled: true,
          thirdPartyCookiesEnabled: true,
          domStorageEnabled: true,
          useShouldOverrideUrlLoading: false,
        ),
      ),
    );
  }
}
