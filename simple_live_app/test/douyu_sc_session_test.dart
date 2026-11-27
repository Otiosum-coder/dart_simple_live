import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/live_room/live_room_page.dart';
import 'package:simple_live_app/widgets/superchat_card.dart';
import 'package:simple_live_core/simple_live_core.dart';

class _Player extends Fake implements Player {
  int stops = 0;
  @override
  Future<void> stop() async => stops++;
}

class _Danmaku extends Fake implements LiveDanmaku {
  @override
  Function(LiveMessage)? onMessage;
  @override
  Function(String)? onClose;
  @override
  Function()? onReady;
  int stops = 0;
  @override
  Future<void> stop() async => stops++;
}

class _Room extends LiveRoomController {
  _Room({String siteId = 'douyu', String id = 'fixture'})
      : super(pSite: Sites.allSites[siteId]!, pRoomId: id, embedded: true) {
    liveDanmaku = _Danmaku();
  }

  final backend = _Player();
  int reloads = 0;
  @override
  Player get player => backend;
  @override
  Future<void> loadData() async => reloads++;
  @override
  Future<void> closePlayer() async {}

  void receive(LiveSuperChatMessage message) => onWSMessage(LiveMessage(
      type: LiveMessageType.superChat,
      data: message,
      userName: message.userName,
      message: message.message,
      color: LiveMessageColor.white));
}

class _ScPage extends LiveRoomPage {
  const _ScPage(this.controller);
  @override
  final LiveRoomController controller;
}

