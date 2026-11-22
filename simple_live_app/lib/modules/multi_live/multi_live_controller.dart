import 'dart:async';

import 'package:flutter/widgets.dart';

import 'multi_live_device_policy.dart';
import 'session/multi_live_room_session.dart';
import 'storage/multi_live_workspace_store.dart';
import 'widgets/multi_live_view_model.dart';

typedef MultiLiveRoomPicker = Future<MultiLiveRoomSpec?> Function();
typedef MultiLiveRoomBatchPicker = Future<List<MultiLiveRoomSpec>?> Function(
    int remainingSlots, Set<String> existingRoomKeys);
typedef MultiLiveRoomBuilder = Widget Function(
    BuildContext context, MultiLiveRoomSession session);
typedef MultiLiveChatBuilder = Widget Function(BuildContext context,
    MultiLiveRoomSession session, Future<String?> Function(String) send);

class MultiLiveController extends ChangeNotifier implements MultiLiveViewModel {
  MultiLiveController({
    required MultiLiveDevicePolicy policy,
    required Map<String, String> sites,
    required MultiLiveWorkspaceStore store,
    required MultiLiveRoomPicker pickRoom,
    required MultiLiveRoomBuilder roomBuilder,
    required MultiLiveChatBuilder chatBuilder,
    required ValueChanged<String> notice,
    MultiLiveRoomBatchPicker? pickRooms,
    MultiLiveRoomBuilder? settingsBuilder,
    MultiLiveSessionFactory? sessionFactory,
  })  : _policy = policy,
        _sites = Map.unmodifiable(sites),
        _store = store,
        _pickRoom = pickRoom,
        _pickRooms = pickRooms,
        _roomBuilder = roomBuilder,
        _chatBuilder = chatBuilder,
        _notice = notice,
        _settingsBuilder = settingsBuilder,
        _factory = sessionFactory ?? MultiLiveRoomSession.new {
    _writer = MultiLiveWorkspaceWriter(
        store: store, onWriteError: () => _show('无法保存多开布局'));
  }

  final MultiLiveDevicePolicy _policy;
  final Map<String, String> _sites;
  final MultiLiveWorkspaceStore _store;
  final MultiLiveRoomPicker _pickRoom;
  final MultiLiveRoomBatchPicker? _pickRooms;
  bool _batchPicking = false;
  final MultiLiveRoomBuilder _roomBuilder;
  final MultiLiveRoomBuilder? _settingsBuilder;
  final MultiLiveChatBuilder _chatBuilder;
  final ValueChanged<String> _notice;
  final MultiLiveSessionFactory _factory;
  late final MultiLiveWorkspaceWriter _writer;
  final _sessions = <String, MultiLiveRoomSession>{};
  final _bodyBuilders = <String, WidgetBuilder>{};
  MultiLiveLayoutNode? _layout;
  String? _selected;
  int _selectionEpoch = 0;

  void _setSelected(String? id) {
    if (_selected == id) return;
    _selected = id;
    _selectionEpoch++;
  }

  String? _maximized;
  MultiLiveRoomSession? _sender;
  int _nextId = 0;
  int _pending = 0;
  bool _closing = false;
  bool _disposed = false;
  Future<void> _operations = Future.value();
  Future<void> _leases = Future.value();
  final _pendingDanmaku = <(MultiLiveRoomSession, String)>{};
  Future<void>? _closingFuture;
  final _stopPicking = Completer<MultiLiveRoomSpec?>();

  @override
  int get maxRooms => _policy.maxRooms;
  @override
  bool get busy => _pending != 0;
  @override
  bool get allMuted =>
      _sessions.isNotEmpty && _sessions.values.every((s) => s.spec.muted);
  @override
  MultiLiveLayoutNode? get layout => _layout;
  @override
  String? get selectedRoomId => _selected;
  @override
  String? get maximizedRoomId => _maximized;

