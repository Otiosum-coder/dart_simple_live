import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/multi_live/multi_live_controller.dart';
import 'package:simple_live_app/modules/multi_live/integration/multi_live_route.dart';
import 'package:simple_live_app/modules/multi_live/multi_live_device_policy.dart';
import 'package:simple_live_app/modules/multi_live/session/multi_live_room_session.dart';
import 'package:simple_live_app/modules/multi_live/storage/multi_live_workspace_store.dart';
import 'package:simple_live_app/modules/multi_live/widgets/multi_live_view_model.dart';

MultiLiveRoomSpec spec(String room) =>
    MultiLiveRoomSpec(siteId: 'douyu', roomId: room);

class _Harness {
  _Harness(TargetPlatform platform,
      {Future<MultiLiveRoomSpec?> Function()? pick,
      this.raw,
      Future<Object?> Function()? read,
      Future<void> Function(String)? write}) {
    model = MultiLiveController(
      policy: MultiLiveDevicePolicy(platform),
      sites: const {'douyu': '斗鱼'},
      store: MultiLiveWorkspaceStore(
          read: read ?? () async => raw,
          write: write ?? (value) async => writes.add(value)),
      pickRoom: pick ?? () async => null,
      roomBuilder: (_, __) => const SizedBox(),
      chatBuilder: (_, __, ___) => const SizedBox(),
      notice: notices.add,
      sessionFactory: ({required id, required spec}) {
        final driver = drivers[spec.roomId] = _Driver(this, spec.roomId);
        events.add('factory:${spec.roomId}');
        return MultiLiveRoomSession(
            id: id, spec: spec, driverFactory: (_) => driver);
      },
    );
  }

  final String? raw;
  late final MultiLiveController model;
  final drivers = <String, _Driver>{};
  final events = <String>[];
  final notices = <String>[];
  final writes = <String>[];
  final active = <String>{};
  final initialize = <String, Completer<void>>{};
  int peakSenders = 0;

  Future<void> dispose() async {
    await model.close();
    model.dispose();
  }
}

class _Driver implements MultiLiveRoomDriver {
  _Driver(this.harness, this.id);
  final _Harness harness;
  final String id;
  final volumes = <double>[];
  final sent = <String>[];
  Completer<void>? closing;
  Completer<void>? releasing;
  Completer<String?>? sending;
  final started = Completer<void>();
  final closeStarted = Completer<void>();
  final releaseStarted = Completer<void>();
  final sendStarted = Completer<void>();

  @override
  LiveRoomController? get room => null;
  @override
  Future<void> initialize() async {
    started.complete();
    await harness.initialize[id]?.future;
  }

  @override
  Future<void> setVolume(double volume) async => volumes.add(volume);
  @override
  Future<void> setDanmakuVisible(bool visible) async {}
  @override
  Future<void> setSenderActive(bool active) async {
    if (active) {
      harness.active.add(id);
      if (harness.active.length > harness.peakSenders) {
        harness.peakSenders = harness.active.length;
      }
    } else {
      if (harness.active.contains(id) && releasing != null) {
        releaseStarted.complete();
        await releasing!.future;
      }
      harness.active.remove(id);
    }
  }

  @override
  Future<String?> sendDanmaku(String text) async {
    sent.add(text);
    if (!sendStarted.isCompleted) sendStarted.complete();
    return sending == null ? null : await sending!.future;
  }

  @override
  Future<void> close() async {
    closeStarted.complete();
    await closing?.future;
    harness.active.remove(id);
    harness.events.add('closed:$id');
  }
}

