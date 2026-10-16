/// 房间状态：一次查询就能拿全的信息
///
/// 各平台能拿到的字段不一致，取不到的为 null：
/// - 斗鱼：betard 的 show_status / show_time / end_time
/// - 抖音：详情接口的状态 + start_time
/// - 虎牙：mp 接口的 liveStatus + startTime
/// - B站：登录后关注列表接口的 live_status + record_live_time（上次直播结束时间）
class LiveRoomStatus {
  /// 房间号（部分平台会返回标准房间号，例如抖音的 19 位 ID）
  final String roomId;

  /// 是否正在直播
  final bool isLive;

  /// 本场开播时间（秒级时间戳字符串），未开播时为 null
  final String? startTime;

  /// 上次直播时间（秒级时间戳字符串），直播中时为 null
  final String? lastLiveTime;

  /// 房间已失效/不存在（例如旧房间号、主播已注销），区别于「未开播」
  final bool roomNotFound;

  LiveRoomStatus({
    required this.roomId,
    required this.isLive,
    this.startTime,
    this.lastLiveTime,
    this.roomNotFound = false,
  });
}