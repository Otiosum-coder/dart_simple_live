import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/multi_live/integration/multi_live_chat.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class _Settings extends AppSettingsController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

class _Follows extends FollowService {
  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  Future<void> loadData({bool updateStatus = true}) async {}
}

class _Database extends DBService {
  @override
  bool getFollowExist(String id) => false;
}

class _Backend extends PlatformPlayer {
  _Backend() : super(configuration: const PlayerConfiguration());
}

// Keep LiveRoomController.onInit and onWSMessage intact: pausing, pending-buffer
// limits and the resume worker must be exercised together with the real widget.
// Only network, storage and native player boundaries are replaced.
class _Room extends LiveRoomController {
  _Room(String id)
      : super(pSite: Sites.allSites['douyu']!, pRoomId: id, embedded: true);

  late final _player = Player(platformPlayer: _Backend());

  @override
  Player get player => _player;

  @override
  Future<void> loadData() async {}

  @override
  void initSystem() {}

  @override
  void initStream() {}

  @override
  Future<void> closePlayer() async => disposeDanmakuController();
}

LiveMessage _message(String content) => LiveMessage(
    type: LiveMessageType.chat,
    userName: 'reader',
    message: content,
    color: LiveMessageColor.white);

_Room _room(WidgetTester tester, String id, {int count = 200}) {
  final room = _Room(id)..onInit();
  for (var i = 0; i < count; i++) {
    room.onWSMessage(_message('$id $i'));
  }
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await room.closeRoom();
      await room.player.dispose();
    });
  });
  return room;
}

Widget _app(Widget child) => MaterialApp(
    theme: AppStyle.lightTheme.copyWith(platform: TargetPlatform.windows),
    navigatorObservers: [FlutterSmartDialog.observer],
    builder: FlutterSmartDialog.init(),
    home: Scaffold(body: child));

Widget _chat(LiveRoomController room) =>
    MultiLiveChat(room: room, send: (_) async => null);

Finder _list(LiveRoomController room) => find.descendant(
    of: find.byWidgetPredicate(
        (widget) => widget is MultiLiveChat && identical(widget.room, room)),
    matching: find.byType(ListView));

ScrollPosition _position(WidgetTester tester, LiveRoomController room) => tester
    .state<ScrollableState>(
        find.descendant(of: _list(room), matching: find.byType(Scrollable)))
    .position;

Finder _line(String content) =>
    find.text('reader：$content', findRichText: true);

