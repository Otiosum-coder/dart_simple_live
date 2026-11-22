import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/modules/multi_live/multi_live_page.dart';
import 'package:simple_live_app/modules/multi_live/widgets/multi_live_view_model.dart';
import 'page_interaction_test.dart' show FakeModel, Probe;

class _TrackedModel extends FakeModel {
  _TrackedModel(super.count, {super.maxRooms});
  final invalidAudioCalls = <String>[];
  final audioCalls = <String>[];

  @override
  Future<void> setVolume(String id, double value) async {
    if (!ids.contains(id)) invalidAudioCalls.add(id);
    audioCalls.add('volume:$id');
    await super.setVolume(id, value);
  }

  @override
  Future<void> toggleMute(String id) async {
    if (!ids.contains(id)) invalidAudioCalls.add(id);
    audioCalls.add('mute:$id');
    await super.toggleMute(id);
  }
}

Future<void> _mount(WidgetTester tester, FakeModel model,
    {Size size = const Size(1200, 800),
    TargetPlatform platform = TargetPlatform.windows,
    bool nestedRoute = false}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
      theme: ThemeData(useMaterial3: true, platform: platform),
      home: nestedRoute
          ? Builder(
              builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                              builder: (_) => MultiLivePage(model: model))),
                      child: const Text('Open'))))
          : MultiLivePage(model: model)));
  if (nestedRoute) {
    await tester.tap(find.text('Open'));
  }
  await tester.pumpAndSettle();
}

Future<void> _openAudio(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('audio-panel')));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('multi-live-audio-panel')), findsOneWidget);
}

Finder _slider(String id) => find.byKey(ValueKey('audio-volume:$id'));
Finder _mute(String id) => find.byKey(ValueKey('audio-mute:$id'));

