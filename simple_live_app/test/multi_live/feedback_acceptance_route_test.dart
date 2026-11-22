import 'dart:async';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/main.dart' show MyApp;
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/multi_live/integration/multi_live_route.dart';
import 'package:simple_live_app/modules/multi_live/multi_live_controller.dart';
import 'package:simple_live_app/modules/multi_live/multi_live_page.dart';
import 'package:simple_live_app/modules/multi_live/session/multi_live_room_session.dart';
import 'package:simple_live_app/modules/multi_live/storage/multi_live_workspace_store.dart';
import 'package:simple_live_app/routes/app_navigation.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/widgets/net_image.dart';
import 'package:simple_live_core/simple_live_core.dart';

final _windows = TargetPlatformVariant.only(TargetPlatform.windows);
final _android = TargetPlatformVariant.only(TargetPlatform.android);
const _enter = LogicalKeyboardKey.enter;
const _escape = LogicalKeyboardKey.escape;
const _window = MethodChannel('window_manager');
const _copyBody = '复制弹幕';
const _copyFull = '复制「昵称：内容」';
const _first =
    MultiLiveRoomSpec(siteId: 'huya', roomId: '501', danmakuVisible: false);
const _second =
    MultiLiveRoomSpec(siteId: 'huya', roomId: '502', danmakuVisible: false);

Finder _key(String name) => find.byKey(ValueKey(name));
Finder get _prompt => _key('quick-danmaku-prompt');
Finder get _quickInput =>
    find.descendant(of: _prompt, matching: _key('multi-live-danmaku-input'));
Finder get _items => find.byType(PopupMenuItem<String>);
Finder _line(LiveMessage item) => find.byKey(ObjectKey(item));

LiveMessage _chat(String nick, String body, {bool rich = false}) => LiveMessage(
      type: LiveMessageType.chat,
      userName: nick,
      message: body,
      color: LiveMessageColor.white,
      spans: rich
          ? const [
              LiveMessageSpan.text('可见富文本'),
              LiveMessageSpan.image('asset://assets/images/logo.png'),
            ]
          : null,
    );

class _Settings extends AppSettingsController {
  @override
  // ignore: must_call_super
  void onInit() => siteSort.assignAll(Sites.allSites.keys);
}

class _Follows extends FollowService {
  @override
  // ignore: must_call_super
  void onInit() {}
}

class _NoMedia extends PlatformPlayer {
  _NoMedia() : super(configuration: const PlayerConfiguration());
}

class _NoVideo implements VideoController {
  _NoVideo(this.player);
  @override
  final Player player;
  @override
  final notifier = ValueNotifier<PlatformVideoController?>(null);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Room extends LiveRoomController {
  _Room(MultiLiveRoomSpec spec)
      : super(
            pSite: Sites.allSites[spec.siteId]!,
            pRoomId: spec.roomId,
            embedded: true) {
    detail.value = LiveRoomDetail(
      roomId: roomId,
      title: '直播标题 $roomId',
      cover: '',
      userName: '主播 $roomId',
      userAvatar: '',
      online: 0,
      status: false,
      url: '',
    );
  }
  final _player = Player(platformPlayer: _NoMedia());
  late final _video = _NoVideo(_player);
  int closes = 0;
  @override
  Player get player => _player;
  @override
  VideoController get videoController => _video;
  @override
  Future<void> closeRoom() async {
    closes++;
    await player.dispose();
    videoController.notifier.dispose();
    scrollController.dispose();
  }
}

class _Driver implements MultiLiveRoomDriver {
  _Driver(MultiLiveRoomSpec spec, this.activeRooms) : room = _Room(spec);
  final Set<String> activeRooms;
  final sent = <String>[];
  final volumes = <double>[];
  Completer<String?>? reply;
  @override
  final _Room room;
  @override
  Future<void> initialize() async {}
  @override
  Future<void> setVolume(double volume) async => volumes.add(volume);
  @override
  Future<void> setDanmakuVisible(bool visible) async {}
  @override
  Future<void> setSenderActive(bool isActive) async {
    if (isActive) {
      activeRooms.add(room.roomId);
    } else {
      activeRooms.remove(room.roomId);
    }
    expect(activeRooms.length, lessThanOrEqualTo(1));
  }

  @override
  Future<String?> sendDanmaku(String text) async {
    expect(activeRooms, {room.roomId});
    sent.add(text);
    return await reply?.future;
  }

