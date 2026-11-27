import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/modules/mine/account/huya/huya_phone_login_api.dart';
import 'package:simple_live_app/modules/mine/account/huya/huya_phone_login_controller.dart';

/// 模拟 HTTP 适配器：拦截 dio 请求，按路径返回预置响应，并记录请求体
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.onRequest);

  final Future<ResponseBody> Function(RequestOptions options) onRequest;
  final List<RequestOptions> captured = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    captured.add(options);
    return onRequest(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Map<String, dynamic> body,
    {List<String> setCookie = const []}) {
  return ResponseBody.fromString(
    jsonEncode(body),
    200,
    headers: {
      Headers.contentTypeHeader: ["application/json;charset=UTF-8"],
      if (setCookie.isNotEmpty) "set-cookie": setCookie,
    },
  );
}

HuyaPhoneLoginApi _apiWith(
    Future<ResponseBody> Function(RequestOptions) handler) {
  var dio = Dio(BaseOptions(responseType: ResponseType.plain));
  dio.httpClientAdapter = _FakeAdapter(handler);
  return HuyaPhoneLoginApi(dio: dio);
}

const _bootstrapCookies = [
  "guid=0123456789abcdef0123456789abcdef; Path=/",
  "__yamid_new=0123456789ABCDEF0123456789ABCDEF; Path=/",
  "udb_guiddata=0123456789abcdef0123456789abcdef; Path=/",
  "sdid=0123456789abcdef0123456789abcdef-0123456789abcdef0123456789abcdef; Path=/",
];

