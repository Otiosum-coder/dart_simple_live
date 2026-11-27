import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/modules/mine/account/huya/huya_udb_request.dart';
import 'package:simple_live_app/requests/http_client.dart';
import 'package:simple_live_app/services/huya_cookie_harvester.dart';

/// 发送短信验证码的结果
class HuyaSmsCodeResult {
  final bool ok;
  final int code;
  final String message;

  /// 服务端在风控场景下会返回 authId，登录时回传
  final String authId;

  /// 是否被风控要求先完成安全验证（虎牙滑块验证）
  final bool needCaptcha;

  /// 风控会话标识（需写入 udb_wession Cookie，验证通过后重试发送）
  final String sessionData;

  /// 安全验证页地址（strategy.dataType == 4 时下发，需用 WebView 打开完成滑块）
  final String safeAuthUrl;

  const HuyaSmsCodeResult({
    required this.ok,
    required this.code,
    required this.message,
    this.authId = "",
    this.needCaptcha = false,
    this.sessionData = "",
    this.safeAuthUrl = "",
  });
}

/// 短信登录结果
class HuyaSmsLoginResult {
  final bool ok;
  final int code;
  final String message;

  /// 登录成功后汇总好的整条 Cookie（含 udb_uid）
  final String cookie;
  final Object? cookieMetadata;

  const HuyaSmsLoginResult({
    required this.ok,
    required this.code,
    required this.message,
    this.cookie = "",
    this.cookieMetadata,
  });
}

/// 虎牙「手机号 + 短信验证码」登录的纯 API 实现（不依赖 WebView）。
///
/// 逆向自虎牙官方 UDB Web SDK（udb_login_v2），与扫码登录共用同一套信封协议：
/// * 发送验证码：POST https://udblgn.huya.com/web/v2/smsCode  uri=60027
///   body.data = {phone, behavior, page}
/// * 短信登录：  POST https://udblgn.huya.com/web/v2/smsLogin uri=60025
///   body.data = {phone, authId, authcode, sessionData, domainList, remember, behavior, page}
///
/// 返回体 returnCode == 0 视为成功；登录成功时服务端直接 Set-Cookie
/// （udb_uid / yyuid / username / udb_biztoken …），与扫码登录一致，
/// 没有「用 ticket 换 Cookie」的跳转。
class HuyaPhoneLoginApi {
  HuyaPhoneLoginApi({Dio? dio, String? userAgent})
      : _dio = dio ?? HttpClient.instance.dio,
        userAgent = userAgent ?? defaultUserAgent;

  final Dio _dio;
  final String userAgent;

  static const String defaultUserAgent =
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

  /// 简易 Cookie 容器：引导请求、发码、登录必须同一会话，
  /// 否则服务端下发的 udb_uid 绑定不到本次登录。
  final HuyaCookieJar _jar = HuyaCookieJar();
  bool _sessionInited = false;

  Map<String, String> get cookies => Map.unmodifiable(_jar);

  String get cookieHeader => _jar.header;

  String get _wbContext =>
      "WB-${_jar["udb_guiddata"] ?? ""}-${_jar["__yamid_new"] ?? ""}-${_jar["guid"] ?? ""}";

  String get _sdid => _jar["sdid"] ?? "";

  static String _newGuid() {
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

  void _ensureSession() {
    if (_sessionInited) {
      return;
    }
    _sessionInited = true;
    _jar["guid"] ??= _newGuid();
    _jar["__yamid_new"] ??= _newGuid().toUpperCase();
    _jar["udb_guiddata"] ??= _newGuid();
    _jar["sdid"] ??= "${_newGuid()}-${_newGuid()}";
  }

  /// 先访问 i.huya.com，让服务端下发 guid / __yamid_new / udb_guiddata / sdid，
  /// 保证 context 与实际会话一致。
  Future<void> _bootstrap() async {
    if (_jar.isEmpty) {
      await _get("https://i.huya.com/");
    }
    _ensureSession();
  }

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
        if (_jar.isNotEmpty)
          "cookie": _jar.headerFor(Uri.parse(HuyaUdbRequest.baseUrl)),
      };

