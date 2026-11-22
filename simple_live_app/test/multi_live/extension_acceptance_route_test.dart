import 'dart:async';
import 'dart:convert';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/main.dart' show MyApp;
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/multi_live/integration/multi_live_route.dart';
import 'package:simple_live_app/modules/multi_live/multi_live_controller.dart';
import 'package:simple_live_app/modules/multi_live/multi_live_page.dart';
import 'package:simple_live_app/modules/multi_live/session/multi_live_room_session.dart';
import 'package:simple_live_app/modules/multi_live/storage/multi_live_workspace_store.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

final _desktop = TargetPlatformVariant.only(TargetPlatform.windows);
const _windowChannel = MethodChannel('window_manager');
const _open = '打开离线验收工作区';
const _escape = LogicalKeyboardKey.escape;
const _enter = LogicalKeyboardKey.enter;
const _oldTitle = '这是旧版直播标题，不是主播名';
Finder get _prompt => find.byKey(const ValueKey('quick-danmaku-prompt'));
Finder get _input => find.byKey(const ValueKey('multi-live-danmaku-input'));
Finder get _promptInput => find.descendant(of: _prompt, matching: _input);
Finder get _add => find.byKey(const ValueKey('add-room'));
Finder get _batchConfirm =>
    find.byKey(const ValueKey('multi-live-confirm-selection'));
Finder _follow(String id) => find.byKey(ValueKey('multi-live-follow-huya-$id'));

MultiLiveRoomSpec _spec(String id) =>
    MultiLiveRoomSpec(siteId: 'huya', roomId: id, danmakuVisible: false);

LiveRoomDetail _detail(String id, String name, String title) => LiveRoomDetail(
      roomId: id,
      title: title,
      cover: '',
      userName: name,
      userAvatar: '',
      online: 0,
      status: false,
      url: '',
    );

class _Settings extends AppSettingsController {
  @override
  // ignore: must_call_super
  void onInit() => siteSort.assignAll(Sites.allSites.keys);
}

class _Follows extends FollowService {
  @override
  // ignore: must_call_super
  void onInit() => followList.assignAll([
        for (final id in ['101', '102', '103', '104', '105'])
          FollowUser(
            id: 'huya-$id',
            siteId: 'huya',
            roomId: id,
            userName: '关注名 $id',
            face: '',
            addTime: DateTime(2026),
          )..liveStatus.value = 2,
      ]);
}

class _WindowChannel {
  static const original = Rect.fromLTWH(37, 53, 910, 620);
  bool full = false;
  bool maximized = false;
  Rect bounds = original;
  final methods = <String>[];
  final transitions = <bool>[];
  Completer<void>? exitGate;

  Future<Object?> invoke(MethodCall call) async {
    methods.add(call.method);
    final args = call.arguments;
    switch (call.method) {
      case 'isFullScreen':
        return full;
      case 'isMaximized':
        return maximized;
      case 'getBounds':
        return {
          'x': bounds.left,
          'y': bounds.top,
          'width': bounds.width,
          'height': bounds.height,
        };
      case 'setFullScreen':
        final value = (args as Map)['isFullScreen'] as bool;
        if (!value) await exitGate?.future;
        full = value;
        transitions.add(value);
        if (value) {
          bounds = const Rect.fromLTWH(0, 0, 1600, 900);
          maximized = false;
        }
        return null;
      case 'setBounds':
        final fields = args as Map;
        bounds = Rect.fromLTWH(fields['x'] as double, fields['y'] as double,
            fields['width'] as double, fields['height'] as double);
        return null;
      case 'maximize':
        maximized = true;
        return null;
      case 'unmaximize':
        maximized = false;
        return null;
      default:
        throw StateError('Unexpected window host call: ${call.method}');
    }
  }
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
            pSite: Sites.allSites['huya']!,
            pRoomId: spec.roomId,
            embedded: true) {
    // No room fetch; the first reply can have a title but no name.
    detail.value = _detail(spec.roomId, '', '详情直播标题 $roomId');
    showDanmakuState.value = false;
  }
  final _player = Player(platformPlayer: _NoMedia());
  late final _video = _NoVideo(_player);
  @override
  Player get player => _player;
  @override
  VideoController get videoController => _video;
}