void main() {
  testWidgets(
      'mobile route preserves excess saved workspace after seed and exit',
      (tester) async {
    final saved = snapshot(['a', 'b', 'c', 'd']).encode();
    final h = _Harness(TargetPlatform.android, raw: saved);
    final nav = await _pushRoute(tester, h, initial: spec('seed'));
    expect(h.drivers.keys, ['seed']);
    expect(h.notices.single, contains('原布局未修改'));
    expect(find.text('多开直播 1/2'), findsOneWidget);
    await nav.maybePop();
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(h.events, ['factory:seed', 'closed:seed']);
    expect(h.writes, isEmpty);
  });

  testWidgets(
      'first back restores split; route exits once after close and flush',
      (tester) async {
    final written = Completer<void>();
    final h = _Harness(TargetPlatform.android,
        raw: snapshot(['a', 'b']).encode(), write: (_) => written.future);
    final observer = _PopObserver();
    final nav = await _pushRoute(tester, h, observer: observer, settle: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('恢复布局'));
    await tester.pumpAndSettle();
    final id = h.model.rooms.first.id;
    h.model.maximizeRoom(id);
    await tester.pump();
    await nav.maybePop();
    await tester.pumpAndSettle();
    expect(h.model.maximizedRoomId, isNull);
    expect(find.text('多开直播 2/2'), findsOneWidget);
    expect(observer.workspacePops, 0);
    await h.model.setVolume(id, 27);
    final driver = h.drivers['a']!;
    driver.closing = Completer<void>();
    await nav.maybePop();
    await tester.pump();
    await nav.maybePop();
    expect(observer.workspacePops, 0);
    driver.closing!.complete();
    await tester.pump();
    expect(observer.workspacePops, 0);
    written.complete();
    await tester.pumpAndSettle();
    expect(observer.workspacePops, 1);
    expect(find.text('Home'), findsOneWidget);
  });

  testWidgets('back during saved layout read cannot open a late stream',
      (tester) async {
    final saved = Completer<Object?>();
    final h = _Harness(TargetPlatform.android, read: () => saved.future);
    final nav =
        await _pushRoute(tester, h, initial: spec('seed'), settle: false);
    await nav.maybePop();
    await tester.pumpAndSettle();
    saved.complete(snapshot(['a', 'b']).encode());
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(h.drivers, isEmpty);
  });

  testWidgets('dismiss restore then back does not open saved streams or write',
      (tester) async {
    final h =
        _Harness(TargetPlatform.android, raw: snapshot(['a', 'b']).encode());
    final nav = await _pushRoute(tester, h, settle: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('恢复多开布局？'), findsOneWidget);
    await nav.maybePop();
    await tester.pumpAndSettle();
    expect(find.text('多开直播 0/2'), findsOneWidget);
    await nav.maybePop();
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(h.drivers, isEmpty);
    expect(h.writes, isEmpty);
  });

  for (final (platform, capacity) in [
    (TargetPlatform.windows, 4),
    (TargetPlatform.macOS, 4),
    (TargetPlatform.linux, 4),
    (TargetPlatform.android, 2),
    (TargetPlatform.iOS, 2),
  ]) {
    test(
        '$platform concurrent adds reserve at most $capacity slots before factory',
        () async {
      final h = _Harness(platform);
      addTearDown(h.dispose);
      await Future.wait(
          [for (var i = 0; i < 6; i++) h.model.addSpec(spec('$i'))]);
      expect(h.model.rooms, hasLength(capacity));
      expect(h.drivers, hasLength(capacity));
      expect(h.notices, hasLength(6 - capacity));
      expect(h.peakSenders, 1);
    });
  }

  test('replacement waits for old close and keeps remaining controllers',
      () async {
    final h = _Harness(TargetPlatform.android);
    addTearDown(h.dispose);
    await h.model.addSpec(spec('a'));
    await h.model.addSpec(spec('b'));
    final a = h.model.rooms.first;
    final b = h.model.rooms.last;
    h.model.swapRooms(a.id, b.id);
    h.model.maximizeRoom(a.id);
    await h.model.setVolume(b.id, 37);
    final driver = h.drivers['a']!;
    driver.closing = Completer<void>();
    final replacement = h.model.replaceSpec(a.id, spec('c'));
    await driver.closeStarted.future;
    expect(h.drivers.containsKey('c'), isFalse);
    driver.closing!.complete();
    await replacement;
    expect(
        h.events.indexOf('closed:a'), lessThan(h.events.indexOf('factory:c')));
    expect(h.model.rooms.first.bodyBuilder, same(b.bodyBuilder));
    expect(h.model.rooms.first.volume, 37);
    expect(h.model.layout!.roomIds, [b.id, h.model.maximizedRoomId]);
    await h.model.addSpec(spec('b'));
    expect(h.model.rooms, hasLength(2));
    expect(h.events.where((event) => event == 'factory:b'), hasLength(1));
  });

  test('close releases late initialization and cancels unresolved picker',
      () async {
    final picking = Completer<void>();
    final h = _Harness(TargetPlatform.android, pick: () {
      picking.complete();
      return Completer<MultiLiveRoomSpec?>().future;
    });
    addTearDown(h.dispose);
    final pending = h.model.addRoom();
    await picking.future;
    final queued = h.model.addSpec(spec('queued'));
    await h.model.close();
    await Future.wait([pending, queued]);
    expect(h.drivers, isEmpty);

    final late = _Harness(TargetPlatform.android);
    addTearDown(late.dispose);
    final start = late.initialize['a'] = Completer<void>();
    final add = late.model.addSpec(spec('a'));
    await Future<void>.delayed(Duration.zero);
    await late.drivers['a']!.started.future;
    final close = late.model.close();
    start.complete();
    await Future.wait([add, close]);
    expect(late.events, ['factory:a', 'closed:a']);
    expect(late.model.rooms, isEmpty);
    expect(late.writes, isEmpty);
  });

  test(
      'rapid chat switches serialize leases and drop stale send, never change volume',
      () async {
    final h = _Harness(TargetPlatform.windows);
    addTearDown(h.dispose);
    await h.model.addSpec(spec('a'));
    await h.model.addSpec(spec('b'));
    final a = h.model.rooms.first.id;
    final b = h.model.rooms.last.id;
    await h.model.setVolume(a, 29);
    await h.model.setVolume(b, 61);
    h.drivers['b']!.releasing = Completer<void>();
    h.model.selectRoom(a);
    await h.drivers['b']!.releaseStarted.future;
    final stale = h.model.sendDanmaku(a, 'stale');
    h.model.selectRoom(b);
    h.model.selectRoom(a);
    h.drivers['b']!.releasing!.complete();
    expect(await stale, '发送房间已切换');
    h.drivers['a']!.sending = Completer<String?>();
    final inFlight = h.model.sendDanmaku(a, 'fixed');
    await h.drivers['a']!.sendStarted.future;
    h.model.selectRoom(b);
    expect(await h.model.sendDanmaku(b, 'next'), isNull);
    h.drivers['a']!.sending!.complete(null);
    expect(await inFlight, isNull);
    expect(h.drivers['a']!.sent, ['fixed']);
    expect(h.drivers['b']!.sent, ['next']);
    expect(h.drivers['a']!.volumes, [100, 29]);
    expect(h.drivers['b']!.volumes, [100, 61]);
    expect(h.peakSenders, 1);
  });

  test('excess restore does not allocate or overwrite until an explicit edit',
      () async {
    final saved = snapshot(['a', 'b', 'c', 'd']);
    final h = _Harness(TargetPlatform.android, raw: saved.encode());
    addTearDown(h.dispose);
    final loaded = await h.model.loadSavedWorkspace();
    expect(loaded.status, MultiLiveRestoreStatus.overCapacity);
    expect(loaded.savedCount, 4);
    await h.model.restore(saved);
    expect(h.drivers, isEmpty);
    await h.model.openInitialRoom(spec('a'));
    h.model.maximizeRoom(h.model.rooms.single.id);
    await h.model.close();
    expect(h.writes, isEmpty);

    final edited = _Harness(TargetPlatform.android, raw: saved.encode());
    addTearDown(edited.dispose);
    await edited.model.openInitialRoom(spec('a'));
    await edited.model.setVolume(edited.model.rooms.single.id, 17);
    await edited.model.close();
    final restored = MultiLiveWorkspaceStore.decode(edited.writes.single,
        supportedSites: {'douyu'}, maxRooms: 2);
    expect(restored.snapshot!.rooms.single.spec.volume, 17);
  });
}

