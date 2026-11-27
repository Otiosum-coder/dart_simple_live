import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/services/huya_cookie_harvester.dart';

Cookie _cookie(String name, String value) =>
    Cookie(name: name, value: value, domain: '.huya.com', path: '/');

HuyaCookieJar _app(String uid) =>
    HuyaCookieJar.restore('udb_uid=$uid; fixture=app-old');

// The production seam exposes reads only: no writer or page loader can be invoked.
class _SnapshotSource {
  _SnapshotSource(this.cookies);

  final List<Cookie> cookies;
  final reads = <Uri>[];

  Future<List<Cookie>> read(Uri uri) async {
    reads.add(uri);
    return List<Cookie>.from(cookies);
  }

  List<List<Object?>> get state => [
        for (final cookie in cookies)
          [
            cookie.name,
            cookie.value,
            cookie.domain,
            cookie.path,
            cookie.expiresDate,
            cookie.isSecure,
            cookie.isHttpOnly
          ],
      ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('读取全部URL后才发布同账号候选，网页新值和独有字段优先且源存储不变', () async {
    final app = _app('101');
    app.collect(['probe=app-only; Path=/known-only'],
        Uri.parse('https://www.huya.com/known-only'));
    final appBefore = app.metadata;
    final source = _SnapshotSource([
      _cookie('udb_uid', '101'),
      _cookie('fixture', 'web-new'),
      _cookie('web_only', 'retained'),
    ]);
    final webBefore = source.state;
    final reachedLast = Completer<void>();
    final releaseLast = Completer<void>();
    var published = false;
    final result =
        HuyaCookieHarvester.harvestWithReader(app, readCookies: (uri) async {
      if (uri.path == '/known-only') {
        reachedLast.complete();
        await releaseLast.future;
      }
      return source.read(uri);
    });
    final observed = result.then((candidate) {
      published = true;
      return candidate;
    });
    await reachedLast.future;
    expect(published, isFalse);
    expect(app.metadata, appBefore);
    expect(source.state, webBefore);
    releaseLast.complete();
    final candidate = await observed;
    expect(candidate, isNotNull);
    expect(candidate!['fixture'], 'web-new');
    expect(candidate['web_only'], 'retained');
    expect(candidate['probe'], isNull);
    expect(
        source.reads.map((uri) => uri.host).toSet(),
        containsAll([
          'www.huya.com',
          'huya.com',
          'i.huya.com',
          'udblgn.huya.com',
          'aq.huya.com'
        ]));
    expect(source.reads.map((uri) => uri.path),
        containsAll(['/10199', '/udb_web/udbport2.php', '/known-only']));
    expect(app.metadata, appBefore);
    expect(source.state, webBefore);
  });

  test('udb_uid相同而yyuid编号不同仍是合法同账号候选', () async {
    final app = HuyaCookieJar.restore('udb_uid=1; yyuid=2; fixture=app-old');
    final source = _SnapshotSource([
      _cookie('udb_uid', '1'),
      _cookie('yyuid', '2'),
      _cookie('fixture', 'web-new'),
    ]);
    final candidate = await HuyaCookieHarvester.harvestWithReader(app,
        readCookies: source.read);
    expect(candidate, isNotNull);
    expect(candidate!['udb_uid'], '1');
    expect(candidate['yyuid'], '2');
    expect(candidate['fixture'], 'web-new');
  });

  test('仅有udb_uid身份上下文也可采集同账号网页完整候选', () async {
    final app = HuyaCookieJar.restore('udb_uid=101');
    final source = _SnapshotSource([
      _cookie('udb_uid', '101'),
      _cookie('udb_biztoken', 'web-token'),
      _cookie('web_only', 'retained'),
    ]);
    final before = app.metadata;
    final candidate = await HuyaCookieHarvester.harvestWithReader(app,
        readCookies: source.read);
    expect(candidate, isNotNull);
    expect(candidate!['udb_uid'], '101');
    expect(candidate['udb_biztoken'], 'web-token');
    expect(candidate['web_only'], 'retained');
    expect(app.metadata, before);
  });

  test('不同账号完整读取后拒绝，App和网页均不清理或改写', () async {
    final app = _app('101');
    final before = app.metadata;
    final source = _SnapshotSource([
      _cookie('udb_uid', '202'),
      _cookie('fixture', 'other-account'),
    ]);
    final webBefore = source.state;
    final candidate = await HuyaCookieHarvester.harvestWithReader(app,
        readCookies: source.read);
    expect(candidate, isNull);
    expect(source.reads, hasLength(7));
    expect(app.metadata, before);
    expect(source.state, webBefore);
  });

  test('跨URL及同名跨scope多个udb_uid拒绝，不能取最后值冒充当前身份', () async {
    final app = _app('101');
    final source = _SnapshotSource([
      _cookie('udb_uid', '101'),
      Cookie(name: 'udb_uid', value: '202', domain: 'i.huya.com', path: '/'),
    ]);
    final before = source.state;
    expect(
        await HuyaCookieHarvester.harvestWithReader(app,
            readCookies: source.read),
        isNull);
    expect(source.state, before);
    var reads = 0;
    expect(
        await HuyaCookieHarvester.harvestWithReader(app,
            readCookies: (uri) async {
          reads++;
          return [_cookie('udb_uid', uri.host == 'i.huya.com' ? '202' : '101')];
        }),
        isNull);
    expect(reads, 7);
  });

  test('App已有多udb_uid作用域冲突时不接触网页', () async {
    final app = HuyaCookieJar();
    app.collect(['udb_uid=101; Domain=.huya.com; Path=/'],
        Uri.parse('https://www.huya.com/'));
    app.collect(['udb_uid=202; Path=/'], Uri.parse('https://i.huya.com/'));
    var reads = 0;
    expect(
        await HuyaCookieHarvester.harvestWithReader(app,
            readCookies: (_) async {
          reads++;
          return [_cookie('udb_uid', '101')];
        }),
        isNull);
    expect(reads, 0);
  });

  test('空白、匿名或有认证字段但无udb_uid均保持原样，不种入也不加载页面', () async {
    for (final cookies in <List<Cookie>>[
      [],
      [_cookie('guid', 'anonymous')],
      [_cookie('udb_biztoken', 'identity-unknown'), _cookie('yyuid', '2')],
    ]) {
      final app = _app('101');
      final before = app.metadata;
      final source = _SnapshotSource(cookies);
      final webBefore = source.state;
      expect(
          await HuyaCookieHarvester.harvestWithReader(app,
              readCookies: source.read),
          isNull);
      expect(source.state, webBefore);
      expect(app.metadata, before);
    }
  });

  test('读取中途失败不发布部分候选、不修改存量，后续请求仍可执行', () async {
    final app = _app('101');
    final before = app.metadata;
    final source = _SnapshotSource([
      _cookie('udb_uid', '101'),
      _cookie('fixture', 'web-new'),
    ]);
    final webBefore = source.state;
    var reads = 0;
    expect(
        await HuyaCookieHarvester.harvestWithReader(app, readCookies: (uri) {
          reads++;
          if (reads == 3) throw StateError('synthetic cookie read failure');
          return source.read(uri);
        }),
        isNull);
    expect(app.metadata, before);
    expect(source.state, webBefore);
    final candidate = await HuyaCookieHarvester.harvestWithReader(app,
        readCookies: source.read);
    expect(candidate!['fixture'], 'web-new');
  });

  test('超时不毒化队列，晚到读取不能继续扫描或发布另一个账号', () async {
    final stalled = Completer<List<Cookie>>();
    final firstApp = _app('101');
    final before = firstApp.metadata;
    var lateReads = 0;
    final first = HuyaCookieHarvester.harvestWithReader(firstApp,
        timeout: const Duration(milliseconds: 1), readCookies: (_) {
      lateReads++;
      return stalled.future;
    });
    expect(await first, isNull);
    final secondSource = _SnapshotSource([
      _cookie('udb_uid', '202'),
      _cookie('fixture', 'second'),
    ]);
    final second = await HuyaCookieHarvester.harvestWithReader(_app('202'),
        readCookies: secondSource.read);
    expect(second!['fixture'], 'second');
    stalled.complete([_cookie('udb_uid', '202')]);
    await Future<void>.value();
    expect(lateReads, 1);
    expect(firstApp.metadata, before);
  });

  test('全局串行且入队时复制，排队期间切换App账号不串入下一请求', () async {
    final firstRead = Completer<void>();
    final releaseFirst = Completer<void>();
    var firstReads = 0;
    final first = HuyaCookieHarvester.harvestWithReader(_app('101'),
        readCookies: (_) async {
      if (firstReads++ == 0) {
        firstRead.complete();
        await releaseFirst.future;
      }
      return [_cookie('udb_uid', '101')];
    });
    await firstRead.future;
    final app = _app('202');
    final source = _SnapshotSource([_cookie('udb_uid', '202')]);
    final second =
        HuyaCookieHarvester.harvestWithReader(app, readCookies: source.read);
    app['udb_uid'] = '303';
    expect(source.reads, isEmpty);
    releaseFirst.complete();
    expect((await first)!['udb_uid'], '101');
    expect((await second)!['udb_uid'], '202');
    expect(app['udb_uid'], '303');
  });

  test('Android同值不返期限时不能被App旧期限提前裁掉', () async {
    var time = DateTime.utc(2026, 1, 1);
    final app = HuyaCookieJar(now: () => time);
    app.collect([
      'udb_uid=101; Domain=.huya.com; Path=/',
      'fixture=same; Domain=.huya.com; Path=/; Max-Age=60; Secure; HttpOnly',
    ], Uri.parse('https://www.huya.com/'));
    final source = _SnapshotSource([
      Cookie(name: 'udb_uid', value: '101'),
      Cookie(name: 'fixture', value: 'same'),
    ]);
    final candidate = await HuyaCookieHarvester.harvestWithReader(app,
        readCookies: source.read);
    expect(candidate, isNotNull);
    time = time.add(const Duration(seconds: 61));
    expect(candidate!['fixture'], 'same');
    expect(app['fixture'], isNull);
    expect(candidate.headerFor(Uri.parse('http://www.huya.com/')),
        isNot(contains('fixture=')));
  });

  test('Android作用域省略且App同名多作用域时拒绝旧值回填', () async {
    final app = _app('101');
    app.collect(
        ['fixture=host-old; Path=/'], Uri.parse('https://www.huya.com/'));
    // The legacy import is replaced by collect; add a second known parent scope.
    app.collect(['fixture=parent-old; Domain=.huya.com; Path=/'],
        Uri.parse('https://www.huya.com/'));
    final source = _SnapshotSource([
      Cookie(name: 'udb_uid', value: '101'),
      Cookie(name: 'fixture', value: 'web-new'),
    ]);
    final before = source.state;
    expect(
        await HuyaCookieHarvester.harvestWithReader(app,
            readCookies: source.read),
        isNull);
    expect(source.state, before);
  });
}
