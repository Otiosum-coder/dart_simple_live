import 'dart:convert';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/web_socket_util.dart';
import 'package:test/test.dart';

void main() {
  test('只将明确 biz exception:905 判断为凭据失效', () {
    for (final description in [
      'wup request biz exception:905',
      'WUP REQUEST BIZ EXCEPTION : 905',
      'biz exception:905; rejected',
    ]) {
      expect(HuyaDanmaku.isSessionExpiredError(description), isTrue);
    }
    for (final description in [
      'wup request biz exception:100',
      'biz exception:1905',
      'biz exception:9050',
      'biz exception:905x',
      'biz exception',
      '房间 905 网络超时',
      'unknown status:905',
    ]) {
      expect(HuyaDanmaku.isSessionExpiredError(description), isFalse);
    }
  });

  test('启动前同步或清空凭据使用空房间参数，不创建任何连接', () {
    final danmaku = HuyaDanmaku();
    danmaku.updateCookie('');
    danmaku.updateCookie('udb_uid=202; guid=fixture-prestart');
    expect(danmaku.selfUid, 202);
    expect(danmaku.guid, 'fixture-prestart');
    expect(danmaku.danmakuArgs.ayyuid, 0);
    expect(danmaku.danmakuArgs.topSid, 0);
    expect(danmaku.danmakuArgs.subSid, 0);
    expect(danmaku.webScoketUtils, isNull);
    danmaku.updateCookie('');
    expect(danmaku.selfUid, 0);
    expect(danmaku.guid, isEmpty);
  });

  test('已创建房间同步新凭据后下一帧读取新身份和 Cookie，保留接收连接', () {
    final danmaku = HuyaDanmaku();
    const oldCookie = 'udb_uid=101; guid=old-guid-00000001; fixture=old';
    const newCookie = 'udb_uid=202; guid=new-guid-00000001; fixture=new';
    danmaku.danmakuArgs = HuyaDanmakuArgs(
      ayyuid: 123,
      topSid: 456,
      subSid: 789,
      presenterUid: 321,
      cookie: oldCookie,
    );
    final receive = WebScoketUtils(
      url: 'wss://example.com',
      heartBeatTime: 1000,
    );
    danmaku.webScoketUtils = receive;
    danmaku.updateCookie(newCookie);
    expect(danmaku.selfUid, 202);
    expect(danmaku.guid, 'new-guid-00000001');
    expect(danmaku.danmakuArgs.cookie, newCookie);
    expect(danmaku.danmakuArgs.presenterUid, 321);
    expect(danmaku.danmakuArgs.topSid, 456);
    expect(identical(danmaku.webScoketUtils, receive), isTrue);
    final frame = utf8.decode(
      danmaku.buildSendFrame('fixture message', 71),
      allowMalformed: true,
    );
    expect(frame.contains(newCookie), isTrue);
    expect(frame.contains(oldCookie), isFalse);
    final current = danmaku.danmakuArgs;
    danmaku.updateCookie(newCookie);
    expect(identical(danmaku.danmakuArgs, current), isTrue);
    danmaku.updateCookie('');
    expect(danmaku.selfUid, 0);
    expect(danmaku.guid, isEmpty);
  });
}
