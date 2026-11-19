import 'dart:convert';

import 'package:simple_live_core/src/model/live_message.dart';

import '../common/core_log.dart';
import '../common/http_client.dart' as core_http;

/// 斗鱼弹幕里的图片表情解析。
///
/// 斗鱼没有像 B 站那样把表情图塞进弹幕报文，而是前端拿一份「表情表」自己替换：
/// 弹幕正文里出现 [表情名]（正则 \[.+?\]），命中表情表就换成 <img>。
/// 表情表来自房间接口（钻粉专属表情 / 房间表情），每个主播不一样，所以必须按房间拉取。
///
/// 接口（网页端抓包确认，游客态即可访问）：
///   * https://www.douyu.com/japi/interact/comm/dfans/emojis?rid=9999
///       data.emoList        -> [{eid:"9999胖头跳舞", text:"胖头跳舞", pic:"https://...webp"}]  钻粉专属表情
///       data.popularEmojis  -> [{name:"梗已老实", webPic:"https://...png"}]                 钻粉人气梗表情
///   * https://www.douyu.com/japi/livebiznc/web/roomemoji/list?rid=9999
///       房间表情（多数房间 data 为 null，有值时结构不固定，这里做兼容解析）
class DouyuEmoticon {
  DouyuEmoticon._();

  /// 表情图相对字号的放大倍数（网页端表情约 1.7 倍字高）
  static const double imageScale = 1.7;

  /// 接口不给素材尺寸，统一按正方形渲染
  static const double imageRatio = 1.0;

  /// 表情表缓存时长（主播改表情不会很频繁）
  static const Duration _ttl = Duration(minutes: 10);

  static const String _userAgent =
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36 Edg/114.0.1823.43";

  static final Map<String, _EmoticonCache> _cache = {};
  static final Map<String, Future<Map<String, String>>> _inflight = {};

  /// 取某房间的表情表（表情名 -> 图片地址）。
  ///
  /// 失败时返回空表（调用方当纯文本处理），不会抛异常。
  static Future<Map<String, String>> load(
    String roomId, {
    String cookie = "",
  }) async {
    if (roomId.isEmpty) {
      return const {};
    }
    final cached = _cache[roomId];
    if (cached != null &&
        DateTime.now().difference(cached.time) < _ttl &&
        cached.items.isNotEmpty) {
      return cached.items;
    }
    final running = _inflight[roomId];
    if (running != null) {
      return running;
    }
    final future = _fetch(roomId, cookie: cookie);
    _inflight[roomId] = future;
    try {
      final items = await future;
      if (items.isNotEmpty) {
        _cache[roomId] = _EmoticonCache(items, DateTime.now());
      }
      return items;
    } finally {
      _inflight.remove(roomId);
    }
  }

  static Future<Map<String, String>> _fetch(
    String roomId, {
    String cookie = "",
  }) async {
    final result = <String, String>{};
    final headers = <String, String>{
      "referer": "https://www.douyu.com/$roomId",
      "user-agent": _userAgent,
      if (cookie.isNotEmpty) "cookie": cookie,
    };
    try {
      final json = await core_http.HttpClient.instance.getJson(
        "https://www.douyu.com/japi/interact/comm/dfans/emojis",
        queryParameters: {"rid": roomId},
        header: headers,
      );
      final data = json is Map ? json["data"] : null;
      if (data is Map) {
        // 钻粉专属表情
        _collect(
          data["emoList"],
          result,
          nameKeys: const ["text", "name", "title"],
          urlKeys: const ["pic", "bigPic", "url"],
        );
        // 钻粉人气梗表情
        _collect(
          data["commEmoList"],
          result,
          nameKeys: const ["text", "name", "title"],
          urlKeys: const ["pic", "bigPic", "url"],
        );
        final popular = data["popularEmojis"];
        if (popular is Map) {
          _collect(
            popular["list"],
            result,
            nameKeys: const ["name", "text", "title"],
            urlKeys: const ["webPic", "appPic", "pic"],
          );
        }
      }
    } catch (e) {
      CoreLog.error("斗鱼表情：钻粉表情接口失败 $e");
    }
    if (result.isEmpty) {
      // 房间表情（部分房间才有）
      try {
        final json = await core_http.HttpClient.instance.getJson(
          "https://www.douyu.com/japi/livebiznc/web/roomemoji/list",
          queryParameters: {"rid": roomId},
          header: headers,
        );
        final data = json is Map ? json["data"] : null;
        if (data is List) {
          _collect(data, result);
        } else if (data is Map) {
          for (final value in data.values) {
            if (value is List) {
              _collect(value, result);
            }
          }
        }
      } catch (e) {
        CoreLog.error("斗鱼表情：房间表情接口失败 $e");
      }
    }
    if (result.isNotEmpty) {
      CoreLog.i("斗鱼表情：房间 $roomId 加载 ${result.length} 个表情");
    }
    return result;
  }