  @override
  List<MultiLiveTileData> get rooms => [
        for (final session in _sessions.values)
          MultiLiveTileData(
            id: session.id,
            title: session.spec.displayName,
            subtitle: '${_sites[session.spec.siteId]} · ${session.spec.roomId}'
                '${session.spec.liveTitle?.trim().isNotEmpty == true ? ' · ${session.spec.liveTitle!.trim()}' : ''}',
            volume: session.spec.volume,
            muted: session.spec.muted,
            danmakuVisible: session.spec.danmakuVisible,
            bodyBuilder: _bodyBuilders[session.id]!,
            settingsBuilder: _settingsBuilder == null
                ? null
                : (context) => _settingsBuilder!(context, session),
          ),
      ];

  /// Resolve only a live workspace-owned session for fixed-room UI callbacks.
  MultiLiveRoomSession? sessionFor(String id) {
    if (_closing || _disposed) return null;
    final session = _sessions[id];
    return session?.closed == false ? session : null;
  }

  @override
  WidgetBuilder? get selectedRoomChatBuilder {
    final session = _sessions[_selected];
    return session == null
        ? null
        : (context) => _chatBuilder(
            context, session, (text) => sendDanmaku(session.id, text));
  }

  void _show(String message) {
    if (!_closing && !_disposed) _notice(message);
  }

  void _notify() {
    if (!_closing && !_disposed) notifyListeners();
  }

  void _save() {
    if (_closing) return;
    _writer.schedule(MultiLiveWorkspaceSnapshot(
      rooms: _sessions.values.map((s) => MultiLiveSavedRoom(s.id, s.spec)),
      layout: _layout,
      selectedRoomId: _selected,
    ));
  }

  Future<void> _run(Future<void> Function() operation) {
    if (_closing) return Future.value();
    _pending++;
    final result = _operations.then((_) async {
      if (!_closing) await operation();
    }).whenComplete(() {
      _pending--;
      _notify();
    });
    _operations = result.then((_) {}, onError: (Object _, StackTrace __) {});
    _notify();
    return result;
  }

  bool _valid(MultiLiveRoomSpec spec) =>
      _sites.containsKey(spec.siteId) && isMultiLiveRoomId(spec.roomId);

  Future<MultiLiveRestoreResult> loadSavedWorkspace() async {
    try {
      return await _store.load(
          supportedSites: _sites.keys.toSet(), maxRooms: maxRooms);
    } catch (_) {
      return const MultiLiveRestoreResult(MultiLiveRestoreStatus.invalid);
    }
  }

  /// Initial room and restoration are not edits: leaving unchanged must not
  /// truncate a workspace saved for a device with a higher capacity.
  Future<void> openInitialRoom(MultiLiveRoomSpec spec) => _run(() async {
        if (_sessions.isEmpty) await _add(spec, save: false);
      });

  Future<void> restore(MultiLiveWorkspaceSnapshot snapshot) => _run(() async {
        if (_sessions.isNotEmpty) return;
        final saved = MultiLiveWorkspaceStore.decode(snapshot.encode(),
            supportedSites: _sites.keys.toSet(), maxRooms: maxRooms);
        final state = saved.snapshot;
        if (state == null) {
          if (saved.status == MultiLiveRestoreStatus.overCapacity) _capacity();
          return;
        }
        for (final room in state.rooms) {
          if (_closing) return;
          await _create(room.id, room.spec);
        }
        if (_closing) return;
        var tree = state.layout;
        for (final room in state.rooms) {
          if (!_sessions.containsKey(room.id)) {
            tree = MultiLiveLayouts.remove(tree, room.id);
          }
        }
        _layout = tree;
        _setSelected(_sessions.containsKey(state.selectedRoomId)
            ? state.selectedRoomId
            : tree?.roomIds.firstOrNull);
        await _syncSender();
        _notify();
      });

  Future<bool> _create(String id, MultiLiveRoomSpec spec,
      {bool reportFailure = true}) async {
    MultiLiveRoomSession? session;
    try {
      session = _factory(id: id, spec: spec);
      await session.initialize();
    } catch (_) {
      if (session != null) await _release(session);
      if (reportFailure) _show('无法初始化直播间，请重试');
      return false;
    }
    final created = session;
    if (_closing) {
      await _release(created);
      return false;
    }
    created.addListener(_notify);
    _sessions[id] = created;
    _bodyBuilders[id] = (context) => _roomBuilder(context, created);
    return true;
  }

