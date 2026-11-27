import 'dart:collection';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/log.dart';

/// 虎牙风控安全验证（滑块拼图）页面。
///
/// 触发 10030「需要进一步认证」时，服务端会下发安全验证页地址
/// （strategys[0].data，页内是虎牙的滑块拼图），用户完成后页面会向父窗口
/// postMessage 一条 {eventType:"udbSafeAuth", param:{data:{authId:...}}}。
/// 这里用 WebView 打开该页面，注入脚本捕获这条消息，把 authId 通过
/// [Get.back] 返回给调用方；调用方带上 authId 重新请求发送验证码。
class HuyaSafeAuthPage extends StatefulWidget {
  const HuyaSafeAuthPage({
    super.key,
    required this.url,
    required this.userAgent,
    this.cookies = const {},
  });

  final String url;
  final String userAgent;

  /// 发送验证码时的会话 Cookie（含 udb_wession / udb_guiddata / sdid），
  /// 写入 WebView，保证滑块验证结果与发码请求绑定在同一会话。
  final Map<String, String> cookies;

  @override
  State<HuyaSafeAuthPage> createState() => _HuyaSafeAuthPageState();
}

class _HuyaSafeAuthPageState extends State<HuyaSafeAuthPage> {
  bool _loading = true;
  bool _finished = false;
  bool _ready = false;

  /// 注入到文档开头：监听页面自身 postMessage 出来的安全验证结果。
  /// 页面是通过 window.parent.postMessage 通知父窗口的，本页即父窗口，
  /// 因此监听 window 的 message 事件即可捕获；同时屏蔽 window.close，
  /// 避免验证成功后页面直接关闭导致来不及回传 authId。
  static const String _bridgeJs = r'''
(function () {
  function report(obj) {
    try { window.flutter_inappwebview.callHandler('HuyaSafeAuth', obj); } catch (e) {}
  }
  window.addEventListener('message', function (e) {
    try {
      var d = e && e.data;
      if (typeof d === 'string') { d = JSON.parse(d); }
      if (d && typeof d === 'object' && typeof d.eventType === 'string'
          && d.eventType.indexOf('udbSafeAuth') === 0) {
        report(d);
      }
    } catch (err) {}
  });
  try { window.close = function () {}; } catch (e) {}
})();
''';

  @override
  void initState() {
    super.initState();
    _prepareCookies();
  }

  Future<void> _prepareCookies() async {
    if (widget.cookies.isNotEmpty) {
      final manager = CookieManager.instance();
      const hosts = [
        "https://aq.huya.com",
        "https://udblgn.huya.com",
        "https://www.huya.com",
        "https://i.huya.com",
      ];
      for (final host in hosts) {
        for (final entry in widget.cookies.entries) {
          try {
            await manager.setCookie(
              url: WebUri(host),
              name: entry.key,
              value: entry.value,
              path: "/",
            );
          } catch (_) {
            // 单个 Cookie 写入失败不影响滑块页面本身
          }
        }
      }
    }
    if (mounted) {
      setState(() => _ready = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("安全验证")),
      body: !_ready
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: [
                InAppWebView(
                  initialUrlRequest: URLRequest(url: WebUri(widget.url)),
                  initialSettings: InAppWebViewSettings(
                    userAgent: widget.userAgent,
                    javaScriptEnabled: true,
                    thirdPartyCookiesEnabled: true,
                    domStorageEnabled: true,
                    useShouldOverrideUrlLoading: false,
                  ),
                  initialUserScripts: UnmodifiableListView<UserScript>([
                    UserScript(
                      source: _bridgeJs,
                      injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                    ),
                  ]),
                  onWebViewCreated: (controller) {
                    controller.addJavaScriptHandler(
                      handlerName: "HuyaSafeAuth",
                      callback: _onMessage,
                    );
                  },
                  onLoadStart: (controller, url) {
                    if (!mounted) {
                      return;
                    }
                    setState(() => _loading = true);
                  },
                  onLoadStop: (controller, url) {
                    if (!mounted) {
                      return;
                    }
                    setState(() => _loading = false);
                  },
                ),
                if (_loading) const LinearProgressIndicator(),
              ],
            ),
    );
  }

  void _onMessage(List<dynamic> args) {
    if (_finished || args.isEmpty) {
      return;
    }
    var data = _toMap(args.first);
    if (data.isEmpty) {
      return;
    }
    var type = (data["eventType"] ?? "").toString();
    Log.i("虎牙安全验证回调：type=$type data=${_safeJson(data)}");
    if (type == "udbSafeAuth") {
      var authId = _extractAuthId(data);
      if (authId.isEmpty) {
        _fail("安全验证结果异常，请重试");
        return;
      }
      _finished = true;
      Get.back(result: authId);
    } else if (type == "udbSafeAuthError") {
      _fail("安全验证失败，请重试");
    } else if (type == "udbSafeAuthExpiredError") {
      _fail("安全验证已过期，请重试");
    }
  }

  Map _toMap(dynamic value) {
    if (value is Map) {
      return value.map((key, val) => MapEntry(key.toString(), val));
    }
    if (value is String && value.isNotEmpty) {
      try {
        var decoded = json.decode(value);
        if (decoded is Map) {
          return decoded.map((key, val) => MapEntry(key.toString(), val));
        }
      } catch (e) {
        Log.logPrint(e);
      }
    }
    return {};
  }

  String _extractAuthId(Map data) {
    var authId = "";
    var param = data["param"];
    if (param is Map) {
      var inner = param["data"];
      if (inner is Map) {
        authId = (inner["authId"] ?? "").toString();
      }
      if (authId.isEmpty) {
        authId = (param["authId"] ?? "").toString();
      }
    }
    if (authId.isEmpty) {
      authId = (data["authId"] ?? "").toString();
    }
    return authId;
  }

  String _safeJson(Map data) {
    try {
      return json.encode(data);
    } catch (e) {
      return data.toString();
    }
  }

  void _fail(String message) {
    if (_finished) {
      return;
    }
    _finished = true;
    SmartDialog.showToast(message);
    Get.back();
  }
}
