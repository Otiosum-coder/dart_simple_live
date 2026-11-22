import 'dart:async';

import 'package:canvas_danmaku/danmaku_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/multi_live/session/multi_live_room_session.dart';
import 'package:simple_live_core/simple_live_core.dart';

import 'session_lifecycle_test.dart' show FakeRoomDriver;

class _Settings extends AppSettingsController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

class _SlowDriver extends FakeRoomDriver {
  Completer<void>? volumeGate;
  Completer<void>? visibilityGate;
  bool failVolume = false;
  Object? visibilityError;
  int inFlight = 0;
  int maximumInFlight = 0;
  final visibility = <bool>[];

  @override
  Future<void> setVolume(double value) async {
    volumes.add(value);
    inFlight++;
    if (inFlight > maximumInFlight) maximumInFlight = inFlight;
    try {
      await volumeGate?.future;
      if (failVolume) throw StateError('fixture volume failure');
    } finally {
      inFlight--;
    }
  }

  @override
  Future<void> setDanmakuVisible(bool visible) async {
    visibility.add(visible);
    inFlight++;
    if (inFlight > maximumInFlight) maximumInFlight = inFlight;
    try {
      await visibilityGate?.future;
      if (visibilityError != null) throw visibilityError!;
    } finally {
      inFlight--;
    }
  }
}

class _Backend extends PlatformPlayer {
  _Backend() : super(configuration: const PlayerConfiguration());
  final opened = <String>[];
  Completer<void>? openGate;
  int inFlight = 0;
  int maximumInFlight = 0;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opened.add((playable as Playlist).medias.single.uri);
    inFlight++;
    if (inFlight > maximumInFlight) maximumInFlight = inFlight;
    try {
      await openGate?.future;
    } finally {
      inFlight--;
    }
  }
}

class _Room extends LiveRoomController {
  _Room({bool embedded = true})
      : super(
            pSite: Sites.allSites['douyu']!,
            pRoomId: 'fixture',
            embedded: embedded) {
    currentLineIndex = 0;
  }
  final backend = _Backend();
  late final _player = Player(platformPlayer: backend);
  Completer<void>? initialization;
  int audioApplications = 0;
  int scrolls = 0;

  @override
  Player get player => _player;
  @override
  // ignore: must_call_super
  void onInit() {}
  @override
  Future<void> initializePlayer() async => initialization?.future;
  @override
  Future<void> applyNetworkBuffering() async {}
  @override
  Future<void> applyAudioOnly() async => audioApplications++;
  @override
  void chatScrollToBottom() => scrolls++;
}

// Chat scheduling has no player; native disposal barriers are covered above.
class _ChatRoom extends LiveRoomController {
  _ChatRoom({required bool embedded})
      : super(
            pSite: Sites.allSites['douyu']!,
            pRoomId: 'fixture',
            embedded: embedded);
  int scrolls = 0;
  @override
  // ignore: must_call_super
  void onInit() {}
  @override
  void chatScrollToBottom() => scrolls++;
  @override
  Future<void> closePlayer() async => disposeDanmakuController();
}

Future<Object?> _outcome(Future<void> operation) => operation
    .then<Object?>((_) => null, onError: (Object error, StackTrace _) => error);

Future<void> _flush() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.value();
  }
}

