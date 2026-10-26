import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/douyu_account_service.dart';

/// 斗鱼登录方式选择：扫码登录 / Web登录 / 手动填写 Cookie
///
/// 账号管理页和「未登录画质限制」提示都会用到，抽出来避免重复实现。
void showDouyuLoginSheet() {
  Utils.showBottomSheet(
    title: "登录斗鱼",
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: const Icon(Icons.qr_code),
          title: const Text("扫码登录"),
          subtitle: const Text("使用斗鱼APP扫描二维码登录"),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            Get.back();
            Get.toNamed(RoutePath.kDouyuQRLogin);
          },
        ),
        ListTile(
          leading: const Icon(Icons.account_circle_outlined),
          title: const Text("Web登录"),
          subtitle: const Text("账号密码 / 手机验证码登录"),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            Get.back();
            Get.toNamed(RoutePath.kDouyuWebLogin);
          },
        ),
        ListTile(
          leading: const Icon(Icons.edit_outlined),
          title: const Text("Cookie登录"),
          subtitle: const Text("手动输入Cookie登录"),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            Get.back();
            showDouyuCookieDialog();
          },
        ),
      ],
    ),
  );
}

/// 手动输入斗鱼 Cookie
Future showDouyuCookieDialog() async {
  var cookie = await Utils.showEditTextDialog(
    DouyuAccountService.instance.cookie,
    title: "请输入斗鱼Cookie",
    hintText: "粘贴 www.douyu.com 的 Cookie",
  );
  if (cookie == null || cookie.isEmpty) {
    return;
  }
  DouyuAccountService.instance.setCookie(cookie);
  if (DouyuAccountService.instance.logined.value) {
    SmartDialog.showToast(
        "斗鱼登录成功：${DouyuAccountService.instance.name.value}");
  } else {
    SmartDialog.showToast("Cookie 里缺少 acf_uid，登录态可能不完整");
  }
}