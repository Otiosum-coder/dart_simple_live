import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/multi_live/integration/multi_live_fullscreen.dart';
import 'package:simple_live_app/modules/multi_live/multi_live_controller.dart';
import 'package:simple_live_app/modules/multi_live/multi_live_device_policy.dart';
import 'package:simple_live_app/modules/multi_live/multi_live_page.dart';
import 'package:simple_live_app/modules/multi_live/session/multi_live_room_session.dart';
import 'package:simple_live_app/modules/multi_live/storage/multi_live_workspace_store.dart';
import 'package:simple_live_app/modules/multi_live/widgets/multi_live_view_model.dart';

import 'fullscreen_controller_test.dart' show FullscreenWindowFake;
import 'page_interaction_test.dart' show FakeModel, Probe;

class _Driver implements MultiLiveRoomDriver {
  int initialized = 0;
  int closed = 0;
  @override
  LiveRoomController? get room => null;
  @override
  Future<void> initialize() async => initialized++;
  @override
  Future<void> close() async => closed++;
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> setDanmakuVisible(bool visible) async {}
  @override
  Future<void> setSenderActive(bool active) async {}
  @override
  Future<String?> sendDanmaku(String text) async => null;
}

bool _contains(Rect outer, Rect inner) =>
    outer.inflate(.5).contains(inner.topLeft) &&
    outer.inflate(.5).contains(inner.bottomRight);

Future<void> _mount(WidgetTester tester, MultiLiveViewModel model,
    MultiLiveWindowFullscreenController fullscreen,
    {Size size = const Size(1200, 800),
    ThemeData? theme,
    double scale = 1}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await fullscreen.initialize();
  await tester.pumpWidget(MaterialApp(
      theme: (theme ?? AppStyle.lightTheme)
          .copyWith(platform: TargetPlatform.windows),
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!),
      home: Builder(
          builder: (context) => Scaffold(
              body: TextButton(
                  onPressed: () async {
                    await Navigator.of(context).push(MaterialPageRoute<void>(
                        builder: (_) => MultiLivePage(
                            model: model, fullscreenControl: fullscreen)));
                    // Minimal injected route host: Page itself must not own it.
                    await fullscreen.close();
                  },
                  child: const Text('Open'))))));
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

final _cleanups = <Future<void> Function()>[];

// Await window cleanup while the widget-test zone can still flush its microtasks.
void _pageTest(String name, WidgetTesterCallback callback) {
  testWidgets(name, (tester) async {
    try {
      await callback(tester);
    } finally {
      for (final cleanup in _cleanups.reversed) {
        await cleanup();
      }
      _cleanups.clear();
    }
  });
}

