import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 抖音登录方式选择：自定义 ttwid
///
/// 抖音纯 API 扫码被风控封死（check_qrconnect 恒返回 4031），
/// 移动端/桌面端也都没有可用的网页登录页（官方只允许 App 内登录），
/// 所以这里只保留 ttwid 配置（决定画质）。
///
/// 注意「登录」和「ttwid」是两件事：
/// * ttwid 决定能不能看全部画质（含蓝光），不登录也能用；
/// * 登录（sessionid）才是身份，用于后续发送弹幕。
void showDouyinLoginSheet() {
  Utils.showBottomSheet(
    title: "登录抖音",
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: const Icon(Icons.edit_outlined),
          title: const Text("配置 ttwid"),
          subtitle: const Text("只影响画质，不影响登录"),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            Get.back();
            showDouyinCookieDialog();
          },
        ),
      ],
    ),
  );
}

/// 配置自定义 ttwid（原样回填：支持粘贴完整 Cookie，也支持只填 ttwid 的值）
void showDouyinCookieDialog() {
  var controller =
      TextEditingController(text: DouyinAccountService.instance.cookie);

  Get.dialog(
    AlertDialog(
      title: const Text("配置抖音 Cookie"),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "默认已内置有效的 ttwid，可观看所有画质（包括蓝光）。\n如有需要可自定义配置。",
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              maxLines: 3,
              decoration: const InputDecoration(
                hintText: "请粘贴 ttwid 值（留空则使用默认值）",
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () {
                // 提取 ttwid 的值部分（去掉 "ttwid=" 前缀）
                var defaultValue = DouyinSite.kDefaultCookie;
                if (defaultValue.startsWith('ttwid=')) {
                  defaultValue = defaultValue.substring(6); // 去掉 "ttwid="
                }
                controller.text = defaultValue;
              },
              icon: const Icon(Icons.restore),
              label: const Text("恢复默认 ttwid"),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Get.back(),
          child: const Text("取消"),
        ),
        TextButton(
          onPressed: () {
            var input = controller.text.trim();
            Get.back();
            if (input.isEmpty) {
              DouyinAccountService.instance.clearCookie();
              SmartDialog.showToast("已清除自定义 Cookie，将使用默认 ttwid");
            } else {
              // 如果用户只输入了 ttwid 值，自动添加 "ttwid=" 前缀
              var cookie = input;
              if (!input.startsWith('ttwid=')) {
                cookie = 'ttwid=$input';
              }
              DouyinAccountService.instance.setCookie(cookie);
              SmartDialog.showToast("ttwid 已保存");
            }
          },
          child: const Text("确定"),
        ),
      ],
    ),
  );
}
