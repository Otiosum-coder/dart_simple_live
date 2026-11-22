import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:simple_live_core/src/common/core_log.dart';
import 'package:simple_live_core/src/model/live_message.dart';
import 'package:simple_live_core/src/model/tars/huya_emoticon.dart';
import 'package:tars_dart/tars/tup/const.dart';
import 'package:tars_dart/tars/tup/tars_uni_packet.dart';

/// 虎牙弹幕表情：进房后异步拉取游客目录，失败时使用旧版默认映射。
/// 目录只用于接收显示，不代表当前账号拥有这些表情的发送权限。
class HuyaEmoticon {
  HuyaEmoticon._();

  /// 表情图相对字号的放大倍数（虎牙网页端表情约 2 倍字高）
  static const double imageScale = 1.8;

  /// 素材原始宽高比（26 x 22）
  static const double imageRatio = 26 / 22;

  static const String _baseUrl = "https://a.msstatic.com/huya/main/emot_png/";

  /// 表情名 -> code（顺序与虎牙客户端面板一致）
  static const Map<String, String> _nameToCode = {
    "大笑": "dx",
    "送花": "sh",
    "偷笑": "tx",
    "大哭": "dk",
    "嘿哈": "hh",
    "666": "66",
    "感动": "gd",
    "疑问": "yw",
    "喜欢": "xh",
    "奸笑": "jx",
    "赞": "zan",
    "可爱": "ka",
    "傲慢": "am",
    "开心": "kx",
    "拜拜": "88",
    "害羞": "hx",
    "衰": "zs",
    "吐血": "pu",
    "嘴馋": "zc",
    "生气": "sq",
    "扶额": "fe",
    "闭嘴": "bz",
    "枯萎": "kw",
    "嘘": "xu",
    "笑哭": "xk",
    "流汗": "lh",
    "不看": "bk",
    "哈欠": "hq",
    "调皮": "tp",
    "鬼脸": "gl",
    "戳脸": "cl",
    "大哥": "dg",
    "困": "kun",
    "拥抱": "yb",
    "猪头": "zt",
    "骷髅": "kl",
    "臭臭": "cc",
    "心动": "xd",
    "刀": "dao",
  };

  /// code -> 表情名
  static final Map<String, String> _codeToName = {
    for (final entry in _nameToCode.entries) entry.value: entry.key,
  };

  static const _ttl = Duration(minutes: 10);
  static const _retryDelay = Duration(seconds: 30);
  static Map<String, String> _cachedItems = const {};
  static DateTime? _updatedAt;
  static DateTime? _lastAttempt;
  static Future<Map<String, String>>? _inflight;

  /// 全站游客目录已验证与房间请求一致；跨房间共用缓存和进行中的请求。
  /// 不等待此方法即可连接弹幕；失败时沿用旧目录，下次进房再重试。
  static Future<Map<String, String>> load() {
    final running = _inflight;
    if (running != null) {
      return running;
    }
    final now = DateTime.now();
    if ((_updatedAt != null && now.difference(_updatedAt!) < _ttl) ||
        (_lastAttempt != null && now.difference(_lastAttempt!) < _retryDelay)) {
      return Future.value(_cachedItems);
    }
    return _inflight = _loadAndCache();
  }

  static Future<Map<String, String>> _loadAndCache() async {
    _lastAttempt = DateTime.now();
    try {
      final items = await _fetch();
      if (items.isEmpty) {
        throw const FormatException('虎牙表情目录没有可用的单图');
      }
      _cachedItems = Map.unmodifiable(items);
      _updatedAt = DateTime.now();
      CoreLog.d('虎牙游客表情目录已更新：${items.length} 个名称/转义标记');
    } catch (e) {
      CoreLog.w('虎牙表情目录拉取失败，沿用缓存或默认表情：$e');
    } finally {
      _inflight = null;
    }
    return _cachedItems;
  }