void main() {
  _pageTest('button F11 Escape and route teardown keep all native bodies alive',
      (tester) async {
    final drivers = <_Driver>[];
    final created = <String, int>{};
    final destroyed = <String, int>{};
    final model = MultiLiveController(
        policy: const MultiLiveDevicePolicy(TargetPlatform.windows),
        sites: const {'douyu': '斗鱼'},
        store: MultiLiveWorkspaceStore(
            read: () async => null, write: (_) async {}),
        pickRoom: () async => null,
        roomBuilder: (_, session) =>
            Probe(id: session.id, created: created, destroyed: destroyed),
        chatBuilder: (_, session, __) => Text('chat:${session.id}'),
        notice: (_) {},
        sessionFactory: ({required id, required spec}) {
          final driver = _Driver();
          drivers.add(driver);
          return MultiLiveRoomSession(
              id: id, spec: spec, driverFactory: (_) => driver);
        });
    for (var i = 0; i < 4; i++) {
      await model
          .addSpec(MultiLiveRoomSpec(siteId: 'douyu', roomId: 'native$i'));
    }
    final window = FullscreenWindowFake();
    final original = window.bounds;
    final fullscreen = MultiLiveWindowFullscreenController(
        backend: window, platform: TargetPlatform.windows);
    _cleanups.add(() async {
      await tester.pumpWidget(const SizedBox());
      await fullscreen.close();
      fullscreen.dispose();
      await model.close();
      model.dispose();
    });
    await _mount(tester, model, fullscreen);
    expect(tester.getSize(find.byType(AppBar)).height, 32);
    expect(drivers.map((driver) => driver.initialized), everyElement(1));
    expect(created.values, everyElement(1));
    await tester.tap(find.byKey(const ValueKey('workspace-fullscreen')));
    await tester.pumpAndSettle();
    expect(window.fullscreen, isTrue);
    expect(find.byTooltip('退出整窗全屏（F11 / Esc）'), findsOneWidget);
    final ids = model.rooms.map((room) => room.id).toList();
    model.selectRoom(ids.last);
    model.setPreset(MultiLiveLayoutPreset.leftMainThree);
    model.maximizeRoom(ids.first);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(model.maximizedRoomId, isNull);
    expect(window.fullscreen, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pumpAndSettle();
    expect(window.fullscreen, isFalse);
    expect(window.bounds, original);
    await tester.tap(find.byKey(const ValueKey('audio-panel')));
    await tester.pumpAndSettle();
    tester
        .widget<Slider>(find.byKey(ValueKey('audio-volume:${ids.first}')))
        .onChanged!(37);
    await tester.pumpAndSettle();
    expect(model.rooms.first.volume, 37);
    expect(model.rooms.skip(1).map((room) => room.volume), everyElement(100));
    await tester.tap(find.byTooltip('关闭音量面板'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pumpAndSettle();
    expect(drivers.map((driver) => driver.initialized), everyElement(1));
    expect(drivers.map((driver) => driver.closed), everyElement(0));
    expect(created.values, everyElement(1));
    expect(destroyed, isEmpty);
    expect(find.byType(Probe, skipOffstage: false), findsNWidgets(4));
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Open'), findsOneWidget);
    expect(window.fullscreen, isFalse);
    expect(window.bounds, original);
    expect(window.closed, 1);
    expect(drivers.map((driver) => driver.initialized), everyElement(1));
    expect(drivers.map((driver) => driver.closed), everyElement(0));
    expect(tester.takeException(), isNull);
  });

  for (final (name, theme) in [
    ('light', AppStyle.lightTheme),
    ('dark', AppStyle.darkTheme)
  ]) {
    for (final scale in [1.5, 2.0]) {
      _pageTest('six toolbar actions and full title fit 320x240 $name $scale',
          (tester) async {
        final model = FakeModel(4);
        final window = FullscreenWindowFake();
        final fullscreen = MultiLiveWindowFullscreenController(
            backend: window, platform: TargetPlatform.windows);
        _cleanups.add(() async {
          await tester.pumpWidget(const SizedBox());
          await fullscreen.close();
          fullscreen.dispose();
          model.dispose();
        });
        await _mount(tester, model, fullscreen,
            size: const Size(320, 240), theme: theme, scale: scale);
        final bar = find.byType(AppBar);
        final bounds = tester.getRect(bar);
        for (final action in [
          find.byType(BackButton),
          find.byKey(const ValueKey('layout-presets')),
          find.byKey(const ValueKey('audio-panel')),
          find.byKey(const ValueKey('chat-panel')),
          find.byKey(const ValueKey('workspace-fullscreen')),
          find.byKey(const ValueKey('add-room'))
        ]) {
          expect(action.hitTestable(), findsOneWidget);
          expect(_contains(bounds, tester.getRect(action)), isTrue);
          expect(tester.getSize(action).height, 32);
        }
        for (final label in ['多开直播', '4/4']) {
          final text =
              find.descendant(of: bar, matching: find.textContaining(label));
          final paragraph = tester.renderObject<RenderParagraph>(
              find.descendant(of: text, matching: find.byType(RichText)));
          expect(paragraph.didExceedMaxLines, isFalse);
          expect(_contains(bounds, tester.getRect(text)), isTrue);
          final boxes = paragraph.getBoxesForSelection(TextSelection(
              baseOffset: 0,
              extentOffset: paragraph.text.toPlainText().length));
          for (final box in boxes) {
            final glyph =
                box.toRect().shift(paragraph.localToGlobal(Offset.zero));
            expect(_contains(bounds, glyph), isTrue);
          }
        }
        await tester.tap(find.byKey(const ValueKey('workspace-fullscreen')));
        await tester.pumpAndSettle();
        expect(window.fullscreen, isTrue);
        expect(model.created.values, everyElement(1));
        expect(model.destroyed, isEmpty);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
