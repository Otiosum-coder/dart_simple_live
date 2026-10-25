import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:simple_live_core/src/common/core_error.dart';
import 'package:simple_live_core/src/common/core_log.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/src/common/live_duration.dart';
import 'package:simple_live_core/src/danmaku/douyu_danmaku.dart';
import 'package:simple_live_core/src/interface/live_danmaku.dart';
import 'package:simple_live_core/src/interface/live_site.dart';
import 'package:simple_live_core/src/model/live_anchor_item.dart';
import 'package:simple_live_core/src/model/live_category.dart';
import 'package:simple_live_core/src/model/live_message.dart';
import 'package:simple_live_core/src/model/live_play_url.dart';
import 'package:simple_live_core/src/model/live_room_item.dart';
import 'package:simple_live_core/src/model/live_search_result.dart';
import 'package:simple_live_core/src/model/live_room_detail.dart';
import 'package:simple_live_core/src/model/live_room_status.dart';
import 'package:simple_live_core/src/model/live_play_quality.dart';
import 'package:simple_live_core/src/model/live_category_result.dart';
import 'package:html_unescape/html_unescape.dart';
import 'package:simple_live_core/src/scripts/douyu_sign.dart';

class DouyuSite implements LiveSite {
  @override
  String id = "douyu";

  @override
  String name = "斗鱼直播";

  @override
  LiveDanmaku getDanmaku() => DouyuDanmaku();

  /// cookie 里的中文/URL 编码字段
  String _decodeCookieValue(String value) {
    try {
      return Uri.decodeComponent(value);
    } catch (e) {
      return value;
    }
  }

  /// 从登录 cookie 里取一个字段
  String _cookieValue(String key) {
    for (var part in cookie.split(';')) {
      var index = part.indexOf('=');
      if (index > 0 && part.substring(0, index).trim() == key) {
        return part.substring(index + 1).trim();
      }
    }
    return "";
  }

  /// 设备 id：优先 acf_did，回退 dy_did，再回退 acf_devid
  String _resolveDevid() {
    for (var key in ["acf_did", "dy_did", "acf_devid"]) {
      var value = _cookieValue(key);
      if (value.isNotEmpty) {
        return value;
      }
    }
    return "";
  }

  /// 斗鱼 2026-09-21 起对未登录用户限制最高画质：原画 / 蓝光4M 只能看 10 分钟。
  /// 登录态必须透传到各接口，尤其是 getH5Play —— 服务端按登录态决定下发的清晰度与 token。
  static const String kUserAgent =
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36 Edg/114.0.1823.43";

  /// 用户登录后的 Cookie，为空表示未登录
  String cookie = "";

  /// 是否已登录
  bool get isLoggedIn => cookie.isNotEmpty;

  /// 统一构造请求头，登录后自动带上 Cookie
  ///
  /// [referer] 不传时使用斗鱼首页；[extraCookie] 用于附加接口自身需要的设备标识
  /// （例如搜索接口的 dy_did/acf_did）。
  Map<String, String> requestHeaders({String? referer, String? extraCookie}) {
    var headers = <String, String>{
      'referer': referer ?? 'https://www.douyu.com/',
      'user-agent': kUserAgent,
    };
    var cookies = <String>[
      if (extraCookie != null && extraCookie.isNotEmpty) extraCookie,
      if (cookie.isNotEmpty) cookie,
    ];
    if (cookies.isNotEmpty) {
      headers['cookie'] = cookies.join(';');
    }
    return headers;
  }

  @override
  Future<List<LiveCategory>> getCategores() async {
    List<LiveCategory> categories = [];
    var result = await HttpClient.instance.getJson(
      "https://m.douyu.com/api/cate/list",
      header: requestHeaders(referer: "https://m.douyu.com/"),
    );
    var subCateList = result["data"]["cate2Info"] as List;
    for (var item in result["data"]["cate1Info"]) {
      var cate1Id = item["cate1Id"];
      var cate1Name = item["cate1Name"];
      List<LiveSubCategory> subCategories = [];
      subCateList.where((x) => x["cate1Id"] == cate1Id).forEach((element) {
        subCategories.add(
          LiveSubCategory(
            pic: element["icon"],
            id: element["cate2Id"].toString(),
            parentId: cate1Id.toString(),
            name: element["cate2Name"].toString(),
          ),
        );
      });
      categories.add(
        LiveCategory(
          id: cate1Id.toString(),
          name: cate1Name.toString(),
          children: subCategories,
        ),
      );
    }
    // 根据ID排序
    categories.sort((a, b) => int.parse(a.id).compareTo(int.parse(b.id)));

    return categories;
  }

