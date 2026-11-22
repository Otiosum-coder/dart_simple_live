import 'dart:async';
import 'package:simple_live_app/app/sites.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/live_room/player/player_controller.dart';
import 'package:simple_live_app/modules/live_room/player/player_wakelock_coordinator.dart';
import 'package:simple_live_app/modules/multi_live/session/multi_live_room_session.dart';

class FakeRoomDriver implements MultiLiveRoomDriver {
  @override
  LiveRoomController? get room => null;
  final volumes = <double>[];
  final leases = <bool>[];
  Completer<void>? initialization;
  Completer<void>? closing;
  bool fail = false;
  int starts = 0;
  int closes = 0;
  @override
  Future<void> initialize() async {
    starts++;
    await initialization?.future;
    if (fail) throw StateError('fixture failure');
  }

  @override
  Future<void> setVolume(double value) async {
    volumes.add(value);
  }

  @override
  Future<void> setDanmakuVisible(bool visible) async {}
  @override
  Future<void> setSenderActive(bool active) async {
    leases.add(active);
  }

  @override
  Future<String?> sendDanmaku(String text) async => null;
  @override
  Future<void> close() async {
    closes++;
    await closing?.future;
  }
}

class LifecycleRoom extends LiveRoomController {
  LifecycleRoom()
      : super(
            pSite: Sites.allSites['douyu']!,
            pRoomId: 'fixture',
            embedded: true);
  int starts = 0;
  final nativeClosed = Completer<void>();
  // This fixture suppresses native media creation but exercises GetX onStart/onDelete.
  @override
  // ignore: must_call_super
  void onInit() {
    starts++;
  }

  @override
  Future<void> closePlayer() => nativeClosed.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const spec = MultiLiveRoomSpec(siteId: 'douyu', roomId: '1');
  MultiLiveRoomSession session(FakeRoomDriver driver, {String id = 'one'}) =>
      MultiLiveRoomSession(id: id, spec: spec, driverFactory: (_) => driver);
  test('spec round trips only safe settings and clamps volume', () {
    final parsed = MultiLiveRoomSpec.tryFromJson(
        {...spec.toJson(), 'volume': 180, 'cookie': 'never saved'});
    expect(parsed!.volume, 100);
    expect(parsed.toJson().containsKey('cookie'), false);
    expect(parsed.roomKey, 'douyu:1');
    expect(
        MultiLiveRoomSpec.tryFromJson({'siteId': '', 'roomId': '1'}), isNull);
  });
  test('four sessions keep identity and all may remain audible', () async {
    final drivers = List.generate(4, (_) => FakeRoomDriver());
    final sessions = List.generate(4, (i) => session(drivers[i], id: '$i'));
    await Future.wait(sessions.map((s) => s.initialize()));
    expect(sessions.map((s) => s.id).toSet().length, 4);
    for (final driver in drivers) {
      expect(driver.starts, 1);
      expect(driver.volumes.last, 100);
    }
    await sessions[0].setVolume(28);
    expect(drivers[0].volumes.last, 28);
    for (final driver in drivers.skip(1)) {
      expect(driver.volumes.last, 100);
    }
    await Future.wait(sessions.map((s) => s.close()));
  });
  test('mute retains requested volume and only changes this player', () async {
    final driver = FakeRoomDriver();
    final s = session(driver);
    await s.setVolume(37);
    await s.setMuted(true);
    expect(driver.volumes.last, 0);
    expect(s.spec.volume, 37);
    await s.setVolume(200);
    expect(driver.volumes.last, 0);
    expect(s.spec.volume, 100);
    await s.setMuted(false);
    expect(driver.volumes.last, 100);
    await s.setVolume(-5);
    expect(driver.volumes.last, 0);
    await s.close();
  });
  test('close waits pending initialization and native cleanup, never revives',
      () async {
    final driver = FakeRoomDriver()
      ..initialization = Completer<void>()
      ..closing = Completer<void>();
    final s = session(driver);
    final initializing = s.initialize();
    await Future<void>.delayed(Duration.zero);
    var closed = false;
    final first = s.close();
    final second = s.close();
    expect(identical(first, second), true);
    unawaited(first.then((_) => closed = true));
    driver.initialization!.complete();
    await initializing;
    await Future<void>.delayed(Duration.zero);
    expect(s.closed, true);
    expect(s.initialized, false);
    expect(closed, false);
    expect(driver.volumes, isEmpty);
    driver.closing!.complete();
    await first;
    expect(driver.closes, 1);
    await s.initialize();
    await s.setVolume(55);
    expect(driver.starts, 1);
    expect(driver.volumes, isEmpty);
  });
  test('initialization failure releases driver and cannot be reopened',
      () async {
    final driver = FakeRoomDriver()..fail = true;
    final s = session(driver);
    await expectLater(s.initialize(), throwsStateError);
    expect(s.closed, true);
    expect(s.initialized, false);
    expect(driver.closes, 1);
    await s.close();
    expect(driver.closes, 1);
  });
  test('sender starts inactive and send follows explicit room selection',
      () async {
    final driver = FakeRoomDriver();
    final s = session(driver);
    await s.initialize();
    expect(driver.leases.every((v) => !v), true);
    expect(await s.sendDanmaku('hello'), isNotNull);
    await s.setSenderActive(true);
    expect(await s.sendDanmaku('hello'), isNull);
    await s.setSenderActive(false);
    expect(await s.sendDanmaku('hello'), isNotNull);
    await s.close();
  });
  test(
      'explicit room lifecycle preserves GetX closed flag and awaits native close',
      () async {
    final room = LifecycleRoom();
    room.onStart();
    room.onStart();
    expect(room.starts, 1);
    expect(room.isClosed, false);
    final closing = room.closeRoom();
    expect(room.isClosed, true);
    expect(identical(closing, room.closeRoom()), true);
    var complete = false;
    unawaited(closing.then((_) => complete = true));
    await Future<void>.delayed(Duration.zero);
    expect(complete, false);
    room.nativeClosed.complete();
    await closing;
    expect(complete, true);
  });
  test('single room player keeps default non-embedded behavior', () {
    expect(PlayerController().embedded, false);
    expect(PlayerController(embedded: true).embedded, true);
  });
  test('wakelock remains enabled until final active player releases it',
      () async {
    final toggles = <bool>[];
    final coordinator = PlayerWakelockCoordinator(toggle: (value) async {
      toggles.add(value);
    });
    final a = Object();
    final b = Object();
    await coordinator.setActive(a, true);
    await coordinator.setActive(b, true);
    await coordinator.setActive(a, false);
    expect(toggles, [true]);
    await coordinator.setActive(b, false);
    expect(toggles, [true, false]);
  });
}