  Future<void> _release(MultiLiveRoomSession session) async {
    session.removeListener(_notify);
    try {
      await session.close();
    } finally {
      session.dispose();
    }
  }

  MultiLiveLayoutNode? _defaultLayout(Iterable<String> ids) =>
      MultiLiveLayouts.create(MultiLiveLayoutPreset.sideBySide, ids);

  String _allocateId() {
    String id;
    do {
      id = 'live-${++_nextId}';
    } while (_sessions.containsKey(id));
    return id;
  }

  void _capacity() => _show('最多同时观看 $maxRooms 个房间，请先关闭或更换房间');

  MultiLiveRoomSession? _existing(MultiLiveRoomSpec spec) =>
      _sessions.values.where((s) => s.spec.roomKey == spec.roomKey).firstOrNull;

  Future<void> _add(MultiLiveRoomSpec spec, {bool save = true}) async {
    if (_closing) return;
    if (!_valid(spec)) {
      _show('平台或房间号无效');
      return;
    }
    final existing = _existing(spec);
    if (existing != null) {
      await _select(existing.id);
      return;
    }
    if (_sessions.length >= maxRooms) {
      _capacity();
      return;
    }
    final oldOrder = _layout?.roomIds ?? const <String>[];
    final id = _allocateId();
    if (!await _create(id, spec) || _closing) return;
    _layout = _defaultLayout([...oldOrder, id]);
    _setSelected(id);
    if (save) _save();
    _notify();
    await _syncSender();
  }

  /// Explicit programmatic adds use the same serialized capacity check as UI.
  Future<void> addSpec(MultiLiveRoomSpec spec) => _run(() => _add(spec));

  /// A batch is rechecked inside the same queue as every single-room edit.
  Future<void> addSpecs(Iterable<MultiLiveRoomSpec> specs) {
    final batch = List<MultiLiveRoomSpec>.unmodifiable(specs);
    return _run(() => _addSpecs(batch));
  }

  Future<void> _addSpecs(List<MultiLiveRoomSpec> specs) async {
    final order = [...?_layout?.roomIds];
    final seen = <String>{};
    var added = 0;
    var duplicate = 0;
    var invalid = 0;
    var failed = 0;
    var overflow = 0;
    String? lastAdded;
    for (final spec in specs) {
      if (_closing) return;
      if (!_valid(spec)) {
        invalid++;
      } else if (!seen.add(spec.roomKey) || _existing(spec) != null) {
        duplicate++;
      } else if (_sessions.length >= maxRooms) {
        overflow++;
      } else if (await _create(_allocateId(), spec, reportFailure: false)) {
        final created = _existing(spec)!;
        order.add(created.id);
        lastAdded = created.id;
        added++;
      } else {
        failed++;
      }
    }
    if (_closing) return;
    if (lastAdded != null) {
      _layout = _defaultLayout(order);
      _setSelected(lastAdded);
      _save();
      _notify();
      // No intermediate batch item acquires a sender lease.
      await _syncSelection();
    }
    final skipped = [
      if (duplicate != 0) '$duplicate 个已打开或重复',
      if (invalid != 0) '$invalid 个平台或房间号无效',
      if (failed != 0) '$failed 个未能加载，可重试',
      if (overflow != 0) '$overflow 个超出容量（最多 $maxRooms 个）',
    ];
    if (skipped.isNotEmpty) _show('已添加 $added 个；${skipped.join('；')}');
  }

