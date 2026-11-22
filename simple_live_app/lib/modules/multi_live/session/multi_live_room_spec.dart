/// Credential-free, immutable settings for one independently owned room.
class MultiLiveRoomSpec {
  const MultiLiveRoomSpec(
      {required this.siteId,
      required this.roomId,
      this.title,
      this.streamerName,
      this.liveTitle,
      this.volume = 100,
      this.muted = false,
      this.danmakuVisible = true});
  final String siteId;
  final String roomId;

  /// Legacy display text of unknown origin; never infer a streamer name from it.
  final String? title;
  final String? streamerName;
  final String? liveTitle;
  String get displayName => streamerName?.trim().isNotEmpty == true
      ? streamerName!.trim()
      : '房间 $roomId · 主播名待加载';
  final double volume;
  final bool muted;
  final bool danmakuVisible;
  String get roomKey => '$siteId:$roomId';
  MultiLiveRoomSpec copyWith(
          {String? siteId,
          String? roomId,
          String? title,
          String? streamerName,
          String? liveTitle,
          double? volume,
          bool? muted,
          bool? danmakuVisible}) =>
      MultiLiveRoomSpec(
          siteId: siteId ?? this.siteId,
          roomId: roomId ?? this.roomId,
          title: title ?? this.title,
          streamerName: streamerName ?? this.streamerName,
          liveTitle: liveTitle ?? this.liveTitle,
          volume: volume ?? this.volume,
          muted: muted ?? this.muted,
          danmakuVisible: danmakuVisible ?? this.danmakuVisible);
  Map<String, Object?> toJson() => {
        'siteId': siteId,
        'roomId': roomId,
        if (title != null) 'title': title,
        if (streamerName != null) 'streamerName': streamerName,
        if (liveTitle != null) 'liveTitle': liveTitle,
        'volume': _volume(volume),
        'muted': muted,
        'danmakuVisible': danmakuVisible
      };
  static double _volume(double value) =>
      value.isFinite ? value.clamp(0, 100).toDouble() : 100;
  static MultiLiveRoomSpec? tryFromJson(Object? value) {
    if (value is! Map) return null;
    final site = value['siteId'];
    final room = value['roomId'];
    if (site is! String ||
        site.trim().isEmpty ||
        room is! String ||
        room.trim().isEmpty) {
      return null;
    }
    final volume = value['volume'];
    return MultiLiveRoomSpec(
        siteId: site,
        roomId: room,
        title: value['title'] is String ? value['title'] as String : null,
        streamerName: value['streamerName'] is String
            ? value['streamerName'] as String
            : null,
        liveTitle:
            value['liveTitle'] is String ? value['liveTitle'] as String : null,
        volume: volume is num ? _volume(volume.toDouble()) : 100,
        muted: value['muted'] is bool ? value['muted'] as bool : false,
        danmakuVisible: value['danmakuVisible'] is bool
            ? value['danmakuVisible'] as bool
            : true);
  }
}
