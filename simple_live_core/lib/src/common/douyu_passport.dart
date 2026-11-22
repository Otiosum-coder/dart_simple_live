// 参考来源（本文件大部分端点与流程由此二者验证可用）：
// - safeAuth 续期（接口/参数/Set-Cookie 处理）：
//   SlotSun/dart_simple_live v1.8.13, douyu_utils.dart `refreshCookie`
//   （issue #182: ltp0 & dy_did 配置说明）
// - 扫码登录流程（generateCode / japi/scan/auth 状态码 / 确认地址取凭据）：
//   fancrest-png/dart_simple_live PR #190 分支 `feat-douyu-qr-login`
//   （该 PR 未被 SlotSun 合并，实现经其 docs/douyu-qr-login.md 核对）
//
// 设计要点：
// - 本文件只做两件事：判断登录 Cookie 里的「播放 token」是否过期；用长效凭证
//   LTP0 + 设备 id dy_did 静默换一份新的 Cookie。
// - 播放 token 是 acf_jwt_token（约 7 天有效期），与发弹幕用的 acf_dmjwt_token
//   互相独立。LTP0 由 passport.douyu.com 在登录时下发、存放远长于 7 天，
//   所以能用它无感续期，用户不必重新扫码。
// - 续期失败一律抛 CoreError，由调用方决定是否登出（本项目保留旧 Cookie、不登出）。

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:simple_live_core/src/common/core_error.dart';
import 'package:simple_live_core/src/common/http_client.dart';

class DouyuPassport {
  DouyuPassport._();

  /// 播放 token 名（约 7 天有效期）
  static const String kPlayTokenKey = 'acf_jwt_token';

  static const String kUserAgent =
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36 Edg/114.0.1823.43";

  /// 从 "k=v; k2=v2" 取字段（取不到返回空串）
  static String cookieValue(String cookie, String name) {
    for (var part in cookie.split(';')) {
      var index = part.indexOf('=');
      if (index <= 0) continue;
      if (part.substring(0, index).trim() == name) {
        return part.substring(index + 1).trim();
      }
    }
    return '';
  }

  static Map<String, String> _parseCookie(String cookie) {
    var map = <String, String>{};
    for (var part in cookie.split(';')) {
      var index = part.indexOf('=');
      if (index <= 0) continue;
      var key = part.substring(0, index).trim();
      if (key.isNotEmpty) map[key] = part.substring(index + 1).trim();
    }
    return map;
  }

  static void _mergeSetCookie(Map<String, String> jar, dynamic setCookie) {
    if (setCookie == null) return;
    var lines = setCookie is List ? setCookie : [setCookie];
    for (var line in lines) {
      var pair = line.toString().split(';').first;
      var index = pair.indexOf('=');
      if (index <= 0) continue;
      jar[pair.substring(0, index).trim()] = pair.substring(index + 1).trim();
    }
  }

  static DateTime? _jwtExpireAt(String jwt) {
    try {
      var parts = jwt.split('.');
      if (parts.length < 2) return null;
      var payload = parts[1].replaceAll('-', '+').replaceAll('_', '/');
      while (payload.length % 4 != 0) {
        payload += '=';
      }
      var data = json.decode(utf8.decode(base64.decode(payload)));
      var exp = data['exp'];
      if (exp is! num) return null;
      return DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000);
    } catch (_) {
      return null;
    }
  }

  /// 播放 token 是否已过期（默认提前 [ahead] 即视为过期）。
  /// 解析不出 exp（不是 JWT / 没有该字段）时返回 false，避免误触发续期。
  static bool isCookieExpired(
    String cookie, {
    Duration ahead = const Duration(minutes: 2),
  }) {
    var token = cookieValue(cookie, kPlayTokenKey);
    if (token.isEmpty) return false;
    var exp = _jwtExpireAt(token);
    if (exp == null) return false;
    return exp.difference(DateTime.now()) < ahead;
  }

  /// 把 Set-Cookie 列表拼成 "k=v; k2=v2"（只取每条的 name=value）
  static String cookiesFromSetCookie(List<String> setCookies) {
    var jar = <String, String>{};
    for (var line in setCookies) {
      _mergeSetCookie(jar, line);
    }
    return jar.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  /// 用长效凭证 [ltp0] + 设备 id [dyDid] 静默换一份新的登录 Cookie。
  ///
  /// 返回「原 Cookie 合并新 Set-Cookie」后的完整 Cookie（保留 acf_uid 等字段）。
  /// safeAuth 可能先返回 3xx，再在下一跳写 token，这里手动逐跳累积 Set-Cookie。
  /// 换不到新的 acf_jwt_token 或换回来仍过期时抛 CoreError。
  static Future<String> refreshPlayCookie({
    required String dyDid,
    required String ltp0,
    required String currentCookie,
    String userAgent = kUserAgent,
  }) async {
    if (ltp0.isEmpty || dyDid.isEmpty) {
      throw CoreError('缺少斗鱼续期凭证（LTP0 / dy_did），请重新扫码登录');
    }
    var store = _parseCookie(currentCookie); // 最终返回的完整 Cookie
    store['LTP0'] = ltp0;
    store['dy_did'] = dyDid;

    // 握手阶段只带长效凭证（不带已过期的 acf_jwt_token，避免被判未登录），
    // 并累积中途下发的 Cookie。
    var handshake = <String, String>{'LTP0': ltp0, 'dy_did': dyDid};
    String header() =>
        handshake.entries.map((e) => '${e.key}=${e.value}').join('; ');

    var now = DateTime.now().millisecondsSinceEpoch;
    var url = 'https://passport.douyu.com/lapi/passport/iframe/safeAuth'
        '?client_id=1&t=$now&_=$now&callback=axiosJsonpCallback';
    late Response<dynamic> res;
    for (var hop = 0; hop < 6; hop++) {
      try {
        res = await HttpClient.instance.dio.get(
          url,
          options: Options(
            responseType: ResponseType.plain,
            followRedirects: false,
            validateStatus: (status) => status != null && status < 500,
            headers: {
              'Cookie': header(),
              'User-Agent': userAgent,
              'Referer': 'https://www.douyu.com/',
              'Origin': 'https://www.douyu.com',
            },
          ),
        );
      } catch (e) {
        throw CoreError('斗鱼续期请求失败：$e');
      }
      var setCookie = res.headers['set-cookie'];
      _mergeSetCookie(store, setCookie);
      _mergeSetCookie(handshake, setCookie);
      var status = res.statusCode ?? 0;
      if (status >= 300 && status < 400) {
        var location = res.headers.value('location');
        if (location == null || location.isEmpty) break;
        url = location.startsWith('http')
            ? location
            : Uri.parse(url).resolve(location).toString();
        continue;
      }
      break;
    }

    var merged = store.entries.map((e) => '${e.key}=${e.value}').join('; ');
    if (cookieValue(merged, kPlayTokenKey).isEmpty) {
      throw CoreError('斗鱼续期失败（未返回 acf_jwt_token），请重新扫码登录');
    }
    if (isCookieExpired(merged, ahead: Duration.zero)) {
      throw CoreError('斗鱼续期失败（新 token 仍过期），请重新扫码登录');
    }
    return merged;
  }
}
