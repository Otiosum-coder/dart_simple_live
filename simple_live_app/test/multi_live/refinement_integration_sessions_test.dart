import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/multi_live/multi_live_controller.dart';
import 'package:simple_live_app/modules/multi_live/multi_live_device_policy.dart';
import 'package:simple_live_app/modules/multi_live/multi_live_page.dart';
import 'package:simple_live_app/modules/multi_live/session/multi_live_room_session.dart';
import 'package:simple_live_app/modules/multi_live/storage/multi_live_workspace_store.dart';
import 'package:simple_live_app/modules/multi_live/widgets/multi_live_view_model.dart';

import 'page_interaction_test.dart' show Probe;

class _Driver implements MultiLiveRoomDriver {
  int initializations = 0;
  int closes = 0;
  final volumes = <double>[];

  @override
  LiveRoomController? get room => null;
  @override
  Future<void> initialize() async => initializations++;
  @override
  Future<void> close() async => closes++;
  @override
  Future<void> setVolume(double volume) async => volumes.add(volume);
  @override
  Future<void> setDanmakuVisible(bool visible) async {}
  @override
  Future<void> setSenderActive(bool active) async {}
  @override
  Future<String?> sendDanmaku(String text) async => null;
}

const _first = MultiLiveRoomSpec(siteId: 'douyu', roomId: '1001', title: '主播一');
const _second =
    MultiLiveRoomSpec(siteId: 'douyu', roomId: '1002', title: '主播二');
const _replacement =
    MultiLiveRoomSpec(siteId: 'douyu', roomId: '1003', title: '主播三');

Finder _slider(String id) => find.byKey(ValueKey('audio-volume:$id'));
Finder _mute(String id) => find.byKey(ValueKey('audio-mute:$id'));
Finder _row(String id) => find.byKey(ValueKey('audio-row:$id'));

void main() {
  testWidgets('pointer volume, room replacement and close stay isolated',
      (tester) async {
    final drivers = <String, _Driver>{};
    final created = <String, int>{};
    final destroyed = <String, int>{};
    final model = MultiLiveController(
      policy: const MultiLiveDevicePolicy(TargetPlatform.windows),
      sites: const {'douyu': '斗鱼'},
      store:
          MultiLiveWorkspaceStore(read: () async => null, write: (_) async {}),
      pickRoom: () async => null,
      roomBuilder: (_, session) =>
          Probe(id: session.id, created: created, destroyed: destroyed),
      chatBuilder: (_, __, ___) => const SizedBox.shrink(),
      notice: (_) {},
      sessionFactory: ({required id, required spec}) {
        final driver = drivers[spec.roomId] = _Driver();
        return MultiLiveRoomSession(
            id: id, spec: spec, driverFactory: (_) => driver);
      },
    );
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 800);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    try {
      await model.addSpec(_first);
      await model.addSpec(_second);
      final firstId = model.rooms.first.id;
      final secondId = model.rooms.last.id;
      final firstDriver = drivers[_first.roomId]!;
      final secondDriver = drivers[_second.roomId]!;
      await tester.pumpWidget(MaterialApp(
        theme: AppStyle.lightTheme.copyWith(platform: TargetPlatform.windows),
        home: MultiLivePage(model: model),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('audio-panel')));
      await tester.pumpAndSettle();

      final gesture =
          await tester.startGesture(tester.getCenter(_slider(firstId)));
      await gesture.moveBy(const Offset(-36, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      final dragged = model.rooms.first.volume;
      expect(dragged, inExclusiveRange(0, 100));
      expect(firstDriver.volumes.last, dragged);
      expect(secondDriver.volumes, [100]);
      expect(
          tester
              .widget<Text>(find.byKey(ValueKey('audio-percent:$firstId')))
              .data,
          '${dragged.round()}%');

      model.selectRoom(firstId);
      expect(await model.sendDanmaku(firstId, 'lease barrier'), isNull);
      model.setPreset(MultiLiveLayoutPreset.stacked);
      model.maximizeRoom(secondId);
      await tester.pumpAndSettle();
      expect(model.selectedRoomId, firstId);
      expect(model.maximizedRoomId, secondId);
      expect(created, {firstId: 1, secondId: 1});
      expect(destroyed, isEmpty);
      expect(firstDriver.initializations, 1);
      expect(secondDriver.initializations, 1);

      final staleVolume = tester.widget<Slider>(_slider(firstId)).onChanged!;
      final staleMute = tester.widget<IconButton>(_mute(firstId)).onPressed!;
      await model.replaceSpec(firstId, _replacement);
      await tester.pumpAndSettle();
      final replacementId =
          model.rooms.singleWhere((room) => room.id != secondId).id;
      final replacementDriver = drivers[_replacement.roomId]!;
      final oldCallCount = firstDriver.volumes.length;
      staleVolume(7);
      staleMute();
      await tester.pump();
      expect(_row(firstId), findsNothing);
      expect(_row(replacementId), findsOneWidget);
      expect(firstDriver.closes, 1);
      expect(firstDriver.volumes, hasLength(oldCallCount));
      expect(replacementDriver.volumes, [100]);
      expect(secondDriver.volumes, [100]);

      final closedMute =
          tester.widget<IconButton>(_mute(replacementId)).onPressed!;
      final closedVolume =
          tester.widget<Slider>(_slider(replacementId)).onChanged!;
      await model.closeRoom(replacementId);
      closedMute();
      closedVolume(15);
      await tester.pumpAndSettle();
      expect(_row(replacementId), findsNothing);
      expect(_row(secondId), findsOneWidget);
      expect(replacementDriver.closes, 1);
      expect(replacementDriver.volumes, [100]);
      expect(secondDriver.closes, 0);
      expect(secondDriver.volumes, [100]);
      expect(created[secondId], 1);
      expect(destroyed[secondId], isNull);
      expect(tester.takeException(), isNull);
    } finally {
      // Flush the debounced workspace write inside the widget test's fake clock.
      await tester.pumpWidget(const SizedBox.shrink());
      await model.close();
      model.dispose();
    }
    expect(drivers.values.map((driver) => driver.closes), everyElement(1));
  });
}