  @override
  Future<void> addRoom() {
    final pickBatch = _pickRooms;
    if (pickBatch == null) {
      return _run(() async {
        if (_sessions.length >= maxRooms) {
          _capacity();
          return;
        }
        final picked = await Future.any([_pickRoom(), _stopPicking.future]);
        if (!_closing && picked != null) await _add(picked);
      });
    }
    if (_closing || _batchPicking) return Future.value();
    _batchPicking = true;
    return _run(() async {
      final remaining = maxRooms - _sessions.length;
      if (remaining <= 0) {
        _capacity();
        return;
      }
      final picked = await Future.any<List<MultiLiveRoomSpec>?>([
        pickBatch(remaining,
            Set.unmodifiable(_sessions.values.map((s) => s.spec.roomKey))),
        _stopPicking.future.then((_) => null),
      ]);
      if (!_closing && picked != null) await _addSpecs(picked);
    }).whenComplete(() => _batchPicking = false);
  }

  @override
  Future<void> replaceRoom(String id) => _run(() async {
        if (!_sessions.containsKey(id)) return;
        final picked = await Future.any([_pickRoom(), _stopPicking.future]);
        if (!_closing && picked != null) await _replace(id, picked);
      });

  Future<void> replaceSpec(String id, MultiLiveRoomSpec spec) =>
      _run(() => _replace(id, spec));

  Future<void> _replace(String id, MultiLiveRoomSpec spec) async {
    if (!_sessions.containsKey(id)) return;
    if (!_valid(spec)) {
      _show('平台或房间号无效');
      return;
    }
    final existing = _existing(spec);
    if (existing != null) {
      await _select(existing.id);
      return;
    }
    final previous = _layout!;
    final previousMaximized = _maximized;
    await _remove(id);
    if (_closing) return;
    final newId = _allocateId();
    if (await _create(newId, spec) && !_closing) {
      _layout = _replaceLeaf(previous, id, newId);
      _setSelected(newId);
      if (previousMaximized == id) _maximized = newId;
    }
    _save();
    _notify();
    await _syncSender();
  }

  static MultiLiveLayoutNode _replaceLeaf(
          MultiLiveLayoutNode node, String oldId, String newId) =>
      switch (node) {
        MultiLiveLeaf(:final roomId) =>
          roomId == oldId ? MultiLiveLeaf(id: node.id, roomId: newId) : node,
        MultiLiveSplit(:final first, :final second) => node.copyWith(
            first: _replaceLeaf(first, oldId, newId),
            second: _replaceLeaf(second, oldId, newId)),
      };

  Future<void> _remove(String id) async {
    final previous = _sessions.remove(id);
    if (previous == null) return;
    _bodyBuilders.remove(id);
    _layout = MultiLiveLayouts.remove(_layout, id);
    if (_maximized == id) _maximized = null;
    if (_selected == id) _setSelected(_layout?.roomIds.firstOrNull);
    _save();
    _notify();
    try {
      await _syncSender();
    } finally {
      await _release(previous);
      if (identical(_sender, previous)) _sender = null;
    }
  }

  @override
  Future<void> closeRoom(String id) => _run(() => _remove(id));