class _Driver implements MultiLiveRoomDriver {
  _Driver(MultiLiveRoomSpec spec, this.active, this.leases, this.startGate)
      : room = _Room(spec);
  @override
  final _Room room;
  final Set<String> active;
  final List<(String, bool)> leases;
  final Completer<void>? startGate;
  final sent = <String>[];
  Completer<String?>? sendGate;
  Completer<void>? activationGate;
  bool closed = false;

  @override
  Future<void> initialize() async => await startGate?.future;
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> setDanmakuVisible(bool visible) async {}
  @override
  Future<void> setSenderActive(bool value) async {
    if (value) await activationGate?.future;
    final id = room.roomId;
    final changed = value ? active.add(id) : active.remove(id);
    if (changed) leases.add((id, value));
  }

  @override
  Future<String?> sendDanmaku(String text) async {
    if (active.length != 1 || !active.contains(room.roomId)) {
      throw StateError('Send reached a driver without the sole sender lease');
    }
    sent.add(text);
    return await sendGate?.future;
  }

  @override
  Future<void> close() async {
    closed = true;
    await room.player.dispose();
    room.videoController.notifier.dispose();
  }
}

class _Workspace {
  _Workspace(this.tester, {this.oldSave});
  final WidgetTester tester;
  final String? oldSave;
  final window = _WindowChannel();
  final drivers = <String, _Driver>{};
  final active = <String>{};
  final leases = <(String, bool)>[];
  final startGates = <String, Completer<void>>{};
  final saves = <String>[];
  final notices = <String>[];

  MultiLiveController get model =>
      tester.widget<MultiLivePage>(find.byType(MultiLivePage)).model
          as MultiLiveController;

  Future<void> mount() async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    Get.put<AppSettingsController>(_Settings());
    Get.put<FollowService>(_Follows());
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_windowChannel, window.invoke);
    addTearDown(() async {
      final quit = window.exitGate;
      if (quit != null && !quit.isCompleted) quit.complete();
      for (final gate in startGates.values) {
        if (!gate.isCompleted) gate.complete();
      }
      for (final driver in drivers.values) {
        final activate = driver.activationGate;
        if (activate != null && !activate.isCompleted) activate.complete();
        final send = driver.sendGate;
        if (send != null && !send.isCompleted) send.complete(null);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 400));
      messenger.setMockMethodCallHandler(_windowChannel, null);
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      Get.reset();
    });
    await tester.pumpWidget(Builder(builder: (context) {
      // Use the exact MyApp keyboard builder, not a copied listener.
      // Skip application startup and substitute only disk and room drivers.
      final colorRoot = const MyApp().build(context) as DynamicColorBuilder;
      final app = colorRoot.builder(null, null) as GetMaterialApp;
      final route =
          app.getPages!.singleWhere((r) => r.name == RoutePath.kMultiLive);
      return GetMaterialApp(
        builder: app.builder,
        navigatorObservers: app.navigatorObservers!,
        theme: ThemeData(platform: defaultTargetPlatform),
        initialRoute: '/',
        getPages: [
          GetPage(
              name: '/',
              page: () => Scaffold(
                    body: Focus(
                      autofocus: true,
                      child: TextButton(
                        onPressed: () => Get.toNamed<void>(route.name,
                            arguments: _spec('101')),
                        child: const Text(_open),
                      ),
                    ),
                  )),
          GetPage(
              name: route.name,
              page: () {
                final production = route.page() as MultiLiveRoute;
                return MultiLiveRoute(
                  initialRoom: production.initialRoom,
                  store: MultiLiveWorkspaceStore(
                    read: () async => oldSave,
                    write: (value) async => saves.add(value),
                  ),
                  sessionFactory: ({required id, required spec}) =>
                      MultiLiveRoomSession(
                    id: id,
                    spec: spec,
                    driverFactory: (spec) => drivers[spec.roomId] = _Driver(
                      spec,
                      active,
                      leases,
                      startGates[spec.roomId],
                    ),
                  ),
                  onNotice: notices.add,
                );
              }),
        ],
      );
    }));
    await tester.pumpAndSettle();
  }

  Future<void> open() async {
    await tester.tap(find.text(_open));
    if (oldSave == null) {
      await tester.pumpAndSettle();
    } else {
      // The restore question covers an intentionally spinning startup page.
      await frame();
    }
  }

  Future<void> frame() async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> key(LogicalKeyboardKey key, {String? platform}) async {
    await tester.sendKeyEvent(key, platform: platform);
    await frame();
  }

  void expectSingleSenderThroughout() {
    final current = <String>{};
    for (final (id, on) in leases) {
      on ? current.add(id) : current.remove(id);
      expect(current.length, lessThanOrEqualTo(1), reason: '$leases');
    }
  }

  Future<void> tap(Finder finder) async {
    await tester.tap(finder);
    await frame();
  }
}