void main() {
  testWidgets('desktop toolbar is 32px with every action and back reachable',
      (tester) async {
    final model = _TrackedModel(2);
    await _mount(tester, model, size: const Size(360, 400), nestedRoute: true);
    expect(tester.getSize(find.byType(AppBar)).height, 32);
    for (final finder in [
      find.byType(BackButton),
      find.byKey(const ValueKey('layout-presets')),
      find.byKey(const ValueKey('audio-panel')),
      find.byTooltip('查看选中房间聊天'),
      find.byKey(const ValueKey('add-room')),
    ]) {
      expect(finder.hitTestable(), findsOneWidget);
      expect(tester.getSize(finder).height, 32);
    }
    await tester.tap(find.byKey(const ValueKey('layout-presets')));
    await tester.pumpAndSettle();
    final preset = find.text('${MultiLiveLayoutPreset.sideBySide.label} · 2路');
    expect(preset, findsOneWidget);
    await tester.tap(preset);
    await tester.pumpAndSettle();
    await _openAudio(tester);
    await tester.tap(find.byTooltip('关闭音量面板'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Open'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'panel drag shows live percentage and preserves independent levels',
      (tester) async {
    final model = _TrackedModel(4);
    await _mount(tester, model);
    await _openAudio(tester);
    expect(find.text('各直播间音量'), findsOneWidget);
    for (final id in model.ids) {
      expect(find.byKey(ValueKey('audio-row:$id')), findsOneWidget);
    }
    final gesture =
        await tester.startGesture(tester.getCenter(_slider('room0')));
    await gesture.moveBy(const Offset(-35, 0));
    await tester.pump();
    final dragged = tester.widget<Slider>(_slider('room0')).value;
    expect(dragged, inExclusiveRange(0, 100));
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('audio-percent:room0')))
            .data,
        '${dragged.round()}%');
    await gesture.up();
    await tester.pumpAndSettle();
    expect(model.volume.keys, ['room0']);
    expect(model.rooms.skip(1).map((room) => room.volume), everyElement(100));
    await tester.tap(_mute('room0'));
    await tester.pumpAndSettle();
    expect(model.muted, {'room0': true});
    expect(model.rooms.first.volume, dragged);
    await tester.tap(_mute('room0'));
    await tester.pumpAndSettle();
    expect(model.muted['room0'], isFalse);
    expect(model.rooms.first.volume, dragged);
    tester.widget<Slider>(_slider('room1')).onChanged!(23);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('audio-all-muted')));
    await tester.pumpAndSettle();
    expect(model.allMuted, isTrue);
    expect(find.text('恢复所有声音'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('audio-all-muted')));
    await tester.pumpAndSettle();
    expect(model.rooms.map((room) => room.muted), everyElement(false));
    expect(model.volume, {'room0': dragged, 'room1': 23});
    expect(model.created, {'room0': 1, 'room1': 1, 'room2': 1, 'room3': 1});
    expect(model.destroyed, isEmpty);
    expect(model.selectedRoomId, 'room0');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'open panel tracks additions selection replacement and closed rows',
      (tester) async {
    final model = _TrackedModel(2);
    await _mount(tester, model);
    await _openAudio(tester);
    await model.addRoom();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('audio-row:room2')), findsOneWidget);
    model.selectRoom('room1');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('audio-selected:room1')), findsOneWidget);
    expect(find.byKey(const ValueKey('audio-selected:room0')), findsNothing);
    await model.replaceRoom('room2');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('audio-row:room2new')), findsOneWidget);
    expect(find.byKey(const ValueKey('audio-row:room2')), findsNothing);
    final staleVolume = tester.widget<Slider>(_slider('room0')).onChanged!;
    final staleMute = tester.widget<IconButton>(_mute('room0')).onPressed!;
    await model.closeRoom('room0');
    staleVolume(7);
    staleMute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('audio-row:room0')), findsNothing);
    expect(model.invalidAudioCalls, isEmpty);
    expect(model.audioCalls, isEmpty);
    expect(model.created.values, everyElement(1));
    expect(model.destroyed, {'room2': 1, 'room0': 1});
    for (final id in [...model.ids]) {
      await model.closeRoom(id);
    }
    await tester.pumpAndSettle();
    expect(find.text('暂无直播间，添加后可独立调节音量'), findsOneWidget);
    expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('audio-all-muted')))
            .onPressed,
        isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow desktop audio panel scrolls every row without overflow',
      (tester) async {
    final model = _TrackedModel(4);
    await _mount(tester, model, size: const Size(320, 240));
    await _openAudio(tester);
    final panel = find.byKey(const ValueKey('multi-live-audio-panel'));
    final scrollable =
        find.descendant(of: panel, matching: find.byType(Scrollable));
    for (final id in model.ids) {
      await tester.scrollUntilVisible(_mute(id), 64, scrollable: scrollable);
      await tester.tap(_mute(id));
      await tester.pumpAndSettle();
      expect(model.muted[id], isTrue);
      expect(tester.takeException(), isNull);
    }
    expect(model.created.values, everyElement(1));
    expect(model.destroyed, isEmpty);
    final smallHeight = tester.getSize(panel).height;
    tester.view.physicalSize = const Size(1200, 800);
    await tester.pumpAndSettle();
    expect(tester.getSize(panel).height, greaterThan(smallHeight));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('关闭音量面板'));
    await tester.pumpAndSettle();
    expect(find.byType(Probe), findsNWidgets(4));
  });

  testWidgets(
      'phone preserves 40px toolbar targets and two room audio on rotate',
      (tester) async {
    final model = _TrackedModel(2, maxRooms: 2);
    await _mount(tester, model,
        size: const Size(320, 568),
        platform: TargetPlatform.android,
        nestedRoute: true);
    expect(tester.getSize(find.byType(AppBar)).height, 44);
    for (final key in ['audio-panel', 'layout-presets', 'add-room']) {
      expect(tester.getSize(find.byKey(ValueKey(key))).height, 40);
      expect(find.byKey(ValueKey(key)).hitTestable(), findsOneWidget);
    }
    expect(find.byType(BackButton).hitTestable(), findsOneWidget);
    await _openAudio(tester);
    expect(find.byType(BottomSheet), findsOneWidget);
    tester.widget<Slider>(_slider('room1')).onChanged!(0);
    await tester.pumpAndSettle();
    expect(model.rooms[1].volume, 0);
    await tester.tap(_mute('room1'));
    await tester.pumpAndSettle();
    expect(model.rooms[1].muted, isTrue);
    tester.view.physicalSize = const Size(568, 320);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(model.created, {'room0': 1, 'room1': 1});
    expect(model.destroyed, isEmpty);
    await tester.tap(find.byTooltip('关闭音量面板'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('add-room')));
    await tester.pumpAndSettle();
    expect(model.adds, 0);
    expect(find.textContaining('最多同时观看 2 个房间'), findsOneWidget);
  });

  testWidgets(
      'small room has direct audio entry and stale sheet callbacks are safe',
      (tester) async {
    final model = _TrackedModel(4);
    await _mount(tester, model, size: const Size(320, 240));
    expect(find.byKey(const ValueKey('volume:room0')), findsNothing);
    await tester.tap(find.byTooltip('音量与静音 房间 0'));
    await tester.pumpAndSettle();
    final sheetSlider = find.byKey(const ValueKey('room-audio-volume:room0'));
    final staleVolume = tester.widget<Slider>(sheetSlider).onChanged!;
    final staleMute =
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged!;
    staleVolume(31);
    await tester.pumpAndSettle();
    expect(model.volume, {'room0': 31});
    await model.closeRoom('room0');
    staleVolume(4);
    staleMute(true);
    await tester.pumpAndSettle();
    expect(find.text('房间已关闭'), findsOneWidget);
    expect(model.invalidAudioCalls, isEmpty);
    expect(model.audioCalls, ['volume:room0']);
    expect(tester.takeException(), isNull);
  });
}
