import 'dart:convert';

class LiveRoomDetail {
  /// 房间ID
  final String roomId;

  /// 房间标题
  final String title;

  /// 封面
  final String cover;

  /// 用户名
  final String userName;

  /// 头像
  final String userAvatar;

  /// 在线
  final int online;

  /// 介绍
  final String? introduction;

  /// 公告
  final String? notice;

  /// 状态
  final bool status;

  /// 附加信息
  final dynamic data;

  /// 弹幕附加信息
  final dynamic danmakuData;

  /// 是否录播
  final bool isRecord;

  /// 链接
  final String url;

  /// 开播时间（秒级时间戳字符串），直播中由各平台填充
  final String? showTime;

  /// 上次直播时间（秒级时间戳字符串），未开播时由各平台填充
  final String? lastLiveTime;

  /// 房间已失效/不存在（旧房间号、主播已注销等）
  final bool roomNotFound;

  LiveRoomDetail({
    required this.roomId,
    required this.title,
    required this.cover,
    required this.userName,
    required this.userAvatar,
    required this.online,
    this.introduction,
    this.notice,
    required this.status,
    this.data,
    this.danmakuData,
    required this.url,
    this.isRecord = false,
    this.showTime,
    this.lastLiveTime,
    this.roomNotFound = false,
  });

  @override
  String toString() {
    return json.encode({
      "roomId": roomId,
      "title": title,
      "cover": cover,
      "userName": userName,
      "userAvatar": userAvatar,
      "online": online,
      "introduction": introduction,
      "notice": notice,
      "status": status,
      "data": data.toString(),
      "danmakuData": danmakuData.toString(),
      "url": url,
      "isRecord": isRecord,
      "showTime": showTime,
      "lastLiveTime": lastLiveTime,
    });
  }
}
