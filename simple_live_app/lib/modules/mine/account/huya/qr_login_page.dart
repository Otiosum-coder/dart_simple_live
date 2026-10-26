import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/modules/mine/account/huya/qr_login_controller.dart';

class HuyaQRLoginPage extends GetView<HuyaQRLoginController> {
  const HuyaQRLoginPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("虎牙账号登录")),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Center(
            child: Obx(() {
              var status = controller.qrStatus.value;
              if (status == HuyaQRStatus.loading) {
                return const CircularProgressIndicator();
              }
              if (status == HuyaQRStatus.failed) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text("二维码加载失败或登录失败"),
                    TextButton(
                      onPressed: controller.loadQRCode,
                      child: const Text("重试"),
                    ),
                  ],
                );
              }
              if (status == HuyaQRStatus.expired) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text("二维码已失效"),
                    TextButton(
                      onPressed: controller.loadQRCode,
                      child: const Text("刷新二维码"),
                    ),
                  ],
                );
              }
              var image = controller.qrImage.value;
              if (image == null) {
                return const CircularProgressIndicator();
              }
              return Column(
                children: [
                  ClipRRect(
                    borderRadius: AppStyle.radius12,
                    child: Image.memory(
                      image,
                      width: 200.0,
                      height: 200.0,
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                    ),
                  ),
                  AppStyle.vGap8,
                  Visibility(
                    visible: status == HuyaQRStatus.scanned,
                    child: const Text("已扫描，请在手机上确认登录"),
                  ),
                ],
              );
            }),
          ),
          const Padding(
            padding: AppStyle.edgeInsetsA24,
            child: Text(
              "请使用虎牙手机客户端扫描二维码登录\n扫码走的是虎牙登录接口，不经过网页，登录后可用于发送弹幕",
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}