  static Future<Map<String, String>> _fetch() async {
    final packet = TarsUniPacket()
      ..setTarsVersion(Const.PACKET_TYPE_TUP3)
      ..requestId = 1
      ..servantName = 'wupui'
      ..funcName = 'getExpressionEmoticonPackage';
    packet.put('tReq', HuyaEmoticonRequest());
    final bytes = packet.encode();
    // 独立的无 Cookie 客户端，不从账号服务或 WebView 读取登录态。
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 5),
        sendTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 8),
      ),
    );
    try {
      final result = await dio.post<List<int>>(
        'https://wup.huya.com/',
        data: Stream.value(bytes),
        options: Options(
          responseType: ResponseType.bytes,
          contentType: 'application/octet-stream',
          headers: {'content-length': bytes.length},
        ),
      );
      final data = result.data;
      if (data == null || data.length < 4) {
        throw const FormatException('虎牙表情响应为空');
      }
      final response = TarsUniPacket()..decode(Uint8List.fromList(data));
      if (response.getTarsResultCode() != 0 || !response.containsKey('tRsp')) {
        throw const FormatException('虎牙表情响应失败');
      }
      final catalog = response.getByClass('tRsp', HuyaEmoticonResponse());
      final items = <String, String>{};
      // 默认包优先，避免其它包里的同名项覆盖通用表情。
      final packages = catalog.packages
          .where((p) => p.id == '1')
          .followedBy(catalog.packages.where((p) => p.id != '1'));
      for (final package in packages) {
        for (final item in [...package.items, ...package.unavailableItems]) {
          var url = item.url.trim();
          if (url.startsWith('//')) url = 'https:$url';
          final uri = Uri.tryParse(url);
          if (uri == null ||
              !uri.hasAuthority ||
              (uri.scheme != 'http' && uri.scheme != 'https') ||
              uri.path.toLowerCase().endsWith('.zip')) {
            // 没有 sUrl 的梗表情不能用 sFlexiUrl 多帧长图替代。
            continue;
          }
          url = uri.replace(scheme: 'https').toString();
          final name = item.name.trim();
          if (name.isNotEmpty) {
            final marker = name.startsWith('[') ? name : '[$name]';
            items.putIfAbsent(marker, () => url);
          }
          final escape = item.escape.trim().replaceFirst(RegExp(r'\}$'), '');
          if (RegExp(r'^/\{[A-Za-z0-9_]+$').hasMatch(escape)) {
            items.putIfAbsent(escape, () => url);
          }
        }
      }
      return items;
    } finally {
      dio.close(force: true);
    }
  }

  /// 名字标记和网页实际使用的无右括号转义标记，兼容旧版 /{dx}。
  static final RegExp _matcher = RegExp(
    r'/\{([A-Za-z0-9_]+)\}?|\[([^\[\]]{1,64})\]',
  );

  static String _url(String code) => "$_baseUrl$code.png";

  /// 把一条弹幕正文拆成「文字 + 表情图」片段。
  ///
  /// 没有任何可识别表情时返回 null（调用方继续按纯文本处理）。
  static List<LiveMessageSpan>? parseSpans(
    String content, [
    Map<String, String>? emoticons,
  ]) {
    if (content.isEmpty ||
        (!content.contains("[") && !content.contains("/{"))) {
      return null;
    }
    final images = emoticons ?? _cachedItems;
    final List<LiveMessageSpan> spans = [];
    var last = 0;
    var hasImage = false;
    for (final match in _matcher.allMatches(content)) {
      final escapeCode = match.group(1);
      final name = match.group(2);
      final marker = escapeCode != null ? '/{$escapeCode' : '[$name]';
      final remoteUrl = images[marker];
      String? code;
      if (escapeCode != null && _codeToName.containsKey(escapeCode)) {
        code = escapeCode;
      } else if (name != null && _nameToCode.containsKey(name)) {
        code = _nameToCode[name];
      }
      if (remoteUrl == null && code == null) {
        // 没有单图资源或尚未识别的标记保留原文。
        continue;
      }
      if (match.start > last) {
        spans.add(LiveMessageSpan.text(content.substring(last, match.start)));
      }
      spans.add(
        LiveMessageSpan.image(
          remoteUrl ?? _url(code!),
          imageScale: imageScale,
          imageRatio: remoteUrl == null ? imageRatio : 1.0,
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

  /// 整条弹幕是不是只由图片表情组成（用于「屏蔽图片表情」开关）
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
}
