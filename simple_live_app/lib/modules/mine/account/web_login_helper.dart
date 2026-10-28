import 'dart:async';
import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:simple_live_app/app/log.dart';

/// WebView 登录的通用工具：轮询 Cookie、清理登录态、适配桌面版登录框。
///
/// 哔哩哔哩登录成功后会跳到 m.bilibili.com，可以靠 uri.host 判断；
/// 而抖音 / 虎牙 / 斗鱼登录成功后都不换域名，只能盯 Cookie。
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

  /// 退出登录后重新打开 Web 登录时先清掉登录态。
  /// 否则 WebView 里还留着上次的 Cookie，会直接自动登录上一个账号。
  Future<void> clear(List<String> urls) async {
    for (final url in urls) {
      try {
        await _cookieManager.deleteCookies(url: WebUri(url));
      } catch (e) {
        Log.logPrint(e);
      }
    }
    // 兜底：平台常把 Cookie 写到父域（.huya.com 等），逐域删可能漏，
    // 直接清空 WebView 全部 Cookie 与本地存储，确保不会自动登录旧账号
    try {
      await _cookieManager.deleteAllCookies();
      await WebStorageManager.instance().deleteAllData();
      Log.i("Web登录：已清空 WebView Cookie 与本地存储");
    } catch (e) {
      Log.logPrint(e);
    }
  }

  /// 把桌面版网页里的登录框适配成铺满手机屏幕的样子：
  /// 找到登录框 → 隐藏页面其它内容 → 等比缩放到可视区域 → 贴左上角。
  /// 页面里的登录浮层多为异步挂载，脚本内部会重试 10 秒左右。
  static Future<String?> fitLoginPanel(
    InAppWebViewController? controller,
    List<String> selectors,
  ) async {
    if (controller == null) {
      return null;
    }
    try {
      var sels = jsonEncode(selectors);
      var source = _fitScript.replaceFirst("%SELS%", sels);
      var result = await controller.evaluateJavascript(source: source);
      Log.i("Web登录页面适配：$result");
      // 2.5 秒后回读是否真的适配成功（登录浮层多为异步渲染）
      Future.delayed(const Duration(milliseconds: 2500), () async {
        try {
          var state = await controller.evaluateJavascript(
            source: "window.__dshFitOk || 'pending'",
          );
          Log.i("Web登录页面适配结果：$state");
        } catch (e) {
          Log.logPrint(e);
        }
      });
      return result?.toString();
    } catch (e) {
      Log.logPrint(e);
      return null;
    }
  }

  static const String _fitScript = r'''
(function(){
  var sels = %SELS%;
  var tries = 0;
  function fit(){
    tries++;
    var el = null;
    for (var i = 0; i < sels.length; i++) { el = document.querySelector(sels[i]); if (el) break; }
    if (!el) { if (tries < 15) { setTimeout(fit, 700); } return; }
    var r = el.getBoundingClientRect();
    var w = r.width || 712; var h = r.height || 410;
    var scale = Math.min(window.innerWidth / w, window.innerHeight / h, 1.6);
    var node = el;
    while (node && node.parentElement) {
      var parent = node.parentElement;
      for (var i = 0; i < parent.children.length; i++) {
        var c = parent.children[i];
        if (c !== node && !c.contains(el)) { c.style.setProperty("display", "none", "important"); }
      }
      node = parent;
    }
    el.style.setProperty("position", "fixed", "important");
    el.style.setProperty("left", "0", "important");
    el.style.setProperty("top", "0", "important");
    el.style.setProperty("margin", "0", "important");
    el.style.setProperty("width", w + "px", "important");
    el.style.setProperty("height", h + "px", "important");
    el.style.setProperty("transform-origin", "top left", "important");
    el.style.setProperty("transform", "scale(" + scale + ")", "important");
    el.style.setProperty("z-index", "2147483647", "important");
    el.style.setProperty("border-radius", "0", "important");
    document.body.style.setProperty("background", "#0b0b0f", "important");
    document.documentElement.style.setProperty("overflow", "hidden", "important");
    window.__dshFitOk = "ok " + w + "x" + h + " scale=" + scale;
  }
  window.__dshFitOk = "";
  fit();
  return "fitting";
})()
''';

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
