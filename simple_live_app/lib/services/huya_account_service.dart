import 'dart:convert';

import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/requests/http_client.dart';
import 'package:simple_live_app/services/huya_cookie_harvester.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 虎牙账号
///
/// 虎牙登录成功后由服务端直接下发 Cookie（`udb_uid` / `yyuid` / `username` /
/// `udb_biztoken` / `udb_cred`），没有额外的「用 ticket 换 Cookie」环节，
/// 所以这里只负责保存、解析并透传给 [HuyaSite]。
///
/// 判断是否登录以 `udb_uid` 为准；昵称取 `username`（虎牙前端自己展示的就是它），
/// 取不到时退回 `udb_passport`（手机号/虎牙号）。
class HuyaAccountService extends GetxService {
  static HuyaAccountService get instance => Get.find<HuyaAccountService>();

  var cookie = "";
  var uid = "";
  var name = "未登录".obs;
  var logined = false.obs;

  /// 展示昵称（Cookie 里只有账号名，昵称走用户信息接口）
  var nickname = "";

  @override
  void onInit() {
    cookie = LocalStorageService.instance
        .getValue(LocalStorageService.kHuyaCookie, "");
    nickname = LocalStorageService.instance
        .getValue(LocalStorageService.kHuyaNickname, "");
    parseCookie();
    setSite();
    // 启动时用服务端对昵称/登录态对账一次（异步、失败静默）
    if (logined.value) {
      fetchNickname();
    }
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

  /// 从 Cookie 中解析登录信息，解析不出 udb_uid 就认为未登录
  void parseCookie() {
    if (cookie.isEmpty) {
      uid = "";
      name.value = "未登录";
      logined.value = false;
      return;
    }
    var map = parseCookieMap(cookie);
    uid = map["udb_uid"] ?? map["yyuid"] ?? "";
    var display = nickname;
    if (display.isEmpty) {
      display = _decode(map["username"] ?? "");
    }
    if (display.isEmpty) {
      display = _decode(map["udb_passport"] ?? "");
    }
    if (display.isNotEmpty) {
      name.value = display;
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

  void setSite() {
    var site = (Sites.allSites[Constant.kHuya]!.liveSite as HuyaSite);
    site.cookie = cookie;
  }

  void setCookie(String value, {bool freshLogin = false}) {
    cookie = value.trim();
    if (freshLogin && cookie.isNotEmpty) {
      _loginAt = DateTime.now();
    } else if (cookie.isEmpty) {
      _loginAt = null;
    }
    LocalStorageService.instance
        .setValue(LocalStorageService.kHuyaCookie, cookie);
    parseCookie();
    setSite();
    // 登录成功后（或 Cookie 还比较薄时）用不可见 WebView 到 www.huya.com
    // 补全整套 Cookie —— 发弹幕要用那份"厚 Cookie"
    if (logined.value && cookie.length < 1500) {
      harvestCookie();
    }
  }

  bool _harvesting = false;
  bool _fetchingNickname = false;
  DateTime? _loginAt;

  /// 刚扫码登录后的短时间内，www.huya.com 的昵称接口可能还没同步
  /// udblgn 下发的登录态，会短暂返回 isLogined=false。此时不能把刚登录
  /// 成功的账号直接踢下线，否则会先提示“登录成功”紧接着又提示“登录已失效”。
  bool get _isFreshLogin {
    final at = _loginAt;
    return at != null &&
        DateTime.now().difference(at) < const Duration(minutes: 2);
  }

  /// 用（补全后的）Cookie 查展示昵称：www.huya.com 的用户信息接口
  Future<void> fetchNickname() async {
    if (_fetchingNickname || cookie.isEmpty) {
      return;
    }
    _fetchingNickname = true;
    try {
      var result = await HttpClient.instance.getJson(
        "https://www.huya.com/udb_web/udbport2.php",
        queryParameters: {"m": "User", "do": "getUserInfo"},
        header: {
          "cookie": cookie,
          "user-agent":
              "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
          "referer": "https://www.huya.com/",
        },
        timeout: const Duration(seconds: 8),
      );
      var map = result is Map
          ? result
          : (result is String && result.trim().startsWith("{")
              ? jsonDecode(result)
              : <dynamic, dynamic>{});
      var nick = (map["userNick"] ?? "").toString().trim();
      Log.i("虎牙昵称接口：isLogined=${map["isLogined"]} userNick=$nick");
      // 服务端明确判未登录：本地有 udb_uid 也不可信。仅在本地也没有昵称缓存时
      // 翻转，避免接口偶发误判把正常用户踢下线；真正的发送失败由弹幕回执（905）兜底。
      // 扫码登录拿到的是 udblgn 域的薄 Cookie，www.huya.com 的昵称接口
      // 在桌面端可能始终不认它（桌面不做 WebView 补全）。刚登录 2 分钟内
      // 以及仍带 web_qrlogin_confirm_id 的二维码 Cookie，都不能据此把用户
      // 踢下线，否则会在“登录成功”后马上又提示“登录已失效”。
      final isQrCookie = cookie.contains('web_qrlogin_confirm_id');
      if (map["isLogined"] == false && (_isFreshLogin || isQrCookie)) {
        Log.i("虎牙昵称接口暂未同步二维码登录态，保留本地登录态");
        return;
      }
      if (map["isLogined"] == false) {
        if (nickname.isEmpty) {
          logined.value = false;
          name.value = "未登录";
          SmartDialog.showToast("虎牙登录已失效，请重新登录");
        } else {
          // 本地有昵称缓存时仍不翻转登录态（避免接口偶发误判直接踢下线），
          // 但必须提示用户：这种账号就是「显示已登录、实际发不出弹幕」。
          Log.i("虎牙昵称接口判未登录，本地有昵称缓存，提示用户重新登录但不强制翻转");
          SmartDialog.showToast("虎牙登录已失效，请重新登录");
        }
        return;
      }
      if (nick.isNotEmpty) {
        nickname = nick;
        LocalStorageService.instance
            .setValue(LocalStorageService.kHuyaNickname, nick);
        parseCookie();
      }
    } catch (e) {
      Log.logPrint(e);
    } finally {
      _fetchingNickname = false;
    }
  }

  /// 用不可见 WebView 补全 Cookie（成功后覆盖保存）
  Future<void> harvestCookie() async {
    if (_harvesting || cookie.isEmpty) {
      return;
    }
    _harvesting = true;
    try {
      var before = cookie.length;
      var full = await HuyaCookieHarvester.harvest(cookie);
      if (full != null && full.isNotEmpty && full.length > before) {
        Log.i("虎牙Cookie补全：$before -> ${full.length}");
        cookie = full;
        LocalStorageService.instance
            .setValue(LocalStorageService.kHuyaCookie, cookie);
        parseCookie();
        setSite();
      } else {
        Log.i("虎牙Cookie补全：未拿到更多 Cookie（before=$before）");
      }
      // Cookie 变厚之后，网页域可能已经能查到昵称了
      if (logined.value && nickname.isEmpty) {
        fetchNickname();
      }
    } catch (e) {
      Log.logPrint(e);
    } finally {
      _harvesting = false;
    }
  }

  void logout() {
    setCookie("");
  }
}
