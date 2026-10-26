import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 抖音账号
///
/// 抖音有两种 Cookie，用途不同，这里分开存：
/// * 「自定义 ttwid」：只要 ttwid 就能看全部画质（含蓝光），与登录无关；
/// * 「登录 Cookie」：扫码 / Web 登录后拿到的完整 Cookie，关键是 sessionid，
///   用于需要身份的接口（后续发送弹幕）。
///
/// 真正发给 [DouyinSite] 的是两者的合并结果：登录 Cookie 优先，
/// 缺 ttwid 时补上默认 ttwid。
class DouyinAccountService extends GetxService {
  static DouyinAccountService get instance =>
      Get.find<DouyinAccountService>();

  /// 用户自定义的 ttwid（可只填值，也可填完整 Cookie）
  var cookie = "";

  /// 登录后的完整 Cookie（含 sessionid）
  var loginCookie = "";

  var hasCookie = false.obs;
  var logined = false.obs;
  var name = "未登录".obs;

  @override
  void onInit() {
    cookie = LocalStorageService.instance
        .getValue(LocalStorageService.kDouyinCookie, "");
    loginCookie = LocalStorageService.instance
        .getValue(LocalStorageService.kDouyinLoginCookie, "");
    hasCookie.value = cookie.isNotEmpty;
    parseLoginCookie();
    setSite();
    super.onInit();
  }

  /// 实际透传给站点的 Cookie
  String get effectiveCookie {
    if (loginCookie.isEmpty) {
      return cookie;
    }
    if (loginCookie.contains("ttwid=")) {
      return loginCookie;
    }
    return "$loginCookie; ${DouyinSite.kDefaultCookie}";
  }

  /// 从登录 Cookie 里取一个字段
  String cookieValue(String key) {
    for (var part in loginCookie.split(';')) {
      var index = part.indexOf('=');
      if (index <= 0) {
        continue;
      }
      if (part.substring(0, index).trim() == key) {
        return part.substring(index + 1).trim();
      }
    }
    return "";
  }

  /// 登录 Cookie 里是否含有 sessionid（抖音登录态的唯一判据）
  void parseLoginCookie() {
    if (loginCookie.isEmpty) {
      logined.value = false;
      name.value = "未登录";
      return;
    }
    var hasSession = cookieValue("sessionid").isNotEmpty ||
        cookieValue("sessionid_ss").isNotEmpty ||
        cookieValue("sid_tt").isNotEmpty;
    logined.value = hasSession;
    name.value = hasSession ? "已登录" : "已登录（Cookie 不完整）";
  }

  void setSite() {
    var site = (Sites.allSites[Constant.kDouyin]!.liveSite as DouyinSite);
    site.cookie = effectiveCookie;
  }

  /// 保存「自定义 ttwid」
  void setCookie(String rawCookie) {
    // 归一化：只填了 ttwid 的值就补上字段名；填的是完整 Cookie（含 = 或 ;）就原样保存
    var value = rawCookie.trim();
    if (value.isNotEmpty && !value.contains("=")) {
      value = "ttwid=$value";
    }
    cookie = value;
    LocalStorageService.instance
        .setValue(LocalStorageService.kDouyinCookie, value);
    hasCookie.value = value.isNotEmpty;
    setSite();
  }

  /// 保存「登录 Cookie」（扫码 / Web 登录成功后调用）
  void setLoginCookie(String rawCookie) {
    loginCookie = rawCookie.trim();
    LocalStorageService.instance
        .setValue(LocalStorageService.kDouyinLoginCookie, loginCookie);
    parseLoginCookie();
    setSite();
  }

  void clearCookie() {
    cookie = "";
    LocalStorageService.instance
        .setValue(LocalStorageService.kDouyinCookie, "");
    hasCookie.value = false;
    setSite();
  }

  /// 退出登录（只清登录态，保留自定义 ttwid）
  void logout() {
    loginCookie = "";
    LocalStorageService.instance
        .setValue(LocalStorageService.kDouyinLoginCookie, "");
    parseLoginCookie();
    setSite();
  }
}
