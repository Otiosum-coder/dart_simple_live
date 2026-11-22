import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/modules/multi_live/layout/multi_live_layout.dart';
import 'package:simple_live_app/modules/multi_live/session/multi_live_room_spec.dart';
import 'package:simple_live_app/modules/multi_live/storage/multi_live_workspace_store.dart';

MultiLiveWorkspaceSnapshot _snapshot(double volume) =>
    MultiLiveWorkspaceSnapshot(
      rooms: [
        MultiLiveSavedRoom(
            'a',
            MultiLiveRoomSpec(
                siteId: 'douyu',
                roomId: '123',
                title: 'ephemeral title',
                volume: volume,
                muted: true,
                danmakuVisible: false)),
        const MultiLiveSavedRoom(
            'b', MultiLiveRoomSpec(siteId: 'douyu', roomId: '456')),
      ],
      layout:
          MultiLiveLayouts.create(MultiLiveLayoutPreset.stacked, ['b', 'a']),
      selectedRoomId: 'b',
    );

MultiLiveRestoreResult _decode(Object? value) =>
    MultiLiveWorkspaceStore.decode(value,
        supportedSites: {'douyu'}, maxRooms: 2);

double _volume(String value) =>
    _decode(value).snapshot!.rooms.first.spec.volume;

void main() {
  test(
      'workspace JSON round trips stable IDs, layout and audio without transient fields',
      () {
    final saved = _snapshot(24.5);
    final encoded = saved.encode();
    expect(encoded, isNot(contains('ephemeral title')));
    final result = _decode(encoded);
    expect(result.status, MultiLiveRestoreStatus.ready);
    final restored = result.snapshot!;
    expect(restored.rooms.map((r) => r.id), ['a', 'b']);
    expect(restored.rooms.first.spec.volume, 24.5);
    expect(restored.rooms.first.spec.muted, isTrue);
    expect(restored.rooms.first.spec.danmakuVisible, isFalse);
    expect(restored.layout!.toJson(), saved.layout!.toJson());
    expect(restored.selectedRoomId, 'b');
  });

  test(
      'rejects malformed version, site, room, duplicate identities and wrong layout',
      () {
    final original = _snapshot(25).encode();
    expect(_decode(null).status, MultiLiveRestoreStatus.none);
    for (final text in [
      '{',
      original.replaceFirst('"version":1', '"version":2'),
      original.replaceFirst('"douyu"', '"unknown"'),
      original.replaceFirst('"123"', '"https://example.test/secret"'),
      original.replaceFirst('"456"', '"123"'),
      original.replaceFirst('"id":"b"', '"id":"a"'),
      original.replaceFirst('"roomId":"b"', '"roomId":"missing"'),
      original.replaceFirst(
          '"selectedRoomId":"b"', '"selectedRoomId":"missing"'),
      original.replaceFirst('"volume":25.0', '"volume":1e999'),
      original.replaceFirst('"volume":25.0', '"volume":-1'),
    ]) {
      expect(_decode(text).status, MultiLiveRestoreStatus.invalid,
          reason: text);
    }
  });

  testWidgets(
      'debounce coalesces changes and flush serializes behind active write',
      (tester) async {
    final first = Completer<void>();
    final writes = <double>[];
    var active = 0;
    var maxActive = 0;
    final writer = MultiLiveWorkspaceWriter(
      onWriteError: () => fail('write should succeed'),
      store: MultiLiveWorkspaceStore(
          read: () async => null,
          write: (json) async {
            active++;
            if (active > maxActive) maxActive = active;
            writes.add(_volume(json));
            if (writes.length == 1) await first.future;
            active--;
          }),
    );
    writer.schedule(_snapshot(1));
    writer.schedule(_snapshot(2));
    await tester.pump(const Duration(milliseconds: 349));
    expect(writes, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(writes, [2]);
    writer.schedule(_snapshot(3));
    writer.schedule(_snapshot(4));
    final flushed = writer.flush();
    await tester.pump();
    expect(writes, [2]);
    first.complete();
    await tester.pump();
    await flushed;
    expect(writes, [2, 4]);
    expect(maxActive, 1);
  });

  test('failed write keeps pending snapshot for a later flush', () async {
    final attempts = <String>[];
    var errors = 0;
    final writer = MultiLiveWorkspaceWriter(
      onWriteError: () => errors++,
      store: MultiLiveWorkspaceStore(
          read: () async => null,
          write: (value) async {
            attempts.add(value);
            if (attempts.length == 1) throw StateError('storage failure');
          }),
    );
    writer.schedule(_snapshot(14));
    await writer.flush();
    await writer.flush();
    expect(errors, 1);
    expect(attempts, hasLength(2));
    expect(jsonDecode(attempts.first), jsonDecode(attempts.last));
  });
}
