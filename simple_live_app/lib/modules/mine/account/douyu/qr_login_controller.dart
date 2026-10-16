import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart' hide Response;
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/requests/http_client.dart';
import 'package:simple_live_app/services/douyu_account_service.dart';

enum DouyuQRStatus {
  loading,
  unscanned,
  scanned,
  expired,
  failed,
}

/// 斗鱼扫码登录
///
/// 接口均在 passport.douyu.com（已实测）：
/// - POST /scan/generateCode  form: client_id=1, isMultiAccount=false
///   → {error:0, data:{expire:300, url:"<二维码内容>", code:"<轮询用>"}}
/// - GET  /japi/scan/auth?time=<ms>&code=<code>
///   → error: -2 未扫码 / 1 已扫码待确认 / 0 成功 / -1 失败
/// - POST /scan/deleteCode    form: code
///
/// 扫码成功后返回的 url（www.douyu.com/api/passport/login?...&loginType=scanCheck）
/// 是一串跳转，浏览器靠它设置登录 Cookie。这里用简单 cookie 容器 + 手动逐跳跟随
/// 来收集每一跳的 Set-Cookie。
///
/// 注意：斗鱼这些接口的响应可能是 JSONP 而不是纯 JSON，所以统一用明文响应再自行解析。
class DouyuQRLoginController extends GetxController {
  static const String baseUrl = "https://passport.douyu.com";
  static const String userAgent =
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36 Edg/114.0.1823.43";

  /// 二维码有效期（秒），斗鱼返回的 expire 是 300
  static const int expireSeconds = 300;

  var qrcodeUrl = "".obs;
  String qrcodeCode = "";
  Rx<DouyuQRStatus> qrStatus = DouyuQRStatus.loading.obs;
  Timer? _timer;
  DateTime? _startTime;

  /// 简易 cookie 容器，模拟浏览器在扫码流程中保持 Cookie
  final Map<String, String> _jar = {};

  String get _cookieHeader =>
      _jar.entries.map((e) => '${e.key}=${e.value}').join('; ');

  Map<String, String> get _headers => {
        "user-agent": userAgent,
        "referer": "$baseUrl/member/login",
        "origin": baseUrl,
        "x-requested-with": "XMLHttpRequest",
        if (_jar.isNotEmpty) "cookie": _cookieHeader,
      };

  void _collectCookies(Headers headers) {
    headers["set-cookie"]?.forEach((element) {
      var item = element.split(';').first.trim();
      var index = item.indexOf('=');
      if (index <= 0) {
        return;
      }
      _jar[item.substring(0, index).trim()] =
          item.substring(index + 1).trim();
    });
  }

  /// 统一请求：明文响应（避免 JSONP 解析异常），不自动跳转，自己收集 Cookie
  Future<Response<dynamic>> _request(
    String method,
    String url, {
    Map<String, dynamic>? form,
    Map<String, dynamic>? query,
  }) async {
    var response = await HttpClient.instance.dio.request(
      url,
      data: form,
      queryParameters: query,
      options: Options(
        method: method,
        responseType: ResponseType.plain,
        followRedirects: false,
        validateStatus: (status) => status != null && status < 500,
        headers: _headers,
        contentType:
            form != null ? Headers.formUrlEncodedContentType : null,
      ),
    );
    _collectCookies(response.headers);
    return response;
  }

  /// 手动跟随跳转，逐跳累积 Set-Cookie
  Future<void> _followRedirects(String url) async {
    var current = url;
    for (var i = 0; i < 6; i++) {
      var response = await _request("GET", current);
      var status = response.statusCode ?? 0;
      Log.i("斗鱼扫码登录：第${i + 1}跳 status=$status jar=${_jar.length}");
      if (status >= 300 && status < 400) {
        var location = response.headers.value("location");
        if (location == null || location.isEmpty) {
          break;
        }
        current = location.startsWith("http")
            ? location
            : Uri.parse(current).resolve(location).toString();
        continue;
      }
      break;
    }
  }

