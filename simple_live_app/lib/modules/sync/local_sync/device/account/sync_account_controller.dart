import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/models/sync_client_info_model.dart';
import 'package:simple_live_app/requests/sync_client_request.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_app/services/douyu_account_service.dart';
import 'package:simple_live_app/services/huya_account_service.dart';
import 'package:simple_live_app/services/sync_service.dart';

/// 局域网同步-账号：把本机的登录凭证推给对方
class SyncAccountController extends BaseController {
  final SyncClinet client;
  final SyncClientInfoModel info;
  SyncAccountController({required this.client, required this.info});

  SyncClientRequest request = SyncClientRequest();

  bool get biliLogined => BiliBiliAccountService.instance.logined.value;
  String get biliName => BiliBiliAccountService.instance.name.value;

  bool get douyuLogined => DouyuAccountService.instance.logined.value;
  String get douyuName => DouyuAccountService.instance.name.value;

  bool get huyaLogined => HuyaAccountService.instance.logined.value;
  String get huyaName => HuyaAccountService.instance.name.value;

  bool get douyinLogined => DouyinAccountService.instance.logined.value;
  String get douyinName => DouyinAccountService.instance.name.value;

  int get loginedCount => [
        biliLogined,
        douyuLogined,
        huyaLogined,
        douyinLogined,
      ].where((e) => e).length;

  Future<void> _pushBili() async {
    await request.syncBiliAccount(
      client,
      BiliBiliAccountService.instance.cookie,
    );
  }

  Future<void> _pushDouyu() async {
    await request.syncDouyuAccount(
      client,
      DouyuAccountService.instance.cookie,
    );
  }

  Future<void> _pushHuya() async {
    await request.syncHuyaAccount(
      client,
      HuyaAccountService.instance.cookie,
    );
  }

  Future<void> _pushDouyin() async {
    var service = DouyinAccountService.instance;
    await request.syncDouyinAccount(
      client,
      cookie: service.cookie,
      loginCookie: service.loginCookie,
    );
  }

  Future<void> _run(Future<void> Function() action, String okMsg) async {
    try {
      SmartDialog.showLoading(msg: "同步中...");
      await action();
      SmartDialog.showToast(okMsg);
    } catch (e) {
      SmartDialog.showToast("同步失败:$e");
      Log.logPrint(e);
    } finally {
      SmartDialog.dismiss();
    }
  }

  void syncBili() {
    if (!biliLogined) {
      SmartDialog.showToast("本机未登录哔哩哔哩");
      return;
    }
    _run(_pushBili, "已同步哔哩哔哩账号");
  }

  void syncDouyu() {
    if (!douyuLogined) {
      SmartDialog.showToast("本机未登录斗鱼");
      return;
    }
    _run(_pushDouyu, "已同步斗鱼账号");
  }

  void syncHuya() {
    if (!huyaLogined) {
      SmartDialog.showToast("本机未登录虎牙");
      return;
    }
    _run(_pushHuya, "已同步虎牙账号");
  }

  void syncDouyin() {
    if (!douyinLogined) {
      SmartDialog.showToast("本机未登录抖音");
      return;
    }
    _run(_pushDouyin, "已同步抖音账号");
  }

  /// 一键把本机已登录的账号全部推给对方
  Future<void> syncAll() async {
    if (loginedCount == 0) {
      SmartDialog.showToast("本机没有已登录的账号");
      return;
    }
    var ok = 0;
    var failed = <String>[];
    try {
      SmartDialog.showLoading(msg: "同步中...");
      if (biliLogined) {
        try {
          await _pushBili();
          ok++;
        } catch (e) {
          failed.add("哔哩哔哩");
          Log.logPrint(e);
        }
      }
      if (douyuLogined) {
        try {
          await _pushDouyu();
          ok++;
        } catch (e) {
          failed.add("斗鱼");
          Log.logPrint(e);
        }
      }
      if (huyaLogined) {
        try {
          await _pushHuya();
          ok++;
        } catch (e) {
          failed.add("虎牙");
          Log.logPrint(e);
        }
      }
      if (douyinLogined) {
        try {
          await _pushDouyin();
          ok++;
        } catch (e) {
          failed.add("抖音");
          Log.logPrint(e);
        }
      }
    } finally {
      SmartDialog.dismiss();
    }
    if (failed.isEmpty) {
      SmartDialog.showToast("已同步 $ok 个账号");
    } else {
      SmartDialog.showToast("已同步 $ok 个账号，失败：${failed.join("、")}");
    }
  }
}
