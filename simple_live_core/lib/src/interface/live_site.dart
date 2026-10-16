import 'package:simple_live_core/src/model/live_anchor_item.dart';

import '../interface/live_danmaku.dart';
import '../model/live_category_result.dart';
import '../model/live_message.dart';
import '../model/live_play_url.dart';
import '../model/live_room_detail.dart';
import '../model/live_room_status.dart';
import '../common/core_log.dart';
import '../model/live_search_result.dart';

import '../model/live_category.dart';
import '../model/live_play_quality.dart';
import '../model/live_room_item.dart';

class LiveSite {
  /// 站点唯一ID
  String id = "";

  /// 站点名称
  String name = "";

  /// 站点名称
  LiveDanmaku getDanmaku() => LiveDanmaku();

  /// 读取网站的分类
  Future<List<LiveCategory>> getCategores() {
    return Future.value(<LiveCategory>[]);
  }

  /// 搜索直播间
  Future<LiveSearchRoomResult> searchRooms(String keyword, {int page = 1}) {
    return Future.value(
        LiveSearchRoomResult(hasMore: false, items: <LiveRoomItem>[]));
  }

  /// 搜索直播间
  Future<LiveSearchAnchorResult> searchAnchors(String keyword, {int page = 1}) {
    return Future.value(
        LiveSearchAnchorResult(hasMore: false, items: <LiveAnchorItem>[]));
  }

  /// 读取类目下房间
  Future<LiveCategoryResult> getCategoryRooms(LiveSubCategory category,
      {int page = 1}) {
    return Future.value(
        LiveCategoryResult(hasMore: false, items: <LiveRoomItem>[]));
  }

  /// 读取推荐的房间
  Future<LiveCategoryResult> getRecommendRooms({int page = 1}) {
    return Future.value(
        LiveCategoryResult(hasMore: false, items: <LiveRoomItem>[]));
  }

  /// 读取房间详情
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) {
    return Future.value(LiveRoomDetail(
      cover: '',
      online: 0,
      roomId: '',
      status: false,
      title: '',
      url: '',
      userAvatar: '',
      userName: '',
    ));
  }

  /// 读取房间清晰度
  Future<List<LivePlayQuality>> getPlayQualites(
      {required LiveRoomDetail detail}) {
    return Future.value(<LivePlayQuality>[]);
  }

  /// 读取播放链接
  Future<LivePlayUrl> getPlayUrls(
      {required LiveRoomDetail detail, required LivePlayQuality quality}) {
    return Future.value(LivePlayUrl(urls: []));
  }

  /// 查询直播状态
  Future<bool> getLiveStatus({required String roomId}) {
    return Future.value(false);
  }

  /// 查询房间状态（一次拿全：是否直播 + 本场开播时间 / 上次直播时间）
  ///
  /// 默认实现见 [defaultGetRoomStatus]，各平台应按「请求最少」的方式覆写：
  /// - 斗鱼：betard 一次拿到状态 + show_time
  /// - 抖音：详情接口本身就带状态和时间（避免重复请求）
  /// - 虎牙：mp 接口一次拿到 liveStatus + startTime
  /// - B站：登录后用关注列表批量接口拿 record_live_time
  Future<LiveRoomStatus> getRoomStatus({required String roomId}) {
    return defaultGetRoomStatus(this, roomId: roomId);
  }

  /// 读取指定房间的SC
  Future<List<LiveSuperChatMessage>> getSuperChatMessage(
      {required String roomId}) {
    return Future.value([]);
  }
}

/// [LiveSite.getRoomStatus] 的默认实现：查状态，直播中再查详情
///
/// 未开播时拿不到「上次直播时间」，需要平台自己覆写。
Future<LiveRoomStatus> defaultGetRoomStatus(
  LiveSite site, {
  required String roomId,
}) async {
  var isLive = await site.getLiveStatus(roomId: roomId);
  var standardRoomId = roomId;
  String? showTime;
  if (isLive) {
    try {
      var detail = await site.getRoomDetail(roomId: roomId);
      standardRoomId = detail.roomId;
      showTime = detail.showTime;
    } catch (e) {
      CoreLog.error(e);
    }
  }
  return LiveRoomStatus(
    roomId: standardRoomId,
    isLive: isLive,
    startTime: isLive ? showTime : null,
  );
}
