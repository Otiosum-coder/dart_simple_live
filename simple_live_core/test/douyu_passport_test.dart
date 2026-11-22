import 'dart:convert';

import 'package:simple_live_core/src/common/douyu_passport.dart';
import 'package:test/test.dart';

String _jwt(Map<String, dynamic> payload) {
  var body = base64Url.encode(utf8.encode(json.encode(payload))).replaceAll('=', '');
  return 'x.$body.y';
}

void main() {
  test('isCookieExpired: 未来 exp 未过期', () {
    var exp = DateTime.now().add(const Duration(days: 5)).millisecondsSinceEpoch ~/ 1000;
    expect(DouyuPassport.isCookieExpired('acf_jwt_token=${_jwt({'exp': exp})}'),
        isFalse);
  });

  test('isCookieExpired: 过去 exp 已过期', () {
    var exp = DateTime.now().subtract(const Duration(days: 1)).millisecondsSinceEpoch ~/ 1000;
    expect(DouyuPassport.isCookieExpired('acf_jwt_token=${_jwt({'exp': exp})}'),
        isTrue);
  });

  test('isCookieExpired: 无 token 返回 false', () {
    expect(DouyuPassport.isCookieExpired('acf_uid=1'), isFalse);
  });

  test('isCookieExpired: 非 JWT 返回 false', () {
    expect(DouyuPassport.isCookieExpired('acf_jwt_token=notajwt'), isFalse);
  });

  test('cookiesFromSetCookie 拼接 name=value', () {
    expect(
      DouyuPassport.cookiesFromSetCookie([
        'acf_jwt_token=abc; Path=/; HttpOnly',
        'dy_did=123; Path=/',
      ]),
      'acf_jwt_token=abc; dy_did=123',
    );
  });

  test('cookieValue 取值', () {
    expect(DouyuPassport.cookieValue('a=1; b=2', 'b'), '2');
    expect(DouyuPassport.cookieValue('a=1', 'c'), '');
  });
}
