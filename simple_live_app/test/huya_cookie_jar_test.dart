import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/services/huya_cookie_harvester.dart';

void main() {
  final www = Uri.parse('https://www.huya.com/udb_web/udbport2.php');
  final i = Uri.parse('https://i.huya.com/');
  late DateTime time;
  late HuyaCookieJar jar;
  setUp(() {
    time = DateTime.utc(2026, 1, 1);
    jar = HuyaCookieJar(now: () => time);
  });

  test('旧裸 Cookie 超过 24 小时不推断到期日', () {
    jar = HuyaCookieJar.restore('udb_uid=101; fixture=legacy', now: () => time);
    time = time.add(const Duration(days: 7));
    expect(jar['udb_uid'], '101');
    expect(jar['fixture'], 'legacy');
  });

  test('等长及更短轮换覆盖旧值，Max-Age 优先于 Expires', () {
    jar.collect(['fixture=first; Path=/; Max-Age=10'], www);
    jar.collect([
      'fixture=other; Path=/; Max-Age=20; Expires=Thu, 01 Jan 1970 00:00:00 GMT'
    ], www);
    expect(jar['fixture'], 'other');
    time = time.add(const Duration(seconds: 11));
    expect(jar['fixture'], 'other');
    jar.collect(['fixture=x; Path=/; Max-Age=10'], www);
    expect(jar['fixture'], 'x');
    time = time.add(const Duration(seconds: 10));
    expect(jar['fixture'], isNull);
  });

  test('逐条解析 Expires 逗号，并处理 Max-Age=0/负数和空值删除', () {
    jar.collect([
      'future=present; Path=/; Expires=Fri, 02 Jan 2026 00:00:00 GMT',
      'zero=present; Path=/',
      'negative=present; Path=/',
      'empty=present; Path=/',
    ], www);
    jar.collect([
      'zero=removed; Path=/; Max-Age=0',
      'negative=removed; Path=/; Max-Age=-1',
      'empty=; Path=/'
    ], www);
    expect(jar.keys.toSet(), {'future'});
    time = time.add(const Duration(days: 1));
    expect(jar, isEmpty);
  });

  test('同名不同域及路径不互相覆盖，发送遵守 host-only/secure/path 边界', () {
    jar.collect([
      'fixture=host; Path=/; Secure',
      'fixture=deep; Domain=.huya.com; Path=/udb_web'
    ], www);
    jar.collect(['fixture=other; Path=/'], i);
    expect(jar.headerFor(www), 'fixture=deep; fixture=host');
    expect(jar.headerFor(i), 'fixture=other');
    expect(jar.headerFor(Uri.parse('http://www.huya.com/')), isEmpty);
    expect(jar.headerFor(Uri.parse('https://www.huya.com/udb_webb')),
        'fixture=host');
    jar.collect(
        ['fixture=gone; Domain=.huya.com; Path=/udb_web; Max-Age=0'], www);
    expect(jar.headerFor(www), 'fixture=host');
    expect(jar.headerFor(i), 'fixture=other');
  });

  test('拒绝其它站点或不属于响应主机的 Domain', () {
    jar.collect([
      'fixture=other; Domain=.example.com; Path=/',
      'fixture=sibling; Domain=i.huya.com; Path=/'
    ], www);
    jar.collect(['fixture=foreign; Domain=.huya.com; Path=/'],
        Uri.parse('https://example.com/'));
    expect(jar, isEmpty);
  });

  test('元数据重启保留期限且不把过期记录降级为无期限旧 Cookie', () {
    jar.collect(['fixture=present; Path=/; Max-Age=60'], www);
    final header = jar.header;
    final metadata = jsonEncode(jar.metadata);
    time = time.add(const Duration(seconds: 61));
    final restored =
        HuyaCookieJar.restore(header, metadata: metadata, now: () => time);
    expect(restored, isEmpty);
  });

  test('旁路元数据不匹配或损坏时回退现有裸 Cookie', () {
    jar.collect(['fixture=old; Path=/'], www);
    final changed =
        HuyaCookieJar.restore('fixture=new', metadata: jar.metadata);
    expect(changed['fixture'], 'new');
    final broken = HuyaCookieJar.restore('fixture=legacy', metadata: {
      'version': 1,
      'header': 'fixture=legacy',
      'cookies': [
        {
          'name': 'fixture',
          'value': 'bad',
          'domain': 'huya.com',
          'path': '/',
          'hostOnly': 'not-a-bool'
        },
      ],
    });
    expect(broken['fixture'], 'legacy');
  });

  test('WebView 等长/短值轮换和删除不依赖总长度，未探测路径保留', () {
    jar.collect([
      'udb_uid=101; Path=/',
      'fixture=first; Path=/',
      'deleted=present; Path=/',
      'hidden=present; Path=/unprobed'
    ], www);
    jar.replaceFromWebView({
      Uri.parse('https://www.huya.com/'): [
        Cookie(name: 'udb_uid', value: '101'),
        Cookie(name: 'fixture', value: 'other'),
      ]
    });
    expect(jar['fixture'], 'other');
    expect(jar['deleted'], isNull);
    expect(jar['hidden'], 'present');
    jar.replaceFromWebView({
      Uri.parse('https://www.huya.com/'): [
        Cookie(name: 'udb_uid', value: '101'),
        Cookie(name: 'fixture', value: 'x'),
      ]
    });
    expect(jar['fixture'], 'x');
  });

  test('Android 缺少期限时保留作用域，同值可能续期而不沿用旧期限', () {
    jar.collect([
      'fixture=present; Domain=.huya.com; Path=/; Max-Age=60; Secure; HttpOnly'
    ], www);
    jar.replaceFromWebView({
      www: [Cookie(name: 'fixture', value: 'present')]
    });
    expect(jar.headerFor(i), 'fixture=present');
    expect(jar.headerFor(Uri.parse('http://www.huya.com/')), isEmpty);
    time = time.add(const Duration(seconds: 61));
    expect(jar['fixture'], 'present');
    expect(
        ((jar.metadata as Map)['cookies'] as List).single['expires'], isNull);
  });

  test('Android 轮换值未带期限时不套用旧值期限', () {
    jar.collect(['fixture=old; Domain=.huya.com; Path=/; Max-Age=60'], www);
    jar.replaceFromWebView({
      www: [Cookie(name: 'fixture', value: 'new')]
    });
    time = time.add(const Duration(seconds: 61));
    expect(jar['fixture'], 'new');
  });
}