  @override
  Future<void> close() => room.closeRoom();
}

class _Workspace {
  _Workspace(this.tester);
  final WidgetTester tester;
  final _Room origin = _Room(_first);
  final active = <String>{};
  final drivers = <String, _Driver>{};
  final clipboard = <String>[];
  final notices = <String>[];
  final transitions = <bool>[];
  bool full = false;

  _Driver get first => drivers[_first.roomId]!;
  MultiLiveController get model =>
      tester.widget<MultiLivePage>(find.byType(MultiLivePage)).model
          as MultiLiveController;

  Future<void> mount(
      {Size size = const Size(1280, 800),
      double scale = 1,
      ThemeData? theme}) async {
    const originRoute = '/feedback-fixture-origin';
    final platform = defaultTargetPlatform;
    tester.view.devicePixelRatio = 1;
    // The test-only launcher starts at a normal desktop height. The production
    // route is then resized and checked against the requested viewport.
    final launchSize = size.height < 400 ? const Size(1280, 800) : size;
    tester.view.physicalSize = launchSize;
    await tester.binding.setSurfaceSize(launchSize);
    Get.put<AppSettingsController>(_Settings());
    Get.put<FollowService>(_Follows());
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    messenger.setMockMethodCallHandler(_window, (call) async {
      switch (call.method) {
        case 'isFullScreen':
          return full;
        case 'isMaximized':
          return false;
        case 'getBounds':
          return {'x': 20.0, 'y': 30.0, 'width': 1280.0, 'height': 800.0};
        case 'setFullScreen':
          full = (call.arguments as Map)['isFullScreen'] as bool;
          transitions.add(full);
          return null;
        case 'setBounds':
          return null;
        default:
          throw StateError('Unexpected window call: ${call.method}');
      }
    });
    addTearDown(() async {
      for (final driver in drivers.values) {
        final pending = driver.reply;
        if (pending != null && !pending.isCompleted) pending.complete(null);
      }
      unawaited(SmartDialog.dismiss(status: SmartStatus.allToast));
      await frame();
      await tester.pumpWidget(const SizedBox.shrink());
      await frame();
      if (origin.closes == 0) await origin.closeRoom();
      messenger.setMockMethodCallHandler(_window, null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      Get.reset();
      await tester.binding.setSurfaceSize(null);
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(Builder(builder: (context) {
      final colors = const MyApp().build(context) as DynamicColorBuilder;
      final app = colors.builder(null, null) as GetMaterialApp;
      final route =
          app.getPages!.singleWhere((r) => r.name == RoutePath.kMultiLive);
      return GetMaterialApp(
        builder: app.builder,
        navigatorObservers: app.navigatorObservers!,
        theme: (theme ?? AppStyle.lightTheme).copyWith(platform: platform),
        initialRoute: '/',
        getPages: [
          GetPage(
              name: '/',
              page: () => Scaffold(
                      body: Center(
                          child: TextButton(
                    onPressed: () => Get.toNamed<void>(originRoute),
                    child: const Text('离线直播间'),
                  )))),
          GetPage(
              name: originRoute,
              page: () => Builder(
                  builder: (context) => Scaffold(
                        body: Center(
                            child: TextButton(
                          onPressed: () =>
                              AppNavigator.toMultiLive(context, origin),
                          child: const Text('打开多开工作区'),
                        )),
                      ))),
          GetPage(
              name: route.name,
              page: () {
                final production = route.page() as MultiLiveRoute;
                return Builder(
                    builder: (context) => MediaQuery(
                          data: MediaQuery.of(context)
                              .copyWith(textScaler: TextScaler.linear(scale)),
                          child: MultiLiveRoute(
                            initialRoom: production.initialRoom,
                            store: MultiLiveWorkspaceStore(
                                read: () async => null, write: (_) async {}),
                            sessionFactory: ({required id, required spec}) =>
                                MultiLiveRoomSession(
                              id: id,
                              spec: spec,
                              driverFactory: (_) =>
                                  drivers[spec.roomId] = _Driver(spec, active),
                            ),
                            onNotice: notices.add,
                          ),
                        ));
              }),
        ],
      );
    }));
    await tester.pumpAndSettle();
    await tap(find.widgetWithText(TextButton, '离线直播间'));
    await tap(find.widgetWithText(TextButton, '打开多开工作区'));
    expect(origin.closes, 1);
    expect(find.byType(MultiLiveRoute), findsOneWidget);
    expect(active, {_first.roomId});
    expect(notices, isEmpty);
    if (launchSize != size) {
      tester.view.physicalSize = size;
      await tester.binding.setSurfaceSize(size);
      await frame();
    }
    expect(tester.getSize(find.byType(Scaffold).first), size);
  }

  Future<void> frame() async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pump();
  }

  Future<void> tap(Finder target) async {
    expect(target.hitTestable(), findsOneWidget);
    await tester.tap(target);
    await frame();
  }

  Future<void> key(LogicalKeyboardKey key) async {
    // The Linux test mapping preserves the keypad logical key on this SDK.
    await tester.sendKeyEvent(key,
        platform: key == LogicalKeyboardKey.numpadEnter ? 'linux' : null);
    await frame();
  }

  void expectPrompt(String id, {String? draft}) {
    expect(_prompt, findsOneWidget);
    expect(find.text('发送弹幕 · 主播 $id'), findsOneWidget);
    final field = tester.widget<TextField>(_quickInput);
    expect(field.focusNode!.hasPrimaryFocus, isTrue);
    if (draft != null) expect(field.controller!.text, draft);
  }
}

void _noHeaderButton() {
  final header = _key('chat-target');
  expect(header, findsOneWidget);
  final row = find.ancestor(of: header, matching: find.byType(Row)).first;
  expect(find.descendant(of: row, matching: find.byType(IconButton)),
      findsNothing);
  expect(_key('quick-danmaku-entry'), findsNothing);
  expect(_key('multi-live-danmaku-send').hitTestable(), findsOneWidget);
}

void _expectInside(Rect outer, Rect inner) {
  expect(outer.inflate(.5).contains(inner.topLeft), isTrue,
      reason: '$inner outside $outer');
  expect(outer.inflate(.5).contains(inner.bottomRight), isTrue,
      reason: '$inner outside $outer');
}

void _checkBar(WidgetTester tester,
    {required double height, required double control, required bool desktop}) {
  final bar = find.byType(AppBar);
  final bounds = tester.getRect(bar);
  expect(tester.widget<AppBar>(bar).toolbarHeight, height);
  for (final action in [
    find.byType(BackButton),
    _key('layout-presets'),
    _key('audio-panel'),
    _key('chat-panel'),
    if (desktop) _key('workspace-fullscreen'),
    _key('add-room'),
  ]) {
    expect(action.hitTestable(), findsOneWidget);
    expect(tester.getSize(action), Size.square(control));
    _expectInside(bounds, tester.getRect(action));
  }
  expect(tester.takeException(), isNull);
}

void main() {
  testWidgets('desktop primary and secondary clicks open anchored copy menus',
      (tester) async {
    final h = _Workspace(tester);
    await h.mount();
    _noHeaderButton();
    final room = h.first.room;
    final blank = _chat('空文本', '   ');
    final target = _chat('原昵称', '  剪贴板正文  ', rich: true);
    room.onWSMessage(target);
    room.onWSMessage(blank);
    await h.frame();
    for (final button in [kPrimaryMouseButton, kSecondaryMouseButton]) {
      await tester.tapAt(tester.getCenter(_line(blank)),
          kind: PointerDeviceKind.mouse, buttons: button);
      await h.frame();
      expect(_items, findsNothing);
    }
    for (final (button, option, payload, inset) in [
      (kPrimaryMouseButton, _copyFull, '原昵称：  剪贴板正文', 16.0),
      (kSecondaryMouseButton, _copyBody, '剪贴板正文', 56.0),
    ]) {
      if (!room.messages.contains(target)) room.onWSMessage(target);
      await h.frame();
      final row = tester.getRect(_line(target));
      expect(
          find.descendant(of: _line(target), matching: find.byType(NetImage)),
          findsOneWidget);
      final point = Offset(row.left + inset, row.center.dy);
      final count = h.clipboard.length;
      await tester.tapAt(point, kind: PointerDeviceKind.mouse, buttons: button);
      await h.frame();
      expect(_items, findsNWidgets(2));
      final menu = tester
          .getRect(_items.first)
          .expandToInclude(tester.getRect(_items.last));
      // The chat is on the right. Flutter grows the popup toward the left.
      expect(menu.right, closeTo(point.dx + 1, 1));
      expect(menu.inflate(16).contains(point), isTrue);
      expect(h.clipboard, hasLength(count));
      await h.key(_enter);
      expect(_prompt, findsNothing);
      expect(_items, findsNWidgets(2));
      for (var i = 0; i < 220; i++) {
        room.onWSMessage(_chat('后来的人', '新弹幕 $i'));
      }
      await h.frame();
      expect(room.messages, hasLength(200));
      expect(room.messages, isNot(contains(target)));
      await h.tap(find.descendant(of: _items, matching: find.text(option)));
      expect(h.clipboard, hasLength(count + 1));
      expect(h.clipboard.last, payload);
      await tester.pump(const Duration(seconds: 3));
      await h.frame();
      await h.key(_enter);
      h.expectPrompt(_first.roomId);
      await h.key(_escape);
    }
    room.onWSMessage(target);
    await h.frame();
    final row = tester.getRect(_line(target));
    await tester.tapAt(Offset(row.left + 16, row.center.dy),
        kind: PointerDeviceKind.mouse);
    await h.frame();
    expect(_items, findsNWidgets(2));
    await h.key(_escape);
    expect(h.clipboard, ['原昵称：  剪贴板正文', '剪贴板正文']);
    expect(_items, findsNothing);
    expect(h.first.sent, isEmpty);
  }, variant: _windows);

  testWidgets(
      'phone single tap previews rich text and bottom send remains usable',
      (tester) async {
    final h = _Workspace(tester);
    await h.mount(size: const Size(360, 690));
    expect(h.model.maxRooms, 2);
    await h.tap(_key('chat-panel'));
    _noHeaderButton();
    final room = h.first.room;
    final blank = _chat('无正文', '  ');
    final target = _chat('手机昵称', '  正文内容  ', rich: true);
    room.onWSMessage(blank);
    room.onWSMessage(target);
    await h.frame();
    await h.tap(_line(blank));
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(h.clipboard, isEmpty);
    for (final (option, payload) in [
      (_copyBody, '正文内容'),
      (_copyFull, '手机昵称：  正文内容')
    ]) {
      if (!room.messages.contains(target)) room.onWSMessage(target);
      await h.frame();
      final count = h.clipboard.length;
      await h.tap(_line(target));
      expect(find.byType(BottomSheet), findsNWidgets(2));
      final sheet = find
          .ancestor(
              of: find.widgetWithText(ListTile, _copyFull),
              matching: find.byType(BottomSheet))
          .first;
      expect(
          find.descendant(
              of: sheet,
              matching: find.textContaining('可见富文本', findRichText: true)),
          findsOneWidget);
      expect(find.descendant(of: sheet, matching: find.byType(NetImage)),
          findsOneWidget);
      expect(h.clipboard, hasLength(count));
      for (var i = 0; i < 220; i++) {
        room.onWSMessage(_chat('手机新消息', '第 $i 条'));
      }
      await h.frame();
      expect(room.messages, isNot(contains(target)));
      await h.tap(find.widgetWithText(ListTile, option));
      expect(h.clipboard, hasLength(count + 1));
      expect(h.clipboard.last, payload);
      await tester.pump(const Duration(seconds: 3));
      await h.frame();
    }
    await tester.enterText(_key('multi-live-danmaku-input'), '手机底栏派发');
    await h.tap(_key('multi-live-danmaku-send'));
    expect(h.first.sent, ['手机底栏派发']);
    expect(find.byType(BottomSheet), findsOneWidget);
  }, variant: _android);

  testWidgets(
      'Enter recovers after menus, layout, audio, pane and window changes',
      (tester) async {
    final h = _Workspace(tester);
    await h.mount();
    expect(h.model.maxRooms, 4);
    await h.model.addSpec(_second);
    await h.frame();
    final second = h.model.selectedRoomId!;
    final first = h.model.rooms.first.id;

    await h.tap(_key('layout-presets'));
    await h.key(_escape);
    expect(find.text('上下双屏 · 2路'), findsNothing);
    await h.key(LogicalKeyboardKey.numpadEnter);
    h.expectPrompt(_second.roomId);
    await h.key(_enter);
    expect(_prompt, findsNothing);

    await h.tap(_key('layout-presets'));
    await h.tap(find.text('上下双屏 · 2路'));
    await h.key(_enter);
    h.expectPrompt(_second.roomId);
    await h.key(_escape);

    await h.tap(_key('volume:$second'));
    expect(h.drivers[_second.roomId]!.volumes.last, lessThan(80));
    expect(h.first.volumes.last, 100);
    await h.key(_enter);
    h.expectPrompt(_second.roomId);
    await h.key(_escape);

    await h.tap(_key('audio-panel'));
    await h.tap(_key('audio-mute:$second'));
    expect(h.drivers[_second.roomId]!.volumes.last, 0);
    await h.key(_escape);
    await h.key(_enter);
    h.expectPrompt(_second.roomId);
    await h.key(_escape);

    await h.tap(_key('title:$first'));
    await h.key(LogicalKeyboardKey.f11);
    expect(h.transitions, [true]);
    await h.tap(find.byTooltip('放大 主播 ${_first.roomId}'));
    expect(h.model.maximizedRoomId, first);
    FocusManager.instance.primaryFocus?.unfocus();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await h.frame();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await h.frame();
    await h.key(_enter);
    h.expectPrompt(_first.roomId);
    await h.key(_escape);
    expect(h.model.maximizedRoomId, first);
    expect(h.transitions, [true]);
    await h.key(_escape);
    expect(h.model.maximizedRoomId, isNull);
    expect(h.transitions, [true]);
    await h.key(_escape);
    expect(h.transitions, [true, false]);
    await h.key(_enter);
    h.expectPrompt(_first.roomId);
    expect(h.first.sent, isEmpty);
  }, variant: _windows);

  testWidgets('held hardware Enter and IME confirmation do not send or toggle',
      (tester) async {
    final h = _Workspace(tester);
    await h.mount();
    final driver = h.first;
    driver.room.danmakuDraft.value = '保留草稿';
    await tester.sendKeyDownEvent(_enter);
    await h.frame();
    h.expectPrompt(_first.roomId, draft: '保留草稿');
    await tester.sendKeyRepeatEvent(_enter);
    await h.frame();
    expect(driver.sent, isEmpty);
    await tester.sendKeyUpEvent(_enter);
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await h.frame();
    expect(driver.sent, isEmpty);

    final input = tester.testTextInput;
    void edit(String text, {required bool composing}) =>
        input.updateEditingValue(TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
          composing: composing
              ? TextRange(start: 0, end: text.length)
              : TextRange.empty,
        ));
    edit('你好', composing: true);
    await h.frame();
    await tester.sendKeyDownEvent(_enter);
    edit('你好', composing: false);
    await input.receiveAction(TextInputAction.send);
    await tester.sendKeyUpEvent(_enter);
    await h.frame();
    h.expectPrompt(_first.roomId, draft: '你好');
    expect(driver.sent, isEmpty);

    edit('测试', composing: true);
    await h.frame();
    edit('测试', composing: false);
    await tester.sendKeyDownEvent(_enter);
    await input.receiveAction(TextInputAction.send);
    await tester.sendKeyUpEvent(_enter);
    await h.frame();
    h.expectPrompt(_first.roomId, draft: '测试');
    expect(driver.sent, isEmpty);

    edit('   ', composing: false);
    await h.frame();
    await tester.sendKeyDownEvent(_enter);
    await h.frame();
    expect(_prompt, findsNothing);
    await tester.sendKeyRepeatEvent(_enter);
    await h.frame();
    expect(_prompt, findsNothing);
    await tester.sendKeyUpEvent(_enter);
    expect(driver.sent, isEmpty);

    await h.key(_enter);
    h.expectPrompt(_first.roomId, draft: '   ');
    edit('  明确提交  ', composing: false);
    await h.frame();
    final reply = driver.reply = Completer<String?>();
    await tester.sendKeyDownEvent(_enter);
    await tester.sendKeyRepeatEvent(_enter);
    await input.receiveAction(TextInputAction.send);
    await h.frame();
    expect(driver.sent, ['明确提交']);
    await tester.sendKeyUpEvent(_enter);
    reply.complete(null);
    await h.frame();
    expect(_prompt, findsNothing);
    expect(driver.room.danmakuDraft.value, isEmpty);
  }, variant: _windows);

  testWidgets('reopened prompt and bottom composer share the pending send',
      (tester) async {
    final h = _Workspace(tester);
    await h.mount();
    final driver = h.first;
    final reply = driver.reply = Completer<String?>();
    await h.key(_enter);
    await tester.enterText(_quickInput, '同一草稿');
    await h.key(_enter);
    expect(driver.sent, ['同一草稿']);
    await h.key(_escape);
    await h.key(_enter);
    h.expectPrompt(_first.roomId, draft: '同一草稿');
    await h.key(_enter);
    expect(driver.sent, ['同一草稿']);
    await h.key(_escape);
    await h.tap(_key('multi-live-danmaku-send'));
    expect(driver.sent, ['同一草稿']);
    expect(_prompt, findsNothing);
    reply.complete('离线回执失败');
    await h.frame();
    await h.key(_enter);
    h.expectPrompt(_first.roomId, draft: '同一草稿');
    driver.reply = null;
    await h.key(_enter);
    expect(driver.sent, ['同一草稿', '同一草稿']);
    expect(_prompt, findsNothing);
  }, variant: _windows);

  for (final (name, theme) in [
    ('light', AppStyle.lightTheme),
    ('dark', AppStyle.darkTheme)
  ]) {
    testWidgets('$name desktop has a 32 logical pixel toolbar', (tester) async {
      final h = _Workspace(tester);
      await h.mount(theme: theme);
      _checkBar(tester, height: 32, control: 32, desktop: true);
      expect(tester.getSize(find.byType(AppBar)).height, 32);
    }, variant: _windows);
    for (final scale in [1.5, 2.0]) {
      testWidgets(
          '$name desktop 320x240 at $scale fits the title and every action',
          (tester) async {
        final h = _Workspace(tester);
        await h.mount(theme: theme, size: const Size(320, 240), scale: scale);
        _checkBar(tester, height: 32, control: 32, desktop: true);
        final bar = tester.getRect(find.byType(AppBar));
        final title = find.descendant(
            of: find.byType(AppBar), matching: find.textContaining('多开直播'));
        expect(title, findsOneWidget);
        final paragraph = tester.renderObject<RenderParagraph>(title);
        expect(paragraph.didExceedMaxLines, isFalse);
        expect(paragraph.textScaler.scale(16), 16 * scale);
        final glyphs = paragraph.getBoxesForSelection(TextSelection(
            baseOffset: 0, extentOffset: paragraph.text.toPlainText().length));
        expect(glyphs, isNotEmpty);
        for (final box in glyphs) {
          _expectInside(
              bar, box.toRect().shift(paragraph.localToGlobal(Offset.zero)));
        }
        await h.tap(_key('audio-panel'));
        expect(_key('multi-live-audio-panel'), findsOneWidget);
        await h.tap(find.byTooltip('关闭音量面板'));
        await h.key(_enter);
        h.expectPrompt(_first.roomId);
        await h.key(_escape);
      }, variant: _windows);
    }
  }

  testWidgets('Android 320x568 at 2x retains a 44 bar and 40 touch targets',
      (tester) async {
    final h = _Workspace(tester);
    await h.mount(size: const Size(320, 568), scale: 2);
    await h.model.addSpec(_second);
    await h.frame();
    _checkBar(tester, height: 44, control: 40, desktop: false);
    expect(tester.getSize(find.byType(AppBar)).height, 44);
    expect(find.bySemanticsLabel('多开直播 2/2'), findsOneWidget);
    await h.tap(_key('chat-panel'));
    _noHeaderButton();
    await h.key(_escape);
    await h.tap(_key('audio-panel'));
    expect(_key('multi-live-audio-panel'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: _android);

  testWidgets(
      'phone bottom composer sends to the selected room above the navigation bar',
      (tester) async {
    tester.view.padding = const FakeViewPadding(bottom: 48);
    addTearDown(tester.view.resetPadding);
    final h = _Workspace(tester);
    await h.mount(size: const Size(360, 690));
    expect(h.model.maxRooms, 2);
    // The explanatory hint row is replaced by a persistent composer.
    expect(find.textContaining('拖动标题栏交换'), findsNothing);
    expect(_key('multi-live-bottom-danmaku-input'), findsOneWidget);
    expect(_key('multi-live-bottom-danmaku-send'), findsOneWidget);
    final input = _key('multi-live-bottom-danmaku-input');
    expect(tester.getRect(input).bottom, lessThanOrEqualTo(690 - 48));
    await tester.enterText(input, '底栏消息');
    await h.frame();
    await h.tap(_key('multi-live-bottom-danmaku-send'));
    expect(h.first.sent, ['底栏消息']);

    await h.model.addSpec(_second);
    await h.frame();
    final secondId = h.model.selectedRoomId!;
    expect(h.model.rooms.last.id, secondId);
    await tester.enterText(input, '第二路消息');
    await h.frame();
    await h.tap(_key('multi-live-bottom-danmaku-send'));
    expect(h.drivers[_second.roomId]!.sent, ['第二路消息']);
    expect(h.first.sent, ['底栏消息']);
  }, variant: _android);
}