Future<Finder> _pause(WidgetTester tester, _Room room) async {
  final position = _position(tester, room);
  expect(position.pixels, position.minScrollExtent);
  expect(tester.widget<ListView>(_list(room)).reverse, isTrue);
  // Dragging the content down in this reversed list reveals older rows.
  await tester.drag(_list(room), const Offset(0, 240));
  await tester.pumpAndSettle();
  expect(position.pixels, greaterThan(position.minScrollExtent));
  expect(room.disableAutoScroll.value, isTrue);
  expect(find.text('最新'), findsOneWidget);
  final viewport = tester.getRect(_list(room));
  final visible = find.descendant(of: _list(room), matching: find.byType(Text));
  return visible
      .evaluate()
      .map((element) => find.byWidget(element.widget))
      .firstWhere((finder) => viewport.contains(tester.getRect(finder).center));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    Get.testMode = true;
    Get.put<AppSettingsController>(_Settings());
    Get.put<FollowService>(_Follows());
    Get.put<DBService>(_Database());
  });

  tearDown(() {
    Get.reset();
  });

  testWidgets('history stays fixed through buffer eviction, latest flushes now',
      (tester) async {
    final room = _room(tester, 'history');
    await tester.pumpWidget(_app(_chat(room)));
    await tester.pumpAndSettle();
    expect(_line('history 199'), findsOneWidget);
    expect(tester.getTopLeft(_line('history 198')).dy,
        lessThan(tester.getTopLeft(_line('history 199')).dy));
    final anchor = await _pause(tester, room);
    final anchorText = tester.widget<Text>(anchor).textSpan!.toPlainText();
    final anchorRect = tester.getRect(anchor);
    final visibleMessages = room.messages.toList();
    final offset = _position(tester, room).pixels;

    for (var i = 0; i < 1000; i++) {
      room.onWSMessage(_message('incoming $i'));
    }
    room.addSysMsg('pending system');
    await tester.pumpAndSettle();
    expect(room.messages, orderedEquals(visibleMessages));
    expect(_position(tester, room).pixels, offset);
    expect(
        tester.getRect(find.text(anchorText, findRichText: true)), anchorRect);
    expect(_line('incoming 999'), findsNothing);

    await tester.tap(find.text('最新'));
    await tester.pumpAndSettle();
    expect(room.disableAutoScroll.value, isFalse);
    expect(find.text('最新'), findsNothing);
    // No additional arrival is needed to drain the shared pending buffer.
    expect(room.messages.length, 200);
    expect(room.messages.first.message, 'incoming 801');
    expect(room.messages.last.message, 'pending system');
    expect(_position(tester, room).pixels,
        _position(tester, room).minScrollExtent);
    expect(find.text('LiveSysMessage：pending system', findRichText: true),
        findsOneWidget);
    room.onWSMessage(_message('following again'));
    await tester.pumpAndSettle();
    expect(_line('following again'), findsOneWidget);
    expect(_position(tester, room).pixels, 0);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('dragging to the bottom resumes without pressing latest',
      (tester) async {
    final room = _room(tester, 'drag');
    await tester.pumpWidget(_app(_chat(room)));
    await tester.pumpAndSettle();
    await _pause(tester, room);
    room.onWSMessage(_message('queued before return'));
    await tester.pumpAndSettle();
    expect(_line('queued before return'), findsNothing);

    await tester.drag(_list(room), const Offset(0, -1200));
    await tester.pumpAndSettle();
    expect(room.disableAutoScroll.value, isFalse);
    expect(room.messages.last.message, 'queued before return');
    expect(_line('queued before return'), findsOneWidget);
    expect(_position(tester, room).pixels, 0);
    expect(find.text('最新'), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('mouse wheel pauses history and resumes at reversed bottom',
      (tester) async {
    final room = _room(tester, 'wheel');
    await tester.pumpWidget(_app(_chat(room)));
    await tester.pumpAndSettle();
    final point = tester.getCenter(_list(room));
    await tester.sendEventToBinding(PointerScrollEvent(
        position: point, scrollDelta: const Offset(0, -200)));
    await tester.pumpAndSettle();
    expect(_position(tester, room).pixels, greaterThan(0));
    expect(room.disableAutoScroll.value, isTrue);
    final before = room.messages.toList();
    room.onWSMessage(_message('wheel pending'));
    await tester.pumpAndSettle();
    expect(room.messages, orderedEquals(before));

    await tester.sendEventToBinding(PointerScrollEvent(
        position: point, scrollDelta: const Offset(0, 1000)));
    await tester.pumpAndSettle();
    expect(room.disableAutoScroll.value, isFalse);
    expect(_position(tester, room).pixels, 0);
    expect(_line('wheel pending'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('switching room drains old buffer and resets the viewport',
      (tester) async {
    final first = _room(tester, 'first');
    final second = _room(tester, 'second');
    await tester.pumpWidget(_app(_chat(first)));
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(MultiLiveChat));
    await _pause(tester, first);
    first.onWSMessage(_message('first pending'));
    second.onWSMessage(_message('second live'));
    await tester.pumpWidget(_app(_chat(second)));
    await tester.pumpAndSettle();

    expect(tester.state(find.byType(MultiLiveChat)), same(state));
    expect(first.disableAutoScroll.value, isFalse);
    expect(first.messages.last.message, 'first pending');
    expect(second.disableAutoScroll.value, isFalse);
    expect(_position(tester, second).pixels, 0);
    expect(_line('second live'), findsOneWidget);
    expect(_line('first pending'), findsNothing);
    expect(find.text('最新'), findsNothing);
    first.onWSMessage(_message('first hidden live'));
    expect(first.messages.last.message, 'first hidden live');

    await tester.pumpWidget(_app(_chat(first)));
    await tester.pumpAndSettle();
    expect(_position(tester, first).pixels, 0);
    expect(_line('first hidden live'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('closing a paused sidebar drains only its own room',
      (tester) async {
    final first = _room(tester, 'closing');
    final second = _room(tester, 'other');
    await tester.pumpWidget(_app(_chat(first)));
    await tester.pumpAndSettle();
    await _pause(tester, first);
    first.onWSMessage(_message('closing pending'));
    // A different room's pause must survive this sidebar being removed.
    second.disableAutoScroll.value = true;
    second.onWSMessage(_message('other pending'));

    await tester.pumpWidget(_app(const SizedBox.shrink()));
    await tester.pumpAndSettle();
    expect(first.disableAutoScroll.value, isFalse);
    expect(first.messages.last.message, 'closing pending');
    expect(second.disableAutoScroll.value, isTrue);
    expect(second.messages.last.message, 'other 199');
    second.disableAutoScroll.value = false;
    expect(second.messages.last.message, 'other pending');

    await tester.pumpWidget(_app(_chat(first)));
    await tester.pumpAndSettle();
    expect(_position(tester, first).pixels, 0);
    expect(_line('closing pending'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('closing the room before its paused sidebar is safe',
      (tester) async {
    final room = _room(tester, 'closed');
    await tester.pumpWidget(_app(_chat(room)));
    await tester.pumpAndSettle();
    await _pause(tester, room);
    room.onWSMessage(_message('discarded on close'));
    await tester.runAsync(room.closeRoom);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(room.isClosed, isTrue);
    expect(room.messages, isEmpty);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets(
      'a paused historical row remains clickable and copies its content',
      (tester) async {
    final copied = <String>[];
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
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });
    final room = _room(tester, 'copy');
    await tester.pumpWidget(_app(_chat(room)));
    await tester.pumpAndSettle();
    final anchor = await _pause(tester, room);
    final content = tester
        .widget<Text>(anchor)
        .textSpan!
        .toPlainText()
        .substring('reader：'.length);
    await tester.tap(anchor);
    await tester.pumpAndSettle();
    expect(find.byType(PopupMenuItem<String>), findsNWidgets(2));
    for (var i = 0; i < 500; i++) {
      room.onWSMessage(_message('while copying $i'));
    }
    await tester.tap(find.text('复制弹幕'));
    await tester.pumpAndSettle();
    expect(copied, [content]);
    expect(room.disableAutoScroll.value, isTrue);
    expect(room.messages.last.message, 'copy 199');
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
