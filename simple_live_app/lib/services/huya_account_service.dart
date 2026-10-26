import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/sites.dart';
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

  @override
  void onInit() {
    cookie = LocalStorageService.instance
        .getValue(LocalStorageService.kHuyaCookie, "");
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
    var nickname = _decode(map["username"] ?? "");
    if (nickname.isEmpty) {
      nickname = _decode(map["udb_passport"] ?? "");
    }
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

  void setSite() {
    var site = (Sites.allSites[Constant.kHuya]!.liveSite as HuyaSite);
    site.cookie = cookie;
  }

  void setCookie(String value) {
    cookie = value.trim();
    LocalStorageService.instance
        .setValue(LocalStorageService.kHuyaCookie, cookie);
    parseCookie();
    setSite();
  }

  void logout() {
    setCookie("");
  }
}
