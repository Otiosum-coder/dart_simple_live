import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/modules/mine/account/douyu/qr_login_controller.dart';

class DouyuQRLoginPage extends GetView<DouyuQRLoginController> {
  const DouyuQRLoginPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("斗鱼账号登录")),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Center(
            child: Obx(() {
              var status = controller.qrStatus.value;
              if (status == DouyuQRStatus.loading) {
                return const CircularProgressIndicator();
              }
              if (status == DouyuQRStatus.failed) {
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
              if (status == DouyuQRStatus.expired) {
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
              return Column(
                children: [
                  ClipRRect(
                    borderRadius: AppStyle.radius12,
                    child: QrImageView(
                      data: controller.qrcodeUrl.value,
                      version: QrVersions.auto,
                      backgroundColor: Colors.white,
                      size: 200.0,
                      padding: AppStyle.edgeInsetsA12,
                    ),
                  ),
                  AppStyle.vGap8,
                  Visibility(
                    visible: status == DouyuQRStatus.scanned,
                    child: const Text("已扫描，请在手机上确认登录"),
                  ),
                ],
              );
            }),
          ),
          const Padding(
            padding: AppStyle.edgeInsetsA24,
            child: Text(
              "请使用斗鱼手机客户端扫描二维码登录\n登录后可解除未登录状态下原画/蓝光4M 的观看限制",
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}