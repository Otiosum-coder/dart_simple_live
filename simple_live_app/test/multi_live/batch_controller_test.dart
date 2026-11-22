import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/multi_live/multi_live_controller.dart';
import 'package:simple_live_app/modules/multi_live/multi_live_device_policy.dart';
import 'package:simple_live_app/modules/multi_live/session/multi_live_room_session.dart';
import 'package:simple_live_app/modules/multi_live/storage/multi_live_workspace_store.dart';
import 'package:simple_live_core/simple_live_core.dart';

MultiLiveRoomSpec _spec(String id, {String? name, String? title}) =>
    MultiLiveRoomSpec(
        siteId: 'douyu', roomId: id, streamerName: name, title: title);

class _MetadataRoom extends LiveRoomController {
  _MetadataRoom(String id)
      : super(pSite: Sites.allSites['douyu']!, pRoomId: id, embedded: true);
  @override
  // ignore: must_call_super
  void onInit() {}
}

LiveRoomDetail _detail(String id, String name, String title) => LiveRoomDetail(
    roomId: id,
    title: title,
    cover: '',
    userName: name,
    userAvatar: '',
    online: 0,
    status: true,
    url: '');

class _Harness {
  _Harness(
      {TargetPlatform platform = TargetPlatform.windows,
      MultiLiveRoomBatchPicker? batch,
      MultiLiveRoomPicker? single,
      this.metadata = false}) {
    model = MultiLiveController(
      policy: MultiLiveDevicePolicy(platform),
      sites: const {'douyu': '斗鱼', 'huya': '虎牙'},
      store: MultiLiveWorkspaceStore(
          read: () async => raw, write: (value) async => writes.add(value)),
      pickRoom: () async {
        singleCalls++;
        return single?.call();
      },
      pickRooms: batch,
      roomBuilder: (_, __) => const SizedBox(),
      chatBuilder: (_, __, ___) => const SizedBox(),
      notice: notices.add,
      sessionFactory: ({required id, required spec}) {
        factories.add(spec.roomKey);
        final driver = _Driver(
            this, spec.roomId, metadata ? _MetadataRoom(spec.roomId) : null);
        drivers[spec.roomId] = driver;
        final session = MultiLiveRoomSession(
            id: id, spec: spec, driverFactory: (_) => driver);
        sessions[spec.roomId] = session;
        return session;
      },
    );
  }
  final bool metadata;
  late final MultiLiveController model;
  final drivers = <String, _Driver>{};
  final sessions = <String, MultiLiveRoomSession>{};
  final gates = <String, Completer<void>>{};
  final failures = <String>{};
  final active = <String>{};
  final factories = <String>[];
  final activations = <String>[];
  final notices = <String>[];
  final writes = <String>[];
  int peak = 0;
  int singleCalls = 0;
  String? raw;
  Future<void> dispose() async {
    await model.close();
    model.dispose();
  }
}

class _Driver implements MultiLiveRoomDriver {
  _Driver(this.h, this.id, this.room);
  final _Harness h;
  final String id;
  @override
  final LiveRoomController? room;
  final initialized = Completer<void>();
  Completer<void>? release;
  int starts = 0;
  int closes = 0;
  final volumes = <double>[];
  @override
  Future<void> initialize() async {
    starts++;
    initialized.complete();
    await h.gates[id]?.future;
    if (h.failures.contains(id)) throw StateError('fixture initialization');
  }

  @override
  Future<void> setVolume(double volume) async => volumes.add(volume);
  @override
  Future<void> setDanmakuVisible(bool visible) async {}
  @override
  Future<void> setSenderActive(bool active) async {
    if (active) {
      h.active.add(id);
      h.activations.add(id);
      if (h.active.length > h.peak) h.peak = h.active.length;
    } else {
      if (h.active.contains(id)) await release?.future;
      h.active.remove(id);
    }
  }

  @override
  Future<String?> sendDanmaku(String text) async => null;
  @override
  Future<void> close() async {
    closes++;
    h.active.remove(id);
  }
}

