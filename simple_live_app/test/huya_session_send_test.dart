import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/services/huya_account_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class _Settings extends AppSettingsController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

class _Account extends HuyaAccountService {
  _Account()
      : super(
          automaticChecks: false,
          readStorage: (_, fallback) => fallback,
          writeStorage: (key, value) async {},
          onCookieChanged: (_) {},
        );

  int recoveries = 0;
  Future<bool> Function()? recover;

  @override
  Future<bool> recoverSession() async {
    recoveries++;
    return await recover?.call() ?? false;
  }
}

class _Sender extends HuyaDanmaku {
  _Sender() {
    danmakuArgs = HuyaDanmakuArgs(ayyuid: 0, topSid: 0, subSid: 0);
  }

  String result = '虎牙登录已失效';
  int sends = 0;
  final updates = <String>[];

  @override
  void updateCookie(String cookie) {
    updates.add(cookie);
    super.updateCookie(cookie);
  }

  @override
  Future<String?> sendDanmaku(String message) async {
    sends++;
    return result;
  }
}

class _Room extends LiveRoomController {
  _Room(_Sender sender)
      : super(
            pSite: Sites.allSites['huya']!,
            pRoomId: 'offline',
            embedded: true) {
    liveDanmaku = sender;
  }

  @override
  Future<void> closePlayer() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Account account;
  late _Sender sender;
  late _Room room;

  setUp(() async {
    Get.testMode = true;
    final settings = _Settings()..playerSendDanmaku.value = true;
    Get.put<AppSettingsController>(settings);
    account = _Account();
    Get.put<HuyaAccountService>(account);
    await account.setCookie('udb_uid=10001; guid=offline-a');
    sender = _Sender();
    room = _Room(sender);
    await room.setSenderActive(true);
  });

  tearDown(() async {
    await room.closeRoom();
    Get.reset();
  });

  test('普通业务错误不恢复、不退出，发送前同步当前 Cookie', () async {
    sender.result = 'biz exception: 999; detail 905';
    expect(await room.sendDanmaku('离线测试'), sender.result);
    expect(account.recoveries, 0);
    expect(account.logined.value, isTrue);
    expect(sender.sends, 1);
    expect(sender.updates, [account.cookie]);
    expect(sender.selfUid, 10001);
  });

  test('明确失效恢复成功只更新发送凭据，不自动重发', () async {
    account.recover = () async {
      account.cookie = 'udb_uid=10001; guid=offline-rotated';
      return true;
    };
    expect(await room.sendDanmaku('离线测试'), '虎牙登录状态已恢复，请重试发送');
    expect(account.recoveries, 1);
    expect(sender.sends, 1);
    expect(sender.updates, hasLength(2));
    expect(sender.guid, 'offline-rotated');
    expect(account.logined.value, isTrue);
  });

  test('恢复网络结果未知时保留登录，不自动重发', () async {
    expect(await room.sendDanmaku('离线测试'), '虎牙登录状态暂无法确认，请稍后重试');
    expect(account.recoveries, 1);
    expect(account.logined.value, isTrue);
    expect(sender.sends, 1);
  });

  test('服务复验明确失效后展示重新登录', () async {
    account.recover = () async {
      account.markSessionExpired(sessionGeneration: account.sessionGeneration);
      return false;
    };
    expect(await room.sendDanmaku('离线测试'), '虎牙登录已失效，请重新登录');
    expect(account.logined.value, isFalse);
    expect(sender.sends, 1);
  });

  test('恢复期间换账号不会误标记新会话', () async {
    final started = Completer<void>();
    final recovery = Completer<bool>();
    account.recover = () {
      started.complete();
      return recovery.future;
    };
    final sending = room.sendDanmaku('离线测试');
    await started.future;
    await account.setCookie('udb_uid=10002; guid=offline-b');
    recovery.complete(false);
    expect(await sending, '虎牙账号已更新，请重试发送');
    expect(account.uid, '10002');
    expect(account.logined.value, isTrue);
    expect(sender.sends, 1);
  });

  test('恢复期间退出房间不重发或写回房间状态', () async {
    final started = Completer<void>();
    final recovery = Completer<bool>();
    account.recover = () {
      started.complete();
      return recovery.future;
    };
    final sending = room.sendDanmaku('离线测试');
    await started.future;
    await room.closeRoom();
    recovery.complete(true);
    expect(await sending, '发送房间已切换或关闭');
    expect(sender.sends, 1);
    expect(sender.updates, hasLength(1));
    expect(account.logined.value, isTrue);
  });
}
