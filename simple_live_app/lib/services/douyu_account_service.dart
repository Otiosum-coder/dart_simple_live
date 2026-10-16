import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

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