LiveSuperChatMessage _message(String id, {DateTime? endTime, String? text}) {
  final now = DateTime.now();
  return LiveSuperChatMessage(
    id: id,
    userName: '观众',
    face: '',
    message: text ?? '付费留言 $id',
    price: 30,
    startTime: now.subtract(const Duration(minutes: 2)),
    endTime: endTime ?? now.subtract(const Duration(seconds: 1)),
    backgroundColor: 'd3e4ff',
    backgroundBottomColor: '2a60b2',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('过期斗鱼增量保留在列表，不重新进入浮层', (tester) async {
    final room = _Room();
    final message = _message('expired');
    room.receive(message);
    expect(room.superChats, [message]);
    expect(room.overlaySuperChats, isEmpty);
    room.removeSuperChats();
    await tester.pump(const Duration(minutes: 3));
    expect(room.superChats, [message]);
    await room.closeRoom();
  });

  testWidgets('真实过期与有效增量合包进入房间后分别进入历史和浮层', (tester) async {
    final room = _Room();
    final decoder = DouyuDanmaku()
      ..danmakuArgs = DouyuDanmakuArgs(roomId: room.roomId)
      ..onMessage = room.onWSMessage;
    final now = DateTime.now();
    final ended = DateTime.fromMillisecondsSinceEpoch(
        now.subtract(const Duration(seconds: 30)).millisecondsSinceEpoch ~/
            1000 *
            1000);
    final active = DateTime.fromMillisecondsSinceEpoch(
        now.add(const Duration(minutes: 2)).millisecondsSinceEpoch ~/
            1000 *
            1000);
    List<int> packet(String id, DateTime endTime) {
      final fields = {
        'type': 'voice_trlt',
        'mtype': '2',
        'list': jsonEncode([
          {
            'vrId': id,
            'un': '观众',
            'content': '合包留言 $id',
            'realPrice': '3000',
            'etimeV2': '${endTime.millisecondsSinceEpoch ~/ 1000}',
          }
        ]),
      };
      final stt = fields.entries
          .map((entry) => '${entry.key}@=${decoder.scapeSlashAt(entry.value)}/')
          .join();
      return decoder.serializeDouyu(stt, type: 690);
    }

    decoder.decodeMessage(
        [...packet('ended', ended), ...packet('active', active)]);
    expect(room.superChats.map((message) => message.id), ['ended', 'active']);
    expect(room.superChats.map((message) => message.endTime), [ended, active]);
    expect(room.overlaySuperChats, hasLength(1));
    expect(room.overlaySuperChats.single.message.id, 'active');
    expect(room.overlaySuperChats.single.expireAt.isBefore(active), isTrue);
    await decoder.stop();
    await room.closeRoom();
  });

  testWidgets('斗鱼只保留最近100条，重复ID不重排或重开浮层', (tester) async {
    final room = _Room();
    for (var i = 0; i < 110; i++) {
      room.receive(_message('$i'));
    }
    expect(room.superChats, hasLength(100));
    expect(room.superChats.first.id, '10');
    expect(room.superChats.last.id, '109');
    final retained = room.superChats.first;
    room.receive(_message('10',
        text: '重复推送',
        endTime: DateTime.now().add(const Duration(seconds: 60))));
    expect(room.superChats, hasLength(100));
    expect(identical(room.superChats.first, retained), isTrue);
    expect(room.overlaySuperChats, isEmpty);
    await room.closeRoom();
  });

  testWidgets('后台接收、返回前台和同房间刷新保留记录及已有浮层截止时间', (tester) async {
    final room = _Room();
    final message = _message('background',
        endTime: DateTime.now().add(const Duration(minutes: 2)));
    room.didChangeAppLifecycleState(AppLifecycleState.paused);
    room.receive(message);
    final expiry = room.overlaySuperChats.single.expireAt;
    room.didChangeAppLifecycleState(AppLifecycleState.resumed);
    room.refreshRoom();
    await tester.pump();
    expect(room.isBackground, isFalse);
    expect(room.reloads, 1);
    expect(room.superChats, [message]);
    expect(room.overlaySuperChats.single.expireAt, expiry);
    await room.resetRoom(room.site, room.roomId);
    expect(room.superChats, [message]);
    await room.closeRoom();
  });

  testWidgets('换房清空临时记录，旧房回调不能串入新房', (tester) async {
    final room = _Room();
    room.initDanmau();
    final previous = room.liveDanmaku;
    room.receive(_message('old'));
    await room.resetRoom(Sites.allSites['douyu']!, 'another');
    expect(room.superChats, isEmpty);
    expect(room.overlaySuperChats, isEmpty);
    expect(room.backend.stops, 1);
    previous.onMessage!.call(LiveMessage(
        type: LiveMessageType.superChat,
        data: _message('late'),
        userName: '观众',
        message: '迟到留言',
        color: LiveMessageColor.white));
    expect(room.superChats, isEmpty);
    room.receive(_message('new'));
    expect(room.superChats.single.id, 'new');
    await room.closeRoom();
  });

  testWidgets('退出房间立即清空，迟到消息无效，重进房间从空开始', (tester) async {
    final room = _Room();
    room.receive(_message('before-close'));
    await room.closeRoom();
    expect(room.superChats, isEmpty);
    room.receive(_message('after-close'));
    expect(room.superChats, isEmpty);
    final reopened = _Room();
    expect(reopened.superChats, isEmpty);
    await reopened.closeRoom();
  });

  testWidgets('多房间内存记录相互隔离', (tester) async {
    final first = _Room(id: 'one');
    final second = _Room(id: 'two');
    first.receive(_message('same-id', text: '房间一'));
    second.receive(_message('same-id', text: '房间二'));
    await first.closeRoom();
    expect(first.superChats, isEmpty);
    expect(second.superChats.single.message, '房间二');
    await second.closeRoom();
  });

  for (final site in ['huya', 'bilibili']) {
    testWidgets('$site 维持到期不收录及清理行为', (tester) async {
      final room = _Room(siteId: site);
      room.receive(_message('expired'));
      expect(room.superChats, isEmpty);
      room.superChats.add(_message('previously-active'));
      room.removeSuperChats();
      expect(room.superChats, isEmpty);
      await room.closeRoom();
    });
  }

  testWidgets('SC标签重建后仍显示已结束记录，不需要未读状态', (tester) async {
    final room = _Room();
    room.receive(_message('visible'));
    Future<void> mount() => tester.pumpWidget(
        MaterialApp(home: Scaffold(body: _ScPage(room).buildSuperChats())));
    await mount();
    expect(find.text('已结束'), findsOneWidget);
    expect(find.text('付费留言 visible'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await mount();
    expect(find.text('已结束'), findsOneWidget);
    expect(room.superChats, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    await room.closeRoom();
  });

  testWidgets('返回前台按截止时间校准，已结束卡片只通知一次且不保留定时器', (tester) async {
    var now = DateTime(2026, 11, 1, 12);
    final message =
        _message('clocked', endTime: now.add(const Duration(seconds: 30)));
    var expired = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SuperChatCard(message, now: () => now, onExpire: () => expired++),
      ),
    ));
    expect(find.text('30'), findsOneWidget);
    final binding = tester.binding;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    // 模拟系统挂起整个进程，Timer 没有获得任何 tick。
    now = now.add(const Duration(minutes: 2));
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text('已结束'), findsOneWidget);
    expect(expired, 1);
    await tester.pump(const Duration(minutes: 2));
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(expired, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
