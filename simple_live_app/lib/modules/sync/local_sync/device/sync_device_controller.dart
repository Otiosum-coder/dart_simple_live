import 'dart:convert';

import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/sync_client_info_model.dart';
import 'package:simple_live_app/requests/sync_client_request.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/sync_service.dart';

class SyncDeviceController extends BaseController {
  final SyncClinet client;
  final SyncClientInfoModel info;
  SyncDeviceController({required this.client, required this.info});
  SyncClientRequest request = SyncClientRequest();

  Future<bool> showOverlayDialog() async {
    var overlay = await Utils.showAlertDialog(
      "是否覆盖远端数据？",
      title: "数据覆盖",
      confirm: "覆盖",
      cancel: "不覆盖",
    );
    return overlay;
  }

  /// 让用户选同步方向（关注数量显示在设备页，这里只做选择）
  void showSyncDirectionSheet() {
    Utils.showBottomSheet(
      title: "选择同步方向",
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.upload_outlined),
            title: const Text("本机覆盖对方"),
            subtitle: Text(
                "把本机的 ${DBService.instance.getFollowList().length} 个关注推给对方"),
            onTap: () {
              Get.back();
              syncFollowAndTag();
            },
          ),
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: const Text("对方覆盖本机"),
            subtitle: Text("拉取对方的 ${info.followCount} 个关注覆盖本机"),
            onTap: () {
              Get.back();
              pullFollowAndTag();
            },
          ),
        ],
      ),
    );
  }

  /// 反向同步：拉取对方数据覆盖本机
  void pullFollowAndTag() async {
    try {
      var localCount = DBService.instance.getFollowList().length;
      var ok = await Utils.showAlertDialog(
        "将用对方数据覆盖本机，本机现有 $localCount 个关注。确定吗？",
        title: "对方覆盖本机",
        confirm: "覆盖",
        cancel: "取消",
      );
      if (!ok) {
        return;
      }
      SmartDialog.showLoading(msg: "同步中...");
      var data = await request.fetchExport(client);
      if (data["status"] != true) {
        throw data["message"] ??
            "对方不支持反向同步（请把对方 App 也升级到新版本）";
      }
      await DBService.instance.followBox.clear();
      for (var item in (data["follow"] as List? ?? const [])) {
        var user = FollowUser.fromJson(item);
        await DBService.instance.followBox.put(user.id, user);
      }
      await DBService.instance.tagBox.clear();
      for (var item in (data["tag"] as List? ?? const [])) {
        var tag = FollowUserTag.fromJson(item);
        await DBService.instance.tagBox.put(tag.id, tag);
      }
      for (var item in (data["history"] as List? ?? const [])) {
        var history = History.fromJson(item);
        await DBService.instance.addOrUpdateHistory(history);
      }
      EventBus.instance.emit(Constant.kUpdateFollow, 0);
      SmartDialog.showToast("已用对方数据覆盖本机");
    } catch (e) {
      SmartDialog.showToast("同步失败:$e");
      Log.logPrint(e);
    } finally {
      SmartDialog.dismiss();
    }
  }

  void syncFollowAndTag() async {
    try {
      var overlay = await showOverlayDialog();
      SmartDialog.showLoading(msg: "同步中...");
      var users = DBService.instance.getFollowList();
      var tags = DBService.instance.getFollowTagList();
      var data = json.encode(users.map((e) => e.toJson()).toList());
      var dataT = json.encode(tags.map((e) => e.toJson()).toList());
      await request.syncFollow(client, data, overlay: overlay);
      // 标签和关注必须同时同步
      await request.syncTag(client, dataT, overlay: overlay);
      SmartDialog.showToast("已同步关注列表和标签");
    } catch (e) {
      SmartDialog.showToast("同步失败:$e");
      Log.logPrint(e);
    } finally {
      SmartDialog.dismiss();
    }
  }

  void syncHistory() async {
    try {
      var overlay = await showOverlayDialog();
      SmartDialog.showLoading(msg: "同步中...");
      var histores = DBService.instance.getHistores();
      var data = json.encode(histores.map((e) => e.toJson()).toList());
      await request.syncHistory(client, data, overlay: overlay);
      SmartDialog.showToast("已同步历史记录");
    } catch (e) {
      SmartDialog.showToast("同步失败:$e");
      Log.logPrint(e);
    } finally {
      SmartDialog.dismiss();
    }
  }

  void syncBlockedWord() async {
    try {
      var overlay = await showOverlayDialog();
      SmartDialog.showLoading(msg: "同步中...");
      var shieldList = AppSettingsController.instance.shieldList;
      var data = json.encode(shieldList.toList());
      await request.syncBlockedWord(client, data, overlay: overlay);
      SmartDialog.showToast("已同步屏蔽词");
    } catch (e) {
      SmartDialog.showToast("同步失败:$e");
      Log.logPrint(e);
    } finally {
      SmartDialog.dismiss();
    }
  }

  void syncBiliAccount() async {
    try {
      if (!BiliBiliAccountService.instance.logined.value) {
        SmartDialog.showToast("未登录哔哩哔哩");
        return;
      }
      SmartDialog.showLoading(msg: "同步中...");

      await request.syncBiliAccount(
          client, BiliBiliAccountService.instance.cookie);
      SmartDialog.showToast("已同步哔哩哔哩账号");
    } catch (e) {
      SmartDialog.showToast("同步失败:$e");
      Log.logPrint(e);
    } finally {
      SmartDialog.dismiss();
    }
  }
}
