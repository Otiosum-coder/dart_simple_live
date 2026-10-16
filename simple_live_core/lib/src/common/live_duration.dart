/// 开播时间（秒级时间戳）的解析与开播时长格式化，各平台共用。
///
/// 各平台接口里的字段名不一样：
/// - B站：room_info.live_start_time
/// - 斗鱼：data.show_time
/// - 虎牙：data.liveData.startTime
/// - 抖音：data.room.start_time / create_time
///
/// 但取值规则和展示格式是一致的，统一放这里，避免每个平台各写一份。
class LiveDuration {
  LiveDuration._();

  /// 解析秒级时间戳，无效（null、空、非数字、小于等于 0）时返回 null。
  ///
  /// [value] 可以是 int、String 等任意类型，方便直接传入接口原始字段。
  static String? parse(dynamic value) {
    var text = value?.toString().trim() ?? "";
    if (text.isEmpty) {
      return null;
    }
    var timestamp = int.tryParse(text);
    if (timestamp == null || timestamp <= 0) {
      return null;
    }
    return timestamp.toString();
  }

  /// 计算已开播时长，返回 HH:MM:SS；[startTime] 无效时返回 null。
  static String? format(String? startTime) {
    var timestamp = int.tryParse(startTime ?? "");
    if (timestamp == null || timestamp <= 0) {
      return null;
    }
    var durationInSeconds =
        DateTime.now().millisecondsSinceEpoch ~/ 1000 - timestamp;
    // 设备时间与服务器时间有偏差时可能出现负数，兜底为 0
    if (durationInSeconds < 0) {
      durationInSeconds = 0;
    }
    var hours = durationInSeconds ~/ 3600;
    var minutes = (durationInSeconds % 3600) ~/ 60;
    var seconds = durationInSeconds % 60;
    return '${_pad(hours)}:${_pad(minutes)}:${_pad(seconds)}';
  }

  /// 打印统一格式的开播时长日志，例如：虎牙直播间 60066 开播时长: 01:52:26
  ///
  /// [siteName] 传平台名（Bilibili、斗鱼、虎牙、抖音），[startTime] 无效时不打印。
  static void log(String siteName, String roomId, String? startTime) {
    var duration = format(startTime);
    if (duration == null) {
      return;
    }
    print('$siteName直播间 $roomId 开播时长: $duration');
  }

  /// 距现在多久：刚刚 / 12分钟前 / 3小时前 / 3天前 / 2个月前 / 1年前
  /// 用于「上次开播 3 天前」
  static String agoText(String? startTime) {
    var timestamp = int.tryParse(startTime ?? "");
    if (timestamp == null || timestamp <= 0) {
      return "";
    }
    var diff = DateTime.now().millisecondsSinceEpoch ~/ 1000 - timestamp;
    if (diff < 0) {
      diff = 0;
    }
    if (diff < 60) {
      return "刚刚";
    }
    if (diff < 3600) {
      return '${diff ~/ 60}分钟前';
    }
    if (diff < 86400) {
      return '${diff ~/ 3600}小时前';
    }
    if (diff < 86400 * 30) {
      return '${diff ~/ 86400}天前';
    }
    if (diff < 86400 * 365) {
      return '${diff ~/ (86400 * 30)}个月前';
    }
    return '${diff ~/ (86400 * 365)}年前';
  }

  /// 具体时间：今天 16:20 / 昨天 21:35 / 10-10 21:35 / 2024-10-10 21:35
  static String timeText(String? startTime) {
    var timestamp = int.tryParse(startTime ?? "");
    if (timestamp == null || timestamp <= 0) {
      return "";
    }
    var time = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    var now = DateTime.now();
    var today = DateTime(now.year, now.month, now.day);
    var target = DateTime(time.year, time.month, time.day);
    var hhmm = '${_pad(time.hour)}:${_pad(time.minute)}';
    if (target == today) {
      return '今天 $hhmm';
    }
    if (target == today.subtract(const Duration(days: 1))) {
      return '昨天 $hhmm';
    }
    if (time.year == now.year) {
      return '${time.month}-${time.day} $hhmm';
    }
    return '${time.year}-${time.month}-${time.day} $hhmm';
  }

  /// 完整日期时间：2026-10-13 16:06:29
  ///
  /// 和 [timeText] 的区别是不做「今天/昨天」这类相对化，用于需要精确时间的场景。
  static String fullTimeText(String? startTime) {
    var timestamp = int.tryParse(startTime ?? "");
    if (timestamp == null || timestamp <= 0) {
      return "";
    }
    var time = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    return '${time.year}-${_pad(time.month)}-${_pad(time.day)} '
        '${_pad(time.hour)}:${_pad(time.minute)}:${_pad(time.second)}';
  }

  static String _pad(int value) => value.toString().padLeft(2, '0');
}