  /// 兼容各种字段名，把「名字 -> 图片」收进 map
  static void _collect(
    dynamic list,
    Map<String, String> out, {
    List<String> nameKeys = const ["name", "text", "title"],
    List<String> urlKeys = const ["pic", "url", "bigPic", "webPic"],
  }) {
    if (list is! List) {
      return;
    }
    for (final item in list) {
      if (item is! Map) {
        continue;
      }
      String name = "";
      for (final key in nameKeys) {
        final value = item[key];
        if (value is String && value.trim().isNotEmpty) {
          name = value.trim();
          break;
        }
      }
      String url = "";
      for (final key in urlKeys) {
        final value = item[key];
        if (value is String) {
          final text = value.trim();
          if (text.startsWith("http")) {
            url = text;
            break;
          }
        }
      }
      if (name.isNotEmpty && url.isNotEmpty) {
        out[name] = url;
      }
    }
  }

  static final RegExp _matcher = RegExp(r"\[([^\[\]]{1,20})\]");

  /// 把一条弹幕正文拆成「文字 + 表情图」片段。
  ///
  /// [emoticons] 为空或没有命中时返回 null（调用方继续按纯文本处理）。
  static List<LiveMessageSpan>? parseSpans(
    String content,
    Map<String, String> emoticons,
  ) {
    if (content.isEmpty || emoticons.isEmpty || !content.contains("[")) {
      return null;
    }
    final List<LiveMessageSpan> spans = [];
    var last = 0;
    var hasImage = false;
    for (final match in _matcher.allMatches(content)) {
      final name = match.group(1);
      if (name == null) {
        continue;
      }
      final url = emoticons[name];
      if (url == null) {
        // 不认识的标记（全站表情 / 普通方括号文字）：保持原样
        continue;
      }
      if (match.start > last) {
        spans.add(LiveMessageSpan.text(content.substring(last, match.start)));
      }
      spans.add(
        LiveMessageSpan.image(
          url,
          imageScale: imageScale,
          imageRatio: imageRatio,
        ),
      );
      hasImage = true;
      last = match.end;
    }
    if (!hasImage) {
      return null;
    }
    if (last < content.length) {
      spans.add(LiveMessageSpan.text(content.substring(last)));
    }
    return spans;
  }

  /// 整条弹幕是不是只由图片表情组成
  static bool isOnlyEmoticon(List<LiveMessageSpan> spans) {
    var hasImage = false;
    for (final span in spans) {
      if (span.isImage) {
        hasImage = true;
      } else if (span.isText && span.text!.trim().isNotEmpty) {
        return false;
      }
    }
    return hasImage;
  }

  /// 供调试：把表情表转成 JSON
  static String dump(Map<String, String> emoticons) => json.encode(emoticons);
}

class _EmoticonCache {
  final Map<String, String> items;
  final DateTime time;
  _EmoticonCache(this.items, this.time);
}
