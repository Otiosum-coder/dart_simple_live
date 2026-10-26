import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/modules/mine/account/douyin/qr_login_controller.dart';

class DouyinQRLoginPage extends GetView<DouyinQRLoginController> {
  const DouyinQRLoginPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("抖音账号登录")),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Center(
            child: Obx(() {
              var status = controller.qrStatus.value;
              if (status == DouyinQRStatus.loading) {
                return const CircularProgressIndicator();
              }
              if (status == DouyinQRStatus.failed) {
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
              if (status == DouyinQRStatus.expired) {
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
                    visible: status == DouyinQRStatus.scanned,
                    child: const Text("已扫描，请在手机上确认登录"),
                  ),
                ],
              );
            }),
          ),
          const Padding(
            padding: AppStyle.edgeInsetsA24,
            child: Text(
              "请打开「抖音APP」点左上角扫一扫登录\n抖音的二维码是图片（base64），不是链接，所以直接用图片显示",
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}
