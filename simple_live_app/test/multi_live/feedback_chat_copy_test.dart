import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/multi_live/integration/multi_live_chat.dart';
import 'package:simple_live_app/widgets/net_image.dart';
import 'package:simple_live_core/simple_live_core.dart';

LiveMessage _message(String name, String text, {bool emoji = false}) =>
    LiveMessage(
        type: LiveMessageType.chat,
        userName: name,
        message: text,
        color: LiveMessageColor.white,
        spans: emoji
            ? const [
                LiveMessageSpan.text('富文本前'),
                LiveMessageSpan.image('asset://assets/images/logo.png'),
                LiveMessageSpan.text('富文本后'),
              ]
            : null);

Future<LiveRoomController> _mount(WidgetTester tester,
    {required TargetPlatform platform, required List<String> copied}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(800, 600);
  final room = LiveRoomController(
      pSite: Sites.allSites['douyu']!, pRoomId: 'offline', embedded: true);
  room.messages.assignAll([
    _message('旧昵称', '  原始内容  ', emoji: true),
    _message('系统', '   '),
  ]);
  tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      copied.add((call.arguments as Map)['text'] as String);
    }
    return null;
  });
  addTearDown(() async {
    await SmartDialog.dismiss(status: SmartStatus.allToast);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    room.scrollController.dispose();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(MaterialApp(
      theme: AppStyle.lightTheme.copyWith(platform: platform),
      navigatorObservers: [FlutterSmartDialog.observer],
      builder: FlutterSmartDialog.init(),
      home:
          Scaffold(body: MultiLiveChat(room: room, send: (_) async => null))));
  await tester.pumpAndSettle();
  return room;
}

Finder get _richLine => find.textContaining('旧昵称：', findRichText: true);

void main() {
  for (final buttons in [kPrimaryMouseButton, kSecondaryMouseButton]) {
    for (final full in [false, true]) {
      testWidgets(
          'desktop button $buttons copies full=$full after list eviction',
          (tester) async {
        final copied = <String>[];
        final room = await _mount(tester,
            platform: TargetPlatform.windows, copied: copied);
        expect(find.byType(NetImage), findsOneWidget);
        final line = tester.getRect(_richLine);
        final point = Offset(line.left + 15, line.center.dy);
        final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse, buttons: buttons);
        await mouse.down(point);
        await mouse.up();
        await tester.pumpAndSettle();
        final menu = find.byType(PopupMenuItem<String>);
        expect(menu, findsNWidgets(2));
        expect(copied, isEmpty);
        expect(tester.getTopLeft(menu.first).dx, closeTo(point.dx, 1));
        // Replace the entire backing list, including the clicked message.
        room.messages
            .assignAll(List.generate(200, (i) => _message('新昵称 $i', '新消息 $i')));
        await tester.pumpAndSettle();
        await tester.tap(find.text(full ? '复制「昵称：内容」' : '复制弹幕'));
        await tester.pumpAndSettle();
        expect(copied, [full ? '旧昵称：  原始内容' : '原始内容']);
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final full in [false, true]) {
    testWidgets('mobile tap previews rich text and copies full=$full',
        (tester) async {
      final copied = <String>[];
      final room = await _mount(tester,
          platform: TargetPlatform.android, copied: copied);
      await tester.tap(_richLine);
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.textContaining('富文本前', findRichText: true), findsNWidgets(2));
      expect(find.byType(NetImage), findsNWidgets(2));
      expect(copied, isEmpty);
      room.messages.assignAll([_message('后来的人', '后来消息')]);
      await tester.pumpAndSettle();
      expect(find.textContaining('旧昵称：', findRichText: true), findsOneWidget);
      final option = find.widgetWithText(ListTile, full ? '复制「昵称：内容」' : '复制弹幕');
      await tester.tap(option);
      await tester.pumpAndSettle();
      expect(copied, [full ? '旧昵称：  原始内容' : '原始内容']);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    testWidgets('${platform.name} cancel and blank text never copy',
        (tester) async {
      final copied = <String>[];
      final room = await _mount(tester, platform: platform, copied: copied);
      await tester.tap(find.textContaining('系统：', findRichText: true));
      await tester.pumpAndSettle();
      expect(find.byType(PopupMenuItem<String>), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
      await tester.tap(_richLine);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(copied, isEmpty);
      room.messages
          .assignAll(List.generate(1000, (i) => _message('昵称 $i', '内容 $i')));
      await tester.pumpAndSettle();
      // The existing lazy, reversed list must remain scrollable with bounded
      // visible widget work, even when its backing buffer reaches its limit.
      expect(find.byType(GestureDetector).evaluate().length, lessThan(100));
      await tester.drag(find.byType(ListView), const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