Future<void> _tick() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    final max = platform == TargetPlatform.windows ? 4 : 2;
    for (var count = 0; count <= max; count++) {
      test('$platform count $count supplies actual remaining capacity once',
          () async {
        var calls = 0;
        final h = _Harness(
            platform: platform,
            batch: (remaining, existing) async {
              calls++;
              expect(remaining, max - count);
              expect(existing, {for (var i = 0; i < count; i++) 'douyu:$i'});
              expect(() => existing.add('douyu:x'), throwsUnsupportedError);
              return [for (var i = count; i < max + 2; i++) _spec('$i')];
            });
        addTearDown(h.dispose);
        await h.model.addSpecs([for (var i = 0; i < count; i++) _spec('$i')]);
        await h.model.addRoom();
        expect(calls, count == max ? 0 : 1);
        expect(h.singleCalls, 0);
        expect(h.model.rooms, hasLength(max));
        expect(h.factories, hasLength(max));
        expect(h.peak, lessThanOrEqualTo(1));
        if (count < max) {
          expect(h.notices.single, contains('2 个超出容量'));
        } else {
          expect(h.notices.single, contains('最多同时观看 $max'));
        }
      });
    }
  }

  test(
      'one batch adds three to the existing player and activates only final sender',
      () async {
    final h =
        _Harness(batch: (_, __) async => [_spec('2'), _spec('3'), _spec('4')]);
    addTearDown(h.dispose);
    await h.model.addSpec(_spec('1', name: '原主播'));
    final before = h.model.rooms.single;
    final session = h.model.sessionFor(before.id);
    await h.model.setVolume(before.id, 29);
    h.model.toggleDanmaku(before.id);
    await h.model.addRoom();
    expect(h.model.rooms.map((r) => r.id).toSet(), hasLength(4));
    expect(h.model.rooms.first.id, before.id);
    expect(
        identical(h.model.rooms.first.bodyBuilder, before.bodyBuilder), isTrue);
    expect(identical(h.model.sessionFor(before.id), session), isTrue);
    expect(session!.spec.volume, 29);
    expect(session.spec.danmakuVisible, isFalse);
    expect(h.drivers.values.map((d) => d.starts), everyElement(1));
    expect(h.activations, ['1', '4']);
    expect(h.active, {'4'});
    expect(h.peak, 1);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final saved = MultiLiveWorkspaceStore.decode(h.writes.last,
            supportedSites: {'douyu'}, maxRooms: 4)
        .snapshot!;
    expect(saved.rooms.map((r) => r.id), h.model.rooms.map((r) => r.id));
    expect(saved.selectedRoomId, h.model.rooms.last.id);
  });

  test('programmatic batches serialize, deduplicate and snapshot caller input',
      () async {
    final h = _Harness();
    addTearDown(h.dispose);
    h.gates['1'] = Completer<void>();
    final input = [_spec('1'), _spec('1'), _spec('2')];
    final first = h.model.addSpecs(input);
    input.clear();
    await _tick();
    final second =
        h.model.addSpecs([_spec('2'), _spec('3'), _spec('4'), _spec('5')]);
    expect(h.factories, ['douyu:1']);
    h.gates['1']!.complete();
    await Future.wait([first, second]);
    expect(h.factories, ['douyu:1', 'douyu:2', 'douyu:3', 'douyu:4']);
    expect(h.model.rooms, hasLength(4));
    expect(h.notices.join(), contains('1 个已打开或重复'));
    expect(h.notices.join(), contains('1 个超出容量'));
    expect(h.peak, 1);
  });

  test(
      'invalid duplicate failed and excess rooms report partial success, original survives',
      () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.model.addSpec(_spec('old'));
    final original = h.model.rooms.single;
    h.failures.add('fail');
    await h.model.addSpecs([
      _spec('old'),
      _spec('fail'),
      const MultiLiveRoomSpec(siteId: 'unknown', roomId: '1'),
      _spec('unsafe/room'),
      _spec('ok'),
      _spec('ok'),
      _spec('next'),
      _spec('last'),
      _spec('overflow'),
    ]);
    expect(h.model.rooms, hasLength(4));
    expect(h.model.rooms.first.id, original.id);
    expect(identical(h.model.rooms.first.bodyBuilder, original.bodyBuilder),
        isTrue);
    expect(h.drivers['old']!.closes, 0);
    expect(h.drivers['fail']!.closes, 1);
    expect(
        h.notices.single,
        allOf(contains('已添加 3 个'), contains('2 个已打开或重复'),
            contains('2 个平台或房间号无效'), contains('1 个未能加载'), contains('1 个超出容量')));
    expect(h.peak, 1);
  });

  test('all failure or duplicate batch retains selection, layout and sender',
      () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.model.addSpecs([_spec('1'), _spec('2')]);
    final layout = h.model.layout!.toJson();
    final selected = h.model.selectedRoomId;
    h.failures.add('failed');
    await h.model.addSpecs([_spec('1'), _spec('failed')]);
    expect(h.model.layout!.toJson(), layout);
    expect(h.model.selectedRoomId, selected);
    expect(h.active, {'2'});
    expect(h.activations, ['2']);
  });

  test('double add while picking opens one dialog; cancel creates no sessions',
      () async {
    final pending = Completer<List<MultiLiveRoomSpec>?>();
    var calls = 0;
    final h = _Harness(batch: (_, __) {
      calls++;
      return pending.future;
    });
    addTearDown(h.dispose);
    final first = h.model.addRoom();
    final duplicate = h.model.addRoom();
    await _tick();
    expect(h.model.busy, isTrue);
    expect(calls, 1);
    pending.complete(null);
    await Future.wait([first, duplicate]);
    expect(h.factories, isEmpty);
    expect(h.model.busy, isFalse);
  });

  test(
      'closing cancels pending batch picker and ignores success or error arriving later',
      () async {
    for (final error in [false, true]) {
      final pending = Completer<List<MultiLiveRoomSpec>?>();
      final h = _Harness(batch: (_, __) => pending.future);
      final adding = h.model.addRoom();
      await _tick();
      await h.model.close();
      await adding;
      if (error) {
        pending.completeError(StateError('late fixture'));
      } else {
        pending.complete([_spec('late')]);
      }
      await _tick();
      expect(h.factories, isEmpty);
      expect(h.model.rooms, isEmpty);
      expect(h.notices, isEmpty);
      await h.dispose();
    }
  });

  test(
      'closing mid initialization releases late player and never creates next item',
      () async {
    final h = _Harness();
    h.gates['1'] = Completer<void>();
    final adding = h.model.addSpecs([_spec('1'), _spec('2')]);
    await _tick();
    final closing = h.model.close();
    expect(h.model.sessionFor('live-1'), isNull);
    h.gates['1']!.complete();
    await Future.wait([adding, closing]);
    expect(h.factories, ['douyu:1']);
    expect(h.drivers['1']!.closes, 1);
    expect(h.activations, isEmpty);
    expect(h.model.rooms, isEmpty);
    h.model.dispose();
  });

  test('queued add after batch uses current count instead of stale free slots',
      () async {
    final picked = Completer<List<MultiLiveRoomSpec>?>();
    final h = _Harness(
        platform: TargetPlatform.android, batch: (_, __) => picked.future);
    addTearDown(h.dispose);
    final first = h.model.addRoom();
    await _tick();
    final queued = h.model.addSpecs([_spec('2'), _spec('3')]);
    picked.complete([_spec('1'), _spec('2')]);
    await Future.wait([first, queued]);
    expect(h.factories, ['douyu:1', 'douyu:2']);
    expect(h.model.rooms, hasLength(2));
    expect(h.notices.single, allOf(contains('已打开或重复'), contains('超出容量')));
  });

  test(
      'original single add and replace remain single and keep unrelated players',
      () async {
    var picked = _spec('one');
    final h = _Harness(
        single: () async => picked, batch: (_, __) async => [_spec('batch')]);
    addTearDown(h.dispose);
    await h.model.addRoom();
    expect(h.singleCalls, 0);
    await h.model.addSpec(_spec('existing'));
    final existing = h.model.rooms.last;
    final replaced = h.model.rooms.first.id;
    await h.model.replaceRoom(replaced);
    expect(h.singleCalls, 1);
    expect(h.model.rooms.map((r) => r.id), contains(existing.id));
    expect(h.model.sessionFor(replaced), isNull);
    expect(h.drivers['existing']!.closes, 0);
    picked = _spec('existing');
    await h.model.replaceRoom(h.model.rooms.last.id);
    expect(h.factories.where((k) => k == 'douyu:existing'), hasLength(1));
    final legacy = _Harness(single: () async => _spec('legacy'));
    await legacy.model.addRoom();
    expect(legacy.singleCalls, 1);
    expect(legacy.model.rooms.single.id, isNotEmpty);
    await legacy.dispose();
  });

  test('slow lease release never activates batch intermediate senders',
      () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.model.addSpec(_spec('old'));
    h.drivers['old']!.release = Completer<void>();
    final adding = h.model.addSpecs([_spec('2'), _spec('3'), _spec('4')]);
    await _tick();
    expect(h.active, {'old'});
    expect(h.activations, ['old']);
    h.drivers['old']!.release!.complete();
    await adding;
    expect(h.activations, ['old', '4']);
    expect(h.peak, 1);
  });

  test(
      'old ambiguous title is never a streamer; explicit metadata survives spec roundtrip',
      () {
    final old =
        MultiLiveRoomSpec.tryFromJson(_spec('123', title: '旧直播标题').toJson())!;
    expect(old.streamerName, isNull);
    expect(old.displayName, '房间 123 · 主播名待加载');
    final known = old.copyWith(streamerName: ' 主播名 ', liveTitle: '直播标题');
    final restored = MultiLiveRoomSpec.tryFromJson(known.toJson())!;
    expect(restored.displayName, '主播名');
    expect(restored.liveTitle, '直播标题');
    expect(restored.copyWith(volume: 25).streamerName, ' 主播名 ');
  });

  test(
      'follow, link, initial and replacement converge on real username without recreating drivers',
      () async {
    final h = _Harness(metadata: true);
    addTearDown(h.dispose);
    await h.model.openInitialRoom(_spec('initial', title: '来自单开的直播标题'));
    await h.model.addSpecs([_spec('follow', name: '缓存主播名'), _spec('link')]);
    final ids = {
      for (final entry in h.sessions.entries) entry.key: entry.value.id
    };
    final bodies = h.model.rooms.map((r) => r.bodyBuilder).toList();
    expect(h.model.rooms.map((r) => r.title),
        ['房间 initial · 主播名待加载', '缓存主播名', '房间 link · 主播名待加载']);
    final activeBefore = [...h.activations];
    for (final id in ids.keys) {
      h.drivers[id]!.room!.detail.value = _detail(id, '真实主播 $id', '直播标题 $id');
    }
    await _tick();
    expect(h.model.rooms.map((r) => r.title),
        ['真实主播 initial', '真实主播 follow', '真实主播 link']);
    expect(h.model.rooms.every((r) => r.subtitle.contains('直播标题')), isTrue);
    expect(h.model.rooms.map((r) => r.bodyBuilder), bodies);
    expect(h.activations, activeBefore);
    expect(h.drivers.values.every((d) => d.starts == 1), isTrue);
    final oldRoom = h.drivers['initial']!.room!;
    await h.model
        .replaceSpec(ids['initial']!, _spec('replacement', title: '不可信旧标题'));
    expect(h.model.rooms.last.title, contains('主播名待加载'));
    oldRoom.detail.value = _detail('initial', '已关闭旧主播', '旧标题');
    h.drivers['replacement']!.room!.detail.value =
        _detail('replacement', '替换后主播', '新直播标题');
    await _tick();
    expect(h.model.rooms.last.title, '替换后主播');
    expect(h.sessions['initial']!.spec.streamerName, '真实主播 initial');
    expect(h.drivers['follow']!.starts, 1);
    expect(h.drivers['link']!.starts, 1);
  });

  test(
      'restore ignores old title, then updates metadata and closes subscription safely',
      () async {
    final original = _Harness();
    await original.model.addSpec(_spec('saved', name: '不持久化主播', title: '未知标题'));
    await original.model.close();
    final raw = original.writes.last;
    expect(raw, isNot(contains('不持久化主播')));
    await original.dispose();
    final map = jsonDecode(raw) as Map<String, dynamic>;
    (map['rooms'] as List).first['spec']['title'] = '旧版任意文本';
    final h = _Harness(metadata: true)..raw = jsonEncode(map);
    final snapshot = (await h.model.loadSavedWorkspace()).snapshot!;
    await h.model.restore(snapshot);
    final id = h.model.rooms.single.id;
    final session = h.model.sessionFor(id)!;
    final body = h.model.rooms.single.bodyBuilder;
    expect(h.model.rooms.single.title, '房间 saved · 主播名待加载');
    final room = h.drivers['saved']!.room!;
    room.detail.value = _detail('saved', '恢复后真实主播', '当前直播标题');
    await _tick();
    expect(h.model.rooms.single.title, '恢复后真实主播');
    expect(identical(h.model.rooms.single.bodyBuilder, body), isTrue);
    expect(h.model.sessionFor(id), same(session));
    room.detail.value = _detail('saved', '', '只变化的直播标题');
    await _tick();
    expect(h.model.rooms.single.title, '恢复后真实主播');
    await h.model.close();
    expect(h.model.sessionFor(id), isNull);
    room.detail.value = _detail('saved', '关闭后晚到名字', '晚到标题');
    await _tick();
    expect(session.spec.streamerName, '恢复后真实主播');
    h.model.dispose();
  });
}
