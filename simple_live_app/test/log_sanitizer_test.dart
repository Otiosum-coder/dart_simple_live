import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_core/simple_live_core.dart';

void main() {
  test('headers and nested credential values are redacted without mutation',
      () {
    final original = <String, Object?>{
      'Cookie': 'SESSDATA=login-secret',
      'Set-Cookie': ['SESSDATA=another-secret; HttpOnly'],
      'Authorization': 'Bearer bearer-secret',
      'x-csrf-token': 'csrf-secret',
      'status': 403,
      'data': [
        {'refresh_token': 'refresh-secret', 'expires_in': 3600}
      ],
    };
    final safe = LogSanitizer.data(original) as Map;
    expect(safe['Cookie'], LogSanitizer.redacted);
    expect(safe['Set-Cookie'], LogSanitizer.redacted);
    expect(safe['Authorization'], LogSanitizer.redacted);
    expect(safe['x-csrf-token'], LogSanitizer.redacted);
    expect(safe['status'], 403);
    expect((safe['data'] as List).first['expires_in'], 3600);
    expect(original['Cookie'], 'SESSDATA=login-secret');
    expect(safe.toString(), isNot(contains('-secret')));
  });

  test('signed WebSocket URLs keep room routing but hide credentials', () {
    final safe = Uri.parse(LogSanitizer.url(
        'wss://example.com/push?room_id=123&signature=sign-secret&'
        'user_unique_id=user-secret&baseinfo=baseinfo-secret&access_token=one&access_token=two'));
    expect(safe.host, 'example.com');
    expect(safe.path, '/push');
    expect(safe.queryParameters['room_id'], '123');
    expect(safe.queryParameters['signature'], LogSanitizer.redacted);
    expect(safe.queryParameters['user_unique_id'], LogSanitizer.redacted);
    expect(safe.queryParameters['baseinfo'], LogSanitizer.redacted);
    expect(safe.queryParametersAll['access_token'], [LogSanitizer.redacted]);
  });

  test('URL userinfo, encoded keys, nested redirects and fragments are safe',
      () {
    final safe = LogSanitizer.url('https://user:pass@example.com/path?'
        '%74oken=encoded-secret&redirect='
        'https%3A%2F%2Fother.test%2F%3Fcsrf%3Dnested-secret'
        '#access_token=fragment-secret');
    for (final secret in [
      'user:pass',
      'encoded-secret',
      'nested-secret',
      'fragment-secret'
    ]) {
      expect(safe, isNot(contains(secret)));
    }
    expect(safe, contains('example.com/path'));
  });

  test('error messages preserve reasons while removing URLs and auth values',
      () {
    const raw =
        'HTTP 403 timed out https://example.com/a?token=url-secret&room=9\n'
        'Authorization: Bearer header-secret\nSESSDATA=cookie-secret; code=403';
    final safe = LogSanitizer.text(raw);
    expect(safe, contains('HTTP 403 timed out'));
    expect(safe, contains('code=403'));
    expect(safe, isNot(contains('-secret')));
    expect(LogSanitizer.text(safe), safe);
  });

  test('JSON and form bodies redact credentials and preserve error messages',
      () {
    final safe = jsonDecode(LogSanitizer.data(
            '{"code":-101,"message":"login expired","data":{"token":"json-secret"}}')
        as String);
    expect(safe['code'], -101);
    expect(safe['message'], 'login expired');
    expect(safe['data']['token'], LogSanitizer.redacted);
    final form = Uri.splitQueryString(
        LogSanitizer.data('csrf=form-secret&roomid=123&msg=hello') as String);
    expect(form['csrf'], LogSanitizer.redacted);
    expect(form['roomid'], '123');
    expect(form['msg'], 'hello');
  });

  test('outgoing danmaku text is hidden only for the send endpoint', () {
    final body = {
      'msg': 'private chat',
      'csrf': 'send-secret',
      'roomid': '123'
    };
    final safe = LogSanitizer.requestData(
        Uri.parse('https://api.live.bilibili.com/msg/send'), body) as Map;
    expect(safe['msg'], LogSanitizer.redacted);
    expect(safe['csrf'], LogSanitizer.redacted);
    expect(safe['roomid'], '123');
    expect(body['msg'], 'private chat');
    expect((LogSanitizer.data({'message': 'server error'}) as Map)['message'],
        'server error');
  });

  test('null, ordinary values and malformed URLs do not break logging', () {
    expect(LogSanitizer.data(null), null);
    expect(LogSanitizer.data(403), 403);
    expect(LogSanitizer.data('ordinary diagnostic'), 'ordinary diagnostic');
    expect(LogSanitizer.url('https://[invalid'), LogSanitizer.redacted);
  });
}