void main() {
  group("HuyaPhoneLoginApi.sendCode", () {
    test("手机号格式错误时返回失败并带服务端提示", () async {
      var api = _apiWith((options) async {
        if (options.method == "GET") {
          return _json({}, setCookie: _bootstrapCookies);
        }
        return _json({"returnCode": 101, "description": "手机号码格式不正确!"});
      });
      var result = await api.sendCode("00000000000");
      expect(result.ok, isFalse);
      expect(result.code, 101);
      expect(result.message, contains("手机号"));
    });

    test("发送成功时返回 authId 且信封 uri=60027", () async {
      late RequestOptions postOptions;
      var api = _apiWith((options) async {
        if (options.method == "GET") {
          return _json({}, setCookie: _bootstrapCookies);
        }
        postOptions = options;
        return _json({
          "returnCode": 0,
          "data": {"authId": "auth-1"},
        });
      });
      var result = await api.sendCode("13800000000");
      expect(result.ok, isTrue);
      expect(result.authId, "auth-1");

      var body = jsonDecode(postOptions.data as String) as Map;
      expect(body["uri"], "60027");
      expect(body["appId"], "5002");
      expect(postOptions.headers["uri"], "60027");
      expect(postOptions.uri.path, "/web/v2/smsCode");
      expect((body["data"] as Map)["phone"], "13800000000");
    });
  });

  group("HuyaPhoneLoginApi.sendCode 风控安全验证", () {
    const safeUrl =
        "https://aq.huya.com/p/safe_auth/pt_auth.html?param=abc&sceneType=0&appId=5002";

    test("10030 时返回安全验证地址与 sessionData，并写入 udb_wession", () async {
      var api = _apiWith((options) async {
        if (options.method == "GET") {
          return _json({}, setCookie: _bootstrapCookies);
        }
        return _json({
          "returnCode": 10030,
          "description": "需要进一步认证",
          "data": {
            "code": 10030,
            "sessionData": "SESS-1",
            "strategys": [
              {"strategy": 64, "dataType": 4, "data": safeUrl}
            ]
          }
        });
      });
      var result = await api.sendCode("13800000000");
      expect(result.ok, isFalse);
      expect(result.code, 10030);
      expect(result.needCaptcha, isTrue);
      expect(result.safeAuthUrl, safeUrl);
      expect(result.sessionData, "SESS-1");
      expect(api.cookieHeader, contains("udb_wession=SESS-1"));
    });

    test("完成安全验证后带 authcode 重试发送", () async {
      var postCount = 0;
      late RequestOptions retryOptions;
      var api = _apiWith((options) async {
        if (options.method == "GET") {
          return _json({}, setCookie: _bootstrapCookies);
        }
        postCount++;
        if (postCount == 1) {
          return _json({
            "returnCode": 10030,
            "data": {
              "sessionData": "SESS-2",
              "strategys": [
                {"strategy": 64, "dataType": 4, "data": safeUrl}
              ]
            }
          });
        }
        retryOptions = options;
        return _json({
          "returnCode": 0,
          "data": {"authId": "auth-after-captcha"}
        });
      });
      var first = await api.sendCode("13800000000");
      expect(first.needCaptcha, isTrue);
      var second = await api.sendCode("13800000000", authcode: "SAFE-AUTH-1");
      expect(second.ok, isTrue);
      expect(second.authId, "auth-after-captcha");
      var body = jsonDecode(retryOptions.data as String) as Map;
      var data = body["data"] as Map;
      expect(data["authcode"], "SAFE-AUTH-1");
      expect(retryOptions.headers["cookie"], contains("udb_wession=SESS-2"));
    });
  });

  group("HuyaPhoneLoginApi.login", () {
    test("登录成功时汇总出含 udb_uid 的 Cookie", () async {
      var api = _apiWith((options) async {
        if (options.method == "GET") {
          return _json({}, setCookie: _bootstrapCookies);
        }
        if (options.uri.path == "/web/v2/smsLogin") {
          return _json({
            "returnCode": 0
          }, setCookie: [
            "udb_uid=10086; Path=/",
            "yyuid=10086; Path=/",
            "username=hello; Path=/",
          ]);
        }
        return _json({"returnCode": 0});
      });
      var result = await api.login(phone: "13800000000", authcode: "123456");
      expect(result.ok, isTrue);
      expect(result.cookie, contains("udb_uid=10086"));
      expect(result.cookie, contains("yyuid=10086"));
    });

    test("验证码错误时返回失败信息", () async {
      var api = _apiWith((options) async {
        if (options.method == "GET") {
          return _json({}, setCookie: _bootstrapCookies);
        }
        return _json({
          "returnCode": 100,
          "description": "短信验证码错误",
        });
      });
      var result = await api.login(phone: "13800000000", authcode: "000000");
      expect(result.ok, isFalse);
      expect(result.code, 100);
      expect(result.message, contains("验证码"));
    });

    test("登录信封使用 uri=60025 且回传 authId/authcode", () async {
      late RequestOptions postOptions;
      var api = _apiWith((options) async {
        if (options.method == "GET") {
          return _json({}, setCookie: _bootstrapCookies);
        }
        postOptions = options;
        return _json({"returnCode": 0}, setCookie: ["udb_uid=1; Path=/"]);
      });
      await api.login(
        phone: "13800000000",
        authcode: "654321",
        authId: "auth-x",
      );
      var body = jsonDecode(postOptions.data as String) as Map;
      expect(body["uri"], "60025");
      expect(postOptions.uri.path, "/web/v2/smsLogin");
      var data = body["data"] as Map;
      expect(data["authcode"], "654321");
      expect(data["authId"], "auth-x");
      expect(data["remember"], "1");
    });

    test("风控后登录使用 udb_wession 原始 sessionData", () async {
      late RequestOptions loginOptions;
      var api = _apiWith((options) async {
        if (options.method == "GET") {
          return _json({}, setCookie: _bootstrapCookies);
        }
        if (options.uri.path == "/web/v2/smsCode") {
          return _json({
            "returnCode": 10030,
            "data": {
              "sessionData": "SESS-X",
              "strategys": [
                {
                  "strategy": 64,
                  "dataType": 4,
                  "data": "https://aq.huya.com/p/safe_auth/pt_auth.html?param=x"
                }
              ]
            }
          });
        }
        loginOptions = options;
        return _json({"returnCode": 0}, setCookie: ["udb_uid=10086; Path=/"]);
      });
      await api.sendCode("13800000000");
      await api.login(phone: "13800000000", authcode: "123456");
      var body = jsonDecode(loginOptions.data as String) as Map;
      var data = body["data"] as Map;
      expect(data["sessionData"], "SESS-X");
      expect(data["sessionData"] as String, isNot(contains("guid=")));
    });
  });

  group("HuyaPhoneLoginController 校验", () {
    test("手机号校验", () {
      expect(HuyaPhoneLoginController.isValidPhone("13800000000"), isTrue);
      expect(HuyaPhoneLoginController.isValidPhone("19912345678"), isTrue);
      expect(HuyaPhoneLoginController.isValidPhone("12345678901"), isFalse);
      expect(HuyaPhoneLoginController.isValidPhone("1380000000"), isFalse);
      expect(HuyaPhoneLoginController.isValidPhone("23800000000"), isFalse);
    });

    test("验证码校验", () {
      expect(HuyaPhoneLoginController.isValidCode("1234"), isTrue);
      expect(HuyaPhoneLoginController.isValidCode("123456"), isTrue);
      expect(HuyaPhoneLoginController.isValidCode("12"), isFalse);
      expect(HuyaPhoneLoginController.isValidCode("abcdef"), isFalse);
    });
  });
}
