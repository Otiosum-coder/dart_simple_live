import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:simple_live_core/src/common/convert_helper.dart';
import 'package:simple_live_core/src/common/core_error.dart';
import 'package:simple_live_core/src/common/core_log.dart';
import 'package:simple_live_core/src/common/live_duration.dart';
import 'package:simple_live_core/src/model/live_room_status.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/src/danmaku/bilibili_danmaku.dart';
import 'package:simple_live_core/src/interface/live_danmaku.dart';
import 'package:simple_live_core/src/interface/live_site.dart';
import 'package:simple_live_core/src/model/live_anchor_item.dart';
import 'package:simple_live_core/src/model/live_category.dart';
import 'package:simple_live_core/src/model/live_message.dart';
import 'package:simple_live_core/src/model/live_play_url.dart';
import 'package:simple_live_core/src/model/live_room_item.dart';
import 'package:simple_live_core/src/model/live_search_result.dart';
import 'package:simple_live_core/src/model/live_room_detail.dart';
import 'package:simple_live_core/src/model/live_play_quality.dart';
import 'package:simple_live_core/src/model/live_category_result.dart';

class BiliBiliSite implements LiveSite {
  @override
  String id = "bilibili";

  @override
  String name = "哔哩哔哩直播";

  String cookie = "";
  int userId = 0;

  @override
  LiveDanmaku getDanmaku() => BiliBiliDanmaku();

  static const String kDefaultUserAgent =
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36 Edg/126.0.0.0";
  static const String kDefaultReferer = "https://live.bilibili.com/";

  String buvid3 = "";
  String buvid4 = "";
  String accessId = "";
  Future<Map<String, String>> getHeader() async {
    if (buvid3.isEmpty) {
      var buvidInfo = await getBuvid();
      buvid3 = buvidInfo["b_3"] ?? "";
      buvid4 = buvidInfo["b_4"] ?? "";
    }
    return cookie.isEmpty
        ? {
            "user-agent": kDefaultUserAgent,
            "referer": kDefaultReferer,
            "cookie": 'buvid3=$buvid3;buvid4=$buvid4;',
          }
        : {
            "cookie": cookie.contains("buvid3")
                ? cookie
                : "$cookie;buvid3=$buvid3;buvid4=$buvid4;",
            "user-agent": kDefaultUserAgent,
            "referer": kDefaultReferer,
          };
  }

  @override
  Future<List<LiveCategory>> getCategores() async {
    List<LiveCategory> categories = [];
    var result = await HttpClient.instance.getJson(
      "https://api.live.bilibili.com/room/v1/Area/getList",
      queryParameters: {
        "need_entrance": 1,
        "parent_id": 0,
      },
      header: await getHeader(),
    );
    for (var item in result["data"]) {
      List<LiveSubCategory> subs = [];
      for (var subItem in item["list"]) {
        var subCategory = LiveSubCategory(
          id: subItem["id"].toString(),
          name: asT<String?>(subItem["name"]) ?? "",
          parentId: asT<String?>(subItem["parent_id"]) ?? "",
          pic: "${asT<String?>(subItem["pic"]) ?? ""}@100w.png",
        );
        subs.add(subCategory);
      }
      var category = LiveCategory(
        children: subs,
        id: item["id"].toString(),
        name: asT<String?>(item["name"]) ?? "",
      );
      categories.add(category);
    }
    return categories;
  }

  @override
  Future<LiveCategoryResult> getCategoryRooms(LiveSubCategory category,
      {int page = 1}) async {
    const baseUrl =
        "https://api.live.bilibili.com/xlive/web-interface/v1/second/getList";

    var url =
        "$baseUrl?platform=web&parent_area_id=${category.parentId}&area_id=${category.id}&sort_type=&page=$page&w_webid=${await getAccessId()}";

    var queryParams = await getWbiSign(url);

    var result = await HttpClient.instance.getJson(
      baseUrl,
      queryParameters: queryParams,
      header: await getHeader(),
    );

    // B站接口在风控/参数不对时 data 为 null（历史上直接 result["data"]["has_more"] 会崩）
    var data = result is Map ? result["data"] : null;
    if (data is! Map) {
      var code = result is Map ? result["code"] : null;
      var message = result is Map ? result["message"] : null;
      throw CoreError(
        "B站分区列表获取失败（code=$code, message=$message）。"
        "常见原因：未登录/风控拦截，请在「我的-账号」登录哔哩哔哩后重试",
      );
    }
    var hasMore = data["has_more"] == 1;
    var items = <LiveRoomItem>[];
    for (var item in (data["list"] as List? ?? const [])) {
      var roomItem = LiveRoomItem(
        roomId: item["roomid"].toString(),
        title: item["title"].toString(),
        cover: "${item["cover"]}@400w.jpg",
        userName: item["uname"].toString(),
        online: int.tryParse(item["online"].toString()) ?? 0,
      );
      items.add(roomItem);
    }
    return LiveCategoryResult(hasMore: hasMore, items: items);
  }

