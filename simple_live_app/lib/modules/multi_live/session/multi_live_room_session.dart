import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'multi_live_room_spec.dart';
export 'multi_live_room_spec.dart';

typedef MultiLiveSessionFactory = MultiLiveRoomSession Function(
    {required String id, required MultiLiveRoomSpec spec});
typedef MultiLiveRoomDriverFactory = MultiLiveRoomDriver Function(
    MultiLiveRoomSpec spec);

/// Injectable native boundary; every session owns a fresh driver and player.
abstract class MultiLiveRoomDriver {
  LiveRoomController? get room;
  Future<void> initialize();
  Future<void> setVolume(double volume);
  Future<void> setDanmakuVisible(bool visible);
  Future<void> setSenderActive(bool active);
  Future<String?> sendDanmaku(String text);
  Future<void> close();
}

class MultiLiveRoomSession extends ChangeNotifier {
  MultiLiveRoomSession(
      {required this.id,
      required MultiLiveRoomSpec spec,
      MultiLiveRoomDriverFactory? driverFactory})
      : _spec = spec.copyWith(
            volume: spec.volume.isFinite
                ? spec.volume.clamp(0, 100).toDouble()
                : 100),
        _driverFactory = driverFactory ?? _LiveRoomDriver.new;
  final String id;
  MultiLiveRoomSpec _spec;
  MultiLiveRoomSpec get spec => _spec;
  final MultiLiveRoomDriverFactory _driverFactory;
  MultiLiveRoomDriver? _driver;
  LiveRoomController? get room => _driver?.room;
  bool _initialized = false;
  bool get initialized => _initialized;
  bool _closed = false;
  bool get closed => _closed;
  bool _senderActive = false;
  Worker? _detailWorker;
  LiveRoomController? _metadataRoom;

  void _bindMetadata() {
    final source = room;
    if (_closed || source == null || identical(source, _metadataRoom)) return;
    _detailWorker?.dispose();
    _metadataRoom = source;
    _detailWorker = ever(source.detail, (_) => _syncMetadata());
    _syncMetadata();
  }

  void _syncMetadata() {
    if (_closed) return;
    final detail = _metadataRoom?.detail.value;
    if (detail == null) return;
    final name = detail.userName.trim();
    final title = detail.title.trim();
    final updated = _spec.copyWith(
      streamerName: name.isEmpty ? null : name,
      liveTitle: title,
    );
    if (updated.streamerName == _spec.streamerName &&
        updated.liveTitle == _spec.liveTitle) {
      return;
    }
    _spec = updated;
    notifyListeners();
  }

  Future<void>? _initializeFuture;
  Future<void>? _closeFuture;
  Future<void>? _driverCloseFuture;
  Future<void> _closeDriver() =>
      _driverCloseFuture ??= _driver?.close() ?? Future<void>.value();
  Future<void> _operations = Future<void>.value();

  Future<void> initialize() {
    if (_closed) return Future<void>.value();
    return _initializeFuture ??= _initialize();
  }

  Future<void> _initialize() async {
    try {
      final driver = _driver = _driverFactory(_spec);
      _bindMetadata();
      await driver.setSenderActive(false);
      if (_closed) return;
      await driver.initialize();
      if (_closed) return;
      _bindMetadata();
      await driver.setVolume(_spec.muted ? 0 : _spec.volume);
      if (_closed) return;
      await driver.setDanmakuVisible(_spec.danmakuVisible);
      if (_closed) return;
      await driver.setSenderActive(_senderActive);
      if (_closed) return;
      _initialized = true;
      notifyListeners();
    } catch (_) {
      _closed = true;
      _detailWorker?.dispose();
      _detailWorker = null;
      _metadataRoom = null;
      await _closeDriver();
      _initialized = false;
      rethrow;
    }
  }