class _PopObserver extends NavigatorObserver {
  int workspacePops = 0;
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route.settings.name == '/workspace') workspacePops++;
  }
}

Future<NavigatorState> _pushRoute(
  WidgetTester tester,
  _Harness h, {
  MultiLiveRoomSpec? initial,
  bool settle = true,
  _PopObserver? observer,
}) async {
  final key = GlobalKey<NavigatorState>();
  await tester.pumpWidget(MaterialApp(
    navigatorKey: key,
    navigatorObservers: [if (observer != null) observer],
    home: const Scaffold(body: Text('Home')),
  ));
  final navigator = key.currentState!;
  unawaited(navigator.push<void>(MaterialPageRoute<void>(
    settings: const RouteSettings(name: '/workspace'),
    builder: (_) => MultiLiveRoute(
        controller: h.model, initialRoom: initial, onNotice: h.notices.add),
  )));
  await tester.pump();
  if (settle) await tester.pumpAndSettle();
  return navigator;
}

MultiLiveWorkspaceSnapshot snapshot(List<String> rooms) =>
    MultiLiveWorkspaceSnapshot(
      rooms: rooms.map((id) => MultiLiveSavedRoom(id, spec(id))),
      layout: MultiLiveLayouts.create(MultiLiveLayoutPreset.sideBySide, rooms),
      selectedRoomId: rooms.lastOrNull,
    );
