import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/multi_live/integration/multi_live_fullscreen.dart';
import 'package:simple_live_app/modules/multi_live/integration/multi_live_route.dart';
import 'package:simple_live_app/modules/multi_live/multi_live_controller.dart';
import 'package:simple_live_app/modules/multi_live/multi_live_page.dart';
import 'package:simple_live_app/modules/multi_live/session/multi_live_room_session.dart';
import 'package:simple_live_app/modules/multi_live/storage/multi_live_workspace_store.dart';
import 'package:simple_live_app/services/douyu_account_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

import 'fullscreen_controller_test.dart' show FullscreenWindowFake;

const _enter = LogicalKeyboardKey.enter;
const _numpadEnter = LogicalKeyboardKey.numpadEnter;
// Flutter's Windows simulator map does not distinguish keypad Enter.
const _keypadPlatform = 'linux';
const _windows = TargetPlatformVariant({TargetPlatform.windows});
const _escape = LogicalKeyboardKey.escape;
const _addRoom = ValueKey('add-room');
const _quickPrompt = ValueKey('quick-danmaku-prompt');
const _input = ValueKey('multi-live-danmaku-input');
const _send = ValueKey('multi-live-danmaku-send');
const _quickTarget = ValueKey('quick-danmaku-target');
const _confirmBatch = ValueKey('multi-live-confirm-selection');
const _layoutPresets = ValueKey('layout-presets');
const _roomLink = ValueKey('multi-live-room-link');

// Direct HardwareKeyboard dispatch updates pressed keys but skips Flutter's
// focus pipeline in this SDK. Use the native callback to exercise both.
void _syntheticEnter(WidgetTester tester, {required bool down}) {
  tester.binding.platformDispatcher.onKeyData!(ui.KeyData(
      type: down ? ui.KeyEventType.down : ui.KeyEventType.up,
      physical: PhysicalKeyboardKey.enter.usbHidUsage,
      logical: _enter.keyId,
      character: null,
      timeStamp: Duration.zero,
      synthesized: true));
}

MultiLiveRoomSpec _spec(int id) =>
    MultiLiveRoomSpec(siteId: 'douyu', roomId: '$id');

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

class _DouyuAccount extends DouyuAccountService {
  @override
  // ignore: must_call_super
  void onInit() {}
}

class _Follows extends FollowService {
  @override
  // ignore: must_call_super
  void onInit() {
    followList.assignAll([
      for (var id = 1; id <= 5; id++)
        FollowUser(
          id: 'douyu-$id',
          roomId: '$id',
          siteId: 'douyu',
          userName: '关注主播 $id',
          face: '',
          addTime: DateTime(2026),
        )..liveStatus.value = 2,
    ]);
  }
}

class _Window extends FullscreenWindowFake {
  Completer<void>? exitGate;

  @override
  Future<void> setFullScreen(bool value) async {
    if (!value) await exitGate?.future;
    await super.setFullScreen(value);
  }
}

class _PlayerBackend extends PlatformPlayer {
  _PlayerBackend() : super(configuration: const PlayerConfiguration());
}

class _VideoController implements VideoController {
  _VideoController(this.player);

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
    detail.value =
        _detail(spec.roomId, '主播 ${spec.roomId}', '直播标题 ${spec.roomId}');
    showDanmakuState.value = false;
  }

  final _player = Player(platformPlayer: _PlayerBackend());
  late final _videoController = _VideoController(_player);

  @override
  Player get player => _player;
  @override
  VideoController get videoController => _videoController;
}

class _Driver implements MultiLiveRoomDriver {
  _Driver(MultiLiveRoomSpec spec, this.leaseChanges) : room = _Room(spec);

  @override
  final _Room room;
  final List<String> leaseChanges;
  final sent = <String>[];
  Completer<String?>? sendGate;
  Completer<void>? activationGate;
  String? error;
  bool active = false;
  bool closed = false;

  @override
  Future<void> initialize() async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> setDanmakuVisible(bool visible) async {}

  @override
  Future<void> setSenderActive(bool value) async {
    if (active == value) return;
    if (value) await activationGate?.future;
    active = value;
    leaseChanges.add('${room.roomId}:$value');
  }

  @override
  Future<String?> sendDanmaku(String text) async {
    expect(active, isTrue);
    sent.add(text);
    final gate = sendGate;
    if (gate != null) return gate.future;
    return error;
  }

