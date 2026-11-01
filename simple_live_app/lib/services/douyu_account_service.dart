import 'dart:convert';

import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/http_client.dart' as core_http;

/// 斗鱼账号
///
/// 斗鱼 2026-09-21 起对未登录用户限制最高画质（原画/蓝光4M 只能看 10 分钟），
/// 登录态通过 Cookie 透传给斗鱼接口，因此这里只负责保存/解析 Cookie。
/// 昵称等信息直接来自 Cookie 本身（acf_nickname/acf_uid/acf_avatar），无需额外请求。
class DouyuAccountService extends GetxService {
  static DouyuAccountService get instance => Get.find<DouyuAccountService>();

  var cookie = "";
  var uid = "";
  var avatar = "";
  var name = "未登录".obs;
  var logined = false.obs;

  @override
  void onInit() {
    cookie = LocalStorageService.instance
        .getValue(LocalStorageService.kDouyuCookie, "");
    parseCookie();
    setSite();
    super.onInit();
  }

  /// 把 Cookie 字符串解析为键值对
  static Map<String, String> parseCookieMap(String value) {
    var map = <String, String>{};
    for (var part in value.split(';')) {
      var index = part.indexOf('=');
      if (index <= 0) {
        continue;
      }
      var key = part.substring(0, index).trim();
      var val = part.substring(index + 1).trim();
      if (key.isNotEmpty) {
        map[key] = val;
      }
    }
    return map;
  }

  /// 从 Cookie 中解析登录信息，解析不出 acf_uid 就认为未登录
  void parseCookie() {
    if (cookie.isEmpty) {
      uid = "";
      avatar = "";
      name.value = "未登录";
      logined.value = false;
      return;
    }
    var map = parseCookieMap(cookie);
    uid = map["acf_uid"] ?? "";
    var nickname = _decode(map["acf_nickname"] ?? "");
    avatar = _decode(map["acf_avatar"] ?? "");
    if (nickname.isNotEmpty) {
      name.value = nickname;
    } else if (uid.isNotEmpty) {
      name.value = "已登录（$uid）";
    } else {
      name.value = "已登录";
    }
    logined.value = uid.isNotEmpty;
  }

  String _decode(String value) {
    try {
      return Uri.decodeComponent(value);
    } catch (e) {
      return value;
    }
  }

  /// dmjwt 的过期时间（解析 JWT 的 exp；解析失败返回 null）
  DateTime? get jwtExpireAt {
    var jwt = parseCookieMap(cookie)["acf_dmjwt_token"] ?? "";
    if (jwt.isEmpty) {
      return null;
    }
    try {
      var parts = jwt.split(".");
      if (parts.length < 2) {
        return null;
      }
      var payload = parts[1].replaceAll("-", "+").replaceAll("_", "/");
      while (payload.length % 4 != 0) {
        payload += "=";
      }
      var data = json.decode(utf8.decode(base64.decode(payload)));
      var exp = data["exp"];
      if (exp is! num) {
        return null;
      }
      return DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000);
    } catch (e) {
      return null;
    }
  }

  /// dmjwt 是否快过期（15 分钟内）或已经过期
  bool get needRefreshToken {
    if (!logined.value) {
      return false;
    }
    var expire = jwtExpireAt;
    if (expire == null) {
      return false;
    }
    return expire.difference(DateTime.now()) < const Duration(minutes: 15);
  }

  /// 用登录态静默换一个新的 dmjwt（网页版 safeAuth 静默登录）
  ///
  /// 抓包实证（2026-11）纯 HTTP 就能走通：
  /// 1. GET passport.douyu.com/wgapi/member/passport/safeAuth，
  ///    带登录 cookie，返回 302 且 Location 里带一次性 code
  /// 2. 跟随 302 到 www.douyu.com/api/passport/login，
  ///    响应 Set-Cookie 带上新的 acf_dmjwt_token / acf_ltkid / acf_stk / acf_auth…
  ///
  /// 成功返回 true 并把新 cookie 写回本地；失败返回 false（调用方负责退出登录）
  Future<bool> refreshToken() async {
    if (!logined.value) {
      return false;
    }
    var map = parseCookieMap(cookie);
    var did = map["dy_did"] ?? map["acf_did"] ?? "";
    var url = "https://passport.douyu.com/wgapi/member/passport/safeAuth"
        "?client_id=1"
        "&redirect_url=${Uri.encodeComponent("https://www.douyu.com/")}"
        "&did=$did"
        "&t=${DateTime.now().millisecondsSinceEpoch}"
        "&callback=__jp0";
    try {
      var result = await core_http.HttpClient.instance.getRaw(
        url,
        header: {
          "Cookie": cookie,
          "User-Agent": DouyuSite.kUserAgent,
          "Referer": "https://www.douyu.com/",
        },
      );
      var newMap = Map<String, String>.from(map);
      var gotJwt = false;
      for (var line in result.setCookies) {
        var pair = line.split(";").first;
        var index = pair.indexOf("=");
        if (index <= 0) {
          continue;
        }
        var key = pair.substring(0, index).trim();
        newMap[key] = pair.substring(index + 1).trim();
        if (key == "acf_dmjwt_token") {
          gotJwt = true;
        }
      }
      if (!gotJwt) {
        Log.i("斗鱼 dmjwt 刷新：响应里没有新 token（status=${result.statusCode}）");
        return false;
      }
      setCookie(newMap.entries.map((e) => "${e.key}=${e.value}").join("; "));
      Log.i("斗鱼 dmjwt 刷新成功，新过期时间=$jwtExpireAt");
      return true;
    } catch (e) {
      Log.logPrint("斗鱼 dmjwt 刷新失败：$e");
      return false;
    }
  }

  void setSite() {
    var site = (Sites.allSites[Constant.kDouyu]!.liveSite as DouyuSite);
    site.cookie = cookie;
  }

  void setCookie(String value) {
    cookie = value.trim();
    LocalStorageService.instance
        .setValue(LocalStorageService.kDouyuCookie, cookie);
    parseCookie();
    setSite();
  }

  void logout() {
    setCookie("");
  }
}