  /// 取出 playurl_info.playurl；限定/付费直播、未开播时为 null
  Map? _getPlayurl(dynamic result) {
    var data = result is Map ? result["data"] : null;
    var playurlInfo = data is Map ? data["playurl_info"] : null;
    var playurl = playurlInfo is Map ? playurlInfo["playurl"] : null;
    return playurl is Map ? playurl : null;
  }

  /// 没有播放信息时给出可读原因（B站的付费/大航海限定直播就是这种表现）
  String _noPlayUrlMessage(dynamic result) {
    var data = result is Map ? result["data"] : null;
    if (data is Map) {
      if ((asT<int?>(data["live_status"]) ?? 0) != 1) {
        return "直播间当前未开播";
      }
      if (asT<bool?>(data["encrypted"]) == true ||
          asT<bool?>(data["is_locked"]) == true) {
        return "该直播已加密或受限，无法直接观看";
      }
      return "该直播为付费/大航海限定直播，需要开通大航海后观看";
    }
    return "无法获取直播播放信息";
  }

  List _asList(dynamic value) {
    return value is List ? value : const [];
  }

  /// 从 stream 里取所有可用清晰度
  List _getAcceptQn(Map playurl) {
    var streams = _asList(playurl["stream"]);
    if (streams.isEmpty || streams.first is! Map) {
      return const [];
    }
    var formats = _asList(streams.first["format"]);
    if (formats.isEmpty || formats.first is! Map) {
      return const [];
    }
    var codecs = _asList(formats.first["codec"]);
    if (codecs.isEmpty || codecs.first is! Map) {
      return const [];
    }
    return _asList(codecs.first["accept_qn"]);
  }

  @override
  Future<List<LivePlayQuality>> getPlayQualites(
      {required LiveRoomDetail detail}) async {
    List<LivePlayQuality> qualities = [];
    var result = await _getRoomPlayInfo({
      "room_id": detail.roomId,
      "protocol": "0,1",
      "format": "0,1,2",
      "codec": "0,1",
      "platform": "web",
    });
    // 限定/付费直播时 playurl_info 为 null，这里给出明确原因而不是崩在深链上
    var playurl = _getPlayurl(result);
    if (playurl == null) {
      // 只有「在播 + 未加密 + 未锁定」却拿不到 playurl 才是大航海/付费限定，
      // 用它标记 403，界面据此决定是否盖兜底封面（未开播/加密/网络失败都不该盖）
      var noPlayData = result is Map ? result["data"] : null;
      var paidLimited = noPlayData is Map &&
          (asT<int?>(noPlayData["live_status"]) ?? 0) == 1 &&
          asT<bool?>(noPlayData["encrypted"]) != true &&
          asT<bool?>(noPlayData["is_locked"]) != true;
      throw CoreError(
        _noPlayUrlMessage(result),
        statusCode: paidLimited ? 403 : 0,
      );
    }

    var qualitiesMap = <int, String>{};
    var descs = playurl["g_qn_desc"];
    if (descs is List) {
      for (var item in descs) {
        if (item is! Map) {
          continue;
        }
        qualitiesMap[int.tryParse(item["qn"].toString()) ?? 0] =
            item["desc"].toString();
      }
    }

    for (var item in _getAcceptQn(playurl)) {
      var qualityItem = LivePlayQuality(
        quality: qualitiesMap[item] ?? "未知清晰度",
        data: item,
      );
      qualities.add(qualityItem);
    }
    return qualities;
  }

  /// getRoomPlayInfo 结果短时缓存
  ///
  /// B站这个接口响应极大（十几种清晰度 × 协议 × 格式 × 编码 × 多 CDN），
  /// 而切线路/清晰度、音频↔画面来回切都会重新调用它 —— 缓存 15 秒可省掉重复的整轮请求，
  /// 明显加快「恢复画面」的加载（token 有效期约 1 小时，短时复用完全安全）
  final Map<String, Map<String, dynamic>> _playInfoCache = {};
  final Map<String, DateTime> _playInfoCacheTime = {};