  @override
  Future<void> close() async {
    closed = true;
    await room.player.dispose();
    room.videoController.notifier.dispose();
  }
}

class _Harness {
  _Harness(this.tester);

  final WidgetTester tester;
  final window = _Window();
  final drivers = <String, _Driver>{};
  final leaseChanges = <String>[];
  final saved = <String>[];
  final notices = <String>[];
  final ancestorFocus = FocusNode();
  int ancestorEscapes = 0;

  MultiLiveController get model =>
      tester.widget<MultiLivePage>(find.byType(MultiLivePage)).model
          as MultiLiveController;

  Future<void> open() async {
    final platform = defaultTargetPlatform;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    Get.put<AppSettingsController>(_Settings());
    Get.put<FollowService>(_Follows());
    Get.put<DouyuAccountService>(_DouyuAccount());
    addTearDown(() async {
      final exitGate = window.exitGate;
      if (exitGate != null && !exitGate.isCompleted) exitGate.complete();
      for (final driver in drivers.values) {
        final sendGate = driver.sendGate;
        if (sendGate != null && !sendGate.isCompleted) sendGate.complete(null);
        final activation = driver.activationGate;
        if (activation != null && !activation.isCompleted) {
          activation.complete();
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      ancestorFocus.dispose();
      Get.reset();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(GetMaterialApp(
      theme: AppStyle.lightTheme.copyWith(platform: platform),
      builder: (_, child) => KeyboardListener(
        focusNode: ancestorFocus,
        onKeyEvent: (event) async {
          if (event is KeyDownEvent && event.logicalKey == _escape) {
            ancestorEscapes++;
            // Mirrors main.dart's native full-screen exit fallback.
            if (await window.isFullScreen()) await window.setFullScreen(false);
          }
        },
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => MultiLiveRoute(
                initialRoom: _spec(1),
                fullscreenControl: MultiLiveWindowFullscreenController(
                    platform: platform, backend: window),
                store: MultiLiveWorkspaceStore(
                    read: () async => null,
                    write: (value) async => saved.add(value)),
                sessionFactory: ({required id, required spec}) =>
                    MultiLiveRoomSession(
                        id: id,
                        spec: spec,
                        driverFactory: (spec) =>
                            drivers[spec.roomId] = _Driver(spec, leaseChanges)),
                onNotice: notices.add,
              ),
            )),
            child: const Text('打开测试多开页'),
          ),
        ),
      ),
    ));
    await tap(find.text('打开测试多开页'));
    expect(find.byType(MultiLivePage), findsOneWidget);
    expect(notices, isEmpty);
  }

  Future<void> tap(Finder target, {bool whilePicking = false}) async {
    await tester.tap(target);
    if (whilePicking) {
      // The workspace intentionally keeps its progress indicator running
      // behind the picker and the login reminder until selection finishes.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    } else {
      await tester.pumpAndSettle();
    }
  }

  Future<void> key(LogicalKeyboardKey value) async {
    await tester.sendKeyEvent(value,
        platform: value == _numpadEnter ? _keypadPlatform : null);
    await tester.pumpAndSettle();
  }
}

Finder get _prompt => find.byKey(_quickPrompt);
Finder get _promptInput =>
    find.descendant(of: _prompt, matching: find.byKey(_input));
Finder _follow(int id) => find.byKey(ValueKey('multi-live-follow-douyu-$id'));

