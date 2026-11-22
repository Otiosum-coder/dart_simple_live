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
  void onInit() {
    // Keep the real preference API but do not open the user's settings store.
    playerAutoPause.value = false;
  }
}

class _TestPlatformPlayer extends PlatformPlayer {
  _TestPlatformPlayer() : super(configuration: const PlayerConfiguration());

  Completer<void>? pauseBarrier;
  int plays = 0;
  int pauses = 0;

  @override
  Future<void> pause() async {
    pauses++;
    await pauseBarrier?.future;
    state = state.copyWith(playing: false);
    playingController.add(false);
  }

  @override
  Future<void> play() async {
    plays++;
    state = state.copyWith(playing: true);
    playingController.add(true);
  }
}

class _TestVideoController implements VideoController {
  _TestVideoController(this.player);

  @override
  final Player player;
  @override
  final notifier = ValueNotifier<PlatformVideoController?>(null);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestRoom extends LifecycleRoom {
  final backend = _TestPlatformPlayer();
  late final _player = Player(platformPlayer: backend);
  late final _video = _TestVideoController(_player);

  @override
  Player get player => _player;
  @override
  VideoController get videoController => _video;
}

Future<_TestRoom> _mount(WidgetTester tester, {bool autoPause = false}) async {
  final settings = Get.put<AppSettingsController>(_Settings());
  settings.playerAutoPause.value = autoPause;
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  addTearDown(Get.reset);
  final room = _TestRoom()..onStart();
  await tester.pumpWidget(MaterialApp(home: MultiLiveMedia(room: room)));
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await room.player.dispose();
    room.videoController.notifier.dispose();
  });
  return room;
}

void main() {
  testWidgets('embedded Video leaves wakelock to the shared app owner',
      (tester) async {
    await _mount(tester);
    final video = tester.widget<Video>(find.byType(Video));
    expect(video.wakelock, isFalse);
  });

  testWidgets(
      'embedded Video stays playing across background and foreground '
      'when auto-pause is off', (tester) async {
    final room = await _mount(tester);
    final binding = tester.binding;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    // This fixture reports playing state but has no native media backend.
    await room.player.play();
    try {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      final playingInBackground = room.player.state.playing;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect((playingInBackground, room.player.state.playing), (true, true));
    } finally {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }
  });

  testWidgets('stream starting after background entry pauses and can resume',
      (tester) async {
    final room = await _mount(tester, autoPause: true);
    final binding = tester.binding;
    try {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      expect(room.backend.pauses, 0);
      await room.player.play();
      await tester.pump();
      expect(room.player.state.playing, isFalse);
      expect(room.backend.pauses, 1);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(room.player.state.playing, isTrue);
      expect(room.backend.plays, 2);
    } finally {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }
  });

  testWidgets('closing while background pause is pending does not restart room',
      (tester) async {
    final room = await _mount(tester, autoPause: true);
    final binding = tester.binding;
    final barrier = room.backend.pauseBarrier = Completer<void>();
    try {
      await room.player.play();
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      expect(room.backend.pauses, 1);
      final closing = room.closeRoom();
      expect(room.isClosed, isTrue);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      barrier.complete();
      room.nativeClosed.complete();
      await closing;
      await tester.pump();
      expect(room.backend.plays, 1);
      expect(room.player.state.playing, isFalse);
    } finally {
      if (!barrier.isCompleted) barrier.complete();
      if (!room.nativeClosed.isCompleted) room.nativeClosed.complete();
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }
  });
}
