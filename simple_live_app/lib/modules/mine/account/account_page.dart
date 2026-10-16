import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/modules/mine/account/account_controller.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_app/services/douyu_account_service.dart';

class AccountPage extends GetView<AccountController> {
  const AccountPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("账号管理"),
      ),
      body: ListView(
        children: [
          const Padding(
            padding: AppStyle.edgeInsetsA12,
            child: Text(
              "哔哩哔哩账号需要登录才能看高清晰度的直播。\n斗鱼自 2026-09-21 起限制未登录用户：原画 / 蓝光4M 只能观看 10 分钟。",
              textAlign: TextAlign.center,
            ),
          ),
          Obx(
            () => ListTile(
              leading: Image.asset(
                'assets/images/bilibili_2.png',
                width: 36,
                height: 36,
              ),
              title: const Text("哔哩哔哩"),
              subtitle: Text(BiliBiliAccountService.instance.name.value),
              trailing: BiliBiliAccountService.instance.logined.value
                  ? const Icon(Icons.logout)
                  : const Icon(Icons.chevron_right),
              onTap: controller.bilibiliTap,
            ),
          ),
          Obx(
            () => ListTile(
              leading: Image.asset(
                'assets/images/douyu.png',
                width: 36,
                height: 36,
              ),
              title: const Text("斗鱼直播"),
              subtitle: Text(DouyuAccountService.instance.logined.value
                  ? DouyuAccountService.instance.name.value
                  : "未登录（原画/蓝光4M 受限）"),
              trailing: DouyuAccountService.instance.logined.value
                  ? const Icon(Icons.logout)
                  : const Icon(Icons.chevron_right),
              onTap: controller.douyuTap,
            ),
          ),
          ListTile(
            leading: Image.asset(
              'assets/images/huya.png',
              width: 36,
              height: 36,
            ),
            title: const Text("虎牙直播"),
            subtitle: const Text("无需登录"),
            enabled: false,
            trailing: const Icon(Icons.chevron_right),
          ),
          Obx(
            () => ListTile(
              leading: Image.asset(
                'assets/images/douyin.png',
                width: 36,
                height: 36,
              ),
              title: const Text("抖音直播"),
              subtitle: Text(DouyinAccountService.instance.hasCookie.value
                  ? "已自定义（${DouyinAccountService.instance.cookie.length} 字符）"
                  : "使用默认 ttwid"),
              trailing: DouyinAccountService.instance.hasCookie.value
                  ? const Icon(Icons.delete_outline)
                  : const Icon(Icons.chevron_right),
              onTap: controller.douyinTap,
            ),
          ),
        ],
      ),
    );
  }
}