void main() {
  for (final submitKey in [_enter, _numpadEnter]) {
    testWidgets('feedback prompt title click keeps blank ${submitKey.keyLabel}',
        (tester) async {
      final harness = _Harness(tester);
      await harness.open();
      final driver = harness.drivers['1']!;
      await harness.key(submitKey);
      await tester.enterText(_promptInput, '   ');
      expect(tester.widget<TextField>(_promptInput).focusNode!.hasPrimaryFocus,
          isTrue);
      await tester.tap(find.byKey(_quickTarget),
          kind: ui.PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      await harness.key(submitKey);
      expect(_prompt, findsNothing);
      expect(driver.sent, isEmpty);
      expect(driver.room.danmakuDraft.value, '   ');
      expect(tester.takeException(), isNull);
    }, variant: _windows);

    testWidgets(
        'feedback prompt title click keeps single send ${submitKey.keyLabel}',
        (tester) async {
      final harness = _Harness(tester);
      await harness.open();
      final driver = harness.drivers['1']!;
      await harness.key(submitKey);
      await tester.enterText(_promptInput, '  标题点击后发送  ');
      await tester.tap(find.byKey(_quickTarget),
          kind: ui.PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(submitKey,
          platform: submitKey == _numpadEnter ? _keypadPlatform : null);
      await tester.pumpAndSettle();
      await tester.sendKeyRepeatEvent(submitKey,
          platform: submitKey == _numpadEnter ? _keypadPlatform : null);
      await tester.sendKeyUpEvent(submitKey,
          platform: submitKey == _numpadEnter ? _keypadPlatform : null);
      await tester.pumpAndSettle();
      expect(driver.sent, ['标题点击后发送']);
      expect(_prompt, findsNothing);
      expect(driver.room.danmakuDraft.value, isEmpty);
      expect(tester.takeException(), isNull);
    }, variant: _windows);
  }

  testWidgets('feedback prompt title respects Tab and button activation',
      (tester) async {
    final harness = _Harness(tester);
    await harness.open();
    final driver = harness.drivers['1']!;
    await harness.key(_enter);
    await harness.key(LogicalKeyboardKey.tab);
    IconButton? focusedButton() => FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<IconButton>();
    expect(focusedButton()?.key, _send);
    await tester.tap(find.byKey(_quickTarget),
        kind: ui.PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(focusedButton()?.key, _send);
    // Enter on the send button retains its empty-draft no-op behavior.
    await harness.key(_enter);
    expect(_prompt, findsOneWidget);
    expect(driver.sent, isEmpty);
    Future<void> previous() async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
    }

    await previous();
    expect(tester.widget<TextField>(_promptInput).focusNode!.hasPrimaryFocus,
        isTrue);
    await previous();
    expect(focusedButton()?.tooltip, '收起弹幕输入（Esc）');
    await tester.tap(find.byKey(_quickTarget),
        kind: ui.PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(focusedButton()?.tooltip, '收起弹幕输入（Esc）');
    await harness.key(_enter);
    expect(_prompt, findsNothing);
    expect(driver.sent, isEmpty);
    expect(tester.takeException(), isNull);
  }, variant: _windows);

  testWidgets('feedback Enter toggles blank prompt repeatedly on actual route',
      (tester) async {
    final harness = _Harness(tester);
    await harness.open();
    final driver = harness.drivers['1']!;
    expect(find.byKey(const ValueKey('quick-danmaku-entry')), findsNothing);
    expect(find.byKey(_input).hitTestable(), findsOneWidget);
    for (var i = 0; i < 8; i++) {
      await harness.key(i.isEven ? _enter : _numpadEnter);
      expect(_prompt, findsOneWidget);
      expect(tester.widget<TextField>(_promptInput).focusNode!.hasPrimaryFocus,
          isTrue);
      await tester.enterText(_promptInput, i.isEven ? '' : '   ');
      await harness.key(i.isEven ? _enter : _numpadEnter);
      expect(_prompt, findsNothing);
      expect(driver.sent, isEmpty);
    }
    await harness.key(_enter);
    await tester.enterText(_promptInput, '  成功发送  ');
    await harness.key(_enter);
    expect(driver.sent, ['成功发送']);
    expect(_prompt, findsNothing);
    expect(driver.room.danmakuDraft.value, isEmpty);
    // The sidebar composer remains usable after the title entry was removed.
    await tester.enterText(find.byKey(_input).hitTestable(), '底部发送');
    await harness.tap(find.byKey(_send).hitTestable());
    expect(driver.sent, ['成功发送', '底部发送']);
    expect(tester.takeException(), isNull);
  }, variant: _windows);

  testWidgets(
      'feedback Enter recovers from ancestor focus, controls and popups',
      (tester) async {
    final harness = _Harness(tester);
    await harness.open();
    final id = harness.model.selectedRoomId!;
    Future<void> checkEntry() async {
      await harness.key(_enter);
      expect(_prompt, findsOneWidget);
      expect(tester.widget<TextField>(_promptInput).focusNode!.hasPrimaryFocus,
          isTrue);
      await harness.key(_enter);
      expect(_prompt, findsNothing);
    }

    harness.ancestorFocus.requestFocus();
    await tester.pump();
    expect(harness.ancestorFocus.hasPrimaryFocus, isTrue);
    await checkEntry();
    await harness.tap(find.byKey(ValueKey('tile:$id')));
    await checkEntry();
    await harness.tap(find.byKey(const ValueKey('audio-panel')));
    final slider = find.byKey(ValueKey('audio-volume:$id'));
    await tester.tap(slider);
    await tester.pumpAndSettle();
    await harness.key(_enter);
    expect(_prompt, findsNothing);
    await harness.tap(find.byTooltip('关闭音量面板'));
    await checkEntry();
    for (final menu in [
      find.byKey(_layoutPresets),
      find.byKey(ValueKey('room-menu:$id')),
    ]) {
      await harness.tap(menu);
      await harness.key(_escape);
      await checkEntry();
    }
    await harness.tap(find.byKey(_addRoom), whilePicking: true);
    await harness.tap(find.text('取消'));
    await checkEntry();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    FocusManager.instance.rootScope.requestFocus();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    await checkEntry();
    await harness.model.addSpec(_spec(2));
    await tester.pumpAndSettle();
    await checkEntry();
    expect(harness.drivers.values.expand((driver) => driver.sent), isEmpty);
    expect(tester.takeException(), isNull);
  }, variant: _windows);

  testWidgets('feedback held, modified and synthesized Enter never doubles',
      (tester) async {
    final harness = _Harness(tester);
    await harness.open();
    final driver = harness.drivers['1']!;
    for (final modifier in [
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.altLeft,
      LogicalKeyboardKey.shiftLeft,
      LogicalKeyboardKey.metaLeft,
    ]) {
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(_enter);
      await tester.sendKeyUpEvent(modifier);
      await tester.pumpAndSettle();
      expect(_prompt, findsNothing);
    }
    _syntheticEnter(tester, down: true);
    _syntheticEnter(tester, down: false);
    await tester.pumpAndSettle();
    expect(_prompt, findsNothing);
    driver.room.danmakuDraft.value = '已有草稿';
    await tester.sendKeyDownEvent(_enter);
    await tester.pumpAndSettle();
    for (var i = 0; i < 4; i++) {
      await tester.sendKeyRepeatEvent(_enter);
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
    }
    expect(driver.sent, isEmpty);
    expect(_prompt, findsOneWidget);
    await tester.sendKeyUpEvent(_enter);
    await tester.pumpAndSettle();
    driver.error = '保留草稿的失败';
    await tester.sendKeyDownEvent(_enter);
    await tester.pump();
    expect(driver.sent, ['已有草稿']);
    // A completed failure must not permit a following action from this same
    // hardware press to dispatch the same text for a second time.
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.sendKeyRepeatEvent(_enter);
    await tester.sendKeyUpEvent(_enter);
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();
    expect(driver.sent, ['已有草稿']);
    expect(_prompt, findsOneWidget);
    await tester.sendKeyDownEvent(_enter);
    await tester.pumpAndSettle();
    expect(driver.sent, ['已有草稿', '已有草稿']);
    // A key-up can arrive while window/control focus is elsewhere. A fresh
    // key-down after focusing the field must still submit immediately.
    harness.ancestorFocus.requestFocus();
    await tester.pump();
    expect(harness.ancestorFocus.hasPrimaryFocus, isTrue);
    await tester.sendKeyUpEvent(_enter);
    tester.widget<TextField>(_promptInput).focusNode!.requestFocus();
    await tester.pump();
    await harness.key(_enter);
    expect(driver.sent, ['已有草稿', '已有草稿', '已有草稿']);
    await tester.enterText(_promptInput, '   ');
    await tester.sendKeyDownEvent(_enter);
    await tester.pumpAndSettle();
    expect(_prompt, findsNothing);
    await tester.sendKeyRepeatEvent(_enter);
    await tester.sendKeyRepeatEvent(_enter);
    await tester.sendKeyUpEvent(_enter);
    await tester.pumpAndSettle();
    expect(_prompt, findsNothing);
    expect(driver.sent, ['已有草稿', '已有草稿', '已有草稿']);
    await harness.key(_enter);
    expect(_prompt, findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: _windows);

  testWidgets('feedback composer keeps IME, modifiers and synthetic keys safe',
      (tester) async {
    final harness = _Harness(tester);
    await harness.open();
    final driver = harness.drivers['1']!;
    await harness.key(_enter);
    await tester.enterText(_promptInput, '受保护草稿');
    for (final modifier in [
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.altLeft,
      LogicalKeyboardKey.shiftLeft,
      LogicalKeyboardKey.metaLeft,
    ]) {
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyDownEvent(_enter);
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.sendKeyRepeatEvent(_enter);
      await tester.sendKeyUpEvent(_enter);
      await tester.sendKeyUpEvent(modifier);
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(driver.sent, isEmpty);
      expect(_prompt, findsOneWidget);
    }
    _syntheticEnter(tester, down: true);
    await tester.testTextInput.receiveAction(TextInputAction.send);
    _syntheticEnter(tester, down: false);
    await tester.pumpAndSettle();
    expect(driver.sent, isEmpty);
    expect(_prompt, findsOneWidget);
    tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: '拼',
        selection: TextSelection.collapsed(offset: 1),
        composing: TextRange(start: 0, end: 1)));
    // An IME can clear its composing text before delivering confirmation.
    // The now-blank prompt must survive that confirmation frame.
    tester.testTextInput.updateEditingValue(TextEditingValue.empty);
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.sendKeyEvent(_enter);
    await tester.pumpAndSettle();
    expect(driver.sent, isEmpty);
    expect(_prompt, findsOneWidget);
    await harness.key(_enter);
    expect(_prompt, findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: _windows);

  testWidgets('actual route layers Escape and waits for native restore on back',
      (tester) async {
    final harness = _Harness(tester);
    final original = harness.window.bounds;
    await harness.open();
    final model = harness.model;
    final selected = model.selectedRoomId;
    expect(harness.window.calls.take(3),
        ['read-fullscreen', 'read-maximized', 'read-bounds']);
    await harness.key(LogicalKeyboardKey.f11);
    expect(harness.window.fullscreen, isTrue);
    await harness.tap(find.byTooltip('放大 主播 1'));
    expect(model.maximizedRoomId, selected);
    await harness.key(_enter);
    expect(_promptInput, findsOneWidget);
    expect(tester.widget<TextField>(_promptInput).focusNode!.hasPrimaryFocus,
        isTrue);

    await harness.key(_escape);
    expect(_prompt, findsNothing);
    expect(model.maximizedRoomId, selected);
    expect(harness.window.transitions, [true]);
    await harness.key(_escape);
    expect(model.maximizedRoomId, isNull);
    expect(harness.window.transitions, [true]);
    await harness.key(_escape);
    expect(harness.window.transitions, [true, false]);
    expect(harness.window.bounds, original);
    expect(harness.ancestorEscapes, 0);

    await harness.key(LogicalKeyboardKey.f11);
    final exit = harness.window.exitGate = Completer<void>();
    await tester.tap(find.byType(BackButton));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(MultiLiveRoute), findsOneWidget);
    expect(harness.window.fullscreen, isTrue);
    expect(harness.window.closed, 0);
    exit.complete();
    await tester.pumpAndSettle();
    expect(find.byType(MultiLiveRoute), findsNothing);
    expect(harness.window.transitions, [true, false, true, false]);
    expect(harness.window.bounds, original);
    expect(harness.window.closed, 1);
    expect(harness.drivers['1']!.closed, isTrue);
  }, variant: _windows);

  testWidgets('real composer preserves IME and shared draft through retry',
      (tester) async {
    final harness = _Harness(tester);
    await harness.open();
    final driver = harness.drivers['1']!;
    driver.room.danmakuDraft.value = '原草稿';
    await tester.sendKeyDownEvent(_numpadEnter, platform: _keypadPlatform);
    await tester.pumpAndSettle();
    expect(_promptInput, findsOneWidget);
    expect(tester.widget<TextField>(_promptInput).focusNode!.hasPrimaryFocus,
        isTrue);
    expect(tester.widget<TextField>(_promptInput).controller!.text, '原草稿');
    await tester.sendKeyRepeatEvent(_numpadEnter, platform: _keypadPlatform);
    await tester.sendKeyUpEvent(_numpadEnter, platform: _keypadPlatform);
    expect(driver.sent, isEmpty);

    const composing = TextEditingValue(
        text: '弹幕',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2));
    tester.testTextInput.updateEditingValue(composing);
    await harness.key(_enter);
    expect(driver.sent, isEmpty);
    tester.testTextInput
        .updateEditingValue(composing.copyWith(composing: TextRange.empty));
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.sendKeyEvent(_numpadEnter, platform: _keypadPlatform);
    await tester.pumpAndSettle();
    expect(driver.sent, isEmpty);
    expect(driver.room.danmakuDraft.value, '弹幕');

    driver.error = '测试发送失败';
    await harness.key(_numpadEnter);
    expect(driver.sent, ['弹幕']);
    expect(find.text('测试发送失败'), findsOneWidget);
    expect(driver.room.danmakuDraft.value, '弹幕');
    expect(tester.widget<TextField>(_promptInput).controller!.text, '弹幕');
    final sidebar = find.byKey(_input).hitTestable();
    await harness.key(_escape);
    expect(tester.widget<TextField>(sidebar).controller!.text, '弹幕');

    driver.error = null;
    await harness.key(_enter);
    final pending = driver.sendGate = Completer<String?>();
    await tester.sendKeyEvent(_enter);
    await tester.pump();
    expect(driver.sent, ['弹幕', '弹幕']);
    await tester.enterText(_promptInput, '更新的草稿');
    pending.complete(null);
    await tester.pumpAndSettle();
    expect(driver.room.danmakuDraft.value, '更新的草稿');
    expect(tester.widget<TextField>(_promptInput).controller!.text, '更新的草稿');

    driver.sendGate = null;
    await harness.key(_enter);
    expect(driver.sent, ['弹幕', '弹幕', '更新的草稿']);
    expect(driver.room.danmakuDraft.value, isEmpty);
    expect(_prompt, findsNothing);
  }, variant: _windows);

  testWidgets('closing and replacing the actual prompt revoke its send',
      (tester) async {
    final harness = _Harness(tester);
    await harness.open();
    final model = harness.model;
    final first = harness.drivers['1']!;
    unawaited(model.addSpec(_spec(2)));
    await tester.pumpAndSettle();
    final firstId = model.rooms.first.id;
    first.room.danmakuDraft.value = '排队草稿';
    final activation = first.activationGate = Completer<void>();
    model.selectRoom(firstId);
    await harness.key(_enter);
    expect(
        tester.widget<Text>(find.byKey(_quickTarget)).data, contains('主播 1'));
    await tester.sendKeyEvent(_enter);
    await tester.pump();
    expect(first.sent, isEmpty);
    await harness.key(_escape);
    expect(_prompt, findsNothing);
    await tester.tap(find.byKey(_send).hitTestable());
    await tester.pump();
    expect(find.text('相同弹幕正在发送，请稍候'), findsOneWidget);
    activation.complete();
    await tester.pumpAndSettle();
    expect(first.sent, isEmpty);
    expect(first.room.danmakuDraft.value, '排队草稿');

    await harness.key(_enter);
    final sent = first.sendGate = Completer<String?>();
    await tester.sendKeyEvent(_enter);
    await tester.pump();
    expect(first.sent, ['排队草稿']);
    unawaited(model.replaceSpec(firstId, _spec(3)));
    await tester.pumpAndSettle();
    expect(_prompt, findsNothing);
    expect(first.closed, isTrue);
    await harness.key(_enter);
    expect(
        tester.widget<Text>(find.byKey(_quickTarget)).data, contains('主播 3'));
    await tester.enterText(_promptInput, '新房间草稿');
    sent.complete(null);
    await tester.pumpAndSettle();
    expect(harness.drivers['3']!.sent, isEmpty);
    expect(first.room.danmakuDraft.value, '排队草稿');
    expect(tester.widget<TextField>(_promptInput).controller!.text, '新房间草稿');
  }, variant: _windows);

  testWidgets('sidebar shares the quick prompt’s pending-send protection',
      (tester) async {
    final harness = _Harness(tester);
    await harness.open();
    final driver = harness.drivers['1']!;
    final pending = driver.sendGate = Completer<String?>();
    await harness.key(_enter);
    await tester.enterText(_promptInput, '同一条弹幕');
    await tester.sendKeyEvent(_enter);
    await tester.pump();
    expect(driver.sent, ['同一条弹幕']);
    await harness.key(_escape);
    expect(_prompt, findsNothing);

    final sidebarInput = find.byKey(_input).hitTestable();
    final sidebarSend = find.byKey(_send).hitTestable();
    expect(tester.widget<TextField>(sidebarInput).controller!.text, '同一条弹幕');
    await tester.tap(sidebarSend);
    await tester.pump();
    expect(driver.sent, ['同一条弹幕']);
    expect(find.text('相同弹幕正在发送，请稍候'), findsOneWidget);
    expect(driver.room.danmakuDraft.value, '同一条弹幕');

    driver.sendGate = null;
    await tester.enterText(sidebarInput, '另一条弹幕');
    await harness.tap(sidebarSend);
    expect(driver.sent, ['同一条弹幕', '另一条弹幕']);
    expect(driver.room.danmakuDraft.value, isEmpty);

    await tester.enterText(sidebarInput, '更新的草稿');
    pending.complete(null);
    await tester.pumpAndSettle();
    expect(driver.room.danmakuDraft.value, '更新的草稿');

    await tester.enterText(sidebarInput, '同一条弹幕');
    await harness.tap(sidebarSend);
    expect(driver.sent, ['同一条弹幕', '另一条弹幕', '同一条弹幕']);
    expect(driver.room.danmakuDraft.value, isEmpty);
  }, variant: _windows);

  testWidgets('workspace Enter respects the actual menu and picker input',
      (tester) async {
    final harness = _Harness(tester);
    await harness.open();
    final menu = find.byWidgetPredicate((widget) => widget is PopupMenuItem);
    await harness.tap(find.byKey(_layoutPresets));
    expect(menu, findsWidgets);
    await harness.key(_enter);
    expect(_prompt, findsNothing);
    if (menu.evaluate().isNotEmpty) await harness.key(_escape);

    await harness.tap(find.byKey(_addRoom), whilePicking: true);
    final link = find.byKey(_roomLink);
    await harness.tap(link, whilePicking: true);
    expect(tester.widget<TextField>(link).focusNode!.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(_enter);
    await tester.pump();
    expect(link, findsOneWidget);
    expect(_prompt, findsNothing);
    expect(harness.drivers['1']!.sent, isEmpty);
    await harness.tap(find.text('取消'));
  }, variant: _windows);

  for (final (platform, cap) in [
    (TargetPlatform.windows, 4),
    (TargetPlatform.android, 2)
  ]) {
    testWidgets(
        'actual ${platform.name} route batches at capacity $cap with login reminder',
        (tester) async {
      final harness = _Harness(tester);
      await harness.open();
      expect(harness.model.maxRooms, cap);
      final writesBefore = harness.saved.length;
      final leasesBefore = harness.leaseChanges.length;
      await harness.tap(find.byKey(_addRoom), whilePicking: true);
      await harness.tap(_follow(2), whilePicking: true);
      await harness.tap(find.text('取消'));
      expect(harness.drivers.keys, ['1']);
      expect(harness.saved, hasLength(writesBefore));

      await harness.tap(find.byKey(_addRoom), whilePicking: true);
      expect(find.text('斗鱼直播 · 已打开'), findsOneWidget);
      expect(find.text('已选 0 · 还可选 ${cap - 1}'), findsOneWidget);
      for (var i = 2; i <= cap; i++) {
        await harness.tap(_follow(i), whilePicking: true);
      }
      expect(find.text('已选 ${cap - 1} · 还可选 0'), findsOneWidget);
      await harness.tap(find.byKey(_confirmBatch), whilePicking: true);
      expect(find.text('登录斗鱼'), findsOneWidget);
      expect(harness.drivers.keys, ['1']);
      await harness.tap(find.text('取消'));
      expect(find.text('登录斗鱼'), findsNothing);
      expect(harness.drivers.keys, [for (var i = 1; i <= cap; i++) '$i']);
      expect(harness.saved, hasLength(writesBefore + 1));
      expect(harness.leaseChanges.skip(leasesBefore), ['1:false', '$cap:true']);
      final model = harness.model;
      expect(model.selectedRoomId, model.rooms.last.id);
      expect(model.rooms.last.title, '主播 $cap');
      expect(model.rooms.last.subtitle, contains('直播标题 $cap'));
      final active = harness.drivers['$cap']!;
      active.room.detail.value = _detail('$cap', '新主播名', '另一直播标题');
      await tester.pumpAndSettle();
      expect(model.rooms.last.title, '新主播名');
      expect(model.rooms.last.subtitle, contains('另一直播标题'));
    }, variant: TargetPlatformVariant.only(platform));
  }
}