  Future<Map<String, dynamic>> _getRoomPlayInfo(
      Map<String, String> queryParameters) async {
    var key = queryParameters.entries
        .map((e) => "${e.key}=${e.value}")
        .join("&");
    var cached = _playInfoCache[key];
    var cachedTime = _playInfoCacheTime[key];
    if (cached != null &&
        cachedTime != null &&
        DateTime.now().difference(cachedTime).inSeconds < 15) {
      return cached;
    }
    var result = await HttpClient.instance.getJson(
      "https://api.live.bilibili.com/xlive/web-room/v2/index/getRoomPlayInfo",
      queryParameters: queryParameters,
      header: await getHeader(),
    );
    if (result is Map<String, dynamic>) {
      _playInfoCache[key] = result;
      _playInfoCacheTime[key] = DateTime.now();
    }
    return result;
  }

  @override
  Future<LivePlayUrl> getPlayUrls(
      {required LiveRoomDetail detail,
      required LivePlayQuality quality}) async {
    List<String> urls = [];
    var result = await _getRoomPlayInfo({
        "room_id": detail.roomId,
        "protocol": "0,1",
        "format": "0,2",
        "codec": "0",
        "platform": "web",
      "qn": quality.data.toString(),
    });
    var playurl = _getPlayurl(result);
    if (playurl == null) {
      throw CoreError(_noPlayUrlMessage(result));
    }
    var streamList = playurl["stream"];
    for (var streamItem in _asList(streamList)) {
      for (var formatItem in _asList(streamItem["format"])) {
        for (var codecItem in _asList(formatItem["codec"])) {
          var baseUrl = codecItem["base_url"].toString();
          for (var urlItem in _asList(codecItem["url_info"])) {
            urls.add("${urlItem["host"]}$baseUrl${urlItem["extra"]}");
          }
        }
      }
    }
    // 对链接进行排序，包含mcdn的在后
    urls.sort((a, b) {
      if (a.contains("mcdn")) {
        return 1;
      } else {
        return -1;
      }
    });
    return LivePlayUrl(
      urls: urls,
      headers: {
        "referer": "https://live.bilibili.com",
        "user-agent":
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/115.0.0.0 Safari/537.36 Edg/115.0.1901.188"
      },
    );
  }

  @override
  Future<LiveCategoryResult> getRecommendRooms({int page = 1}) async {
    const baseUrl =
        "https://api.live.bilibili.com/xlive/web-interface/v1/second/getListByArea";
    var url = "$baseUrl?platform=web&sort=online&page_size=30&page=$page";

    var queryParams = await getWbiSign(url);

    var result = await HttpClient.instance.getJson(
      baseUrl,
      queryParameters: queryParams,
      header: await getHeader(),
    );

    var hasMore = (result["data"]["list"] as List).isNotEmpty;
    var items = <LiveRoomItem>[];
    for (var item in result["data"]["list"]) {
      var roomItem = LiveRoomItem(
        roomId: item["roomid"].toString(),
        title: item["title"].toString(),
        cover: "${item["cover"]}@400w.jpg",
        userName: item["uname"].toString(),
        online: int.tryParse(item["online"].toString()) ?? 0,
      );
      items.add(roomItem);
    }
    return LiveCategoryResult(hasMore: hasMore, items: items);
  }

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    var roomInfo = await getRoomInfo(roomId: roomId);
    // 房间不存在时 B站不返回 room_info
    if (roomInfo["room_info"] is! Map) {
      return LiveRoomDetail(
        roomId: roomId,
        title: "",
        cover: "",
        userName: "",
        userAvatar: "",
        online: 0,
        status: false,
        url: "https://live.bilibili.com/$roomId",
        roomNotFound: true,
      );
    }
    var realRoomId = roomInfo["room_info"]["room_id"].toString();

    const danmuInfoBaseUrl =
        "https://api.live.bilibili.com/xlive/web-room/v1/index/getDanmuInfo";
    var danmuInfoUrl = "$danmuInfoBaseUrl?id=$realRoomId";
    var queryParams = await getWbiSign(danmuInfoUrl);
    var roomDanmakuResult = await HttpClient.instance.getJson(
      danmuInfoBaseUrl,
      queryParameters: queryParams,
      header: await getHeader(),
    );
    List<String> serverHosts = (roomDanmakuResult["data"]["host_list"] as List)
        .map<String>((e) => e["host"].toString())
        .toList();

    //var buvid = await getBuvid();
    // 从 roomInfo 中提取 live_start_time（秒级时间戳）
    String? liveStartTime =
        LiveDuration.parse(roomInfo["room_info"]?["live_start_time"]);
    var isLive =
        (asT<int?>(roomInfo["room_info"]?["live_status"]) ?? 0) == 1;
    if (isLive) {
      LiveDuration.log("Bilibili", roomId, liveStartTime);
    }

