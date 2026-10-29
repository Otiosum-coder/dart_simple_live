import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/huya_account_service.dart';

/// 虎牙登录方式选择
///
/// * 扫码登录：原生纯 API（推荐，已打通）
/// * Cookie登录：手动粘贴
void showHuyaLoginSheet() {
  Utils.showBottomSheet(
    title: "登录虎牙",
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: const Icon(Icons.qr_code),
          title: const Text("扫码登录"),
          subtitle: const Text("使用虎牙APP扫描二维码登录（不经过网页）"),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            Get.back();
            Get.toNamed(RoutePath.kHuyaQRLogin);
          },
        ),
        ListTile(
          leading: const Icon(Icons.edit_outlined),
          title: const Text("Cookie登录"),
          subtitle: const Text("手动输入Cookie登录"),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            Get.back();
            showHuyaCookieDialog();
          },
        ),
      ],
    ),
  );
}

/// 手动输入虎牙 Cookie
Future showHuyaCookieDialog() async {
  var cookie = await Utils.showEditTextDialog(
    HuyaAccountService.instance.cookie,
    title: "请输入虎牙Cookie",
    hintText: "粘贴 www.huya.com 的 Cookie（需含 udb_uid）",
    maxLines: 5,
  );
  if (cookie == null || cookie.isEmpty) {
    return;
  }
  // 允许直接粘贴整段 cURL，自动取出 Cookie
  cookie = Utils.extractCookieFromText(cookie);
  HuyaAccountService.instance.setCookie(cookie);
  if (HuyaAccountService.instance.logined.value) {
    SmartDialog.showToast(
        "虎牙登录成功：${HuyaAccountService.instance.name.value}");
  } else {
    SmartDialog.showToast("Cookie 里缺少 udb_uid，登录态可能不完整");
  }
}