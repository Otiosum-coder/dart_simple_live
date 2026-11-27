import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/live_room/live_room_page.dart';
import 'package:simple_live_app/modules/live_room/player/player_controls.dart';
import 'package:simple_live_app/widgets/superchat_card.dart';
import 'package:simple_live_core/simple_live_core.dart';

LiveSuperChatMessage _message({
  required int price,
  String? priceLabel,
  String id = 'display-fixture',
  DateTime? endTime,
}) {
  final now = DateTime.now();
  return LiveSuperChatMessage(
    id: id,
    userName: '观众',
    face: '',
    message: '上头条留言',
    price: price,
    priceLabel: priceLabel,
    startTime: now,
    endTime: endTime ?? now.add(const Duration(seconds: 60)),
    backgroundColor: 'd3e4ff',
    backgroundBottomColor: '2a60b2',
  );
}

class _ScRoom extends LiveRoomController {
  _ScRoom()
      : super(
          pSite: Sites.allSites['huya']!,
          pRoomId: 'sc-lifecycle-fixture',
          embedded: true,
        );

  @override
  Future<void> closePlayer() async {}
}

class _SuperChatPage extends LiveRoomPage {
  const _SuperChatPage(this.controller);

  @override
  final LiveRoomController controller;
}

int _countdown(WidgetTester tester, Finder card) => tester
    .widgetList<Text>(find.descendant(of: card, matching: find.byType(Text)))
    .map((text) => int.tryParse(text.data ?? ''))
    .whereType<int>()
    .single;