  @override
  Future<LiveCategoryResult> getCategoryRooms(
    LiveSubCategory category, {
    int page = 1,
  }) async {
    var result = await HttpClient.instance.getJson(
      "https://www.douyu.com/gapi/rkc/directory/mixList/2_${category.id}/$page",
      queryParameters: {},
      header: requestHeaders(),
    );

    var items = <LiveRoomItem>[];
    for (var item in result['data']['rl']) {
      if (item["type"] != 1) {
        continue;
      }
      var roomItem = LiveRoomItem(
        cover: item['rs16'].toString(),
        online: item['ol'],
        roomId: item['rid'].toString(),
        title: item['rn'].toString(),
        userName: item['nn'].toString(),
      );
      items.add(roomItem);
    }
    var hasMore = page < result['data']['pgcnt'];
    return LiveCategoryResult(hasMore: hasMore, items: items);
  }

  /// 重新生成取流签名参数。
  ///
  /// 斗鱼的取流参数（[LiveRoomDetail.data]）是「swf_api/homeH5Enc 的 crptext + 当前时间戳」
  /// 算出来的签名，带有效期。过期后 getH5Play 仍然返回 200，但拿到的地址被 CDN 连上就断
  /// （日志表现为 Stream ends @ 0~1MB，然后无限重连）——
  /// 所以切线路、切画质、断流重连这些「重新取流」的时机，都必须用新参数。
  Future<String> _freshPlayArgs(String roomId, String fallback) async {
    try {
      var jsEncResult = await HttpClient.instance.getText(
        "https://www.douyu.com/swf_api/homeH5Enc?rids=$roomId",
        queryParameters: {},
        header: requestHeaders(referer: "https://www.douyu.com/$roomId"),
      );
      var crptext = json.decode(jsEncResult)["data"]["room$roomId"].toString();
      return DouyuSign.getSign(crptext, roomId);
    } catch (_) {
      // 拿不到新参数就退回旧的（至少还能试一次）
      return fallback;
    }
  }

  @override
  Future<List<LivePlayQuality>> getPlayQualites({
    required LiveRoomDetail detail,
  }) async {
    var data = await _freshPlayArgs(detail.roomId, detail.data.toString());
    data += "&cdn=&rate=-1&ver=Douyu_223061205&iar=1&ive=1&hevc=0&fa=0";
    List<LivePlayQuality> qualities = [];
    var result = await HttpClient.instance.postJson(
      "https://www.douyu.com/lapi/live/getH5Play/${detail.roomId}",
      data: data,
      header: requestHeaders(referer: "https://www.douyu.com/${detail.roomId}"),
      formUrlEncoded: true,
    );

    var cdns = <String>[];
    for (var item in result["data"]["cdnsWithName"]) {
      cdns.add(item["cdn"].toString());
    }

    // 如果cdn以scdn开头，将其放到最后
    cdns.sort((a, b) {
      if (a.startsWith("scdn") && !b.startsWith("scdn")) {
        return 1;
      } else if (!a.startsWith("scdn") && b.startsWith("scdn")) {
        return -1;
      }
      return 0;
    });

    for (var item in result["data"]["multirates"]) {
      qualities.add(
        LivePlayQuality(
          quality: item["name"].toString(),
          data: DouyuPlayData(item["rate"], cdns),
        ),
      );
    }
    return qualities;
  }

