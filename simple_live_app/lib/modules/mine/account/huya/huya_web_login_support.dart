/// 虎牙移动端手机号（短信）登录的支持代码。
///
/// 官方登录页 aq.huya.com/p/udb_login_v2.html 需要父页面通过 postMessage
/// 初始化，并根据传入参数以「仅短信登录」模式打开。这里把地址、移动端 UA、
/// Cookie 域名、注入脚本和若干纯函数集中放置，便于控制器复用与单元测试。
class HuyaWebLoginSupport {
  HuyaWebLoginSupport._();

  /// 虎牙官方登录页（内嵌短信登录表单）
  static const String loginUrl = "https://aq.huya.com/p/udb_login_v2.html";

  /// 移动端 UA：让官方页面按手机屏幕渲染、隐藏桌面大图
  static const String userAgent =
      "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) "
      "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 "
      "Mobile/15E148 Safari/604.1";

  /// 登录态 Cookie 可能落在这些虎牙域名下
  static const List<String> cookieUrls = [
    "https://www.huya.com",
    "https://i.huya.com",
    "https://aq.huya.com",
    "https://udblgn.huya.com",
  ];

  /// 判断抓到的 Cookie 是否已经包含登录态（虎牙以 udb_uid 为准）
  static bool isLogined(Map<String, String> cookies) =>
      (cookies["udb_uid"] ?? "").isNotEmpty;

  /// 把 Cookie 键值对拼成请求头
  static String cookieHeader(Map<String, String> cookies) =>
      cookies.entries.map((e) => "${e.key}=${e.value}").join(";");

  /// 登录方式弹层里是否展示「手机号登录」入口。
  ///
  /// 仅手机端竖屏展示：桌面/横屏时官方网页太大，操作体验差，
  /// 仍推荐扫码或 Cookie 登录。
  static bool showPhoneEntry({
    required bool isMobile,
    required bool isPortrait,
  }) =>
      isMobile && isPortrait;

  /// 初始化官方登录模块为「仅短信登录」模式（向页面自身 postMessage）。
  static const String initSms = r'''
(function(){
  try {
    window.postMessage(JSON.stringify({
      origin: 'udbSdkWeb',
      fnName: 'login',
      opt: {
        appid: '5002',
        domain: 'huya.com',
        noQrLogin: true,
        noThirdLogin: true,
        embedDom: true,
        defaultMode: 1
      },
      args: 'sms'
    }), location.origin);
    return 'init-sms';
  } catch (e) { return 'init-error:' + e; }
})()
''';

  /// 把官方登录页适配成手机铺满布局：隐藏品牌大图、登录框居中铺满。
  static const String fitMobile = r'''
(function(){
  var tries = 0;
  function apply(){
    tries++;
    var main = document.querySelector('#login-main');
    var wrap = document.querySelector('.login-right-wrap') || main;
    if (!wrap) { if (tries < 15) setTimeout(apply, 400); return; }
    var brand = document.querySelector('#login-brand-wrap');
    if (brand) brand.style.setProperty('display','none','important');
    var root = document.querySelector('#input-login-wrap') || wrap;
    root.style.setProperty('width','100%','important');
    root.style.setProperty('min-height','100vh','important');
    root.style.setProperty('display','flex','important');
    root.style.setProperty('align-items','center','important');
    root.style.setProperty('justify-content','center','important');
    root.style.setProperty('background','#0b0b0f','important');
    wrap.style.setProperty('width','100%','important');
    wrap.style.setProperty('max-width','420px','important');
    wrap.style.setProperty('margin','0 auto','important');
    if (main) {
      main.style.setProperty('width','100%','important');
      main.style.setProperty('max-width','420px','important');
    }
    document.body.style.setProperty('margin','0','important');
    document.documentElement.style.setProperty('background','#0b0b0f','important');
    window.__huyaLoginFit = 'ok';
  }
  window.__huyaLoginFit = '';
  apply();
  return 'fitting';
})()
''';
}
