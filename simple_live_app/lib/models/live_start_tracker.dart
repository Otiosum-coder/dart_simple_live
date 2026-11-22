/// 首次观察只建基线；后续可信的未播 → 在播才可能提醒。
class LiveStartTracker {
  final Map<String, _LiveObservation> _observations = {};

  bool observe(
    String id, {
    required bool isLive,
    String? startTime,
    bool querySucceeded = true,
    bool roomNotFound = false,
  }) {
    if (!querySucceeded || roomNotFound) return false;
    final time = int.tryParse(startTime ?? '');
    final session = time != null && time > 0 ? time.toString() : null;
    final previous = _observations[id];
    final offlineCount = isLive ? 0 : (previous?.offlineCount ?? 0) + 1;
    _observations[id] = _LiveObservation(
      isLive: isLive,
      lastSession:
          isLive ? session ?? previous?.lastSession : previous?.lastSession,
      hasObservedLive: isLive || (previous?.hasObservedLive ?? false),
      offlineCount: offlineCount,
    );
    if (previous == null || !isLive || previous.isLive) return false;
    if (session != null && previous.lastSession != null) {
      return session != previous.lastSession;
    }
    // 平台没给场次时，用连续两次成功未播过滤单次状态抖动。
    // 冷启动本来就未播的主播不需要额外确认。
    return !previous.hasObservedLive || previous.offlineCount >= 2;
  }

  void forget(String id) => _observations.remove(id);
  void retain(Set<String> ids) =>
      _observations.removeWhere((id, _) => !ids.contains(id));
  void clear() => _observations.clear();
}

class _LiveObservation {
  final bool isLive;
  final String? lastSession;
  final bool hasObservedLive;
  final int offlineCount;
  const _LiveObservation({
    required this.isLive,
    required this.lastSession,
    required this.hasObservedLive,
    required this.offlineCount,
  });
}
