import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/services/huya_account_service.dart';
import 'package:simple_live_app/services/huya_cookie_harvester.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.reply);
  final Future<ResponseBody> Function(RequestOptions) reply;
  @override
  Future<ResponseBody> fetch(RequestOptions options,
          Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      reply(options);
  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object body, {List<String> cookies = const []}) =>
    ResponseBody.fromString(jsonEncode(body), 200, headers: {
      Headers.contentTypeHeader: ['application/json'],
      if (cookies.isNotEmpty) 'set-cookie': cookies,
    });

class _Harness {
  DateTime now = DateTime.utc(2026, 1, 1);
  final storage = <String, Object?>{};
  int requests = 0;
  int harvests = 0;
  int expired = 0;
  Future<ResponseBody> Function(RequestOptions) reply =
      (_) async => _json({'isLogined': true, 'userNick': '测试昵称'});
  Future<HuyaCookieJar?> Function(HuyaCookieJar) harvest = (_) async => null;
  final published = <String>[];
  final writes = <MapEntry<String, Object?>>[];
  final logs = <String>[];

  void resetJournal() {
    published.clear();
    writes.clear();
    logs.clear();
  }

  HuyaAccountService create({bool automaticChecks = false}) {
    final dio = Dio();
    dio.httpClientAdapter = _Adapter((request) {
      requests++;
      return reply(request);
    });
    return HuyaAccountService(
        dio: dio,
        now: () => now,
        automaticChecks: automaticChecks,
        cookieHarvester: (jar) {
          harvests++;
          return harvest(jar);
        },
        readStorage: (key, fallback) => storage[key] ?? fallback,
        writeStorage: (key, value) async {
          writes.add(MapEntry(key, value));
          storage[key] = value;
        },
        onCookieChanged: published.add,
        onSessionLog: logs.add,
        onExpired: () {
          expired++;
        });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('启动从旧裸 Cookie 恢复，超过 24 小时不按本地时长登出', () async {
    final h = _Harness();
    h.storage[LocalStorageService.kHuyaCookie] = 'udb_uid=101; fixture=legacy';
    h.storage[LocalStorageService.kHuyaNickname] = '缓存昵称';
    h.now = h.now.add(const Duration(hours: 25));
    final service = h.create()..onInit();
    addTearDown(service.onClose);
    expect(service.logined.value, isTrue);
    expect(service.nickname, '缓存昵称');
    await service.checkSession();
    expect(service.logined.value, isTrue);
    expect(h.requests, 1);
  });

  test('启动与回到前台共用五分钟节流，并发检查合并', () async {
    final h = _Harness();
    h.storage[LocalStorageService.kHuyaCookie] = 'udb_uid=101; fixture=legacy';
    final service = h.create(automaticChecks: true)..onInit();
    addTearDown(service.onClose);
    await service.checkSession();
    expect(h.requests, 1);
    service.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await service.checkSession();
    expect(h.requests, 1);
    h.now = h.now.add(const Duration(minutes: 5));
    service.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await service.checkSession();
    expect(h.requests, 2);
  });

  test('同长度及更短服务端 Set-Cookie 及时保存并可重启恢复', () async {
    final h = _Harness();
    final service = h.create();
    await service.setCookie('udb_uid=101; fixture=first');
    var calls = 0;
    h.reply = (_) async => _json({
          'isLogined': true
        }, cookies: [
          calls++ == 0
              ? 'fixture=other; Domain=.huya.com; Path=/; Max-Age=600'
              : 'fixture=x; Domain=.huya.com; Path=/; Max-Age=600',
        ]);
    await service.checkSession(force: true);
    expect(
        HuyaAccountService.parseCookieMap(service.cookie)['fixture'], 'other');
    await service.checkSession(force: true);
    expect(HuyaAccountService.parseCookieMap(service.cookie)['fixture'], 'x');
    final restored = h.create()..onInit();
    addTearDown(restored.onClose);
    expect(restored.cookie, service.cookie);
    expect(HuyaAccountService.parseCookieMap(restored.cookie)['fixture'], 'x');
    h.now = h.now.add(const Duration(seconds: 601));
    final later = h.create()..onInit();
    addTearDown(later.onClose);
    expect(HuyaAccountService.parseCookieMap(later.cookie)['fixture'], 'x');
    expect(later.uid, '101');
    h.reply = (request) async {
      final sent = HuyaAccountService.parseCookieMap(
          request.headers['cookie'] as String);
      expect(sent.containsKey('fixture'), isFalse);
      return _json({'isLogined': true});
    };
    await later.checkSession();
    expect(
        HuyaAccountService.parseCookieMap(later.cookie).containsKey('fixture'),
        isFalse);
  });

  test('服务端删除 Cookie 不被旧值补回', () async {
    final h = _Harness();
    final service = h.create();
    await service.setCookie('udb_uid=101; fixture=old');
    h.reply = (_) async => _json({
          'isLogined': true
        }, cookies: [
          'fixture=removed; Domain=.huya.com; Path=/; Max-Age=0',
        ]);
    await service.checkSession();
    expect(
        HuyaAccountService.parseCookieMap(service.cookie)
            .containsKey('fixture'),
        isFalse);
    final restored = h.create()..onInit();
    addTearDown(restored.onClose);
    expect(
        HuyaAccountService.parseCookieMap(restored.cookie)
            .containsKey('fixture'),
        isFalse);
  });

  test('非 200 响应的 Cookie 仅为未验证候选，不能发布或落盘', () async {
    final h = _Harness();
    final service = h.create();
    await service.setCookie('udb_uid=101; fixture=old');
    final accepted = service.cookie;
    final stored = Map<String, Object?>.from(h.storage);
    h.resetJournal();
    for (final status in [302, 401, 503]) {
      h.reply = (_) async =>
          ResponseBody.fromString('{"isLogined":false}', status, headers: {
            'set-cookie': ['fixture=x; Domain=.huya.com; Path=/'],
            'content-type': ['application/json']
          });
      await service.checkSession(force: true);
      expect(service.cookie, accepted);
      expect(service.logined.value, isTrue);
      expect(h.storage, stored);
      expect(h.writes, isEmpty);
      expect(h.published, isEmpty);
    }
    expect(h.harvests, 0);
    expect(h.expired, 0);
    expect(h.storage[LocalStorageService.kHuyaCookie], service.cookie);
  });

  test('网络异常及未知结构保留 Cookie 和昵称，不补全或提示过期', () async {
    final h = _Harness();
    final service = h.create();
    await service.setCookie('udb_uid=101; fixture=old');
    service.nickname = '缓存昵称';
    h.reply = (request) async => throw DioException(
        requestOptions: request, type: DioExceptionType.connectionTimeout);
    await service.checkSession();
    expect(service.logined.value, isTrue);
    expect(service.nickname, '缓存昵称');
    h.reply = (_) async => _json({'unexpected': false});
    await service.checkSession(force: true);
    expect(service.logined.value, isTrue);
    expect(HuyaAccountService.parseCookieMap(service.cookie)['fixture'], 'old');
    expect(h.expired, 0);
    expect(h.harvests, 0);
  });

  test('主站首次 false 先补全再复验；等长快照有效且不会提示重登', () async {
    final h = _Harness();
    final service = h.create();
    await service.setCookie('udb_uid=101; fixture=first');
    h.harvest =
        (_) async => HuyaCookieJar.restore('udb_uid=101; fixture=other');
    h.reply = (_) async => _json({'isLogined': h.requests > 1});
    await service.checkSession();
    expect(h.requests, 2);
    expect(h.harvests, 1);
    expect(service.logined.value, isTrue);
    expect(
        HuyaAccountService.parseCookieMap(service.cookie)['fixture'], 'other');
    expect(h.expired, 0);
  });

  test('补全后明确 false 即失效，缓存昵称和二维码标记均不能永久豁免', () async {
    final h = _Harness();
    final service = h.create();
    await service
        .setCookie('udb_uid=101; fixture=old; web_qrlogin_confirm_id=fixture');
    service.nickname = '缓存昵称';
    h.reply = (_) async => _json({'isLogined': false});
    await service.checkSession();
    expect(h.requests, 2);
    expect(service.logined.value, isFalse);
    expect(service.cookie, isNotEmpty);
    expect(h.expired, 1);
  });

  test('补全后未知或断网保留本地登录，不把无法确认当作失效', () async {
    final h = _Harness();
    final service = h.create();
    await service.setCookie('udb_uid=101; fixture=old');
    h.reply = (_) async =>
        _json(h.requests == 1 ? {'isLogined': false} : {'unknown': true});
    await service.checkSession();
    expect(service.logined.value, isTrue);
    expect(h.expired, 0);
  });

  test('新登录两分钟缓冲仅为短暂宽限，之后 false 仍标记失效', () async {
    final h = _Harness();
    final service = h.create();
    await service.setCookie('udb_uid=101; fixture=old', freshLogin: true);
    h.reply = (_) async => _json({'isLogined': false});
    await service.checkSession();
    expect(service.logined.value, isTrue);
    h.now = h.now.add(const Duration(minutes: 3));
    await service.checkSession(force: true);
    expect(service.logined.value, isFalse);
    expect(h.expired, 1);
  });

  test('恢复只有主站 true 才成功，未知失败保留状态，明确 false 才登出', () async {
    final h = _Harness();
    final service = h.create();
    await service.setCookie('udb_uid=101; fixture=old');
    h.harvest = (_) async => HuyaCookieJar.restore('udb_uid=101; fixture=x');
    h.reply = (_) async => _json({'unknown': true});
    expect(await service.recoverSession(), isFalse);
    expect(service.logined.value, isTrue);
    expect(HuyaAccountService.parseCookieMap(service.cookie)['fixture'], 'old');
    h.reply = (_) async => _json({'isLogined': false});
    expect(await service.recoverSession(), isFalse);
    expect(service.logined.value, isFalse);
    h.reply = (_) async => _json({'isLogined': true});
    expect(await service.recoverSession(), isTrue);
    expect(service.logined.value, isTrue);
  });

  test('过长 Cookie 也补全；并发补全合并且接受更短快照', () async {
    final h = _Harness();
    final service = h.create();
    final longFixture = List.filled(1600, 'x').join();
    await service.setCookie('udb_uid=101; fixture=$longFixture');
    final gate = Completer<HuyaCookieJar?>();
    h.harvest = (_) => gate.future;
    final first = service.harvestCookie();
    final second = service.harvestCookie();
    expect(h.harvests, 1);
    gate.complete(HuyaCookieJar.restore('udb_uid=101; fixture=x'));
    await Future.wait([first, second]);
    expect(HuyaAccountService.parseCookieMap(service.cookie)['fixture'], 'x');
  });

  test('切换账号后丢弃旧 HTTP 响应和旧代次的失效标记', () async {
    final h = _Harness();
    final service = h.create();
    await service.setCookie('udb_uid=101; fixture=old');
    final generation = service.sessionGeneration;
    final gate = Completer<ResponseBody>();
    final entered = Completer<void>();
    h.reply = (_) {
      entered.complete();
      return gate.future;
    };
    final checking = service.checkSession();
    await entered.future;
    await service.setCookie('udb_uid=202; fixture=new');
    gate.complete(
        _json({'isLogined': false}, cookies: ['fixture=stale; Path=/']));
    await checking;
    service.markSessionExpired(sessionGeneration: generation);
    expect(service.uid, '202');
    expect(service.logined.value, isTrue);
    expect(HuyaAccountService.parseCookieMap(service.cookie)['fixture'], 'new');
    expect(h.harvests, 0);
  });

  test('退出后迟到的 WebView 快照不能复活会话或覆盖存储', () async {
    final h = _Harness();
    final service = h.create();
    await service.setCookie('udb_uid=101; fixture=old');
    final gate = Completer<HuyaCookieJar?>();
    h.harvest = (_) => gate.future;
    final harvesting = service.harvestCookie();
    await service.setCookie('');
    gate.complete(HuyaCookieJar.restore('udb_uid=101; fixture=stale'));
    await harvesting;
    expect(service.cookie, isEmpty);
    expect(service.uid, isEmpty);
    expect(service.nickname, isEmpty);
    expect(service.logined.value, isFalse);
    expect(h.storage[LocalStorageService.kHuyaCookie], isEmpty);
    expect(h.storage[LocalStorageService.kHuyaNickname], isEmpty);
  });

  test('同代次较旧补全不能覆盖已接受的 HTTP 轮换', () async {
    final h = _Harness();
    final service = h.create();
    await service.setCookie('udb_uid=101; fixture=old');
    final gate = Completer<HuyaCookieJar?>();
    h.harvest = (_) => gate.future;
    final harvesting = service.harvestCookie();
    h.reply = (_) async => _json({
          'isLogined': true
        }, cookies: [
          'fixture=new; Domain=.huya.com; Path=/',
        ]);
    await service.checkSession();
    gate.complete(HuyaCookieJar.restore('udb_uid=101; fixture=stale'));
    await harvesting;
    expect(HuyaAccountService.parseCookieMap(service.cookie)['fixture'], 'new');
  });

  test('首次 false 删除 UID 不发布空身份，恢复中及最终未知均保留快照', () async {
    final h = _Harness();
    final service = h.create();
    await service.setCookie('udb_uid=101; fixture=old');
    service.nickname = '保留昵称';
    service.parseCookie();
    final accepted = service.cookie;
    final name = service.name.value;
    final stored = Map<String, Object?>.from(h.storage);
    final entered = Completer<void>();
    final gate = Completer<HuyaCookieJar?>();
    h.harvest = (_) {
      entered.complete();
      return gate.future;
    };
    h.reply = (_) async => h.requests == 1
        ? _json({
            'isLogined': false
          }, cookies: [
            'udb_uid=removed; Domain=.huya.com; Path=/; Max-Age=0',
          ])
        : _json({'unknown': true});
    h.resetJournal();
    final checking = service.checkSession();
    await entered.future;
    expect(service.cookie, accepted);
    expect(service.uid, '101');
    expect(service.logined.value, isTrue);
    expect(service.name.value, name);
    expect(h.published, isEmpty);
    expect(h.writes, isEmpty);
    gate.complete(null);
    await checking;
    expect(service.cookie, accepted);
    expect(service.nickname, '保留昵称');
    expect(service.logined.value, isTrue);
    expect(h.storage, stored);
    expect(h.writes, isEmpty);
    expect(h.published, isEmpty);
    expect(h.expired, 0);
    expect(h.logs.join('\n'), contains('removed=[udb_uid]'));
  });

  test('unknown 或 true 响应删除 UID 都不能提交不完整候选', () async {
    for (final body in [
      {'unknown': true},
      {'isLogined': true}
    ]) {
      final h = _Harness();
      final service = h.create();
      await service.setCookie('udb_uid=101; fixture=old');
      final accepted = service.cookie;
      final stored = Map<String, Object?>.from(h.storage);
      h.reply = (_) async => _json(body, cookies: [
            'udb_uid=removed; Domain=.huya.com; Path=/; Max-Age=0',
          ]);
      h.resetJournal();
      await service.checkSession();
      expect(service.cookie, accepted);
      expect(service.uid, '101');
      expect(service.logined.value, isTrue);
      expect(h.storage, stored);
      expect(h.writes, isEmpty);
      expect(h.published, isEmpty);
      expect(h.expired, 0);
    }
  });

  test('手动网页补全的 false 未知 非200与网络失败都不能提交或改变UI', () async {
    for (final mode in ['false', 'unknown', 'http', 'network']) {
      final h = _Harness();
      final service = h.create();
      await service.setCookie('udb_uid=101; fixture=old');
      service.nickname = '缓存昵称';
      service.parseCookie();
      final accepted = service.cookie;
      final name = service.name.value;
      final stored = Map<String, Object?>.from(h.storage);
      h.harvest = (_) async => HuyaCookieJar.restore('udb_uid=101; fixture=x');
      h.reply = (request) async {
        if (mode == 'network') {
          throw DioException(
              requestOptions: request,
              type: DioExceptionType.connectionTimeout,
              error: 'private-exception');
        }
        if (mode == 'http') {
          return ResponseBody.fromString('{"isLogined":true}', 503, headers: {
            'set-cookie': ['fixture=short; Domain=.huya.com; Path=/']
          });
        }
        return _json(mode == 'false' ? {'isLogined': false} : {'unknown': true},
            cookies: ['fixture=short; Domain=.huya.com; Path=/']);
      };
      h.resetJournal();
      await service.harvestCookie();
      expect(service.cookie, accepted, reason: mode);
      expect(service.nickname, '缓存昵称', reason: mode);
      expect(service.name.value, name, reason: mode);
      expect(service.logined.value, isTrue, reason: mode);
      expect(h.storage, stored, reason: mode);
      expect(h.writes, isEmpty, reason: mode);
      expect(h.published, isEmpty, reason: mode);
      expect(h.expired, 0, reason: mode);
    }
  });

  test('同账号候选只在主站 true 后单次发布并保存同一快照', () async {
    final h = _Harness();
    final service = h.create();
    await service.setCookie('udb_uid=101; fixture=old');
    final accepted = service.cookie;
    final stored = Map<String, Object?>.from(h.storage);
    final entered = Completer<void>();
    final gate = Completer<ResponseBody>();
    h.harvest =
        (_) async => HuyaCookieJar.restore('udb_uid=101; fixture=other');
    h.reply = (_) {
      entered.complete();
      return gate.future;
    };
    h.resetJournal();
    final recovery = service.recoverSession();
    await entered.future;
    expect(service.cookie, accepted);
    expect(h.storage, stored);
    expect(h.writes, isEmpty);
    expect(h.published, isEmpty);
    gate.complete(_json({
      'isLogined': true,
      'userNick': '验证昵称'
    }, cookies: [
      'fixture=x; Domain=.huya.com; Path=/',
    ]));
    expect(await recovery, isTrue);
    expect(HuyaAccountService.parseCookieMap(service.cookie)['fixture'], 'x');
    expect(service.nickname, '验证昵称');
    expect(h.published, [service.cookie]);
    expect(h.writes.length, 3);
    expect(h.writes.map((entry) => entry.key).toSet(), {
      LocalStorageService.kHuyaCookie,
      'HuyaCookieMetadataV1',
      LocalStorageService.kHuyaNickname,
    });
    expect(h.storage[LocalStorageService.kHuyaCookie], service.cookie);
    final metadata =
        jsonDecode(h.storage['HuyaCookieMetadataV1'] as String) as Map;
    expect(metadata['header'], service.cookie);
    expect(h.logs.where((line) => line.contains('stage=commit')).length, 1);
  });

  test('网页缺身份或异账号候选即使预设HTTP为true也不发验证或落盘', () async {
    for (final candidate in ['fixture=other', 'udb_uid=202; fixture=other']) {
      final h = _Harness();
      final service = h.create();
      await service.setCookie('udb_uid=101; fixture=old');
      final accepted = service.cookie;
      final stored = Map<String, Object?>.from(h.storage);
      h.harvest = (_) async => HuyaCookieJar.restore(candidate);
      h.resetJournal();
      expect(await service.recoverSession(), isFalse);
      expect(service.cookie, accepted);
      expect(service.logined.value, isTrue);
      expect(h.requests, 0);
      expect(h.storage, stored);
      expect(h.writes, isEmpty);
      expect(h.published, isEmpty);
    }
  });

  test('主站true但响应身份或SetCookie切换udb_uid时拒绝提交', () async {
    for (final inBody in [true, false]) {
      final h = _Harness();
      final service = h.create();
      await service.setCookie('udb_uid=101; fixture=old');
      final accepted = service.cookie;
      final stored = Map<String, Object?>.from(h.storage);
      h.reply = (_) async => _json({
            'isLogined': true,
            if (inBody) 'udb_uid': 202,
            'userNick': '不应提交昵称',
          }, cookies: inBody ? [] : ['udb_uid=202; Domain=.huya.com; Path=/']);
      h.resetJournal();
      await service.checkSession();
      expect(service.cookie, accepted);
      expect(service.nickname, isEmpty);
      expect(service.logined.value, isTrue);
      expect(h.storage, stored);
      expect(h.writes, isEmpty);
      expect(h.published, isEmpty);
    }
  });

  test('身份只锚定udb_uid，同账号yyuid变化及不同数值不误拒绝', () async {
    final h = _Harness();
    final service = h.create();
    await service.setCookie('udb_uid=101; yyuid=9001; fixture=old');
    h.harvest = (_) async =>
        HuyaCookieJar.restore('udb_uid=101; yyuid=9002; fixture=x');
    h.reply =
        (_) async => _json({'isLogined': true, 'udb_uid': 101, 'yyuid': 9003});
    expect(await service.recoverSession(), isTrue);
    expect(service.uid, '101');
    expect(HuyaAccountService.parseCookieMap(service.cookie)['yyuid'], '9002');
  });

  test('metadata已过期裁剪UID仍可用accepted身份读取同账号网页候选', () async {
    final h = _Harness();
    final jar = HuyaCookieJar.restore('udb_uid=101; fixture=expired-auth',
        now: () => h.now);
    jar.collect([
      'udb_uid=101; Domain=.huya.com; Path=/; Max-Age=1',
      'fixture=expired-auth; Domain=.huya.com; Path=/; Max-Age=1',
    ], Uri.parse('https://www.huya.com/'));
    final metadata = jar.metadata as Map;
    h.storage[LocalStorageService.kHuyaCookie] = metadata['header'];
    h.storage['HuyaCookieMetadataV1'] = jsonEncode(metadata);
    h.storage[LocalStorageService.kHuyaNickname] = '稳定缓存昵称';
    h.now = h.now.add(const Duration(seconds: 2));
    final service = h.create()..onInit();
    addTearDown(service.onClose);
    expect(service.uid, '101');
    expect(service.logined.value, isTrue);
    h.harvest = (context) async {
      final fields = HuyaAccountService.parseCookieMap(context.header);
      expect(fields, {'udb_uid': '101'});
      return HuyaCookieJar.restore('udb_uid=101; fixture=web-valid');
    };
    h.reply = (request) async {
      final fields = HuyaAccountService.parseCookieMap(
          request.headers['cookie'] as String);
      expect(fields['fixture'], 'web-valid');
      return _json({'isLogined': true, 'udb_uid': 101});
    };
    h.resetJournal();
    await service.checkSession();
    expect(h.harvests, 1);
    expect(h.requests, 1);
    expect(HuyaAccountService.parseCookieMap(service.cookie)['fixture'],
        'web-valid');
    expect(service.logined.value, isTrue);
    expect(h.published.length, 1);
    expect(h.writes.length, 3);
    expect(h.logs.join('\n'), contains('reason=identity_context_only'));
  });

  for (final mode in [
    'false',
    'unknown',
    'false_then_unknown',
    'false_then_true',
    'network',
  ]) {
    test('metadata裁剪UID后恢复复验结果为$mode，不能绕过最终状态处理', () async {
      final h = _Harness();
      final jar = HuyaCookieJar.restore('udb_uid=101; fixture=expired-auth',
          now: () => h.now);
      jar.collect([
        'udb_uid=101; Domain=.huya.com; Path=/; Max-Age=1',
        'fixture=expired-auth; Domain=.huya.com; Path=/; Max-Age=1',
      ], Uri.parse('https://www.huya.com/'));
      final metadata = jar.metadata as Map;
      h.storage[LocalStorageService.kHuyaCookie] = metadata['header'];
      h.storage['HuyaCookieMetadataV1'] = jsonEncode(metadata);
      h.storage[LocalStorageService.kHuyaNickname] = '稳定缓存昵称';
      h.now = h.now.add(const Duration(seconds: 2));
      final service = h.create()..onInit();
      addTearDown(service.onClose);
      final accepted = service.cookie;
      final stored = Map<String, Object?>.from(h.storage);
      h.harvest = (context) async {
        expect(HuyaAccountService.parseCookieMap(context.header),
            {'udb_uid': '101'});
        return HuyaCookieJar.restore('udb_uid=101; fixture=web-candidate');
      };
      h.reply = (request) async {
        expect(
            HuyaAccountService.parseCookieMap(
                request.headers['cookie'] as String)['fixture'],
            'web-candidate');
        if (mode == 'network') {
          throw DioException(
              requestOptions: request,
              type: DioExceptionType.connectionTimeout);
        }
        if (mode == 'unknown' ||
            (mode == 'false_then_unknown' && h.requests > 1)) {
          return _json({'unknown': true});
        }
        return _json({
          'isLogined': mode == 'false_then_true' && h.requests > 1,
          'udb_uid': 101,
        });
      };
      h.resetJournal();
      final checking = service.checkSession();
      final recovering = mode == 'false' ? service.recoverSession() : null;
      await checking.timeout(const Duration(seconds: 2));
      if (recovering != null) {
        expect(await recovering.timeout(const Duration(seconds: 2)), isFalse);
      }
      final retried = mode == 'false' || mode.startsWith('false_then_');
      expect(h.requests, retried ? 2 : 1);
      expect(h.harvests, retried ? 2 : 1);
      expect(service.logined.value, mode != 'false');
      expect(h.expired, mode == 'false' ? 1 : 0);
      expect(service.nickname, '稳定缓存昵称');
      if (mode == 'false_then_true') {
        expect(HuyaAccountService.parseCookieMap(service.cookie)['fixture'],
            'web-candidate');
        expect(h.published, hasLength(1));
        expect(h.writes, hasLength(3));
      } else {
        expect(service.cookie, accepted);
        expect(h.storage, stored);
        expect(h.published, isEmpty);
        expect(h.writes, isEmpty);
      }
      if (mode == 'false') {
        await service.checkSession(force: true);
        expect(service.logined.value, isFalse);
        expect(h.requests, 4);
        expect(h.expired, 1);
        expect(service.cookie, accepted);
      }
    });
  }

  test('存储header本身没有udb_uid时不能凭网页猜账号', () async {
    final h = _Harness();
    h.storage[LocalStorageService.kHuyaCookie] = 'yyuid=9001; fixture=legacy';
    final service = h.create()..onInit();
    addTearDown(service.onClose);
    final accepted = service.cookie;
    h.harvest =
        (_) async => HuyaCookieJar.restore('udb_uid=101; fixture=other');
    h.resetJournal();
    await service.checkSession();
    expect(await service.recoverSession(), isFalse);
    expect(h.harvests, 0);
    expect(h.requests, 0);
    expect(service.cookie, accepted);
    expect(h.writes, isEmpty);
    expect(h.published, isEmpty);
  });

  test('同代次迟到HTTP不能覆盖已验证网页修订或发布旧状态', () async {
    final h = _Harness();
    final service = h.create();
    await service.setCookie('udb_uid=101; fixture=old');
    final entered = Completer<void>();
    final gate = Completer<ResponseBody>();
    h.reply = (_) {
      if (h.requests == 1) {
        entered.complete();
        return gate.future;
      }
      return Future.value(_json({'isLogined': true}));
    };
    final checking = service.checkSession();
    await entered.future;
    h.harvest =
        (_) async => HuyaCookieJar.restore('udb_uid=101; fixture=fresh');
    await service.harvestCookie();
    final accepted = service.cookie;
    final stored = Map<String, Object?>.from(h.storage);
    h.resetJournal();
    gate.complete(_json({
      'isLogined': false
    }, cookies: [
      'udb_uid=removed; Domain=.huya.com; Path=/; Max-Age=0',
      'fixture=stale; Domain=.huya.com; Path=/',
    ]));
    await checking;
    expect(service.cookie, accepted);
    expect(
        HuyaAccountService.parseCookieMap(service.cookie)['fixture'], 'fresh');
    expect(service.logined.value, isTrue);
    expect(h.storage, stored);
    expect(h.writes, isEmpty);
    expect(h.published, isEmpty);
    expect(h.logs.join('\n'), contains('reason=stale_response'));
  });

  test('切换账号后迟到网页候选不发HTTP且不能修改新账号', () async {
    final h = _Harness();
    final service = h.create();
    await service.setCookie('udb_uid=101; fixture=old');
    final gate = Completer<HuyaCookieJar?>();
    h.harvest = (_) => gate.future;
    final recovering = service.recoverSession();
    await service.setCookie('udb_uid=202; fixture=new');
    final stored = Map<String, Object?>.from(h.storage);
    h.resetJournal();
    gate.complete(HuyaCookieJar.restore('udb_uid=101; fixture=stale'));
    expect(await recovering, isFalse);
    expect(service.uid, '202');
    expect(service.logined.value, isTrue);
    expect(h.requests, 0);
    expect(h.storage, stored);
    expect(h.writes, isEmpty);
    expect(h.published, isEmpty);
  });

  test('退出后迟到HTTP的true不能复活会话或回写', () async {
    final h = _Harness();
    final service = h.create();
    await service.setCookie('udb_uid=101; fixture=old');
    final entered = Completer<void>();
    final gate = Completer<ResponseBody>();
    h.reply = (_) {
      entered.complete();
      return gate.future;
    };
    final checking = service.checkSession();
    await entered.future;
    await service.setCookie('');
    final stored = Map<String, Object?>.from(h.storage);
    h.resetJournal();
    gate.complete(_json({
      'isLogined': true,
      'userNick': '旧昵称'
    }, cookies: [
      'fixture=stale; Domain=.huya.com; Path=/',
    ]));
    await checking;
    expect(service.cookie, isEmpty);
    expect(service.nickname, isEmpty);
    expect(service.logined.value, isFalse);
    expect(h.storage, stored);
    expect(h.writes, isEmpty);
    expect(h.published, isEmpty);
  });

  test('检查恢复及补全并发完成，不形成相互等待', () async {
    final h = _Harness();
    final service = h.create();
    await service.setCookie('udb_uid=101; fixture=old');
    h.harvest = (_) async => HuyaCookieJar.restore('udb_uid=101; fixture=web');
    await Future.wait<void>([
      service.checkSession(),
      service.recoverSession().then<void>((_) {}),
      service.harvestCookie(),
    ]).timeout(const Duration(seconds: 2));
    expect(service.logined.value, isTrue);
    expect(h.expired, 0);
  });

  test('已明确失效时未验证网页候选不能提前恢复UI', () async {
    final h = _Harness();
    final service = h.create();
    await service.setCookie('udb_uid=101; fixture=old');
    service.markSessionExpired();
    h.harvest = (_) async => HuyaCookieJar.restore('udb_uid=101; fixture=web');
    h.reply = (_) async => _json({'unknown': true});
    h.resetJournal();
    expect(await service.recoverSession(), isFalse);
    expect(service.logined.value, isFalse);
    expect(HuyaAccountService.parseCookieMap(service.cookie)['fixture'], 'old');
    expect(h.writes, isEmpty);
    expect(h.published, isEmpty);
    h.reply = (_) async => _json({'isLogined': true});
    expect(await service.recoverSession(), isTrue);
    expect(service.logined.value, isTrue);
  });

  test('HuyaSession日志含三态阶段与白名单字段差量但不含凭据身份昵称异常', () async {
    final h = _Harness();
    final service = h.create();
    await service.setCookie(
        'udb_uid=43126789; fixture=private-cookie; udb_biztoken=private-token');
    h.reply = (_) async => _json({
          'isLogined': true,
          'userNick': 'private-nickname'
        }, cookies: [
          'udb_biztoken=rotated-private-token; Domain=.huya.com; Path=/',
          'private_field_name=private-field-value; Domain=.huya.com; Path=/',
        ]);
    await service.checkSession();
    h.reply = (_) async => _json({'isLogined': false});
    await service.checkSession(force: true);
    h.reply = (_) async => _json({'unknown': true});
    await service.checkSession(force: true);
    h.reply = (request) async => throw DioException(
        requestOptions: request,
        type: DioExceptionType.connectionTimeout,
        error: 'private-exception');
    await service.checkSession(force: true);
    expect(h.logs, isNotEmpty);
    expect(h.logs.every((line) => line.startsWith('HuyaSession ')), isTrue);
    final text = h.logs.join('\n');
    for (final marker in [
      'stage=check',
      'http=200',
      'isLogined=true',
      'isLogined=false',
      'isLogined=unknown',
      'reason=request_failed',
      'changed=[udb_biztoken]',
      'other=1'
    ]) {
      expect(text, contains(marker));
    }
    for (final secret in [
      '43126789',
      'private-cookie',
      'private-token',
      'rotated-private-token',
      'private-nickname',
      'private_field_name',
      'private-field-value',
      'private-exception',
      'RequestOptions',
      'DioException'
    ]) {
      expect(text, isNot(contains(secret)));
    }
  });

  test('WebView 意外返回其它账号时拒绝覆盖', () async {
    final h = _Harness();
    final service = h.create();
    await service.setCookie('udb_uid=101; fixture=old');
    h.harvest =
        (_) async => HuyaCookieJar.restore('udb_uid=202; fixture=other');
    await service.harvestCookie();
    expect(service.uid, '101');
    expect(HuyaAccountService.parseCookieMap(service.cookie)['fixture'], 'old');
  });
}