  /// 响应可能是 JSON，也可能是 JSONP（callback({...})）
  Map _asMap(dynamic value) {
    if (value is Map) {
      return value;
    }
    if (value is! String) {
      return {};
    }
    var text = value.trim();
    if (text.isEmpty) {
      return {};
    }
    var start = text.indexOf('{');
    var end = text.lastIndexOf('}');
    if (start < 0 || end <= start) {
      return {};
    }
    var decoded = json.decode(text.substring(start, end + 1));
    return decoded is Map ? decoded : {};
  }

  @override
  void onInit() {
    loadQRCode();
    super.onInit();
  }

  Future loadQRCode() async {
    try {
      _timer?.cancel();
      qrStatus.value = DouyuQRStatus.loading;
      qrcodeCode = "";
      var response = await _request(
        "POST",
        "$baseUrl/scan/generateCode",
        form: {"client_id": "1", "isMultiAccount": "false"},
      );
      var result = _asMap(response.data);
      if (result["error"] != 0) {
        throw result["data"]?.toString() ?? "获取二维码失败";
      }
      qrcodeCode = result["data"]["code"].toString();
      qrcodeUrl.value = result["data"]["url"].toString();
      qrStatus.value = DouyuQRStatus.unscanned;
      _startTime = DateTime.now();
      startPoll();
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast(e.toString());
      qrStatus.value = DouyuQRStatus.failed;
    }
  }

  void startPoll() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      var start = _startTime;
      if (start != null &&
          DateTime.now().difference(start).inSeconds > expireSeconds) {
        timer.cancel();
        qrStatus.value = DouyuQRStatus.expired;
        return;
      }
      pollQRStatus();
    });
  }

  Future pollQRStatus() async {
    if (qrcodeCode.isEmpty) {
      return;
    }
    try {
      var response = await _request(
        "GET",
        "$baseUrl/japi/scan/auth",
        query: {
          "time": DateTime.now().millisecondsSinceEpoch,
          "code": qrcodeCode,
        },
      );
      var result = _asMap(response.data);
      var error = result["error"];
      if (error == 0) {
        _timer?.cancel();
        await loginSuccess(result["data"]);
      } else if (error == 1) {
        qrStatus.value = DouyuQRStatus.scanned;
      } else if (error == -1) {
        _timer?.cancel();
        qrStatus.value = DouyuQRStatus.failed;
      }
      // -2：客户端还未扫码，继续轮询
    } catch (e) {
      Log.logPrint(e);
    }
  }

  /// 扫码成功后跟随跳转链路，从 Set-Cookie 中收集登录 Cookie
  Future loginSuccess(dynamic data) async {
    try {
      var url = _asMap(data)["url"]?.toString() ?? "";
      if (url.isEmpty) {
        throw "登录成功，但斗鱼未返回跳转地址";
      }
      for (var candidate in [
        url,
        "$url&callback=json_callback",
        "$url&callback=appClient_json_callback",
      ]) {
        await _followRedirects(candidate);
        if (_jar.containsKey("acf_uid")) {
          break;
        }
      }
      if (!_jar.containsKey("acf_uid")) {
        // 兜底：主站首页有时会补全登录 Cookie
        await _request("GET", "https://www.douyu.com/");
      }
      Log.i("斗鱼扫码登录：抓到的 Cookie 字段 [${_jar.keys.join(',')}]");
      if (_jar.isEmpty) {
        throw "未能获取登录 Cookie，请改用「手动输入 Cookie」";
      }
      var cookieStr = _jar.entries.map((e) => '${e.key}=${e.value}').join(';');
      DouyuAccountService.instance.setCookie(cookieStr);
      if (!DouyuAccountService.instance.logined.value) {
        DouyuAccountService.instance.logout();
        throw "Cookie 里缺少 acf_uid，登录态不完整，请改用「手动输入 Cookie」";
      }
      Log.i("斗鱼扫码登录成功");
      SmartDialog.showToast("斗鱼登录成功");
      Get.back();
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast(e.toString());
      qrStatus.value = DouyuQRStatus.failed;
    }
  }

  @override
  void onClose() {
    _timer?.cancel();
    if (qrcodeCode.isNotEmpty) {
      // 退出页面时释放二维码，避免占用
      _request("POST", "$baseUrl/scan/deleteCode",
          form: {"code": qrcodeCode}).catchError((e) => e as Response);
    }
    super.onClose();
  }
}