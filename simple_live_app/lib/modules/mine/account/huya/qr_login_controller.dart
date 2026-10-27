import 'dart:async';
import 'dart:convert';
import 'dart:math';
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
  static const int expireSeconds = 300;

  static const Duration pollInterval = Duration(milliseconds: 1500);

  var qrImage = Rx<Uint8List?>(null);
  Rx<HuyaQRStatus> qrStatus = HuyaQRStatus.loading.obs;

  String qrId = "";

  /// 是否为本次会话生成过 guid（虎牙用 guid/__yamid_new Cookie 绑定上下文）
  bool _sessionInited = false;

  /// 是否已经给服务端发过「已扫码」通知（只发一次）
  bool _scanNotified = false;

  String _newGuid() {
    var random = Random.secure();
    var chars = "0123456789abcdef";
    var buffer = StringBuffer();
    for (var i = 0; i < 32; i++) {
      if (i == 12) {
        buffer.write("4");
      } else if (i == 16) {
        buffer.write(chars[8 + random.nextInt(4)]);
      } else {
        buffer.write(chars[random.nextInt(16)]);
      }
    }
    return buffer.toString();
  }

  /// 网页端 context 格式：WB-<udb_guiddata>-<__yamid_new>-<guid>
  /// （三个 Cookie 的值，缺一个服务端就会把扫码确认当成别的会话）
  String get _wbContext =>
      "WB-${_jar["udb_guiddata"] ?? ""}-${_jar["__yamid_new"] ?? ""}-${_jar["guid"] ?? ""}";

  String get _sdid => _jar["sdid"] ?? "";

  /// 补齐会话 Cookie（只做一次）：优先用引导请求拿到的值，缺哪个补哪个
  void _ensureSession() {
    if (_sessionInited) {
      return;
    }
    _sessionInited = true;
    _jar["guid"] ??= _newGuid();
    _jar["__yamid_new"] ??= _newGuid().toUpperCase();
    _jar["udb_guiddata"] ??= _newGuid();
    _jar["sdid"] ??= _newGuid() + "-" + _newGuid();
  }

  /// 先访问个人中心：服务端会下发 guid / __yamid_new / udb_guiddata / sdid，
  /// 这些 Cookie 与 context 必须一致，否则扫码确认绑定不到同一会话。
  Future<void> _bootstrap() async {
    await _get("https://i.huya.com/");
  }
  Timer? _timer;
  DateTime? _startTime;

  /// 简易 Cookie 容器，保证「取二维码」和「轮询」是同一个会话
  final Map<String, String> _jar = {};

  String get _cookieHeader =>
      _jar.entries.map((e) => '${e.key}=${e.value}').join('; ');

  Map<String, String> _headersFor(String uri, String reqid) => {
        "accept": "*/*",
        "content-type": "application/json;charset=UTF-8",
        "user-agent": userAgent,
        "origin": HuyaUdbRequest.baseUrl,
        "context": _wbContext,
        "uri": uri,
        "reqid": reqid,
        "referer":
            "${HuyaUdbRequest.baseUrl}/web/middle/${HuyaUdbRequest.version}/$reqid/https/${_jar["udb_guiddata"] ?? ""}",
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
  Future<Map> _post(
    String path,
    String uri,
    Map<String, dynamic> data, {
    String? context,
  }) async {
    var url = "${HuyaUdbRequest.baseUrl}$path";
    var reqid = DateTime.now().millisecondsSinceEpoch.toString();
    var response = await HttpClient.instance.dio.request(
      url,
      data: jsonEncode(
        HuyaUdbRequest.envelope(
          uri: uri,
          data: data,
          context: context ?? _wbContext,
          sdid: _sdid,
          requestId: reqid,
        ),
      ),
      options: Options(
        method: "POST",
        responseType: ResponseType.plain,
        followRedirects: false,
        headers: _headersFor(uri, reqid),
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
      _scanNotified = false;
      await _bootstrap();
      _ensureSession();
      qrImage.value = null;

      var result = await _post("/qrLgn/getQrId", "70001", {
        "behavior": HuyaUdbRequest.behavior(),
        "type": "",
        "domainList": "",
        "page": HuyaUdbRequest.page,
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
      var result = await _post("/qrLgn/tryQrLogin", "70003", context: _wbContext, {
        "qrId": qrId,
        "remember": "1",
        "domainList": "",
        "behavior": HuyaUdbRequest.behavior(),
        "page": HuyaUdbRequest.page,
      });
      if (result["returnCode"] != 0) {
        // 偶发失败不打断轮询
        Log.i("虎牙扫码登录：轮询返回 ${result["returnCode"]} ${result["message"]}");
        return;
      }
      var data = _asMap(result["data"]);
      var stage = data["stage"];
      Log.i("虎牙扫码登录：stage=$stage jar=${_jar.length} data=${jsonEncode(data)}");
      if (stage == 2 || stage == 3) {
        _timer?.cancel();
        await loginSuccess(data);
        return;
      }
      // 兜底：有些情况服务端不推 stage，只直接 Set-Cookie udb_uid
      if (_jar.containsKey("udb_uid")) {
        _timer?.cancel();
        await loginSuccess(data);
        return;
      }
      if (stage == 1 || stage == 10 || stage == 7) {
        // 1/10 已扫待确认；7 为实测出现但文档未覆盖的状态（扫码后出现），
        // 当作「已扫码」继续轮询，等 Cookie
        if (!_scanNotified) {
          _scanNotified = true;
          try {
            var notify = await _post(
              "/qrLgn/scanQrPicNotify",
              "70005",
              {
                "qrId": qrId,
                "behavior": HuyaUdbRequest.behavior(),
                "page": HuyaUdbRequest.page,
              },
              context: _wbContext,
            );
            Log.i("虎牙扫码登录：scanQrPicNotify -> ${jsonEncode(notify)}");
          } catch (e) {
            Log.logPrint(e);
          }
        }
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