LiveMessage _chat(int i) => LiveMessage(
    type: LiveMessageType.chat,
    userName: 'fixture',
    message: 'message $i',
    color: LiveMessageColor.white);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
            'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
            (_) async => const StandardMessageCodec().encodeMessage([null]));
    Get.testMode = true;
    Get.put<AppSettingsController>(_Settings());
  });
  tearDown(Get.reset);

  test(
      'four slow players coalesce 40000 settings events with independent audio',
      () async {
    final drivers = List.generate(4, (_) => _SlowDriver());
    final sessions = List.generate(
        4,
        (i) => MultiLiveRoomSession(
            id: '$i',
            spec: MultiLiveRoomSpec(siteId: 'douyu', roomId: '$i'),
            driverFactory: (_) => drivers[i]));
    await Future.wait(sessions.map((s) => s.initialize()));
    final pending = <Future<void>>[];
    for (var room = 0; room < 4; room++) {
      final driver = drivers[room]..volumeGate = Completer<void>();
      driver.volumes.clear();
      driver.visibility.clear();
      final session = sessions[room];
      final first = session.setVolume(1);
      pending.add(first);
      await _flush();
      final latestVolume = session.setVolume(2);
      final latestVisibility = session.setDanmakuVisible(false);
      expect(identical(first, latestVolume), isFalse);
      expect(identical(latestVolume, latestVisibility), isFalse);
      pending.addAll([latestVolume, latestVisibility]);
      for (var i = 0; i < 10000; i++) {
        expect(identical(latestVolume, session.setVolume(i % 101.0)), isTrue);
        expect(identical(latestVisibility, session.setDanmakuVisible(i.isEven)),
            isTrue);
      }
      expect(identical(latestVolume, session.setVolume(21.0 + room)), isTrue);
      expect(identical(latestVolume, session.setMuted(false)), isTrue);
      expect(
          identical(latestVisibility, session.setDanmakuVisible(true)), isTrue);
      expect(driver.volumes, [1]);
      expect(driver.maximumInFlight, 1);
    }
    for (final driver in drivers) {
      driver.volumeGate!.complete();
    }
    await Future.wait(pending);
    for (var i = 0; i < 4; i++) {
      expect(drivers[i].volumes, [1, 21.0 + i]);
      expect(drivers[i].visibility, [true]);
      expect(drivers[i].maximumInFlight, 1);
    }
    await Future.wait(sessions.map((s) => s.close()));
    expect(drivers.map((d) => d.closes), everyElement(1));
  });

  test(
      'failed settings drain recovers and close waits for its final native call',
      () async {
    final driver = _SlowDriver();
    final session = MultiLiveRoomSession(
        id: 'one',
        spec: const MultiLiveRoomSpec(siteId: 'douyu', roomId: '1'),
        driverFactory: (_) => driver);
    await session.initialize();
    driver.failVolume = true;
    await expectLater(session.setVolume(3), throwsStateError);
    driver.failVolume = false;
    await session.setVolume(7);
    expect(driver.volumes.last, 7);
    driver.volumeGate = Completer<void>();
    final update = session.setVolume(9);
    await _flush();
    for (var i = 0; i < 5000; i++) {
      session.setVolume(i % 100.0);
    }
    var closed = false;
    final closing = session.close().then((_) => closed = true);
    await _flush();
    expect(closed, isFalse);
    expect(driver.closes, 0);
    driver.volumeGate!.complete();
    await Future.wait([update, closing]);
    expect(driver.volumes.last, 9);
    expect(driver.closes, 1);
    await session.close();
    expect(driver.closes, 1);
  });

  for (final duringVisibility in [false, true]) {
    final timing = duringVisibility ? 'in flight' : 'in the same batch';
    test('visibility failure preserves volume requested $timing', () async {
      final driver = _SlowDriver();
      final session = MultiLiveRoomSession(
          id: 'visibility-failure',
          spec: const MultiLiveRoomSpec(siteId: 'huya', roomId: '1'),
          driverFactory: (_) => driver);
      await session.initialize();
      final failure = StateError('fixture visibility failure');
      driver.visibilityGate = Completer<void>();
      driver.visibilityError = failure;
      final hide = _outcome(session.setDanmakuVisible(false));
      if (duringVisibility) await _flush();
      final volume = _outcome(session.setVolume(24));
      await _flush();
      expect(driver.inFlight, 1);
      driver.visibilityGate!.complete();
      expect(await hide, same(failure));
      expect(await volume, isNull);
      expect(driver.volumes, [100, 24]);
      expect(driver.visibility, [true, false]);
      expect(driver.maximumInFlight, 1);
      await _flush();
      expect(driver.visibility, [true, false], reason: 'No automatic retry');
      driver.visibilityError = null;
      await session.setDanmakuVisible(true);
      expect(driver.visibility, [true, false, true]);
      await session.close();
    });
  }

  test('close settles queued settings and retains the active call error',
      () async {
    final driver = _SlowDriver();
    final session = MultiLiveRoomSession(
        id: 'closing-failure',
        spec: const MultiLiveRoomSpec(siteId: 'huya', roomId: '2'),
        driverFactory: (_) => driver);
    await session.initialize();
    driver.volumeGate = Completer<void>();
    driver.failVolume = true;
    final active = _outcome(session.setVolume(24));
    await _flush();
    final queuedVolume = _outcome(session.setVolume(16));
    final queuedVisibility = _outcome(session.setDanmakuVisible(false));
    final closing = session.close();
    expect(identical(closing, session.close()), isTrue);
    expect(await queuedVolume, isNull);
    expect(await queuedVisibility, isNull);
    await session.setVolume(9);
    await session.setMuted(true);
    await session.setDanmakuVisible(true);
    expect(driver.volumes, [100, 24]);
    expect(driver.visibility, [true]);
    expect(driver.closes, 0);
    driver.volumeGate!.complete();
    expect(await active, isStateError);
    await closing;
    expect(driver.volumes, [100, 24]);
    expect(driver.visibility, [true]);
    expect(driver.closes, 1);
  });

  test('newer volume target does not inherit the active target error',
      () async {
    final driver = _SlowDriver();
    final session = MultiLiveRoomSession(
        id: 'later-target',
        spec: const MultiLiveRoomSpec(siteId: 'huya', roomId: '4'),
        driverFactory: (_) => driver);
    await session.initialize();
    final gate = Completer<void>();
    driver.volumeGate = gate;
    final active = _outcome(session.setVolume(24));
    await _flush();
    final latest = _outcome(session.setVolume(16));
    final hide = _outcome(session.setDanmakuVisible(false));
    final failure = StateError('active target failed');
    gate.completeError(failure);
    driver.volumeGate = null;
    expect(await active, same(failure));
    expect(await latest, isNull);
    expect(await hide, isNull);
    expect(driver.volumes, [100, 24, 16]);
    expect(driver.visibility, [true, false]);
    expect(driver.maximumInFlight, 1);
    await _flush();
    expect(driver.volumes, [100, 24, 16], reason: 'No implicit retry');
    await session.close();
  });

  test('initialization failure settles both pending settings without retry',
      () async {
    final driver = _SlowDriver()..failVolume = true;
    final session = MultiLiveRoomSession(
        id: 'initialization-failure',
        spec: const MultiLiveRoomSpec(siteId: 'huya', roomId: '3'),
        driverFactory: (_) => driver);
    final volume = _outcome(session.setVolume(24));
    final visibility = _outcome(session.setDanmakuVisible(false));
    expect(await volume, isStateError);
    expect(await visibility, isStateError);
    expect(session.closed, isTrue);
    expect(driver.volumes, [24]);
    expect(driver.visibility, isEmpty);
    expect(driver.closes, 1);
    await session.close();
    expect(driver.closes, 1);
  });

  test('four slow native opens drain only the latest replacement per room',
      () async {
    final rooms = List.generate(4, (_) => _Room());
    final pending = <Future<void>>[];
    for (var r = 0; r < 4; r++) {
      final room = rooms[r];
      room.backend.openGate = Completer<void>();
      room.playUrls.assignAll(['https://fixture.invalid/$r/first']);
      final first = room.initPlaylist();
      pending.add(first);
      await _flush();
      for (var i = 0; i < 1000; i++) {
        room.playUrls.assignAll(['https://fixture.invalid/$r/$i']);
        expect(identical(first, room.initPlaylist()), isTrue);
      }
      expect(room.backend.opened.length, 1);
    }
    for (final room in rooms) {
      room.backend.openGate!.complete();
    }
    await Future.wait(pending);
    for (var r = 0; r < 4; r++) {
      final room = rooms[r];
      expect(room.backend.opened, [
        'https://fixture.invalid/$r/first',
        'https://fixture.invalid/$r/999'
      ]);
      expect(room.backend.maximumInFlight, 1);
      expect(room.audioApplications, 1);
      await room.closeRoom();
      await room.player.dispose();
    }
  });

  test('late player initialization cannot open the obsolete playlist',
      () async {
    final room = _Room()..initialization = Completer<void>();
    room.playUrls.assignAll(['https://fixture.invalid/obsolete']);
    final first = room.initPlaylist();
    await _flush();
    room.playUrls.assignAll(['https://fixture.invalid/latest']);
    room.initPlaylist();
    room.initialization!.complete();
    await first;
    expect(room.backend.opened, ['https://fixture.invalid/latest']);
    await room.closeRoom();
    await room.player.dispose();
  });

  test('timeout and close keep disposal behind the unfinished native open',
      () async {
    final room = _Room();
    room.backend.openGate = Completer<void>();
    room.playUrls.assignAll(['https://fixture.invalid/blocked']);
    final first = room.initPlaylist();
    await _flush();
    room.playUrls.assignAll(['https://fixture.invalid/replacement']);
    room.initPlaylist();
    // Exercise the actual production timeout; no native process or network runs.
    await Future<void>.delayed(const Duration(seconds: 13));
    expect(room.backend.opened.length, 1);
    var closed = false;
    final closing = room.closeRoom().then((_) => closed = true);
    await _flush();
    expect(closed, isFalse);
    room.backend.openGate!.complete();
    await Future.wait([first, closing]);
    expect(room.backend.opened.length, 1);
    expect(room.audioApplications, 0);
    await room.player.dispose();
  });

  testWidgets(
      'four chat bursts stay bounded and standalone scrolling coalesces per frame',
      (tester) async {
    final rooms = List.generate(4, (i) => _ChatRoom(embedded: i != 0));
    final displayed = List.filled(4, 0);
    final cleared = List.filled(4, 0);
    for (var i = 0; i < rooms.length; i++) {
      rooms[i].liveStatus.value = true;
      rooms[i].showDanmakuState.value = true;
      rooms[i].danmakuController = DanmakuController(
          onAddDanmaku: (_) => displayed[i]++,
          onUpdateOption: (_) {},
          onPause: () {},
          onResume: () {},
          onClear: () => cleared[i]++);
    }
    await tester.pumpWidget(MaterialApp(
        home: ListView(
            controller: rooms.first.scrollController,
            children: const [SizedBox(height: 1000)])));
    for (final room in rooms) {
      for (var i = 0; i < 10000; i++) {
        room.onWSMessage(_chat(i));
      }
      expect(room.messages.length, 200);
      expect(room.messages.last.message, 'message 9999');
      expect(room.scrolls, 0);
    }
    expect(displayed, [10000, 10000, 10000, 10000]);
    await tester.pump();
    expect(rooms.map((r) => r.scrolls), [1, 0, 0, 0]);
    rooms.first.onWSMessage(_chat(10001));
    final closing = rooms.map((room) => room.closeRoom()).toList();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => Future.wait(closing));
    expect(cleared.every((count) => count >= 1), isTrue);
    for (final room in rooms) {
      room.onWSMessage(_chat(10002));
      expect(room.messages, isEmpty);
    }
    await tester.pump();
    expect(rooms.first.scrolls, 1);
  });
}
