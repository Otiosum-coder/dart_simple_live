import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart' hide Response;
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/requests/http_client.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';

enum DouyinQRStatus {
  loading,
  unscanned,
  scanned,
  expired,
  failed,
}

/// 抖音扫码登录（纯 API，不依赖 WebView）
///
/// 两个接口都不需要登录态、也不需要 Cookie：
/// ```
/// GET  /passport/web/get_qrcode/       -> data.qrcode(base64 PNG) + data.token + data.expire_time
/// POST /passport/web/check_qrconnect/  -> data.status: new / scanning / confirmed / expired
/// ```
/// `check_qrconnect` 的 body 是表单：
/// `need_logo=false&is_frontier=true&token=<token>&is_new_login=1&next=...&need_short_url=true`
///
/// 扫码确认后抖音会返回一个跳转地址，跟着它走才能拿到 `sessionid`
/// （登录态的唯一判据），所以这里同样需要自己维护 Cookie 容器。
class DouyinQRLoginController extends GetxController {
  static const String baseUrl = "https://www.douyin.com";
  static const String userAgent =
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

  /// 二维码默认有效期（秒），拿到 expire_time 后会用服务端的时间
  static const int defaultExpireSeconds = 120;

  var qrImage = Rx<Uint8List?>(null);
  Rx<DouyinQRStatus> qrStatus = DouyinQRStatus.loading.obs;

  String token = "";
  Timer? _timer;
  DateTime? _expireAt;

  /// 简易 Cookie 容器
  final Map<String, String> _jar = {};

  String get _cookieHeader =>
      _jar.entries.map((e) => '${e.key}=${e.value}').join('; ');

  Map<String, String> get _headers => {
        "user-agent": userAgent,
        "referer": "https://www.douyin.com/",
        if (_jar.isNotEmpty) "cookie": _cookieHeader,
      };

  /// 两个接口共用的固定查询参数
  Map<String, dynamic> get _query => {
        "aid": "6383",
        "next": "https://www.douyin.com",
        "need_short_url": "true",
        "need_logo": "false",
        "is_new_login": "1",
        "language": "zh",
        "account_app_language": "zh-CN",
        "is_from_ttaccountsdk": "1",
        "is_from_iesaccountsaas": "1",
        "passport_jssdk_version": "3.4.13-beta.4",
        "passport_jssdk_type": "normal",
        "account_sdk_source": "web",
        "ts": DateTime.now().millisecondsSinceEpoch ~/ 1000,
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
    try {
      var decoded = json.decode(text);
      return decoded is Map ? decoded : {};
    } catch (e) {
      Log.logPrint(e);
      return {};
    }
  }

  Future<Map> _request(
    String method,
    String url, {
    Map<String, dynamic>? query,
    Map<String, dynamic>? form,
  }) async {
    var response = await HttpClient.instance.dio.request(
      url,
      queryParameters: query ?? _query,
      data: form,
      options: Options(
        method: method,
        responseType: ResponseType.plain,
        followRedirects: false,
        validateStatus: (status) => status != null && status < 500,
        contentType:
            form != null ? Headers.formUrlEncodedContentType : null,
        headers: _headers,
      ),
    );
    _collectCookies(response.headers);
    return _asMap(response.data);
  }