  void _collectCookies(Headers headers, Uri source) {
    _jar.collect(headers['set-cookie'] ?? const [], source);
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

  int _int(dynamic value) {
    if (value is int) {
      return value;
    }
    return int.tryParse("${value ?? ""}") ?? -1;
  }

  Future<Map> _post(String path, String uri, Map<String, dynamic> data) async {
    var url = "${HuyaUdbRequest.baseUrl}$path";
    var reqid = DateTime.now().millisecondsSinceEpoch.toString();
    var response = await _dio.request(
      url,
      data: jsonEncode(
        HuyaUdbRequest.envelope(
          uri: uri,
          data: data,
          context: _wbContext,
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
    _collectCookies(response.headers, response.realUri);
    return _asMap(response.data);
  }

  Future<void> _get(String url) async {
    var response = await _dio.get(
      url,
      options: Options(
        responseType: ResponseType.plain,
        followRedirects: false,
        validateStatus: (status) => status != null && status < 500,
        headers: {
          "user-agent": userAgent,
          if (_jar.isNotEmpty) "cookie": _jar.headerFor(Uri.parse(url)),
        },
      ),
    );
    _collectCookies(response.headers, response.realUri);
  }

  /// 发送短信验证码
  ///
  /// 触发风控（returnCode=10030）时，服务端会返回 sessionData 与
  /// strategys[0].data（滑块安全验证页地址）。前端需用 WebView 打开该地址，
  /// 用户完成滑块后页面会回传 param.data.authId，再带上 [authcode] 重试本方法。
  Future<HuyaSmsCodeResult> sendCode(String phone,
      {String authcode = ""}) async {
    await _bootstrap();
    var result = await _post("/web/v2/smsCode", "60027", {
      "phone": phone,
      if (authcode.isNotEmpty) "authcode": authcode,
      "behavior": HuyaUdbRequest.behavior(),
      "page": HuyaUdbRequest.page,
    });
    var code = _int(result["returnCode"]);
    var message = (result["description"] ?? result["message"] ?? "").toString();
    var data = _asMap(result["data"]);
    var authId = (data["authId"] ?? "").toString();
    var sessionData = (data["sessionData"] ?? "").toString();
    var strategys = data["strategys"];
    var safeAuthUrl = "";
    if (strategys is List) {
      for (var item in strategys) {
        if (item is! Map) {
          continue;
        }
        var dataType = _int(item["dataType"]);
        var url = (item["data"] ?? "").toString();
        if (dataType == 4 && url.isNotEmpty) {
          safeAuthUrl = url;
          break;
        }
      }
    }
    if (sessionData.isNotEmpty) {
      // 与网页端一致：把风控会话写进 Cookie，验证通过后重试才会被认可
      _jar["udb_wession"] = sessionData;
    }
    var needCaptcha =
        safeAuthUrl.isNotEmpty || (strategys is List && strategys.isNotEmpty);
    Log.i("虎牙短信登录：发送验证码 returnCode=$code $message captcha=$needCaptcha");
    return HuyaSmsCodeResult(
      ok: code == 0,
      code: code,
      message: message,
      authId: authId,
      needCaptcha: needCaptcha,
      sessionData: sessionData,
      safeAuthUrl: safeAuthUrl,
    );
  }

  /// 短信验证码登录
  Future<HuyaSmsLoginResult> login({
    required String phone,
    required String authcode,
    String authId = "",
    String sessionData = "",
  }) async {
    await _bootstrap();
    // 官方 SDK 取 Cookie.get("udb_wession") 作为 sessionData，
    // 它是 10030 风控响应里的原始 sessionData 字符串，不是整条 Cookie。
    var sessionCookie = (_jar["udb_wession"] ?? "").trim();
    var result = await _post("/web/v2/smsLogin", "60025", {
      "phone": phone,
      "authId": authId,
      "authcode": authcode,
      "sessionData": sessionData.isNotEmpty ? sessionData : sessionCookie,
      "domainList": "",
      "remember": "1",
      "behavior": HuyaUdbRequest.behavior(),
      "page": HuyaUdbRequest.page,
    });
    var code = _int(result["returnCode"]);
    var message = (result["description"] ?? result["message"] ?? "").toString();
    Log.i("虎牙短信登录：提交验证码 returnCode=$code $message 字段[${_jar.keys.join(',')}]");
    if (code != 0) {
      return HuyaSmsLoginResult(ok: false, code: code, message: message);
    }
    // 兜底：个别情况下 udb_uid 只在主站域名补全
    if (!_jar.containsKey("udb_uid")) {
      try {
        await _get("https://www.huya.com/");
      } catch (e) {
        Log.logPrint(e);
      }
    }
    var cookieStr = cookieHeader;
    var ok = (_jar["udb_uid"] ?? "").isNotEmpty;
    return HuyaSmsLoginResult(
        ok: ok,
        code: code,
        message: ok ? "登录成功" : "登录未完成，请重试或改用扫码/Cookie 登录",
        cookie: cookieStr,
        cookieMetadata: _jar.metadata);
  }
}
