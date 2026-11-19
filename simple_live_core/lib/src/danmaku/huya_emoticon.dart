import 'package:simple_live_core/src/model/live_message.dart';

/// 虎牙弹幕里的图片表情解析。
///
/// 虎牙网页端把表情存成一个「表情包列表」，弹幕正文里出现两种标记：
///   * 名字标记：[大笑]（正则 \[.+?\]）
///   * 转义标记：/{dx}（正则 \/\{[\w]+）
/// 命中后由前端替换成 https://a.msstatic.com/huya/main/emot_png/<code>.png。
///
/// 这里内置虎牙「本地默认表情」包（40 个，不需要登录、也不需要额外的
/// WUP 接口），弹幕里出现的其它名字（大航海/粉丝团表情包）取不到素材，
/// 保持原样当文字显示。
class HuyaEmoticon {
  HuyaEmoticon._();

  /// 表情图相对字号的放大倍数（虎牙网页端表情约 2 倍字高）
  static const double imageScale = 1.8;

  /// 素材原始宽高比（26 x 22）
  static const double imageRatio = 26 / 22;

  static const String _baseUrl =
      "https://a.msstatic.com/huya/main/emot_png/";

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

  /// 名字标记 或 转义标记
  static final RegExp _matcher = RegExp(
    r"\/{([A-Za-z0-9_]+)}|\[([^\[\]]{1,12})\]",
  );

  static String _url(String code) => "$_baseUrl$code.png";

  /// 把一条弹幕正文拆成「文字 + 表情图」片段。
  ///
  /// 没有任何可识别表情时返回 null（调用方继续按纯文本处理）。
  static List<LiveMessageSpan>? parseSpans(String content) {
    if (content.isEmpty ||
        (!content.contains("[") && !content.contains("/{"))) {
      return null;
    }
    final List<LiveMessageSpan> spans = [];
    var last = 0;
    var hasImage = false;
    for (final match in _matcher.allMatches(content)) {
      final escapeCode = match.group(1);
      final name = match.group(2);
      String? code;
      if (escapeCode != null && _codeToName.containsKey(escapeCode)) {
        code = escapeCode;
      } else if (name != null && _nameToCode.containsKey(name)) {
        code = _nameToCode[name];
      }
      if (code == null) {
        // 不认识的标记（大航海表情包等）：当普通文字，继续往后找
        continue;
      }
      if (match.start > last) {
        spans.add(LiveMessageSpan.text(content.substring(last, match.start)));
      }
      spans.add(
        LiveMessageSpan.image(
          _url(code),
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