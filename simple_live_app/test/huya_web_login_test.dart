import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/modules/mine/account/huya/huya_web_login_support.dart';

void main() {
  test('登录态识别以 udb_uid 为准', () {
    expect(HuyaWebLoginSupport.isLogined({'udb_uid': '12345'}), isTrue);
    expect(HuyaWebLoginSupport.isLogined({'udb_uid': ''}), isFalse);
    expect(HuyaWebLoginSupport.isLogined({'yyuid': '12345'}), isFalse);
    expect(HuyaWebLoginSupport.isLogined(const {}), isFalse);
  });

  test('Cookie 头拼接保留全部字段与顺序', () {
    final header = HuyaWebLoginSupport.cookieHeader({
      'udb_uid': '1',
      'yyuid': '2',
      'udb_cred': 'abc',
    });
    expect(header, 'udb_uid=1;yyuid=2;udb_cred=abc');
  });

  test('手机号登录入口仅在移动端竖屏展示', () {
    expect(
      HuyaWebLoginSupport.showPhoneEntry(isMobile: true, isPortrait: true),
      isTrue,
    );
    expect(
      HuyaWebLoginSupport.showPhoneEntry(isMobile: true, isPortrait: false),
      isFalse,
    );
    expect(
      HuyaWebLoginSupport.showPhoneEntry(isMobile: false, isPortrait: true),
      isFalse,
    );
  });

  test('初始化脚本以短信模式打开并禁用扫码与三方登录', () {
    final script = HuyaWebLoginSupport.initSms;
    expect(script, contains('udbSdkWeb'));
    expect(script, contains("fnName: 'login'"));
    expect(script, contains("args: 'sms'"));
    expect(script, contains('noQrLogin: true'));
    expect(script, contains('defaultMode: 1'));
    expect(script, contains('location.origin'));
  });

  test('适配脚本隐藏品牌区并把登录框居中铺满', () {
    final script = HuyaWebLoginSupport.fitMobile;
    expect(script, contains('#login-brand-wrap'));
    expect(script, contains('.login-right-wrap'));
    expect(script, contains('#login-main'));
    expect(script, contains('100vh'));
    expect(script, contains('max-width'));
  });

  test('登录页地址、UA 与 Cookie 域名配置正确', () {
    expect(HuyaWebLoginSupport.loginUrl, contains('udb_login_v2.html'));
    expect(HuyaWebLoginSupport.userAgent, contains('Mobile'));
    expect(HuyaWebLoginSupport.cookieUrls, contains('https://www.huya.com'));
    expect(
      HuyaWebLoginSupport.cookieUrls,
      contains('https://udblgn.huya.com'),
    );
  });
}
