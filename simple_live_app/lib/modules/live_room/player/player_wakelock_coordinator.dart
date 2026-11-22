import 'package:wakelock_plus/wakelock_plus.dart';

/// Serializes native toggles so closing a room cannot clear another room's lock.
class PlayerWakelockCoordinator {
  PlayerWakelockCoordinator({Future<void> Function(bool)? toggle})
      : _toggle = toggle ?? ((active) => WakelockPlus.toggle(enable: active));
  static final instance = PlayerWakelockCoordinator();
  final Future<void> Function(bool) _toggle;
  final Set<Object> _owners = {};
  Future<void> _pending = Future<void>.value();
  bool? _applied;
  Future<void> setActive(Object owner, bool active) {
    if (active) {
      _owners.add(owner);
    } else {
      _owners.remove(owner);
    }
    final update = _pending.then((_) async {
      final wanted = _owners.isNotEmpty;
      if (_applied == wanted) return;
      await _toggle(wanted);
      _applied = wanted;
    });
    _pending = update.then((_) {}, onError: (Object _, StackTrace __) {});
    return update;
  }
}
