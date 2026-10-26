import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart' hide Response;
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/modules/mine/account/huya/huya_udb_request.dart';
import 'package:simple_live_app/requests/http_client.dart';
import 'package:simple_live_app/services/huya_account_service.dart';

enum HuyaQRStatus {
  loading,
  unscanned,
  scanned,
  expired,
  failed,
}

/// 虎牙扫码登录（纯 API，不依赖 WebView）
///
/// 完整链路（已实测打通）：
/// ```
/// POST https://udblgn.huya.com/qrLgn/getQrId    (信封 uri=70001) -> data.qrId
/// GET  https://udblgn.huya.com/qrLgn/getQrImg?k=<qrId>&appId=0    -> PNG
/// POST https://udblgn.huya.com/qrLgn/tryQrLogin (信封 uri=70003) -> data.stage
/// ```
///
/// `data.stage` 状态机：
/// * `0` / `4`  未扫码
/// * `1` / `10` 已扫码，等待手机确认
/// * `2` / `3`  登录成功
/// * `5`      二维码过期
/// * `6`      出错
///
/// **关键点：必须用同一个 Cookie 容器。**
/// 服务端会下发 `web_qrlogin_confirm_id` 把「二维码」和「轮询」绑定在一起，
/// 换了会话就会一直返回 `stage:6`。
///
/// 登录成功后虎牙直接在响应里 Set-Cookie（`udb_uid` / `yyuid` / `username` /
/// `udb_biztoken` …），没有「用 ticket 换 Cookie」的跳转，所以收完 Cookie 即可。
class HuyaQRLoginController extends GetxController {
  static const String userAgent =
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

  /// 二维码有效期（秒）。虎牙前端没给明确时长，按 3 分钟处理。
  static const int expireSeconds = 180;

  static const Duration pollInterval = Duration(milliseconds: 1500);

  var qrImage = Rx<Uint8List?>(null);
  Rx<HuyaQRStatus> qrStatus = HuyaQRStatus.loading.obs;

  String qrId = "";
  Timer? _timer;
  DateTime? _startTime;

  /// 简易 Cookie 容器，保证「取二维码」和「轮询」是同一个会话
  final Map<String, String> _jar = {};

  String get _cookieHeader =>
      _jar.entries.map((e) => '${e.key}=${e.value}').join('; ');

