import 'dart:convert';

class LivePlayUrl {
  /// 播放地址
  final List<String> urls;

  /// 请求头
  final Map<String, String>? headers;

  /// 纯音频线路在 [urls] 里的下标（null = 该平台没有音频线路）
  ///
  /// 目前只有斗鱼支持：CDN 地址加 `&only-audio=1` 后只下发音频
  /// （实测码率从 ~5.5 Mbps 降到 ~126 kbps）
  final int? audioLineIndex;

  LivePlayUrl({
    required this.urls,
    this.headers,
    this.audioLineIndex,
  });

  @override
  String toString() {
    return json.encode({
      "urls": urls,
      "headers": headers.toString(),
    });
  }
}