  Future<void> _syncSender() {
    final result = _leases.then((_) async {
      while (true) {
        final desired = _closing ? null : _sessions[_selected];
        final previous = _sender;
        if (identical(previous, desired)) return;
        if (previous != null) {
          await previous.setSenderActive(false);
          _sender = null;
          // Re-read selection after releasing the old lease.
          continue;
        }
        if (desired == null) return;
        // Track the candidate before awaiting activation so a partial failure
        // cannot allow a second sender to be activated without releasing it.
        _sender = desired;
        try {
          await desired.setSenderActive(true);
        } catch (_) {
          await desired.setSenderActive(false);
          _sender = null;
          rethrow;
        }
      }
    });
    _leases = result.then((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<void> _syncSelection() async {
    try {
      await _syncSender();
    } catch (_) {
      _show('无法切换弹幕发送房间，请重试');
    }
  }

  Future<String?> sendDanmaku(String id, String text,
      {bool Function()? isCurrent}) async {
    final target = _sessions[id];
    final epoch = _selectionEpoch;
    bool validTarget() =>
        !_closing &&
        epoch == _selectionEpoch &&
        id == _selected &&
        identical(_sessions[id], target) &&
        (isCurrent?.call() ?? true);
    try {
      if (target == null || !validTarget()) return '发送房间已切换';
      // Both composers reserve the payload before waiting for the sender lease.
      final pending = (target, text);
      if (!_pendingDanmaku.add(pending)) return '相同弹幕正在发送，请稍候';
      try {
        await _syncSender();
        bool canSend() => validTarget() && identical(_sender, target);
        if (!canSend()) return '发送房间已切换';
        return await target.sendDanmaku(text, isCurrent: canSend);
      } finally {
        // Only the request that reserved this payload may release it.
        _pendingDanmaku.remove(pending);
      }
    } catch (_) {
      return '发送弹幕失败';
    }
  }

  @override
  void selectRoom(String id) {
    if (busy) return;
    unawaited(_select(id));
  }

  Future<void> _select(String id) async {
    if (_closing || !_sessions.containsKey(id)) return;
    if (id != _selected) {
      _setSelected(id);
      _save();
      _notify();
    }
    await _syncSelection();
  }

  Future<void> _changeRoom(
      String id, Future<void> Function(MultiLiveRoomSession) change) async {
    final session = _sessions[id];
    if (_closing || session == null) return;
    final operation = change(session);
    _save();
    await operation;
  }

  @override
  Future<void> setVolume(String id, double volume) =>
      _changeRoom(id, (s) => s.setVolume(volume));
  @override
  Future<void> toggleMute(String id) =>
      _changeRoom(id, (s) => s.setMuted(!s.spec.muted));
  @override
  Future<void> setAllMuted(bool muted) => Future.wait<void>(_sessions.keys
      .toList()
      .map((id) => _changeRoom(id, (s) => s.setMuted(muted))));
  @override
  void toggleDanmaku(String id) => unawaited(
      _changeRoom(id, (s) => s.setDanmakuVisible(!s.spec.danmakuVisible))
          .catchError((Object _) => _show('无法更新弹幕设置')));

  @override
  void maximizeRoom(String? id) {
    if (_closing || (id != null && !_sessions.containsKey(id))) return;
    _maximized = id;
    _notify();
  }

  void _changeLayout(MultiLiveLayoutNode? tree) {
    _layout = tree;
    _save();
    _notify();
  }

  @override
  void setPreset(MultiLiveLayoutPreset preset) {
    final tree = _layout;
    if (_closing ||
        busy ||
        tree == null ||
        preset.roomCount != _sessions.length) {
      return;
    }
    final order = [...tree.roomIds];
    // Grid traversal is column-major; feed the visual order back row-major.
    if (preset == MultiLiveLayoutPreset.grid &&
        tree is MultiLiveSplit &&
        tree.first is MultiLiveSplit &&
        tree.second is MultiLiveSplit) {
      final second = order[1];
      order[1] = order[2];
      order[2] = second;
    }
    _changeLayout(MultiLiveLayouts.create(preset, order));
  }

  @override
  void resizeSplit(String nodeId, double ratio) {
    final tree = _layout;
    if (_closing || busy || tree == null || !ratio.isFinite) return;
    _changeLayout(MultiLiveLayouts.resize(tree, nodeId, ratio));
  }

  @override
  void swapRooms(String sourceId, String targetId) {
    final tree = _layout;
    if (_closing || busy || tree == null) return;
    final swapped = MultiLiveLayouts.swap(tree, sourceId, targetId);
    if (!identical(tree, swapped)) _changeLayout(swapped);
  }

  Future<void> close() {
    _closing = true;
    if (!_stopPicking.isCompleted) _stopPicking.complete(null);
    return _closingFuture ??= _close();
  }

  Future<void> _close() async {
    await _operations;
    final sessions = _sessions.values.toList();
    _sessions.clear();
    _bodyBuilders.clear();
    _setSelected(null);
    _maximized = null;
    _layout = null;
    try {
      await _syncSender();
    } catch (_) {
      // Session disposal is still required when lease release fails.
    } finally {
      _sender = null;
      await Future.wait([_writer.flush(), ...sessions.map(_release)]);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(close().catchError((Object _) {}));
    super.dispose();
  }
}