  @override
  Future<LivePlayUrl> getPlayUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) async {
    // 关键：每次取流都重新生成签名参数，避免用几分钟前过期的旧签名
    var args = await _freshPlayArgs(detail.roomId, detail.data.toString());
    var data = quality.data as DouyuPlayData;

    // 并发请求各 CDN 的取流地址。
    // 串行时每个请求最多等 20 秒，网络/代理一挂就要等 1 分钟以上（界面表现为"突然没线路了"）；
    // 并发后整体最多 20 秒。失败的那条直接跳过，不影响其它线路。
    var results = await Future.wait(data.cdns.map((item) async {
      try {
        return await getPlayUrl(detail.roomId, args, data.rate, item);
      } catch (_) {
        return "";
      }
    }));
    List<String> urls = results.where((e) => e.isNotEmpty).toList();
    // 追加一条「音频线路」：斗鱼 CDN 支持 &only-audio=1，只下发音频
    // （实测 4 秒下载量 2749KB → 63KB，约 5.5Mbps → 126kbps）
    int? audioLineIndex;
    if (urls.isNotEmpty) {
      urls.add("${urls.first}&only-audio=1");
      audioLineIndex = urls.length - 1;
    }

    // 拉流请求同样要带登录态：未登录时 CDN 会在 10 分钟后掐断原画/蓝光
    return LivePlayUrl(
      urls: urls,
      headers: requestHeaders(referer: "https://www.douyu.com/${detail.roomId}"),
      audioLineIndex: audioLineIndex,
    );
  }

  Future<String> getPlayUrl(
    String roomId,
    String args,
    int rate,
    String cdn,
  ) async {
    args += "&cdn=$cdn&rate=$rate";
    var result = await HttpClient.instance.postJson(
      "https://www.douyu.com/lapi/live/getH5Play/$roomId",
      data: args,
      header: requestHeaders(referer: 'https://www.douyu.com/$roomId'),
      formUrlEncoded: true,
    );

    return "${result["data"]["rtmp_url"]}/${HtmlUnescape().convert(result["data"]["rtmp_live"].toString())}";
  }

  @override
  Future<LiveCategoryResult> getRecommendRooms({int page = 1}) async {
    var result = await HttpClient.instance.getJson(
      "https://www.douyu.com/japi/weblist/apinc/allpage/6/$page",
      queryParameters: {},
      header: requestHeaders(),
    );

    var items = <LiveRoomItem>[];
    for (var item in result['data']['rl']) {
      if (item["type"] != 1) {
        continue;
      }
      var roomItem = LiveRoomItem(
        cover: item['rs16'].toString(),
        online: item['ol'],
        roomId: item['rid'].toString(),
        title: item['rn'].toString(),
        userName: item['nn'].toString(),
      );
      items.add(roomItem);
    }
    var hasMore = page < result['data']['pgcnt'];
    return LiveCategoryResult(hasMore: hasMore, items: items);
  }

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    Map roomInfo;
    try {
      roomInfo = await _getRoomInfo(roomId);
    } catch (e) {
      // 房间不存在：返回空详情，界面显示「该直播间已失效或不存在」
      if (e is CoreError && e.statusCode == 404) {
        return LiveRoomDetail(
          roomId: roomId,
          title: "",
          cover: "",
          userName: "",
          userAvatar: "",
          online: 0,
          status: false,
          url: "https://www.douyu.com/$roomId",
          roomNotFound: true,
        );
      }
      rethrow;
    }

    Map h5RoomInfo = await HttpClient.instance.getJson(
      "https://www.douyu.com/swf_api/h5room/$roomId",
      queryParameters: {},
      header: requestHeaders(referer: 'https://www.douyu.com/$roomId'),
    );
    String? showTime = LiveDuration.parse(h5RoomInfo["data"]?["show_time"]);
    LiveDuration.log("斗鱼", roomId, showTime);

    var jsEncResult = await HttpClient.instance.getText(
      "https://www.douyu.com/swf_api/homeH5Enc?rids=$roomId",
      queryParameters: {},
      header: requestHeaders(referer: 'https://www.douyu.com/$roomId'),
    );
    var crptext = json.decode(jsEncResult)["data"]["room$roomId"].toString();

    var isLive = roomInfo["show_status"] == 1 && roomInfo["videoLoop"] != 1;

    return LiveRoomDetail(
      cover: roomInfo["room_pic"].toString(),
      online: int.tryParse(roomInfo["room_biz_all"]["hot"].toString()) ?? 0,
      roomId: roomInfo["room_id"].toString(),
      title: roomInfo["room_name"].toString(),
      userName: roomInfo["owner_name"].toString(),
      userAvatar: roomInfo["owner_avatar"].toString(),
      introduction: roomInfo["show_details"].toString(),
      notice: "",
      status: isLive,
      // 发弹幕需要 uid + devid + jwt + ltkid + stk（2026-10 抓包实证），
      // 全部从登录 cookie 里取；缺任何一个都发不出去
      danmakuData: DouyuDanmakuArgs(
        roomId: roomInfo["room_id"].toString(),
        uid: _cookieValue("acf_uid"),
        devid: _resolveDevid(),
        nickname: _decodeCookieValue(_cookieValue("acf_nickname")),
        avatar: _decodeCookieValue(_cookieValue("acf_avatar")),
        username: _cookieValue("acf_username"),
        jwt: _decodeCookieValue(_cookieValue("acf_dmjwt_token")),
        ltkid: _decodeCookieValue(_cookieValue("acf_ltkid")),
        biz: _cookieValue("acf_biz"),
        stk: _decodeCookieValue(_cookieValue("acf_stk")),
        // 完整 cookie 用于发送连接的握手头
        cookie: cookie,
      ),
      data: DouyuSign.getSign(crptext, roomInfo["room_id"].toString()),
      url: "https://www.douyu.com/$roomId",
      isRecord: roomInfo["videoLoop"] == 1,
      showTime: isLive ? showTime : null,
      lastLiveTime: isLive ? null : showTime,
    );
  }

  @override
  Future<LiveSearchRoomResult> searchRooms(
    String keyword, {
    int page = 1,
  }) async {
    var did = generateRandomString(32);
    var result = await HttpClient.instance.getJson(
      "https://www.douyu.com/japi/search/api/searchShow",
      queryParameters: {"kw": keyword, "page": page, "pageSize": 20},
      header: requestHeaders(
        referer: 'https://www.douyu.com/search/',
        extraCookie: 'dy_did=$did;acf_did=$did',
      ),
    );
    if (result['error'] != 0) {
      throw Exception(result['msg']);
    }
    var items = <LiveRoomItem>[];
    for (var item in result["data"]["relateShow"]) {
      var roomItem = LiveRoomItem(
        roomId: item["rid"].toString(),
        title: item["roomName"].toString(),
        cover: item["roomSrc"].toString(),
        userName: item["nickName"].toString(),
        online: parseHotNum(item["hot"].toString()),
      );
      items.add(roomItem);
    }
    var hasMore = result["data"]["relateShow"].isNotEmpty;
    return LiveSearchRoomResult(hasMore: hasMore, items: items);
  }

  Future<Map> _getRoomInfo(String roomId) async {
    var result = await HttpClient.instance.getJson(
      "https://www.douyu.com/betard/$roomId",
      queryParameters: {},
      header: requestHeaders(referer: 'https://www.douyu.com/$roomId'),
    );
    try {
      // betard 的 content-type 是 text/html，getJson 会原样返回字符串
      if (result is String) {
        return json.decode(result)["room"];
      }
      return result["room"];
    } on FormatException {
      // 房间不存在时斗鱼返回的是 HTML 错误页，解析必然失败
      throw CoreError("房间不存在", statusCode: 404);
    }
  }

  //生成指定长度的16进制随机字符串
  String generateRandomString(int length) {
    var random = Random.secure();
    var values = List<int>.generate(length, (i) => random.nextInt(16));
    StringBuffer stringBuffer = StringBuffer();
    for (var item in values) {
      stringBuffer.write(item.toRadixString(16));
    }
    return stringBuffer.toString();
  }

  @override
  Future<LiveSearchAnchorResult> searchAnchors(
    String keyword, {
    int page = 1,
  }) async {
    var did = generateRandomString(32);
    var result = await HttpClient.instance.getJson(
      "https://www.douyu.com/japi/search/api/searchUser",
      queryParameters: {
        "kw": keyword,
        "page": page,
        "pageSize": 20,
        "filterType": 1,
      },
      header: requestHeaders(
        referer: 'https://www.douyu.com/search/',
        extraCookie: 'dy_did=$did;acf_did=$did',
      ),
    );

    var items = <LiveAnchorItem>[];
    for (var item in result["data"]["relateUser"]) {
      var liveStatus =
          (int.tryParse(item["anchorInfo"]["isLive"].toString()) ?? 0) == 1;
      var roomType =
          (int.tryParse(item["anchorInfo"]["roomType"].toString()) ?? 0);
      var roomItem = LiveAnchorItem(
        roomId: item["anchorInfo"]["rid"].toString(),
        avatar: item["anchorInfo"]["avatar"].toString(),
        userName: item["anchorInfo"]["nickName"].toString(),
        liveStatus: liveStatus && roomType == 0,
      );
      items.add(roomItem);
    }
    var hasMore = result["data"]["relateUser"].isNotEmpty;
    return LiveSearchAnchorResult(hasMore: hasMore, items: items);
  }

  @override
  Future<LiveRoomStatus> getRoomStatus({required String roomId}) async {
    try {
      // betard 一次就能拿到直播状态 + 开播时间（未开播时 show_time 是上一场的）
      var roomInfo = await _getRoomInfo(roomId);
      var isLive = roomInfo["show_status"] == 1 && roomInfo["videoLoop"] != 1;
      var showTime = LiveDuration.parse(roomInfo["show_time"]);
      return LiveRoomStatus(
        roomId: roomInfo["room_id"]?.toString() ?? roomId,
        isLive: isLive,
        startTime: isLive ? showTime : null,
        lastLiveTime: isLive ? null : showTime,
      );
    } catch (e) {
      CoreLog.error(e);
      // 404 = 房间不存在（斗鱼返回的是 HTML 错误页）
      return LiveRoomStatus(
        roomId: roomId,
        isLive: false,
        roomNotFound: e is CoreError && e.statusCode == 404,
      );
    }
  }

  @override
  Future<bool> getLiveStatus({required String roomId}) async {
    var roomInfo = await _getRoomInfo(roomId);
    return roomInfo["show_status"] == 1 && roomInfo["videoLoop"] != 1;
  }

  int parseHotNum(String hn) {
    try {
      var num = double.parse(hn.replaceAll("万", ""));
      if (hn.contains("万")) {
        num *= 10000;
      }
      return num.round();
    } catch (_) {
      return -999;
    }
  }

  @override
  Future<List<LiveSuperChatMessage>> getSuperChatMessage({
    required String roomId,
  }) {
    //尚不支持
    return Future.value([]);
  }
}

class DouyuPlayData {
  final int rate;
  final List<String> cdns;
  DouyuPlayData(this.rate, this.cdns);
}
