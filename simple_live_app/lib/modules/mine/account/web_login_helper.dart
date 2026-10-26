import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:simple_live_app/app/log.dart';

/// WebView 登录的通用工具：轮询 Cookie，等到关键字段出现即认为登录成功。
///
/// 哔哩哔哩登录成功后会跳到 m.bilibili.com，可以靠 uri.host 判断；
/// 而抖音 / 虎牙 / 斗鱼登录成功后都不换域名，只能盯 Cookie。
/// 三个平台逻辑完全一致，抽到这里避免三份重复实现。
class WebLoginCookieHelper {
  final CookieManager _cookieManager = CookieManager.instance();

  /// 汇总多个域名下的 Cookie（登录流程经常跨多个子域）
  Future<Map<String, String>> collect(List<String> urls) async {
    var map = <String, String>{};
    for (final url in urls) {
      try {
        var cookies = await _cookieManager.getCookies(url: WebUri(url));
        for (final e in cookies) {
          if (e.name.isNotEmpty && e.value.isNotEmpty) {
            map[e.name] = e.value;
          }
        }
      } catch (e) {
        Log.logPrint(e);
      }
    }
    return map;
  }

  static String toHeader(Map<String, String> map) =>
      map.entries.map((e) => "${e.key}=${e.value}").join(";");

  /// 每秒检查一次，[keys] 里任意一个出现就回调 [onSuccess] 并停止。
  /// 返回的 Timer 需要在页面关闭时 cancel。
  Timer watch({
    required List<String> keys,
    required List<String> urls,
    required void Function(Map<String, String> cookies) onSuccess,
    Duration interval = const Duration(seconds: 1),
  }) {
    var busy = false;
    return Timer.periodic(interval, (timer) async {
      if (busy) {
        return;
      }
      busy = true;
      try {
        var map = await collect(urls);
        if (keys.any((k) => (map[k] ?? "").isNotEmpty)) {
          timer.cancel();
          onSuccess(map);
        }
      } finally {
        busy = false;
      }
    });
  }
}