  Map<String, String> get _headers => {
        "content-type": "application/json;charset=UTF-8",
        "user-agent": userAgent,
        "origin": HuyaUdbRequest.baseUrl,
        "referer": "${HuyaUdbRequest.baseUrl}/web/middle/2.5/70001/https/",
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

  /// 发一个带信封的 POST 请求
  Future<Map> _post(String path, String uri, Map<String, dynamic> data) async {
    var url = "${HuyaUdbRequest.baseUrl}$path";
    var response = await HttpClient.instance.dio.request(
      url,
      data: jsonEncode(HuyaUdbRequest.envelope(url: url, uri: uri, data: data)),
      options: Options(
        method: "POST",
        responseType: ResponseType.plain,
        followRedirects: false,
        headers: _headers,
      ),
    );
    _collectCookies(response.headers);
    return _asMap(response.data);
  }

  /// 带 Cookie 的普通 GET（用于兜底补登录态）
  Future<void> _get(String url) async {
    try {
      var response = await HttpClient.instance.dio.get(
        url,
        options: Options(
          responseType: ResponseType.plain,
          followRedirects: false,
          validateStatus: (status) => status != null && status < 500,
          headers: {
            "user-agent": userAgent,
            if (_jar.isNotEmpty) "cookie": _cookieHeader,
          },
        ),
      );
      _collectCookies(response.headers);
    } catch (e) {
      Log.logPrint(e);
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
      qrStatus.value = HuyaQRStatus.loading;
      qrId = "";
      qrImage.value = null;

      var result = await _post("/qrLgn/getQrId", "70001", {
        "behavior": HuyaUdbRequest.behavior(),
        "type": "",
        "domainList": "",
        "page": "https://www.huya.com/",
      });
      if (result["returnCode"] != 0) {
        throw result["message"]?.toString().isNotEmpty == true
            ? result["message"].toString()
            : "获取二维码失败（returnCode=${result["returnCode"]}）";
      }
      qrId = result["data"]?["qrId"]?.toString() ?? "";
      if (qrId.isEmpty) {
        throw "获取二维码失败：qrId 为空";
      }

      // 二维码图不需要 Cookie，但这里还是走同一个会话，避免服务端校验来源
      var imageResponse = await HttpClient.instance.dio.get(
        "${HuyaUdbRequest.baseUrl}/qrLgn/getQrImg",
        queryParameters: {"k": qrId, "appId": HuyaUdbRequest.appId},
        options: Options(
          responseType: ResponseType.bytes,
          headers: {
            "user-agent": userAgent,
            "referer": "https://www.huya.com/",
            if (_jar.isNotEmpty) "cookie": _cookieHeader,
          },
        ),
      );
      var bytes = imageResponse.data as List<int>?;
      if (bytes == null || bytes.isEmpty) {
        throw "二维码图片为空";
      }
      qrImage.value = Uint8List.fromList(bytes);

      qrStatus.value = HuyaQRStatus.unscanned;
      _startTime = DateTime.now();
      startPoll();
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast(e.toString().replaceAll("Exception:", ""));
      qrStatus.value = HuyaQRStatus.failed;
    }
  }

  void startPoll() {
    _timer?.cancel();
    _timer = Timer.periodic(pollInterval, (timer) {
      var start = _startTime;
      if (start != null &&
          DateTime.now().difference(start).inSeconds > expireSeconds) {
        timer.cancel();
        qrStatus.value = HuyaQRStatus.expired;
        return;
      }
      pollQRStatus();
    });
  }

  Future pollQRStatus() async {
    if (qrId.isEmpty) {
      return;
    }
    try {
      var result = await _post("/qrLgn/tryQrLogin", "70003", {
        "qrId": qrId,
        "remember": "0",
        "domainList": "",
        "behavior": HuyaUdbRequest.behavior(),
        "page": "https://www.huya.com/",
      });
      if (result["returnCode"] != 0) {
        // 偶发失败不打断轮询
        Log.i("虎牙扫码登录：轮询返回 ${result["returnCode"]} ${result["message"]}");
        return;
      }
      var data = _asMap(result["data"]);
      var stage = data["stage"];
      Log.i("虎牙扫码登录：stage=$stage jar=${_jar.length}");
      if (stage == 2 || stage == 3) {
        _timer?.cancel();
        await loginSuccess(data);
      } else if (stage == 1 || stage == 10) {
        qrStatus.value = HuyaQRStatus.scanned;
      } else if (stage == 5) {
        _timer?.cancel();
        qrStatus.value = HuyaQRStatus.expired;
      } else if (stage == 6) {
        _timer?.cancel();
        qrStatus.value = HuyaQRStatus.failed;
      }
      // 0 / 4：还没扫码，继续轮询
    } catch (e) {
      Log.logPrint(e);
    }
  }

  /// 扫码成功后收 Cookie
  Future loginSuccess(Map data) async {
    try {
      if (!_jar.containsKey("udb_uid")) {
        // 兜底：主站首页有时会补全登录 Cookie
        await _get("https://www.huya.com/");
      }
      Log.i("虎牙扫码登录：抓到的 Cookie 字段 [${_jar.keys.join(',')}]");
      if (!_jar.containsKey("udb_uid")) {
        throw "未能获取登录 Cookie，请改用「Web登录」或「Cookie登录」";
      }
      var cookieStr = _jar.entries.map((e) => '${e.key}=${e.value}').join(';');
      HuyaAccountService.instance.setCookie(cookieStr);
      if (!HuyaAccountService.instance.logined.value) {
        HuyaAccountService.instance.logout();
        throw "登录态不完整，请改用「Web登录」或「Cookie登录」";
      }
      Log.i("虎牙扫码登录成功：${HuyaAccountService.instance.name.value}");
      SmartDialog.showToast("虎牙登录成功");
      Get.back();
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast(e.toString().replaceAll("Exception:", ""));
      qrStatus.value = HuyaQRStatus.failed;
    }
  }

  @override
  void onClose() {
    _timer?.cancel();
    if (qrId.isNotEmpty) {
      // 退出页面时释放二维码，避免占用
      _post("/qrLgn/cancelLogin", "70009", {"qrId": qrId})
          .catchError((e) => <String, dynamic>{});
    }
    super.onClose();
  }
}