void main() {
  final cases = <({int price, String? label, String expected})>[
    (price: 120, label: '120 虎牙币', expected: '120 虎牙币'),
    (price: 0, label: '礼物价值 1.5 虎牙币', expected: '礼物价值 1.5 虎牙币'),
    (price: 0, label: '上头条', expected: '上头条'),
    (price: 30, label: null, expected: '￥30'),
    (price: 0, label: null, expected: '免费'),
  ];

  for (final value in cases) {
    testWidgets('SC 列表和悬浮卡片一致显示 ${value.expected}', (tester) async {
      final message = _message(price: value.price, priceLabel: value.label);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SuperChatCard(message, onExpire: () {}),
                  SuperChatOverlayCard(OverlaySuperChat(
                    message,
                    DateTime.now().add(const Duration(seconds: 10)),
                  )),
                ],
              ),
            ),
          ),
        ),
      ));

      for (final type in [SuperChatCard, SuperChatOverlayCard]) {
        expect(
          find.descendant(
            of: find.byType(type),
            matching: find.text(value.expected),
          ),
          findsOneWidget,
        );
      }
      if (value.label != null) {
        expect(find.text('￥${value.price}'), findsNothing);
        expect(find.text('免费'), findsNothing);
      }
      expect(tester.takeException(), isNull);
      // Dispose the list card's countdown timer before the widget test ends.
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('同一位置更换消息时重新计算倒计时并重启计时器', (tester) async {
    const key = ValueKey('same-card-slot');
    Future<void> pumpCard(LiveSuperChatMessage message) => tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SuperChatCard(message, key: key, onExpire: () {}),
            ),
          ),
        );
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    await pumpCard(_message(price: 0));
    final state = tester.state(find.byKey(key));
    final original = _countdown(tester, find.byKey(key));
    await tester.pump(const Duration(seconds: 2));
    expect(_countdown(tester, find.byKey(key)), original - 2);

    await pumpCard(_message(
      price: 0,
      endTime: DateTime.now().add(const Duration(seconds: 120)),
    ));
    expect(identical(tester.state(find.byKey(key)), state), isTrue);
    final updated = _countdown(tester, find.byKey(key));
    expect(updated, inInclusiveRange(119, 120));
    await tester.pump(const Duration(seconds: 1));
    expect(_countdown(tester, find.byKey(key)), updated - 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('已结束卡片复用为新消息时恢复倒计时', (tester) async {
    const key = ValueKey('expired-card-slot');
    var expired = 0;
    Future<void> pumpCard(LiveSuperChatMessage message) => tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SuperChatCard(message, key: key, onExpire: () => expired++),
            ),
          ),
        );
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

    await pumpCard(_message(
      price: 0,
      endTime: DateTime.now().subtract(const Duration(seconds: 1)),
    ));
    expect(find.text('已结束'), findsOneWidget);
    expect(expired, 1);
    await pumpCard(_message(price: 0));
    expect(find.text('已结束'), findsNothing);
    final updated = _countdown(tester, find.byKey(key));
    expect(updated, inInclusiveRange(59, 60));
    await tester.pump(const Duration(seconds: 1));
    expect(_countdown(tester, find.byKey(key)), updated - 1);
    expect(expired, 1);
    expect(tester.takeException(), isNull);
  });

  for (final hasPlatformId in [true, false]) {
    testWidgets('移除前项后保留后项倒计时（平台 ID：$hasPlatformId）', (tester) async {
      final room = _ScRoom();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await room.closeRoom();
      });
      final first = _message(
        price: 0,
        id: hasPlatformId ? 'first' : '',
        endTime: DateTime.now().add(const Duration(seconds: 10)),
      );
      final second = _message(
        price: 0,
        id: hasPlatformId ? 'second' : '',
        endTime: DateTime.now().add(const Duration(seconds: 90)),
      );
      final firstKey = hasPlatformId ? ValueKey(first.id) : ObjectKey(first);
      final secondKey = hasPlatformId ? ValueKey(second.id) : ObjectKey(second);
      room.superChats.addAll([first, second]);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: _SuperChatPage(room).buildSuperChats()),
      ));
      expect(find.byKey(firstKey), findsOneWidget);
      expect(find.byKey(secondKey), findsOneWidget);
      expect(_countdown(tester, find.byKey(firstKey)), inInclusiveRange(9, 10));

      room.superChats.removeAt(0);
      await tester.pump();
      expect(find.byKey(firstKey), findsNothing);
      expect(find.byKey(secondKey), findsOneWidget);
      expect(
          _countdown(tester, find.byKey(secondKey)), inInclusiveRange(89, 90));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('实时悬浮卡片不能超过平台截止时间', (tester) async {
    final room = _ScRoom();
    addTearDown(room.closeRoom);
    final end = DateTime.now().add(const Duration(seconds: 2));
    final message = _message(price: 0, endTime: end);

    room.addOverlaySuperChat(message);
    expect(room.overlaySuperChats.single.expireAt, end);
    room.addOverlaySuperChat(message);
    expect(room.overlaySuperChats, hasLength(1));
    expect(room.overlaySuperChats.single.expireAt, end);
    // 定时器不变量先于 addTearDown 检查；异步房间关闭仍交给 teardown。
    room.clearOverlaySuperChats();
  });

  testWidgets('长时 SC 仍遵循悬浮展示上限与自定义时长', (tester) async {
    final room = _ScRoom();
    addTearDown(room.closeRoom);
    final message = _message(price: 0);

    final before = DateTime.now();
    room.addOverlaySuperChat(message);
    final after = DateTime.now();
    final expiry = room.overlaySuperChats.single.expireAt;
    expect(expiry.isBefore(before.add(const Duration(seconds: 10))), isFalse);
    expect(expiry.isAfter(after.add(const Duration(seconds: 10))), isFalse);

    room.clearOverlaySuperChats();
    final customBefore = DateTime.now();
    room.addOverlaySuperChat(message, maxSeconds: 2);
    final customAfter = DateTime.now();
    final customExpiry = room.overlaySuperChats.single.expireAt;
    expect(customExpiry.isBefore(customBefore.add(const Duration(seconds: 2))),
        isFalse);
    expect(customExpiry.isAfter(customAfter.add(const Duration(seconds: 2))),
        isFalse);
    room.clearOverlaySuperChats();
  });

  testWidgets('已到期或零展示时长的 SC 不加入悬浮列表', (tester) async {
    final room = _ScRoom();
    addTearDown(room.closeRoom);
    room.addOverlaySuperChat(_message(
      price: 0,
      endTime: DateTime.now().subtract(const Duration(seconds: 1)),
    ));
    room.addOverlaySuperChat(_message(price: 0), maxSeconds: 0);
    expect(room.overlaySuperChats, isEmpty);
  });
}
