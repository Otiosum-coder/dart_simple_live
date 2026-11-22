import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

import '../layout/multi_live_layout.dart';
import '../session/multi_live_room_spec.dart';

const multiLiveWorkspaceKey = 'multiLive.workspace.v1';

bool isMultiLiveRoomId(String id) => _roomIdPattern.hasMatch(id);

final _roomIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,128}$');
final _sessionIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');
final _nodeIdPattern = RegExp(r'^[A-Za-z0-9_:-]{1,160}$');

class MultiLiveSavedRoom {
  const MultiLiveSavedRoom(this.id, this.spec);

  final String id;
  final MultiLiveRoomSpec spec;

  Map<String, Object?> toJson() => {
        'id': id,
        'spec': {
          'siteId': spec.siteId,
          'roomId': spec.roomId,
          'volume': spec.volume,
          'muted': spec.muted,
          'danmakuVisible': spec.danmakuVisible,
        },
      };
}

class MultiLiveWorkspaceSnapshot {
  MultiLiveWorkspaceSnapshot({
    required Iterable<MultiLiveSavedRoom> rooms,
    required this.layout,
    required this.selectedRoomId,
  }) : rooms = List.unmodifiable(rooms);

  final List<MultiLiveSavedRoom> rooms;
  final MultiLiveLayoutNode? layout;
  final String? selectedRoomId;

  String encode() => jsonEncode({
        'version': 1,
        'rooms': rooms.map((room) => room.toJson()).toList(),
        'layout': layout?.toJson(),
        'selectedRoomId': selectedRoomId,
      });
}

enum MultiLiveRestoreStatus { none, ready, invalid, overCapacity }

class MultiLiveRestoreResult {
  const MultiLiveRestoreResult(this.status, {this.snapshot, this.savedCount});

  final MultiLiveRestoreStatus status;
  final MultiLiveWorkspaceSnapshot? snapshot;
  final int? savedCount;
}

class MultiLiveWorkspaceStore {
  MultiLiveWorkspaceStore({required this.read, required this.write});

  factory MultiLiveWorkspaceStore.local() => MultiLiveWorkspaceStore(
        read: () async => LocalStorageService.instance.getValue<Object?>(
          multiLiveWorkspaceKey,
          null,
        ),
        write: (value) async {
          await LocalStorageService.instance
              .setValue(multiLiveWorkspaceKey, value);
        },
      );

  final Future<Object?> Function() read;
  final Future<void> Function(String value) write;

  Future<MultiLiveRestoreResult> load({
    required Set<String> supportedSites,
    required int maxRooms,
  }) async =>
      decode(await read(), supportedSites: supportedSites, maxRooms: maxRooms);

  static MultiLiveRestoreResult decode(
    Object? raw, {
    required Set<String> supportedSites,
    required int maxRooms,
  }) {
    const invalid = MultiLiveRestoreResult(MultiLiveRestoreStatus.invalid);
    if (raw == null) {
      return const MultiLiveRestoreResult(MultiLiveRestoreStatus.none);
    }
    if (raw is! String || raw.isEmpty || raw.length > 16 * 1024) return invalid;

    final Object? data;
    try {
      data = jsonDecode(raw);
    } catch (_) {
      return invalid;
    }
    if (data is! Map<String, dynamic> ||
        data['version'] is! int ||
        data['version'] != 1) {
      return invalid;
    }
    final savedRooms = data['rooms'];
    if (savedRooms is! List || savedRooms.length > 4) return invalid;
    final rooms = <MultiLiveSavedRoom>[];
    final ids = <String>{};
    final roomKeys = <String>{};
    for (final entry in savedRooms) {
      if (entry is! Map) return invalid;
      final id = entry['id'];
      final values = entry['spec'];
      if (id is! String ||
          !_sessionIdPattern.hasMatch(id) ||
          !ids.add(id) ||
          values is! Map) {
        return invalid;
      }
      final site = values['siteId'];
      final roomId = values['roomId'];
      final volume = values['volume'];
      final muted = values['muted'];
      final danmakuVisible = values['danmakuVisible'];
      if (site is! String ||
          !supportedSites.contains(site) ||
          roomId is! String ||
          !isMultiLiveRoomId(roomId) ||
          volume is! num ||
          !volume.isFinite ||
          volume < 0 ||
          volume > 100 ||
          muted is! bool ||
          danmakuVisible is! bool) {
        return invalid;
      }
      final spec = MultiLiveRoomSpec(
        siteId: site,
        roomId: roomId,
        volume: volume.toDouble(),
        muted: muted,
        danmakuVisible: danmakuVisible,
      );
      if (!roomKeys.add(spec.roomKey)) return invalid;
      rooms.add(MultiLiveSavedRoom(id, spec));
    }

    final rawLayout = data['layout'];
    final layout = MultiLiveLayoutNode.tryFromJson(rawLayout);
    if ((rawLayout != null && layout == null) ||
        !MultiLiveLayouts.validate(layout, ids) ||
        (layout != null && !_validNodeIds(layout))) {
      return invalid;
    }
    final selected = data['selectedRoomId'];
    if (rooms.isEmpty
        ? selected != null
        : selected is! String || !ids.contains(selected)) {
      return invalid;
    }
    if (rooms.length > maxRooms) {
      return MultiLiveRestoreResult(MultiLiveRestoreStatus.overCapacity,
          savedCount: rooms.length);
    }
    return MultiLiveRestoreResult(
      MultiLiveRestoreStatus.ready,
      snapshot: MultiLiveWorkspaceSnapshot(
        rooms: rooms,
        layout: layout,
        selectedRoomId: selected as String?,
      ),
    );
  }

  static bool _validNodeIds(MultiLiveLayoutNode node) =>
      _nodeIdPattern.hasMatch(node.id) &&
      (node is! MultiLiveSplit ||
          (_validNodeIds(node.first) && _validNodeIds(node.second)));
}

/// Keeps at most one pending snapshot, and never starts a second disk write
/// until the previous one settles. Failed writes can be retried by flush.
class MultiLiveWorkspaceWriter {
  MultiLiveWorkspaceWriter({
    required MultiLiveWorkspaceStore store,
    required this.onWriteError,
    this.delay = const Duration(milliseconds: 350),
  }) : _store = store;

  final MultiLiveWorkspaceStore _store;
  final VoidCallback onWriteError;
  final Duration delay;
  Timer? _timer;
  String? _pending;
  Future<void>? _draining;

  void schedule(MultiLiveWorkspaceSnapshot snapshot) {
    _pending = snapshot.encode();
    _timer?.cancel();
    _timer = Timer(delay, () => unawaited(flush()));
  }

  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    final running = _draining;
    if (running != null) {
      await running;
      if (_pending == null || _timer != null) return;
      // An explicit flush may have arrived during the last write.
      await flush();
      return;
    }
    if (_pending == null) return;
    final drain = _drain();
    _draining = drain;
    try {
      await drain;
    } finally {
      _draining = null;
    }
  }

  Future<void> _drain() async {
    while (_pending != null && _timer == null) {
      final value = _pending!;
      _pending = null;
      try {
        await _store.write(value);
      } catch (_) {
        _pending ??= value;
        onWriteError();
        return;
      }
    }
  }
}
