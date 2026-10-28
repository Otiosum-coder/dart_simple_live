import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:simple_live_app/app/log.dart';

/// 虎牙 Cookie 补全：
///
/// 扫码登录只拿到 `udblgn.huya.com` 域的 Cookie（udb_uid / udb_cred 等），
/// 但网页端发弹幕时用的是 `www.huya.com` 下那套完整的 Cookie
/// （约 1.3KB，含 __yamid_new / game_did / _qimei / hy_token 等）。
/// 这里用一个不可见 WebView 打开 www.huya.com，把登录态 Cookie 种进去，
/// 让页面自己补全其它 Cookie，再读回来。
class HuyaCookieHarvester {
  static const String _ua =
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

  static const List<String> _urls = [
    "https://www.huya.com/",
    "https://i.huya.com/",
    "https://www.huya.com/10199",
  ];

  static bool _running = false;

  /// 返回补全后的 Cookie（失败返回 null）
  static Future<String?> harvest(String cookie) async {
    if (_running || cookie.isEmpty) {
      return null;
    }
    if (!Platform.isAndroid && !Platform.isIOS) {
      // 桌面端先不做（WebView 依赖差异大）
      return null;
    }
    _running = true;
    HeadlessInAppWebView? webView;
    var completer = Completer<String?>();
    try {
      var cookieManager = CookieManager.instance();
      // ① 先把已有的登录 Cookie 种到 www.huya.com
      for (var part in cookie.split(';')) {
        var item = part.trim();
        var index = item.indexOf('=');
        if (index <= 0) {
          continue;
        }
        var name = item.substring(0, index).trim();
        var value = item.substring(index + 1).trim();
        if (name.isEmpty || value.isEmpty) {
          continue;
        }
        try {
          await cookieManager.setCookie(
            url: WebUri("https://www.huya.com/"),
            name: name,
            value: value,
            domain: ".huya.com",
            path: "/",
          );
        } catch (e) {
          Log.logPrint(e);
        }
      }

      // ② 不可见 WebView 打开主站，让页面补全 Cookie
      webView = HeadlessInAppWebView(
        initialSize: const Size(800, 900),
        initialUrlRequest: URLRequest(url: WebUri(_urls[0])),
        initialSettings: InAppWebViewSettings(
          userAgent: _ua,
          javaScriptEnabled: true,
          thirdPartyCookiesEnabled: true,
          domStorageEnabled: true,
        ),
        onLoadStop: (controller, url) async {
          if (completer.isCompleted) {
            return;
          }
          // 页面加载完再等几秒，让它把风控/设备 Cookie 写全
          Future.delayed(const Duration(seconds: 4), () async {
            if (completer.isCompleted) {
              return;
            }
            var map = <String, String>{};
            for (final u in _urls) {
              try {
                var cookies = await cookieManager.getCookies(url: WebUri(u));
                for (final e in cookies) {
                  if (e.name.isNotEmpty && e.value.isNotEmpty) {
                    map[e.name] = e.value;
                  }
                }
              } catch (e) {
                Log.logPrint(e);
              }
            }
            if (map.isEmpty) {
              completer.complete(null);
            } else {
              completer.complete(
                map.entries.map((e) => "${e.key}=${e.value}").join(";"),
              );
            }
          });
        },
      );
      await webView.run();
      var result = await completer.future
          .timeout(const Duration(seconds: 20), onTimeout: () => null);
      return result;
    } catch (e) {
      Log.logPrint(e);
      return null;
    } finally {
      _running = false;
      try {
        await webView?.dispose();
      } catch (e) {
        Log.logPrint(e);
      }
    }
  }
}
