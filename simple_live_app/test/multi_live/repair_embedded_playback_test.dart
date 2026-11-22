import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/modules/multi_live/integration/multi_live_media.dart';

import 'session_lifecycle_test.dart' show LifecycleRoom;

class _Settings extends AppSettingsController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

class _Backend extends PlatformPlayer {
  _Backend() : super(configuration: const PlayerConfiguration());

  int pauses = 0;
  int plays = 0;
  Completer<void>? pauseBarrier;

  @override
  Future<void> pause() async {
    pauses++;
    await pauseBarrier?.future;
    state = state.copyWith(playing: false);
  }

  @override
  Future<void> play() async {
    plays++;
    state = state.copyWith(playing: true);
  }
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

class _Room extends LifecycleRoom {
  final backend = _Backend();
  late final _player = Player(platformPlayer: backend);
  late final _video = _VideoController(_player);

  @override
  Player get player => _player;
  @override
  VideoController get videoController => _video;
}

void _lifecycle(WidgetTester tester, AppLifecycleState state) =>
    tester.binding.handleAppLifecycleStateChanged(state);

void _background(WidgetTester tester) {
  _lifecycle(tester, AppLifecycleState.inactive);
  _lifecycle(tester, AppLifecycleState.hidden);
  _lifecycle(tester, AppLifecycleState.paused);
}

Future<void> _mount(
    WidgetTester tester, _Settings settings, List<_Room> rooms) async {
  Get.put<AppSettingsController>(settings);
  _lifecycle(tester, AppLifecycleState.resumed);
  addTearDown(() async {
    _lifecycle(tester, AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox.shrink());
    for (final room in rooms) {
      await room.player.dispose();
      room.videoController.notifier.dispose();
    }
    Get.reset();
  });
  await tester.pumpWidget(MaterialApp(
      home: Row(children: [
    for (final room in rooms) Expanded(child: MultiLiveMedia(room: room)),
  ])));
}

List<bool> _states(List<_Room> rooms) =>
    rooms.map((room) => room.player.state.playing).toList();

void main() {
  for (final preference in [false, true]) {
    testWidgets(
        'auto pause $preference with two playing rooms and one manually paused',
        (tester) async {
      final settings = _Settings()..playerAutoPause.value = preference;
      final rooms = List.generate(3, (_) => _Room());
      await _mount(tester, settings, rooms);
      for (final room in rooms) {
        await room.player.play();
      }
      await rooms.last.player.pause();
      _lifecycle(tester, AppLifecycleState.inactive);
      await tester.pump();
      expect(_states(rooms), [true, true, false]);
      _background(tester);
      await tester.pump();
      expect(_states(rooms), [!preference, !preference, false]);
      _lifecycle(tester, AppLifecycleState.hidden);
      _lifecycle(tester, AppLifecycleState.inactive);
      await tester.pump();
      expect(_states(rooms), [!preference, !preference, false]);
      _lifecycle(tester, AppLifecycleState.resumed);
      await tester.pump();
      expect(_states(rooms), [true, true, false]);
      expect(rooms.last.backend.plays, 1);
      expect(rooms.first.backend.pauses, preference ? 1 : 0);
      expect(rooms[1].backend.pauses, preference ? 1 : 0);
    });
  }

  testWidgets('changing preference on a live view preserves both video states',
      (tester) async {
    final settings = _Settings();
    final rooms = List.generate(2, (_) => _Room());
    await _mount(tester, settings, rooms);
    final videos = find.byType(Video);
    final originalStates = tester.stateList<VideoState>(videos).toList();
    for (final room in rooms) {
      await room.player.play();
    }
    _background(tester);
    await tester.pump();
    expect(_states(rooms), [true, true]);
    settings.playerAutoPause.value = true;
    await tester.pump();
    expect(_states(rooms), [false, false]);
    settings.playerAutoPause.value = false;
    await tester.pump();
    expect(_states(rooms), [true, true]);
    _lifecycle(tester, AppLifecycleState.resumed);
    await tester.pump();
    expect(tester.stateList<VideoState>(videos), orderedEquals(originalStates));
    expect(rooms.every((room) => room.backend.plays == 2), isTrue);
  });

  testWidgets(
      'a foreground event waits for the pending native pause before restoring',
      (tester) async {
    final settings = _Settings()..playerAutoPause.value = true;
    final room = _Room();
    await _mount(tester, settings, [room]);
    await room.player.play();
    final barrier = room.backend.pauseBarrier = Completer<void>();
    _background(tester);
    expect(room.backend.pauses, 1);
    _lifecycle(tester, AppLifecycleState.resumed);
    await tester.pump();
    expect(room.backend.plays, 1);
    barrier.complete();
    await tester.pump();
    expect(room.player.state.playing, isTrue);
    expect(room.backend.plays, 2);
  });
}
