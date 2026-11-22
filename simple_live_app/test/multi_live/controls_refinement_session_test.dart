import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/multi_live/multi_live_controller.dart';
import 'package:simple_live_app/modules/multi_live/multi_live_device_policy.dart';
import 'package:simple_live_app/modules/multi_live/multi_live_page.dart';
import 'package:simple_live_app/modules/multi_live/session/multi_live_room_session.dart';
import 'package:simple_live_app/modules/multi_live/storage/multi_live_workspace_store.dart';
import 'package:simple_live_app/modules/multi_live/widgets/multi_live_view_model.dart';
import 'page_interaction_test.dart' show Probe;

class _NativeBoundary implements MultiLiveRoomDriver {
  int initialized = 0;
  int closed = 0;
  final volumes = <double>[];
  @override
  LiveRoomController? get room => null;
  @override
  Future<void> initialize() async => initialized++;
  @override
  Future<void> close() async => closed++;
  @override
  Future<void> setVolume(double volume) async => volumes.add(volume);
  @override
  Future<void> setDanmakuVisible(bool visible) async {}
  @override
  Future<void> setSenderActive(bool active) async {}
  @override
  Future<String?> sendDanmaku(String text) async => null;
}

void main() {
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    testWidgets(
        '${platform.name} audio panel preserves native sessions and saved levels',
        (tester) async {
      final count = MultiLiveDevicePolicy(platform).maxRooms;
      final boundaries = <String, _NativeBoundary>{};
      final created = <String, int>{};
      final destroyed = <String, int>{};
      final writes = <String>[];
      final notices = <String>[];
      final model = MultiLiveController(
          policy: MultiLiveDevicePolicy(platform),
          sites: const {'douyu': '斗鱼'},
          store: MultiLiveWorkspaceStore(
              read: () async => null,
              write: (value) async => writes.add(value)),
          pickRoom: () async => null,
          roomBuilder: (_, session) =>
              Probe(id: session.id, created: created, destroyed: destroyed),
          chatBuilder: (_, session, __) => Text('chat:${session.id}'),
          notice: notices.add,
          sessionFactory: ({required id, required spec}) {
            final driver = boundaries[spec.roomId] = _NativeBoundary();
            return MultiLiveRoomSession(
                id: id, spec: spec, driverFactory: (_) => driver);
          });
      for (var i = 0; i < count; i++) {
        await model.addSpec(MultiLiveRoomSpec(
            siteId: 'douyu', roomId: 'native$i', title: '主播 $i'));
      }
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = platform == TargetPlatform.windows
          ? const Size(1200, 800)
          : const Size(400, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData(useMaterial3: true, platform: platform),
          home: MultiLivePage(model: model)));
      await tester.pumpAndSettle();
      expect(boundaries.length, count);
      expect(boundaries.values.map((driver) => driver.initialized),
          everyElement(1));
      final ids = model.rooms.map((room) => room.id).toList();
      final first = ids.first;
      await tester.tap(find.byKey(const ValueKey('audio-panel')));
      await tester.pumpAndSettle();
      final slider = find.byKey(ValueKey('audio-volume:$first'));
      final mute = find.byKey(ValueKey('audio-mute:$first'));
      tester.widget<Slider>(slider).onChanged!(37);
      await tester.pumpAndSettle();
      expect(boundaries['native0']!.volumes.last, 37);
      for (final driver in boundaries.values.skip(1)) {
        expect(driver.volumes, [100]);
      }
      await tester.tap(mute);
      await tester.pumpAndSettle();
      expect(boundaries['native0']!.volumes.last, 0);
      expect(model.rooms.first.volume, 37);
      tester.widget<Slider>(slider).onChanged!(61);
      await tester.pumpAndSettle();
      expect(model.rooms.first.volume, 61);
      expect(model.rooms.first.muted, isTrue);
      expect(boundaries['native0']!.volumes.last, 0);
      await tester.tap(mute);
      await tester.pumpAndSettle();
      expect(boundaries['native0']!.volumes.last, 61);
      expect(model.rooms.every((room) => !room.muted), isTrue);
      await tester.tap(find.byKey(const ValueKey('audio-all-muted')));
      await tester.pumpAndSettle();
      expect(boundaries.values.map((driver) => driver.volumes.last),
          everyElement(0));
      await tester.tap(find.byKey(const ValueKey('audio-all-muted')));
      await tester.pumpAndSettle();
      expect(boundaries['native0']!.volumes.last, 61);
      expect(boundaries.values.skip(1).map((driver) => driver.volumes.last),
          everyElement(100));
      model.selectRoom(ids.last);
      model.setPreset(count == 4
          ? MultiLiveLayoutPreset.grid
          : MultiLiveLayoutPreset.stacked);
      model.maximizeRoom(first);
      await tester.pumpAndSettle();
      expect(model.selectedRoomId, ids.last);
      expect(model.maximizedRoomId, first);
      expect(
          find.byKey(ValueKey('audio-selected:${ids.last}')), findsOneWidget);
      expect(find.byType(Probe, skipOffstage: false), findsNWidgets(count));
      expect(created.length, count);
      expect(created.values, everyElement(1));
      expect(destroyed, isEmpty);
      expect(boundaries.values.map((driver) => driver.initialized),
          everyElement(1));
      expect(boundaries.values.map((driver) => driver.closed), everyElement(0));
      await tester.tap(mute);
      await tester.pumpAndSettle();
      expect(model.rooms.first.muted, isTrue);
      await tester.pumpWidget(const SizedBox());
      await model.close();
      model.dispose();
      expect(boundaries.values.map((driver) => driver.closed), everyElement(1));
      expect(notices, isEmpty);
      final saved = MultiLiveWorkspaceStore.decode(writes.last,
              supportedSites: {'douyu'}, maxRooms: count)
          .snapshot!;
      expect(saved.rooms.length, count);
      expect(saved.rooms.first.spec.volume, 61);
      expect(saved.rooms.first.spec.muted, isTrue);
      expect(saved.rooms.skip(1).map((room) => room.spec.volume),
          everyElement(100));
      expect(saved.rooms.skip(1).map((room) => room.spec.muted),
          everyElement(false));
      expect(saved.selectedRoomId, ids.last);
      expect(tester.takeException(), isNull);
    });
  }
}
