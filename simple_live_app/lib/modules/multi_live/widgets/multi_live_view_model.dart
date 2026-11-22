import 'package:flutter/widgets.dart';
import '../layout/multi_live_layout.dart';
export '../layout/multi_live_layout.dart';

/// Presentation only. The host owns all sessions, capacity, storage and cleanup.
abstract class MultiLiveViewModel implements Listenable {
  List<MultiLiveTileData> get rooms;
  MultiLiveLayoutNode? get layout;
  String? get selectedRoomId;
  String? get maximizedRoomId;
  int get maxRooms;
  bool get busy;
  bool get allMuted;
  WidgetBuilder? get selectedRoomChatBuilder;
  Future<void> addRoom();
  Future<void> replaceRoom(String id);
  Future<void> closeRoom(String id);
  Future<void> setVolume(String id, double volume);
  Future<void> toggleMute(String id);
  Future<void> setAllMuted(bool muted);
  void selectRoom(String id);
  void toggleDanmaku(String id);
  void maximizeRoom(String? id);
  void setPreset(MultiLiveLayoutPreset preset);
  void resizeSplit(String nodeId, double ratio);
  void swapRooms(String sourceId, String targetId);
}

@immutable
class MultiLiveTileData {
  const MultiLiveTileData(
      {required this.id,
      this.title = '',
      this.subtitle = '',
      required this.volume,
      required this.muted,
      required this.danmakuVisible,
      required this.bodyBuilder,
      this.settingsBuilder});
  final String id;
  final String title;
  final String subtitle;
  final double volume;
  final bool muted;
  final bool danmakuVisible;

  /// Cached by stable room id. Return a reactive room widget that observes its
  /// own session; changing layout/selection never reconstructs this builder.
  final WidgetBuilder bodyBuilder;
  final WidgetBuilder? settingsBuilder;
  String get displayTitle => title.isEmpty ? id : title;
}
