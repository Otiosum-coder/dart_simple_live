import 'dart:collection';
import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:simple_live_app/app/log.dart';

/// 保留服务器给出的作用域和期限；旧版裸 Cookie 没有期限时不臆造 TTL。
/// Map 接口用于兼容 UDB 请求的 context 字段；HTTP 请求应使用 headerFor。
class HuyaCookieJar extends MapBase<String, String> {
  HuyaCookieJar({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final List<Map<String, dynamic>> _items = [];

  factory HuyaCookieJar.restore(String header,
      {Object? metadata, DateTime Function()? now}) {
    final jar = HuyaCookieJar(now: now);
    try {
      final decoded = metadata is String ? jsonDecode(metadata) : metadata;
      if (decoded is Map &&
          decoded['version'] == 1 &&
          decoded['header'] == header &&
          decoded['cookies'] is List) {
        for (final item in decoded['cookies'] as List) {
          if (item is! Map ||
              item['name'] is! String ||
              (item['name'] as String).isEmpty ||
              item['value'] is! String ||
              item['domain'] is! String ||
              !_isHuya(item['domain'] as String) ||
              item['path'] is! String ||
              !(item['path'] as String).startsWith('/') ||
              item['hostOnly'] is! bool ||
              (item['expires'] != null && item['expires'] is! int) ||
              ['secure', 'httpOnly', 'legacy']
                  .any((key) => item[key] != null && item[key] is! bool)) {
            throw const FormatException('Invalid cookie metadata');
          }
          jar._items.add(Map<String, dynamic>.from(item));
        }
        jar._prune();
        return jar;
      }
    } catch (_) {
      // 损坏或不同版本的旁路元数据不能破坏旧版 Cookie 的恢复。
    }
    jar.clear();
    jar.mergeHeader(header);
    return jar;
  }

  void _prune() {
    final time = _now().millisecondsSinceEpoch;
    _items.removeWhere((e) => e['expires'] is int && e['expires'] <= time);
  }

  @override
  String? operator [](Object? key) {
    _prune();
    for (final item in _items.reversed) {
      if (item['name'] == key) return item['value'] as String;
    }
    return null;
  }

  @override
  void operator []=(String key, String value) {
    remove(key);
    if (value.isEmpty) return;
    _items.add({
      'name': key,
      'value': value,
      'domain': 'huya.com',
      'path': '/',
      'hostOnly': false,
      'legacy': true
    });
  }

  @override
  Iterable<String> get keys {
    _prune();
    return _items.map((e) => e['name'] as String).toSet();
  }

  @override
  void clear() => _items.clear();

  @override
  String? remove(Object? key) {
    final value = this[key];
    _items.removeWhere((e) => e['name'] == key);
    return value;
  }

  /// 无属性的旧存储/手动输入只能作兼容导入，不能推断有效期。
  void mergeHeader(String header) {
    for (final part in header.split(';')) {
      final index = part.indexOf('=');
      if (index <= 0) continue;
      final name = part.substring(0, index).trim();
      if (name.isNotEmpty) this[name] = part.substring(index + 1).trim();
    }
  }

  static bool _isHuya(String host) =>
      host == 'huya.com' || host.endsWith('.huya.com');

  /// 每条 Set-Cookie 分开解析，Expires 内的逗号不能当分隔符。
  void collect(Iterable<String> headers, Uri source) {
    if (!_isHuya(source.host)) return;
    for (final header in headers) {
      try {
        final parsed = io.Cookie.fromSetCookieValue(header);
        final domain = (parsed.domain ?? source.host)
            .toLowerCase()
            .replaceFirst(RegExp(r'^\.'), '');
        if (!_isHuya(domain) ||
            (source.host != domain && !source.host.endsWith('.$domain'))) {
          continue;
        }
        final slash = source.path.lastIndexOf('/');
        final defaultPath = slash <= 0 ? '/' : source.path.substring(0, slash);
        final path =
            parsed.path?.startsWith('/') == true ? parsed.path! : defaultPath;
        DateTime? expires = parsed.expires;
        if (parsed.maxAge != null) {
          expires = _now().add(Duration(seconds: parsed.maxAge!));
        }
        _items.removeWhere((e) =>
            e['name'] == parsed.name &&
            ((e['domain'] == domain && e['path'] == path) ||
                e['legacy'] == true));
        if (parsed.value.isEmpty ||
            (expires != null && !expires.isAfter(_now()))) {
          continue;
        }
        _items.add({
          'name': parsed.name,
          'value': parsed.value,
          'domain': domain,
          'path': path,
          'hostOnly': parsed.domain == null,
          'secure': parsed.secure,
          'httpOnly': parsed.httpOnly,
          if (expires != null) 'expires': expires.millisecondsSinceEpoch
        });
      } catch (_) {
        // 一条异常属性不能吞掉同响应中的其它有效 Cookie，也不记录凭据。
      }
    }
    _prune();
  }

  static bool _matches(Map<String, dynamic> item, Uri uri) {
    final domain = item['domain'] as String;
    final domainMatch = uri.host == domain ||
        (item['hostOnly'] != true && uri.host.endsWith('.$domain'));
    final path = item['path'] as String;
    final actualPath = uri.path.isEmpty ? '/' : uri.path;
    final pathMatch = actualPath == path ||
        (actualPath.startsWith(path) &&
            (path.endsWith('/') ||
                actualPath.substring(path.length).startsWith('/')));
    return domainMatch &&
        pathMatch &&
        (item['secure'] != true || uri.scheme == 'https');
  }

  String headerFor(Uri uri) {
    _prune();
    final selected = _items.where((item) => _matches(item, uri)).toList()
      ..sort((a, b) =>
          (b['path'] as String).length.compareTo((a['path'] as String).length));
    return selected.map((e) => '${e['name']}=${e['value']}').join('; ');
  }

  /// 兼容既有 HuyaSite/弹幕接口的合并 header；所有作用域另存于 metadata。
  String get header {
    _prune();
    return _items.map((e) => '${e['name']}=${e['value']}').join('; ');
  }

  Object get metadata {
    final value = header;
    return {
      'version': 1,
      'header': value,
      'cookies': _items.map((e) => Map<String, dynamic>.from(e)).toList()
    };
  }

  HuyaCookieJar copy() =>
      HuyaCookieJar.restore(header, metadata: metadata, now: _now);

  /// 按读取 URL 对账快照；Android 不返回属性时沿用唯一匹配的已知作用域。
  /// 未探测到的路径保留；同名多作用域无法归属时保留旧记录，不猜测覆盖。
  void replaceFromWebView(Map<Uri, List<Cookie>> snapshots) {
    _prune();
    final before = _items.map((e) => Map<String, dynamic>.from(e)).toList();
    final updated = HuyaCookieJar(now: _now);
    bool matches(Map<String, dynamic> item, Cookie cookie, Uri source) =>
        item['name'] == cookie.name &&
        _matches(item, source) &&
        (cookie.domain == null ||
            item['domain'] ==
                cookie.domain!
                    .replaceFirst(RegExp(r'^\.'), '')
                    .toLowerCase()) &&
        (cookie.path == null || item['path'] == cookie.path);
    void put(Map<String, dynamic> item) {
      updated._items.removeWhere((e) =>
          e['name'] == item['name'] &&
          e['domain'] == item['domain'] &&
          e['path'] == item['path']);
      updated._items.add(item);
    }

    for (final item in before) {
      final observed = snapshots.entries.where((e) => _matches(item, e.key));
      if (observed.isEmpty) put(item);
    }
    for (final entry in snapshots.entries) {
      for (final cookie in entry.value) {
        if (cookie.name.isEmpty ||
            cookie.value is! String ||
            (cookie.value as String).isEmpty) {
          continue;
        }
        final candidates =
            before.where((e) => matches(e, cookie, entry.key)).toList();
        if (candidates.length > 1 &&
            (cookie.domain == null || cookie.path == null)) {
          for (final item in candidates) {
            put(item);
          }
          continue;
        }
        final known = candidates.length == 1 ? candidates.single : null;
        final domain = (cookie.domain ?? known?['domain'] ?? entry.key.host)
            .toString()
            .replaceFirst(RegExp(r'^\.'), '')
            .toLowerCase();
        if (!_isHuya(domain)) continue;
        final item = <String, dynamic>{
          if (known != null) ...known,
          'name': cookie.name,
          'value': cookie.value,
          'domain': domain,
          'path': cookie.path ?? known?['path'] ?? '/',
          'hostOnly': known?['hostOnly'] ??
              (cookie.domain == null || !cookie.domain!.startsWith('.')),
          'secure': cookie.isSecure ?? known?['secure'] ?? false,
          'httpOnly': cookie.isHttpOnly ?? known?['httpOnly'] ?? false,
        };
        // Android 不返回期限，同值也可能已续期；旧到期日不能裁掉网页现存值。
        if (cookie.expiresDate != null) {
          item['expires'] = cookie.expiresDate;
        } else {
          item.remove('expires');
        }
        put(item);
      }
    }
    updated._prune();
    _items
      ..clear()
      ..addAll(updated._items);
  }
}

/// 共享 WebView 只读采样；候选仍须由账号服务向主站验证。
/// Android 不返回完整属性，不能证明种入/页面加载失败后可精确回滚，
/// 因此不向共享存储写入 Cookie，也不加载会隐式改写 Cookie 的页面。
class HuyaCookieHarvester {
  static const List<String> _urls = [
    "https://www.huya.com/",
    "https://huya.com/",
    "https://i.huya.com/",
    "https://www.huya.com/10199",
    "https://udblgn.huya.com/",
    "https://aq.huya.com/",
    "https://www.huya.com/udb_web/udbport2.php",
  ];
  // udb_uid 是登录身份；yyuid 属于另一数字空间，不能与它互比。
  static const _identityNames = {'udb_uid'};
  static Future<void> _tail = Future.value();

  static Future<HuyaCookieJar?> harvest(HuyaCookieJar session) {
    if (!io.Platform.isAndroid && !io.Platform.isIOS) return Future.value(null);
    return harvestWithReader(session,
        readCookies: (uri) =>
            CookieManager.instance().getCookies(url: WebUri(uri.toString())));
  }

  /// 与移动端共用队列和恢复流程，允许离线注入只读 Cookie 采样器。
  /// 不提供写入/页面适配：身份不明、读取失败或超时均保持共享存储原样。
  static Future<HuyaCookieJar?> harvestWithReader(HuyaCookieJar session,
      {required Future<List<Cookie>> Function(Uri) readCookies,
      Duration timeout = const Duration(seconds: 20)}) {
    // 入队即复制，不能到执行时再读取调用者可能已经切换的账号。
    final isolated = session.copy();
    final result = _tail.then((_) => _harvest(isolated, readCookies, timeout));
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  static Set<String> _identities(Iterable<Cookie> cookies) => cookies
      .where((cookie) =>
          _identityNames.contains(cookie.name) &&
          cookie.value is String &&
          (cookie.value as String).trim().isNotEmpty)
      .map((cookie) => (cookie.value as String).trim())
      .toSet();

  static HuyaCookieJar? _reject(String reason) {
    Log.i('HuyaSession harvest rejected reason=$reason');
    return null;
  }

  static Future<HuyaCookieJar?> _harvest(HuyaCookieJar session,
      Future<List<Cookie>> Function(Uri) readCookies, Duration timeout) async {
    final records = session._items;
    final expected = records
        .where((item) => _identityNames.contains(item['name']))
        .map((item) => (item['value'] as String).trim())
        .where((value) => value.isNotEmpty)
        .toSet();
    if (expected.length != 1) {
      return _reject('app_identity_missing_or_conflict');
    }
    final urls = <Uri>{
      ..._urls.map(Uri.parse),
      for (final item in records)
        Uri(
            scheme: 'https',
            host: item['domain'] as String,
            path: item['path'] as String),
    };
    var active = true;
    Future<HuyaCookieJar?> readSnapshot() async {
      try {
        final snapshots = <Uri, List<Cookie>>{};
        for (final url in urls) {
          final cookies = await readCookies(url);
          // Future.timeout 不取消原生读取；晚到的结果不能继续读取或发布候选。
          if (!active) return null;
          snapshots[url] = List<Cookie>.from(cookies);
        }
        final observed = snapshots.values.expand((cookies) => cookies).toList();
        final identities = _identities(observed);
        if (identities.length != 1 || identities.single != expected.single) {
          return _reject('web_identity_missing_or_conflict');
        }
        // Android 省略作用域时，只接受唯一且各 URL 值一致的已知匹配。
        // 不把存在歧义的旧 App 记录重新加入候选，也不猜测 Cookie 的作用域。
        for (final entry in snapshots.entries) {
          for (final cookie in entry.value) {
            if (cookie.domain != null && cookie.path != null) continue;
            final matches = records
                .where((item) =>
                    item['name'] == cookie.name &&
                    HuyaCookieJar._matches(item, entry.key) &&
                    (cookie.domain == null ||
                        item['domain'] ==
                            cookie.domain!
                                .replaceFirst(RegExp(r'^\.'), '')
                                .toLowerCase()) &&
                    (cookie.path == null || item['path'] == cookie.path))
                .toList();
            if (matches.length > 1) return _reject('web_scope_ambiguous');
            if (matches.length == 1) {
              for (final other in snapshots.entries) {
                if (!HuyaCookieJar._matches(matches.single, other.key)) {
                  continue;
                }
                if (other.value.any((value) =>
                    value.name == cookie.name && value.value != cookie.value)) {
                  return _reject('web_scope_ambiguous');
                }
              }
            }
          }
        }
        final candidate = session.copy()..replaceFromWebView(snapshots);
        final candidateIds = candidate._items
            .where((item) => _identityNames.contains(item['name']))
            .map((item) => item['value'] as String)
            .toSet();
        if (candidateIds.length != 1 ||
            candidateIds.single != expected.single) {
          return _reject('candidate_identity_missing_or_conflict');
        }
        Log.i('HuyaSession harvest candidate urls=${snapshots.length}');
        return candidate;
      } catch (_) {
        if (active) _reject('snapshot_read_failed');
        return null;
      }
    }

    try {
      return await readSnapshot()
          .timeout(timeout, onTimeout: () => _reject('snapshot_timeout'));
    } finally {
      active = false;
    }
  }
}