  /// 手动跟随跳转，逐跳收集 Set-Cookie
  Future<void> _followRedirects(String url) async {
    var current = url;
    for (var i = 0; i < 8; i++) {
      var response = await HttpClient.instance.dio.get(
        current,
        options: Options(
          responseType: ResponseType.plain,
          followRedirects: false,
          validateStatus: (status) => status != null && status < 500,
          headers: _headers,
        ),
      );
      _collectCookies(response.headers);
      var status = response.statusCode ?? 0;
      Log.i("抖音扫码登录：第${i + 1}跳 status=$status jar=${_jar.length}");
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

  @override
  void onInit() {
    loadQRCode();
    super.onInit();
  }

  Future loadQRCode() async {
    try {
      _timer?.cancel();
      qrStatus.value = DouyinQRStatus.loading;
      token = "";
      qrImage.value = null;

      var result = await _request(
        "GET",
        "$baseUrl/passport/web/get_qrcode/",
      );
      var data = _asMap(result["data"]);
      var qrcode = data["qrcode"]?.toString() ?? "";
      token = data["token"]?.toString() ?? "";
      if (qrcode.isEmpty || token.isEmpty) {
        throw data["description"]?.toString().isNotEmpty == true
            ? data["description"].toString()
            : "获取二维码失败";
      }
      qrImage.value = base64Decode(qrcode);

      var expire = int.tryParse(data["expire_time"]?.toString() ?? "") ?? 0;
      _expireAt = expire > 0
          ? DateTime.fromMillisecondsSinceEpoch(expire * 1000)
          : DateTime.now().add(const Duration(seconds: defaultExpireSeconds));

      qrStatus.value = DouyinQRStatus.unscanned;
      startPoll();
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast(e.toString().replaceAll("Exception:", ""));
      qrStatus.value = DouyinQRStatus.failed;
    }
  }

  void startPoll() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 1500), (timer) {
      var expireAt = _expireAt;
      if (expireAt != null && DateTime.now().isAfter(expireAt)) {
        timer.cancel();
        qrStatus.value = DouyinQRStatus.expired;
        return;
      }
      pollQRStatus();
    });
  }

  Future pollQRStatus() async {
    if (token.isEmpty) {
      return;
    }
    try {
      var result = await _request(
        "POST",
        "$baseUrl/passport/web/check_qrconnect/",
        form: {
          "need_logo": "false",
          "is_frontier": "true",
          "token": token,
          "is_new_login": "1",
          "next": "https://www.douyin.com",
          "need_short_url": "true",
        },
      );
      var data = _asMap(result["data"]);
      var status = data["status"]?.toString() ?? "";
      Log.i("抖音扫码登录：status=$status");
      if (status == "confirmed" || status == "3") {
        _timer?.cancel();
        await loginSuccess(data);
      } else if (status == "scanning" || status == "2") {
        qrStatus.value = DouyinQRStatus.scanned;
      } else if (status == "expired" || status == "4") {
        _timer?.cancel();
        qrStatus.value = DouyinQRStatus.expired;
      } else if (status == "refused" || status == "canceled" || status == "5") {
        _timer?.cancel();
        qrStatus.value = DouyinQRStatus.failed;
      }
      // new / 1：还没扫码，继续轮询
    } catch (e) {
      Log.logPrint(e);
    }
  }

  /// 扫码确认后跟随跳转，收 sessionid
  Future loginSuccess(Map data) async {
    try {
      var redirect = data["redirect_url"]?.toString() ??
          data["url"]?.toString() ??
          "";
      if (redirect.isNotEmpty) {
        await _followRedirects(redirect);
      }
      if (!_jar.containsKey("sessionid")) {
        // 兜底：主站首页有时会补全登录 Cookie
        await _followRedirects("https://www.douyin.com/");
      }
      Log.i("抖音扫码登录：抓到的 Cookie 字段 [${_jar.keys.join(',')}]");
      if (!_jar.containsKey("sessionid")) {
        throw "未能获取登录 Cookie，请改用「Web登录」或「Cookie登录」";
      }
      var cookieStr = _jar.entries.map((e) => '${e.key}=${e.value}').join(';');
      DouyinAccountService.instance.setLoginCookie(cookieStr);
      if (!DouyinAccountService.instance.logined.value) {
        DouyinAccountService.instance.logout();
        throw "登录态不完整，请改用「Web登录」或「Cookie登录」";
      }
      Log.i("抖音扫码登录成功");
      SmartDialog.showToast("抖音登录成功");
      Get.back();
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast(e.toString().replaceAll("Exception:", ""));
      qrStatus.value = DouyinQRStatus.failed;
    }
  }

  @override
  void onClose() {
    _timer?.cancel();
    super.onClose();
  }
}