  Future<void> _enqueue(Future<void> Function(MultiLiveRoomDriver) operation) {
    final result = _operations.then((_) async {
      if (_closed) return;
      await initialize();
      final driver = _driver;
      if (!_closed && driver != null) await operation(driver);
    });
    _operations = result.then((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<void>? _settingsFuture;
  Completer<void>? _volumeSetting;
  Completer<void>? _danmakuSetting;

  // Keep at most one pending result per setting plus the native call in flight.
  // Different settings report their own outcomes even when one call fails.
  Future<void> _queueSettings({bool volume = false, bool danmaku = false}) {
    assert(volume != danmaku);
    final completion = volume
        ? _volumeSetting ??= Completer<void>()
        : _danmakuSetting ??= Completer<void>();
    _scheduleSettings();
    return completion.future;
  }

  void _scheduleSettings() {
    if (_settingsFuture != null) return;
    final operation = _enqueue((driver) async {
      while (!_closed && (_volumeSetting != null || _danmakuSetting != null)) {
        final volume = _volumeSetting;
        _volumeSetting = null;
        if (volume != null) {
          await _applySetting(
              volume, () => driver.setVolume(_spec.muted ? 0 : _spec.volume));
        }
        final danmaku = _danmakuSetting;
        _danmakuSetting = null;
        if (danmaku != null) {
          await _applySetting(
              danmaku, () => driver.setDanmakuVisible(_spec.danmakuVisible));
        }
      }
    });
    _settingsFuture = operation;
    operation.then((_) {
      _settingsFuture = null;
      if (_closed) {
        _completePendingSettings();
      } else if (_volumeSetting != null || _danmakuSetting != null) {
        // A caller may queue work between the drain ending and this callback.
        _scheduleSettings();
      }
    }, onError: (Object error, StackTrace stack) {
      _settingsFuture = null;
      // Initialization can fail before the drain starts. Settle both callers.
      _completePendingSettings(error, stack);
    });
  }

  Future<void> _applySetting(
      Completer<void> completion, Future<void> Function() update) async {
    try {
      if (!_closed) await update();
      completion.complete();
    } catch (error, stack) {
      completion.completeError(error, stack);
    }
  }

  void _completePendingSettings([Object? error, StackTrace? stack]) {
    final pending = [_volumeSetting, _danmakuSetting];
    _volumeSetting = null;
    _danmakuSetting = null;
    for (final completion in pending) {
      if (completion == null) continue;
      if (error == null) {
        completion.complete();
      } else {
        completion.completeError(error, stack);
      }
    }
  }

  Future<void> setVolume(double value) {
    if (_closed) return Future<void>.value();
    _spec = _spec.copyWith(
        volume: value.isFinite ? value.clamp(0, 100).toDouble() : _spec.volume);
    notifyListeners();
    return _queueSettings(volume: true);
  }

  Future<void> setMuted(bool muted) {
    if (_closed) return Future<void>.value();
    _spec = _spec.copyWith(muted: muted);
    notifyListeners();
    return _queueSettings(volume: true);
  }

  Future<void> setDanmakuVisible(bool visible) {
    if (_closed) return Future<void>.value();
    _spec = _spec.copyWith(danmakuVisible: visible);
    notifyListeners();
    return _queueSettings(danmaku: true);
  }

  Future<void> setSenderActive(bool active) {
    if (_closed) return Future<void>.value();
    _senderActive = active;
    return _enqueue((driver) => driver.setSenderActive(_senderActive));
  }

  Future<String?> sendDanmaku(String text, {bool Function()? isCurrent}) async {
    if (_closed) return '房间已关闭';
    if (!_senderActive) return '请先选择此房间发送弹幕';
    await initialize();
    if (_closed || !_senderActive || isCurrent?.call() == false) {
      return '发送房间已切换';
    }
    return _driver!.sendDanmaku(text);
  }

  Future<void> close() {
    if (_closeFuture != null) return _closeFuture!;
    _closed = true;
    _completePendingSettings();
    _detailWorker?.dispose();
    _detailWorker = null;
    _metadataRoom = null;
    _initialized = false;
    notifyListeners();
    return _closeFuture = _close();
  }

  Future<void> _close() async {
    try {
      await _initializeFuture;
    } catch (_) {/* failed initialization cleaned up */}
    await _operations;
    await _closeDriver();
  }
}

class _LiveRoomDriver implements MultiLiveRoomDriver {
  _LiveRoomDriver(MultiLiveRoomSpec spec) {
    final site = Sites.allSites[spec.siteId];
    if (site == null) {
      throw ArgumentError.value(spec.siteId, 'siteId', 'Unknown live site');
    }
    _room =
        LiveRoomController(pSite: site, pRoomId: spec.roomId, embedded: true);
  }
  late final LiveRoomController _room;
  @override
  LiveRoomController get room => _room;
  Future<void>? _closeFuture;
  @override
  Future<void> initialize() async {
    _room.onStart();
  }

  @override
  Future<void> setVolume(double volume) => _room.player.setVolume(volume);
  @override
  Future<void> setDanmakuVisible(bool visible) async {
    _room.showDanmakuState.value = visible;
    if (!visible) _room.danmakuController?.clear();
  }

  @override
  Future<void> setSenderActive(bool active) => _room.setSenderActive(active);
  @override
  Future<String?> sendDanmaku(String text) => _room.sendDanmaku(text);
  @override
  Future<void> close() => _closeFuture ??= _room.closeRoom();
}
