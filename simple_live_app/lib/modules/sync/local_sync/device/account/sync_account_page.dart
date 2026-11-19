import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/sync/local_sync/device/account/sync_account_controller.dart';
import 'package:simple_live_app/widgets/settings/settings_card.dart';

class SyncAccountPage extends GetView<SyncAccountController> {
  const SyncAccountPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("同步账号"),
      ),
      body: Obx(() => ListView(
            padding: AppStyle.edgeInsetsA12.copyWith(top: 0),
            children: [
              SettingsCard(
                child: ListTile(
                  leading: const Icon(Icons.sync),
                  title: const Text("一键同步已登录的账号"),
                  subtitle: Text(
                    controller.loginedCount == 0
                        ? "本机尚未登录任何账号"
                        : "本机已登录 ${controller.loginedCount} 个账号",
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    controller.syncAll();
                  },
                ),
              ),
              AppStyle.vGap12,
              SettingsCard(
                child: Column(
                  children: [
                    _buildPlatformTile(
                      siteId: Constant.kBiliBili,
                      name: "哔哩哔哩",
                      logined: controller.biliLogined,
                      nickname: controller.biliName,
                      onTap: controller.syncBili,
                    ),
                    AppStyle.divider,
                    _buildPlatformTile(
                      siteId: Constant.kDouyu,
                      name: "斗鱼直播",
                      logined: controller.douyuLogined,
                      nickname: controller.douyuName,
                      onTap: controller.syncDouyu,
                    ),
                    AppStyle.divider,
                    _buildPlatformTile(
                      siteId: Constant.kHuya,
                      name: "虎牙直播",
                      logined: controller.huyaLogined,
                      nickname: controller.huyaName,
                      onTap: controller.syncHuya,
                    ),
                    AppStyle.divider,
                    _buildPlatformTile(
                      siteId: Constant.kDouyin,
                      name: "抖音直播",
                      logined: controller.douyinLogined,
                      nickname: controller.douyinName,
                      onTap: controller.syncDouyin,
                    ),
                  ],
                ),
              ),
              Padding(
                padding: AppStyle.edgeInsetsA12.copyWith(bottom: 0),
                child: Text(
                  "同步的是本机登录凭证（Cookie），建议仅在同一信任网络下使用。",
                  style: Get.textTheme.bodySmall?.copyWith(color: Colors.grey),
                ),
              ),
            ],
          )),
    );
  }

  Widget _buildPlatformTile({
    required String siteId,
    required String name,
    required bool logined,
    required String nickname,
    required void Function() onTap,
  }) {
    var logo = Sites.allSites[siteId]?.logo ?? "";
    return ListTile(
      leading: logo.isEmpty
          ? const Icon(Icons.public)
          : Image.asset(logo, width: 26, height: 26),
      title: Text(name),
      subtitle: Text(
        logined ? "本机已登录：${nickname.isEmpty ? "未知昵称" : nickname}" : "本机未登录",
      ),
      trailing: TextButton(
        onPressed: logined ? onTap : null,
        child: Text(logined ? "同步" : "未登录"),
      ),
      onTap: logined ? onTap : null,
    );
  }
}