void main() {
  testWidgets('MyApp ancestor sees Escape outside but not through work layers',
      (tester) async {
    final h = _Workspace(tester);
    await h.mount();
    // Positive control: the real main.dart handler is connected to this channel.
    h.window.full = true;
    await h.key(_escape);
    expect(h.window.methods, ['isFullScreen', 'setFullScreen']);
    expect(h.window.full, isFalse);
    h.window.methods.clear();
    h.window.transitions.clear();

    await h.open();
    expect(h.drivers.keys, ['101']);
    expect(h.window.methods, ['isFullScreen', 'isMaximized', 'getBounds']);
    final id = h.model.selectedRoomId!;
    await h.tap(find.byKey(const ValueKey('workspace-fullscreen')));
    final channelCalls = List.of(h.window.methods);
    await h.tap(find.byTooltip('放大 房间 101 · 主播名待加载'));
    await h.key(_enter);
    expect(tester.widget<TextField>(_promptInput).focusNode!.hasPrimaryFocus,
        isTrue);
    await tester.enterText(_promptInput, '本地草稿');
    await h.key(_escape);
    expect(_prompt, findsNothing);
    expect(h.model.maximizedRoomId, id);
    expect(h.window.methods, channelCalls);
    await h.key(_escape);
    expect(h.model.maximizedRoomId, isNull);
    expect(h.window.methods, channelCalls);
    await h.key(_escape);
    expect(h.window.transitions, [true, false]);
    expect(h.window.bounds, _WindowChannel.original);

    await h.key(LogicalKeyboardKey.f11);
    expect(h.window.transitions, [true, false, true]);
    final closing = h.window.exitGate = Completer<void>();
    await h.tap(find.byType(BackButton));
    expect(find.byType(MultiLiveRoute), findsOneWidget);
    expect(h.drivers['101']!.closed, isTrue);
    expect(h.window.full, isTrue);
    closing.complete();
    await tester.pumpAndSettle();
    expect(find.byType(MultiLiveRoute), findsNothing);
    expect(h.window.transitions, [true, false, true, false]);
    expect(h.window.bounds, _WindowChannel.original);
    expect(h.notices, isEmpty);
  }, variant: _desktop);

  testWidgets(
      'keypad Enter focuses; repeats and IME do not submit; failures keep the draft',
      (tester) async {
    final h = _Workspace(tester);
    await h.mount();
    await h.open();
    final driver = h.drivers['101']!;
    const keypad = LogicalKeyboardKey.numpadEnter;
    // The test SDK's Windows legacy logical map omits numpad Enter.
    // GTK's map emits the same Flutter logical key without changing the UI variant.
    const keypadMap = 'linux';
    driver.room.danmakuDraft.value = '一条弹幕';
    await tester.sendKeyDownEvent(keypad, platform: keypadMap);
    await h.frame();
    expect(tester.widget<TextField>(_promptInput).focusNode!.hasPrimaryFocus,
        isTrue);
    await tester.sendKeyRepeatEvent(keypad, platform: keypadMap);
    await tester.sendKeyUpEvent(keypad, platform: keypadMap);
    await h.frame();
    expect(driver.sent, isEmpty);
    const composing = TextEditingValue(
        text: '一条弹幕',
        selection: TextSelection.collapsed(offset: 4),
        composing: TextRange(start: 0, end: 4));
    tester.testTextInput.updateEditingValue(composing);
    await tester.sendKeyEvent(_enter);
    tester.testTextInput
        .updateEditingValue(composing.copyWith(composing: TextRange.empty));
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await h.frame();
    expect(driver.sent, isEmpty);

    final failure = driver.sendGate = Completer<String?>();
    await h.key(keypad, platform: keypadMap);
    expect(driver.sent, ['一条弹幕']);
    await h.key(keypad, platform: keypadMap);
    expect(driver.sent, ['一条弹幕']);
    failure.complete('离线夹具：发送失败');
    await h.frame();
    expect(find.text('离线夹具：发送失败'), findsOneWidget);
    expect(driver.room.danmakuDraft.value, '一条弹幕');

    final lateSuccess = driver.sendGate = Completer<String?>();
    await h.key(keypad, platform: keypadMap);
    await tester.enterText(_promptInput, '此时编辑的新草稿');
    lateSuccess.complete(null);
    await h.frame();
    expect(_prompt, findsOneWidget);
    expect(driver.room.danmakuDraft.value, '此时编辑的新草稿');
    driver.sendGate = null;
    await h.key(keypad, platform: keypadMap);
    expect(driver.sent, ['一条弹幕', '一条弹幕', '此时编辑的新草稿']);
    expect(_prompt, findsNothing);
    expect(driver.room.danmakuDraft.value, isEmpty);
  }, variant: _desktop);

  testWidgets(
      'a pending draft cannot be sent again through a reopened composer',
      (tester) async {
    final h = _Workspace(tester);
    await h.mount();
    await h.open();
    final driver = h.drivers['101']!;
    final inflight = driver.sendGate = Completer<String?>();
    await h.key(_enter);
    await tester.enterText(_promptInput, '一条弹幕');
    await h.key(_enter);
    expect(driver.sent, ['一条弹幕']);
    await h.key(_escape);
    expect(driver.room.danmakuDraft.value, '一条弹幕');
    await h.key(_enter);
    expect(tester.widget<TextField>(_promptInput).controller!.text, '一条弹幕');
    await h.key(_enter);
    expect(driver.sent, ['一条弹幕'],
        reason: 'the first driver call is still pending');

    inflight.complete('离线夹具：发送失败');
    await h.frame();
    expect(driver.room.danmakuDraft.value, '一条弹幕');
    driver.sendGate = null;
    await h.key(_enter);
    expect(driver.sent, ['一条弹幕', '一条弹幕']);
    expect(_prompt, findsNothing);
    expect(driver.room.danmakuDraft.value, isEmpty);
  }, variant: _desktop);

  for (final (platform, capacity) in [
    (TargetPlatform.windows, 4),
    (TargetPlatform.android, 2),
  ]) {
    testWidgets(
        'production ${platform.name} batch rechecks duplicates and final lease',
        (tester) async {
      final h = _Workspace(tester);
      await h.mount();
      await h.open();
      expect(h.model.maxRooms, capacity);
      expect(h.active, {'101'});
      await h.tap(_add);
      await h.tap(_follow('102'));
      await h.tap(find.text('取消'));
      expect(h.drivers.keys, ['101']);
      expect(h.saves, isEmpty);
      expect(h.leases, [('101', true)]);

      await h.tap(_add);
      final link = find.byKey(const ValueKey('multi-live-room-link'));
      await tester.enterText(link, 'https://www.huya.com/101');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await h.frame();
      expect(find.text('此直播间已打开'), findsOneWidget);
      expect(_prompt, findsNothing);
      await tester.enterText(link, '');
      final last = (100 + capacity).toString();
      for (var n = 102; n <= 100 + capacity; n++) {
        await h.tap(_follow('$n'));
      }
      await h.tap(_follow('105'));
      expect(find.text('选择已满，请先取消一位已选主播'), findsOneWidget);
      final gate = h.startGates[last] = Completer<void>();
      await h.tap(_batchConfirm);
      expect(
          h.drivers.keys, [for (var n = 101; n <= 100 + capacity; n++) '$n']);
      expect(h.active, {'101'});
      expect(h.saves, isEmpty);
      gate.complete();
      await tester.pumpAndSettle();
      await h.frame();
      expect(h.leases, [('101', true), ('101', false), (last, true)]);
      expect(h.active, {last});
      expect(h.saves, hasLength(1));
      final selected = h.model.sessionFor(h.model.selectedRoomId!)!;
      expect(selected.spec.roomId, last);
      expect(selected.spec.displayName, '关注名 $last');
    }, variant: TargetPlatformVariant.only(platform));
  }

  testWidgets('switching and replacing revoke the correct prompt and send',
      (tester) async {
    final h = _Workspace(tester);
    await h.mount();
    await h.open();
    final model = h.model;
    final oldId = model.selectedRoomId!;
    await model.addSpec(_spec('102'));
    await h.frame();
    final newId = model.selectedRoomId!;
    final old = h.drivers['101']!;
    final newer = h.drivers['102']!;

    final activate = old.activationGate = Completer<void>();
    model.selectRoom(oldId);
    await h.frame();
    expect(h.active, isEmpty);
    await h.key(_enter);
    await tester.enterText(_promptInput, '旧目标草稿');
    await h.key(_enter);
    expect(old.sent, isEmpty);
    model.selectRoom(newId);
    await h.frame();
    expect(_prompt, findsNothing);
    activate.complete();
    await h.frame();
    expect(old.sent, isEmpty);
    expect(newer.sent, isEmpty);
    expect(h.active, {'102'});

    model.selectRoom(oldId);
    await h.frame();
    await h.key(_enter);
    expect(tester.widget<TextField>(_promptInput).controller!.text, '旧目标草稿');
    final reply = old.sendGate = Completer<String?>();
    await h.key(_enter);
    expect(old.sent, ['旧目标草稿']);
    model.selectRoom(newId);
    await h.frame();
    await h.key(_enter);
    await tester.enterText(_promptInput, '新目标草稿');
    reply.complete(null);
    await h.frame();
    expect(tester.widget<TextField>(_promptInput).controller!.text, '新目标草稿');
    expect(newer.sent, isEmpty);
    expect(old.room.danmakuDraft.value, '旧目标草稿');
    await h.key(_escape);

    final reactivation = old.activationGate = Completer<void>();
    model.selectRoom(oldId);
    await h.frame();
    await h.key(_enter);
    await h.key(_enter);
    final replacement = model.replaceSpec(oldId, _spec('103'));
    await h.frame();
    expect(_prompt, findsNothing);
    reactivation.complete();
    await replacement;
    await h.frame();
    expect(old.sent, ['旧目标草稿']);
    expect(old.closed, isTrue);
    expect(h.active, {'103'});
    expect(h.drivers['103']!.sent, isEmpty);
    h.expectSingleSenderThroughout();
  }, variant: _desktop);

  testWidgets('removing the work route revokes a send before driver acceptance',
      (tester) async {
    final h = _Workspace(tester);
    await h.mount();
    await h.open();
    final model = h.model;
    final oldId = model.selectedRoomId!;
    await model.addSpec(_spec('102'));
    final driver = h.drivers['101']!;
    final activate = driver.activationGate = Completer<void>();
    model.selectRoom(oldId);
    await h.frame();
    await h.key(_enter);
    await tester.enterText(_promptInput, '待关闭草稿');
    await h.key(_enter);
    expect(driver.sent, isEmpty);
    final context = tester.element(find.byType(MultiLiveRoute));
    Navigator.of(context).removeRoute(ModalRoute.of(context)!);
    await h.frame();
    activate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(MultiLiveRoute), findsNothing);
    expect(_prompt, findsNothing);
    expect(driver.sent, isEmpty);
    expect(h.drivers.values.every((d) => d.closed), isTrue);
    expect(h.active, isEmpty);
    h.expectSingleSenderThroughout();
  }, variant: _desktop);

  testWidgets('closing during batch initialization rejects the late room',
      (tester) async {
    final h = _Workspace(tester);
    await h.mount();
    await h.open();
    await h.tap(_add);
    await h.tap(_follow('102'));
    await h.tap(_follow('103'));
    final lateRoom = h.startGates['103'] = Completer<void>();
    await h.tap(_batchConfirm);
    expect(h.drivers.keys, ['101', '102', '103']);
    expect(h.active, {'101'});
    await h.tap(find.byType(BackButton));
    expect(find.byType(MultiLiveRoute), findsOneWidget);
    lateRoom.complete();
    await tester.pumpAndSettle();
    expect(find.byType(MultiLiveRoute), findsNothing);
    expect(h.drivers.values.every((driver) => driver.closed), isTrue);
    expect(h.leases, [('101', true), ('101', false)]);
    expect(h.active, isEmpty);
    expect(h.saves, isEmpty);
  }, variant: _desktop);

  testWidgets('legacy title stays provisional until detail updates all labels',
      (tester) async {
    final oldSave = jsonEncode({
      'version': 1,
      'rooms': [
        {
          'id': 'from-v1',
          'spec': {
            'siteId': 'huya',
            'roomId': '777',
            'title': _oldTitle,
            'volume': 42,
            'muted': true,
            'danmakuVisible': false,
          }
        },
      ],
      'layout': {'type': 'leaf', 'id': 'leaf-from-v1', 'roomId': 'from-v1'},
      'selectedRoomId': 'from-v1',
    });
    final h = _Workspace(tester, oldSave: oldSave);
    await h.mount();
    await h.open();
    await h.tap(find.text('恢复布局'));
    const placeholder = '房间 777 · 主播名待加载';
    expect(h.model.selectedRoomId, 'from-v1');
    expect(h.model.rooms.single.volume, 42);
    expect(h.model.rooms.single.muted, isTrue);
    expect(find.text(placeholder), findsOneWidget);
    expect(find.text('聊天 · $placeholder'), findsOneWidget);
    expect(find.textContaining(_oldTitle), findsNothing);
    await h.key(_enter);
    expect(find.text('发送弹幕 · $placeholder'), findsOneWidget);
    final room = h.drivers['777']!.room;
    room.detail.value = _detail('777', '  新主播名  ', '今晚的直播标题');
    await h.frame();
    expect(find.text('发送弹幕 · 新主播名'), findsOneWidget);
    await h.key(_escape);
    expect(find.text('新主播名'), findsOneWidget);
    expect(find.text('聊天 · 新主播名'), findsOneWidget);
    expect(find.textContaining('今晚的直播标题'), findsWidgets);
    await h.tap(find.byKey(const ValueKey('audio-panel')));
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('multi-live-audio-panel')),
            matching: find.text('新主播名')),
        findsOneWidget);
    expect(h.saves, isEmpty);
  }, variant: _desktop);
}