    // B站公开接口在未开播时会把 live_start_time 清零，
    // 只能从「关注列表」批量缓存里取上次直播时间（需要登录）
    String? lastLiveTime;
    if (!isLive && cookie.isNotEmpty) {
      lastLiveTime = _followingCache?[realRoomId]?.lastLiveTime ??
          _followingCache?[roomId]?.lastLiveTime;
    }

    // 封面：部分限定直播没有 cover，回落到 keyframe / background
    var cover = roomInfo["room_info"]?["cover"]?.toString() ?? "";
    if (cover.isEmpty) {
      cover = roomInfo["room_info"]?["keyframe"]?.toString() ?? "";
    }
    if (cover.isEmpty) {
      cover = roomInfo["room_info"]?["background"]?.toString() ?? "";
    }

    return LiveRoomDetail(
      roomId: realRoomId,
      title: roomInfo["room_info"]["title"].toString(),
      cover: cover,
      userName: roomInfo["anchor_info"]["base_info"]["uname"].toString(),
      userAvatar: "${roomInfo["anchor_info"]["base_info"]["face"]}@100w.jpg",
      online: asT<int?>(roomInfo["room_info"]["online"]) ?? 0,
      status: isLive,
      url: "https://live.bilibili.com/$roomId",
      introduction: roomInfo["room_info"]["description"].toString(),
      notice: "",
      danmakuData: BiliBiliDanmakuArgs(
        roomId: int.tryParse(realRoomId) ?? 0,
        uid: userId,
        token: roomDanmakuResult["data"]["token"].toString(),
        serverHost: serverHosts.isNotEmpty
            ? serverHosts.first
            : "broadcastlv.chat.bilibili.com",
        buvid: buvid3,
        cookie: cookie,
      ),
      showTime: isLive ? liveStartTime : null,
      lastLiveTime: lastLiveTime,
    );
  }

  Future<Map<String, dynamic>> getRoomInfo({required String roomId}) async {
    var url =
        "https://api.live.bilibili.com/xlive/web-room/v1/index/getInfoByRoom?room_id=$roomId";
    var queryParams = await getWbiSign(url);
    var result = await HttpClient.instance.getJson(
      "https://api.live.bilibili.com/xlive/web-room/v1/index/getInfoByRoom",
      queryParameters: queryParams,
      header: await getHeader(),
    );
    print("【B站接口返回】roomId=$roomId, result=$result");
    return result["data"];
  }

  @override
  Future<LiveSearchRoomResult> searchRooms(String keyword,
      {int page = 1}) async {
    var result = await HttpClient.instance.getJson(
      "https://api.bilibili.com/x/web-interface/search/type?context=&search_type=live&cover_type=user_cover",
      queryParameters: {
        "order": "",
        "keyword": keyword,
        "category_id": "",
        "__refresh__": "",
        "_extra": "",
        "highlight": 0,
        "single_column": 0,
        "page": page
      },
      header: await getHeader(),
    );

    var items = <LiveRoomItem>[];
    for (var item in result["data"]["result"]["live_room"] ?? []) {
      var title = item["title"].toString();
      //移除title中的<em></em>标签
      title = title.replaceAll(RegExp(r"<.*?em.*?>"), "");
      var roomItem = LiveRoomItem(
        roomId: item["roomid"].toString(),
        title: title,
        cover: "https:${item["cover"]}@400w.jpg",
        userName: item["uname"].toString(),
        online: int.tryParse(item["online"].toString()) ?? 0,
      );
      items.add(roomItem);
    }
    return LiveSearchRoomResult(hasMore: items.length >= 40, items: items);
  }

  @override
  Future<LiveSearchAnchorResult> searchAnchors(String keyword,
      {int page = 1}) async {
    var result = await HttpClient.instance.getJson(
      "https://api.bilibili.com/x/web-interface/search/type?context=&search_type=live_user&cover_type=user_cover",
      queryParameters: {
        "order": "",
        "keyword": keyword,
        "category_id": "",
        "__refresh__": "",
        "_extra": "",
        "highlight": 0,
        "single_column": 0,
        "page": page
      },
      header: await getHeader(),
    );

    var items = <LiveAnchorItem>[];
    for (var item in result["data"]["result"] ?? []) {
      var uname = item["uname"].toString();
      //移除title中的<em></em>标签
      uname = uname.replaceAll(RegExp(r"<.*?em.*?>"), "");
      var anchorItem = LiveAnchorItem(
        roomId: item["roomid"].toString(),
        avatar: "https:${item["uface"]}@400w.jpg",
        userName: uname,
        liveStatus: item["is_live"],
      );
      items.add(anchorItem);
    }
    return LiveSearchAnchorResult(hasMore: items.length >= 40, items: items);
  }

  @override
  Future<bool> getLiveStatus({required String roomId}) async {
    var result = await HttpClient.instance.getJson(
      "https://api.live.bilibili.com/room/v1/Room/get_info",
      queryParameters: {
        "room_id": roomId,
      },
      header: await getHeader(),
    );
    if (asT<int?>(result["code"]) != 0) {
      return false;
    }
    var data = result["data"];
    return data is Map && (asT<int?>(data["live_status"]) ?? 0) == 1;
  }

  /// 关注列表接口每页数量（接口上限就是 10）
  static const int followingPageSize = 10;

  /// 每轮刷新「同步等待」的浅层页数：保证首屏尽快有数据
  static const int followingFastPages = 6;

  /// 一个缓存窗口内最多扫多少页。
  /// 取足够大，让整份关注列表在一个窗口内都能扫到（命中全部目标会提前停），
  /// 这样「刚下播」的主播很快就能拿到 record_live_time。
  static const int followingMaxScanPages = 120;

  /// 缓存有效期（分钟）。
  ///
  /// 「上次直播」是慢变量：而且主播在播时我们已经把开播时间写进了缓存
  /// （见 [getRoomStatus]），刚下播也能立刻显示，所以窗口可以放宽，
  /// 把后台扫描频率降到 1/3。直播状态不受影响，仍然每次实时查询。
  static const int followingCacheMinutes = 30;

  /// 持久化缓存的最大可用时长（小时），超过则丢弃
  static const int followingCacheMaxAgeHours = 24;

  Map<String, LiveRoomStatus>? _followingCache;
  DateTime? _followingCacheTime;
  /// 浅层刷新断点（每个缓存窗口从第 1 页开始）
  int _scanPage = 1;
  /// 本窗口已扫页数（用于控制每窗口的请求预算）
  int _scannedPages = 0;
  int _totalPage = 0;
  /// 深层补齐游标：跨窗口单调前进（到末尾后回卷），
  /// 这样关注列表排名靠后的目标也能在几个窗口内被找到
  int _deepScanPage = 1;
  /// 本轮还没匹配到的目标房间号
  Set<String> _missingTargets = {};
  bool _scanning = false;

  @override
  Future<LiveRoomStatus> getRoomStatus({required String roomId}) async {
    // 关注列表批量缓存只用来提供「上次直播」时间：
    // B站公开接口在未开播时会把 live_start_time 清零，只有登录后的
    // 关注列表接口能拿到 record_live_time。
    // 直播状态则每次实时查询，避免用缓存导致「已经下播却还显示直播中」。
    LiveRoomStatus? cached;
    if (cookie.isNotEmpty) {
      cached = _followingCache?[roomId];
    }
    try {
      var result = await HttpClient.instance.getJson(
        "https://api.live.bilibili.com/room/v1/Room/get_info",
        queryParameters: {"room_id": roomId},
        header: await getHeader(),
      );
      if (asT<int?>(result["code"]) != 0) {
        // B站对不存在的房间返回 code=1「未找到该房间」
        return LiveRoomStatus(
          roomId: roomId,
          isLive: false,
          roomNotFound: true,
        );
      }
      var data = result["data"];
      var isLive = data is Map && (asT<int?>(data["live_status"]) ?? 0) == 1;
      if (!isLive) {
        var lastLiveTime = cached?.lastLiveTime;
        if (lastLiveTime == null && cached?.isLive == true) {
          // 缓存是在主播「还在播」时扫到的（那时 record_live_time 为 0），
          // 现在他已经下播了：后台补扫一次，把这个房间的上次直播时间补上
          _scheduleRefreshRoom(roomId);
        }
        // 未开播：时间取批量缓存（拿不到就是 null，不显示）
        return LiveRoomStatus(
          roomId: roomId,
          isLive: false,
          lastLiveTime: lastLiveTime,
        );
      }
      // 直播中：开播时间只有详情接口有，失败时重试一次
      var standardRoomId = roomId;
      String? startTime;
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          var detail = await getRoomDetail(roomId: roomId);
          standardRoomId = detail.roomId;
          startTime = detail.showTime;
          break;
        } catch (e) {
          CoreLog.error(e);
          if (attempt == 0) {
            await Future.delayed(const Duration(milliseconds: 300));
          }
        }
      }
      if (startTime != null && startTime != "0") {
        // 记住本次观察到的开播时间：B站 关注列表接口有延迟，
        // 主播刚下播而列表还没更新时，用它兜底显示「上次直播」
        _followingCache ??= {};
        _followingCache![roomId] = LiveRoomStatus(
          roomId: roomId,
          isLive: true,
          startTime: startTime,
          lastLiveTime: startTime,
        );
      }
      return LiveRoomStatus(
        roomId: standardRoomId,
        isLive: true,
        startTime: startTime,
      );
    } catch (e) {
      CoreLog.error(e);
      // 查询失败时退回缓存（可能过期，但比没有数据好）
      if (cached != null) {
        return cached;
      }
      return LiveRoomStatus(roomId: roomId, isLive: false);
    }
  }

  /// 目标驱动预取：只关心 [roomIds] 这些房间
  ///
  /// 先同步扫 [followingFastPages] 页保证首屏有数据，剩下的目标在后台继续补齐；
  /// 一个缓存窗口内最多扫 [followingMaxScanPages] 页，避免关注数很多时请求过多。
  Future<void> primeFollowingStatus(List<String> roomIds) async {
    if (cookie.isEmpty || roomIds.isEmpty) {
      return;
    }
    _prepareTargets(roomIds);
    if (_missingTargets.isEmpty || _scannedPages >= followingMaxScanPages) {
      return;
    }
    await _scanPages(followingFastPages);
    if (_missingTargets.isNotEmpty && _scannedPages < followingMaxScanPages) {
      // 剩下的在后台按深层游标继续补齐，不阻塞关注刷新
      _scanPages(followingMaxScanPages - _scannedPages, deep: true).ignore();
    }
  }

  /// 准备本轮要匹配的目标集合；缓存窗口过期时从第 1 页重扫（旧值先留着显示）
  void _prepareTargets(List<String> roomIds) {
    var time = _followingCacheTime;
    var expired = time == null ||
        DateTime.now().difference(time).inMinutes >= followingCacheMinutes;
    if (expired) {
      _scanPage = 1;
      _scannedPages = 0;
      // 窗口过期：已缓存的目标也要重扫一遍刷新时间
      _missingTargets = roomIds.toSet();
    } else {
      _missingTargets = {
        ..._missingTargets,
        ...roomIds.where((id) => !(_followingCache?.containsKey(id) ?? false)),
      };
    }
    _followingCache ??= {};
    _followingCacheTime = DateTime.now();
  }

  /// 针对某个房间触发一次后台补扫（用于补上「刚刚下播」的上次直播时间）
  void _scheduleRefreshRoom(String roomId) {
    if (cookie.isEmpty || _missingTargets.contains(roomId)) {
      return;
    }
    _missingTargets.add(roomId);
    if (_scanning) {
      // 已有扫描在跑，它会把新目标一起找掉
      return;
    }
    CoreLog.d('B站补扫：' + roomId);
    // 补扫不受「本窗口已扫页数」限制，否则窗口预算用完后永远补不上
    _scanPages(followingMaxScanPages, deep: true, ignoreBudget: true).ignore();
  }

  /// 从断点继续扫描最多 [pages] 页，命中全部目标或扫完就停
  ///
  /// [deep] = true 时使用跨窗口单调前进的深层游标（到末尾回卷），
  /// 用于把关注列表排名靠后的目标也逐步补上。
  Future<void> _scanPages(int pages,
      {bool deep = false, bool ignoreBudget = false}) async {
    if (_scanning || pages <= 0) {
      return;
    }
    _scanning = true;
    try {
      var header = await getHeader();
      var scanned = 0;
      while (scanned < pages &&
          _missingTargets.isNotEmpty &&
          (ignoreBudget || _scannedPages < followingMaxScanPages)) {
        var page = deep ? _deepScanPage : _scanPage;
        var result = await _fetchFollowingPage(page, header);
        scanned++;
        _scannedPages++;
        if (result != null) {
          var data = result["data"];
          _collectFollowingPage(data, _followingCache!);
          if (data is Map) {
            var total = int.tryParse(data["totalPage"]?.toString() ?? "") ?? 0;
            if (total > 0) {
              _totalPage = total;
            }
          }
          _missingTargets.removeWhere((id) => _followingCache!.containsKey(id));
        }
        if (deep) {
          _deepScanPage++;
          if (_totalPage > 0 && _deepScanPage > _totalPage) {
            // 深层游标回卷，下一轮从第 1 页重新找
            _deepScanPage = 1;
          }
        } else {
          _scanPage++;
          if (_totalPage > 0 && _scanPage > _totalPage) {
            // 浅层扫到底：剩下的目标不在你的 B站关注列表里
            _missingTargets = {};
            break;
          }
        }
      }
      CoreLog.d('B站关注列表缓存：${_followingCache!.length} 个房间，本轮扫 $scanned 页'
          '（${deep ? "深层游标" : "浅层"} 至第 ${deep ? _deepScanPage : _scanPage} 页）');
    } catch (e) {
      CoreLog.error(e);
    } finally {
      _scanning = false;
    }
  }

  /// 导出缓存，供宿主持久化（例如存到本地配置，冷启动即可用）
  String exportFollowingCacheJson() {
    var rooms = <String, dynamic>{};
    _followingCache?.forEach((key, value) {
      rooms[key] = {
        "live": value.isLive,
        "start": value.startTime,
        "last": value.lastLiveTime,
      };
    });
    return json.encode({
      "time": DateTime.now().millisecondsSinceEpoch,
      "scanPage": _scanPage,
      "deepScanPage": _deepScanPage,
      "scannedPages": _scannedPages,
      "totalPage": _totalPage,
      "rooms": rooms,
    });
  }

  /// 导入缓存（宿主启动时调用）；超过 [followingCacheMaxAgeHours] 的丢弃
  void importFollowingCacheJson(String value) {
    try {
      var decoded = json.decode(value);
      if (decoded is! Map) {
        return;
      }
      var time = int.tryParse(decoded["time"]?.toString() ?? "") ?? 0;
      if (time <= 0 ||
          DateTime.now().millisecondsSinceEpoch - time >
              followingCacheMaxAgeHours * 3600 * 1000) {
        return;
      }
      var rooms = decoded["rooms"];
      if (rooms is! Map) {
        return;
      }
      var map = <String, LiveRoomStatus>{};
      rooms.forEach((key, item) {
        if (item is! Map) {
          return;
        }
        var id = key.toString();
        map[id] = LiveRoomStatus(
          roomId: id,
          isLive: item["live"] == true,
          startTime: item["start"]?.toString(),
          lastLiveTime: item["last"]?.toString(),
        );
      });
      _followingCache = map;
      _followingCacheTime = DateTime.fromMillisecondsSinceEpoch(time);
      _scanPage = int.tryParse(decoded["scanPage"]?.toString() ?? "") ?? 1;
      _deepScanPage =
          int.tryParse(decoded["deepScanPage"]?.toString() ?? "") ?? 1;
      _scannedPages =
          int.tryParse(decoded["scannedPages"]?.toString() ?? "") ?? 0;
      _totalPage = int.tryParse(decoded["totalPage"]?.toString() ?? "") ?? 0;
      CoreLog.d('B站关注列表缓存已恢复：${map.length} 个房间');
    } catch (e) {
      CoreLog.error(e);
    }
  }

  Future<Map?> _fetchFollowingPage(int page, Map<String, String> header) async {
    try {
      var res = await HttpClient.instance.getJson(
        "https://api.live.bilibili.com/xlive/web-ucenter/user/following",
        queryParameters: {
          "page": page,
          "page_size": followingPageSize,
          "ignoreRecord": 1,
          "hit_ab": true,
        },
        header: header,
      );
      var result = res is String ? json.decode(res) : res;
      if (result is! Map || result["code"] != 0) {
        return null;
      }
      return result;
    } catch (e) {
      CoreLog.error(e);
      return null;
    }
  }

  void _collectFollowingPage(dynamic data, Map<String, LiveRoomStatus> map) {
    if (data is! Map) {
      return;
    }
    var list = data["list"];
    if (list is! List) {
      return;
    }
    for (var item in list) {
      if (item is! Map) {
        continue;
      }
      var roomId = item["roomid"]?.toString() ?? "";
      if (roomId.isEmpty) {
        continue;
      }
      var isLive = item["live_status"] == 1;
      map[roomId] = LiveRoomStatus(
        roomId: roomId,
        isLive: isLive,
        lastLiveTime:
            isLive ? null : LiveDuration.parse(item["record_live_time"]),
      );
    }
  }

  @override
  Future<List<LiveSuperChatMessage>> getSuperChatMessage(
      {required String roomId}) async {
    var result = await HttpClient.instance.getJson(
      "https://api.live.bilibili.com/av/v1/SuperChat/getMessageList",
      queryParameters: {
        "room_id": roomId,
      },
      header: await getHeader(),
    );
    List<LiveSuperChatMessage> ls = [];
    for (var item in result["data"]?["list"] ?? []) {
      var message = LiveSuperChatMessage(
        backgroundBottomColor: item["background_bottom_color"].toString(),
        backgroundColor: item["background_color"].toString(),
        endTime: DateTime.fromMillisecondsSinceEpoch(
          item["end_time"] * 1000,
        ),
        face: "${item["user_info"]["face"]}@200w.jpg",
        message: item["message"].toString(),
        price: item["price"],
        startTime: DateTime.fromMillisecondsSinceEpoch(
          item["start_time"] * 1000,
        ),
        userName: item["user_info"]["uname"].toString(),
      );
      ls.add(message);
    }
    return ls;
  }

  /// 获取 buvid3 和 buvid4
  /// 返回buvid3和buvid4
  /// ``` json
  /// {
  ///   "b_3": "buvid3",
  ///   "b_4": "buvid4",
  /// }
  /// ```
  Future<Map> getBuvid() async {
    try {
      if (cookie.contains("buvid3")) {
        return {
          "b_3": RegExp(r"buvid3=(.*?);").firstMatch(cookie)?.group(1) ?? "",
          "b_4": RegExp(r"buvid4=(.*?);").firstMatch(cookie)?.group(1) ?? "",
        };
      }

      var result = await HttpClient.instance.getJson(
        "https://api.bilibili.com/x/frontend/finger/spi",
        queryParameters: {},
        header: {
          "user-agent": kDefaultUserAgent,
          "referer": kDefaultReferer,
          "cookie": cookie,
        },
      );
      return result["data"];
    } catch (e) {
      return {
        "b_3": "",
        "b_4": "",
      };
    }
  }

  static String kImgKey = '';
  static String kSubKey = '';
  static const List<int> mixinKeyEncTab = [
    46,
    47,
    18,
    2,
    53,
    8,
    23,
    32,
    15,
    50,
    10,
    31,
    58,
    3,
    45,
    35,
    27,
    43,
    5,
    49,
    33,
    9,
    42,
    19,
    29,
    28,
    14,
    39,
    12,
    38,
    41,
    13,
    37,
    48,
    7,
    16,
    24,
    55,
    40,
    61,
    26,
    17,
    0,
    1,
    60,
    51,
    30,
    4,
    22,
    25,
    54,
    21,
    56,
    59,
    6,
    63,
    57,
    62,
    11,
    36,
    20,
    34,
    44,
    52
  ];
  Future<(String, String)> getWbiKeys() async {
    if (kImgKey.isNotEmpty && kSubKey.isNotEmpty) {
      return (kImgKey, kSubKey);
    }
    // 获取最新的 img_key 和 sub_key
    var resp = await HttpClient.instance.getJson(
      'https://api.bilibili.com/x/web-interface/nav',
      header: await getHeader(),
    );

    var imgUrl = resp["data"]["wbi_img"]["img_url"].toString();
    var subUrl = resp["data"]["wbi_img"]["sub_url"].toString();
    var imgKey = imgUrl.substring(imgUrl.lastIndexOf('/') + 1).split('.').first;
    var subKey = subUrl.substring(subUrl.lastIndexOf('/') + 1).split('.').first;

    kImgKey = imgKey;
    kSubKey = subKey;

    return (imgKey, subKey);
  }

  String getMixinKey(String origin) {
    // 对 imgKey 和 subKey 进行字符顺序打乱编码
    return mixinKeyEncTab.fold("", (s, i) => s + origin[i]).substring(0, 32);
  }

  Future<Map<String, String>> getWbiSign(String url) async {
    var (imgKey, subKey) = await getWbiKeys();

    // 为请求参数进行 wbi 签名
    var mixinKey = getMixinKey(imgKey + subKey);
    var currentTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    var queryParams = Map<String, String>.from(Uri.parse(url).queryParameters);

    queryParams["wts"] = currentTime.toString(); // 添加 wts 字段

    //按照 key 重排参数
    Map<String, String> map = {};
    var sortedKeys = queryParams.keys.toList()..sort();
    for (var key in sortedKeys) {
      var value = queryParams[key]!;
      // 过滤 value 中的 "!'()*" 字符
      map[key] = value
          .toString()
          .split('')
          .where((c) => "!'()*".contains(c) == false)
          .join('');
    }

    var query = map.keys
        .map((key) => "$key=${Uri.encodeQueryComponent(map[key]!)}")
        .join("&");
    var wbiSign = md5.convert(utf8.encode("$query$mixinKey")).toString();
    queryParams["w_rid"] = wbiSign;
    return queryParams;
  }

  Future<String> getAccessId() async {
    if (accessId.isNotEmpty) {
      return accessId;
    }

    // 获取 access_id
    var resp = await HttpClient.instance.getText(
      "https://live.bilibili.com/lol",
      queryParameters: {},
      header: await getHeader(),
    );
    var id = RegExp(r'"access_id":"(.*?)"')
        .firstMatch(resp)
        ?.group(1)
        ?.replaceAll("\\", "");
    accessId = id ?? "";
    return accessId;
  }
}