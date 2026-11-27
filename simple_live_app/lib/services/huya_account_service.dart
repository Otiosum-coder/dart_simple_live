import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart' hide Response;
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/requests/http_client.dart';
import 'package:simple_live_app/services/huya_cookie_harvester.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 保存 UDB 登录响应和后续主站 Cookie 更新；不设臆测的每日过期时间。
class HuyaAccountService extends GetxService with WidgetsBindingObserver {
  HuyaAccountService({
    Dio? dio,
    DateTime Function()? now,
    Future<HuyaCookieJar?> Function(HuyaCookieJar)? cookieHarvester,
    Object? Function(String, Object?)? readStorage,
    Future<void> Function(String, Object?)? writeStorage,
    void Function(String)? onCookieChanged,
    void Function()? onExpired,
    void Function(String)? onSessionLog,
    this.automaticChecks = true,
  })  : _dio = dio,
        _now = now ?? DateTime.now,
        _harvester = cookieHarvester ?? HuyaCookieHarvester.harvest,
        _readStorage = readStorage,
        _writeStorage = writeStorage,
        _onCookieChanged = onCookieChanged,
        _onExpired = onExpired,
        _onSessionLog = onSessionLog;

  static HuyaAccountService get instance => Get.find<HuyaAccountService>();
  static const _metadataKey = 'HuyaCookieMetadataV1';
  static const checkInterval = Duration(minutes: 5);
  static final _userInfoUri =
      Uri.parse('https://www.huya.com/udb_web/udbport2.php');
  final Dio? _dio;
  final DateTime Function() _now;
  final Future<HuyaCookieJar?> Function(HuyaCookieJar) _harvester;
  final Object? Function(String, Object?)? _readStorage;
  final Future<void> Function(String, Object?)? _writeStorage;
  final void Function(String)? _onCookieChanged;
  final void Function()? _onExpired;
  final void Function(String)? _onSessionLog;
  final bool automaticChecks;
  Object? _cookieMetadata;
  var cookie = '';
  var uid = '';
  var name = '未登录'.obs;
  var logined = false.obs;
  var nickname = '';
  int _generation = 0;
  int _cookieRevision = 0;
  bool _knownExpired = false;
  DateTime? _loginAt;
  DateTime? _lastCheck;
  Future<_HuyaSessionState>? _checking;
  Future<bool>? _recovering;
  Future<_HuyaHarvestResult>? _harvesting;
  Future<void>? _completing;
  int? _harvestGeneration;
  int? _harvestRevision;
  Future<void> _saving = Future.value();

  /// 调用方可在异步恢复前记录，防止恢复期间切换账号后误标记新会话。
  int get sessionGeneration => _generation;

  Object? _read(String key, Object? fallback) => _readStorage != null
      ? _readStorage!(key, fallback)
      : LocalStorageService.instance.settingsBox
          .get(key, defaultValue: fallback);

  Future<void> _write(String key, Object? value) async {
    if (_writeStorage != null) {
      await _writeStorage!(key, value);
    } else {
      // Cookie/元数据不经过会打印 value 的通用 storage 日志包装。
      await LocalStorageService.instance.settingsBox.put(key, value);
    }
  }

  @override
  void onInit() {
    final stored = _read(LocalStorageService.kHuyaCookie, '') as String? ?? '';
    nickname = _read(LocalStorageService.kHuyaNickname, '') as String? ?? '';
    cookie = stored.trim();
    _cookieMetadata = _read(_metadataKey, null);
    _publish();
    _trace('restore',
        reason: cookie.isEmpty ? 'empty_session' : 'accepted_snapshot');
    WidgetsBinding.instance.addObserver(this);
    super.onInit();
    if (automaticChecks && cookie.isNotEmpty) unawaited(checkSession());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && automaticChecks) {
      unawaited(checkSession());
    }
  }

  @override
  void onClose() {
    WidgetsBinding.instance.removeObserver(this);
    _generation++;
    super.onClose();
  }

  static Map<String, String> parseCookieMap(String value) {
    final map = <String, String>{};
    for (final part in value.split(';')) {
      final index = part.indexOf('=');
      if (index <= 0) continue;
      final key = part.substring(0, index).trim();
      if (key.isNotEmpty) map[key] = part.substring(index + 1).trim();
    }
    return map;
  }

  void parseCookie() {
    final map = parseCookieMap(cookie);
    uid = map['udb_uid'] ?? map['yyuid'] ?? '';
    logined.value = uid.isNotEmpty && !_knownExpired;
    if (!logined.value) {
      name.value = '未登录';
      return;
    }
    var display = nickname;
    if (display.isEmpty) display = _decode(map['username'] ?? '');
    if (display.isEmpty) display = _decode(map['udb_passport'] ?? '');
    name.value = display.isNotEmpty ? display : '已登录（$uid）';
  }

  String _decode(String value) {
    try {
      return Uri.decodeComponent(value);
    } catch (_) {
      return value;
    }
  }

  void setSite() {
    if (_onCookieChanged != null) {
      _onCookieChanged!(cookie);
    } else {
      (Sites.allSites[Constant.kHuya]!.liveSite as HuyaSite).cookie = cookie;
    }
  }

  void _publish() {
    parseCookie();
    setSite();
  }

  /// 同一队列串行落盘，保证旧保存不会晚于新登录/退出而覆盖它。
  Future<void> _persist() {
    final header = cookie;
    final metadata = _cookieMetadata;
    final nick = nickname;
    _saving = _saving.then((_) async {
      await _write(LocalStorageService.kHuyaCookie, header);
      await _write(_metadataKey, metadata);
      await _write(LocalStorageService.kHuyaNickname, nick);
    }).catchError((Object _) {
      _trace('storage', reason: 'save_failed');
    });
    return _saving;
  }

  /// 裸字符串旧调用仍可使用；显式登录/退出建立新的会话代次。
  Future<void> setCookie(String value,
      {bool freshLogin = false, Object? cookieMetadata}) {
    final oldUid = uid;
    _generation++;
    _cookieRevision++;
    _checking = null;
    _recovering = null;
    _harvesting = null;
    _completing = null;
    _lastCheck = null;
    _knownExpired = false;
    final jar = HuyaCookieJar.restore(value.trim(),
        metadata: cookieMetadata, now: _now);
    final metadata = jar.metadata as Map;
    cookie = metadata['header'] as String;
    _cookieMetadata = jsonEncode(metadata);
    final map = parseCookieMap(cookie);
    final newUid = map['udb_uid'] ?? map['yyuid'] ?? '';
    if (newUid != oldUid || newUid.isEmpty) nickname = '';
    _loginAt = freshLogin && newUid.isNotEmpty ? _now() : null;
    _publish();
    _trace('set', reason: cookie.isEmpty ? 'cleared' : 'explicit_session');
    final saved = _persist();
    if (automaticChecks && logined.value) {
      // 只有 recover 等待 check；check 不反向等待 recover，避免互等。
      unawaited(recoverSession());
    }
    return saved;
  }

  bool get _isFreshLogin =>
      _loginAt != null &&
      _now().difference(_loginAt!) < const Duration(minutes: 2);

  bool _isCurrent(int generation, int revision) =>
      generation == _generation && revision == _cookieRevision;

  HuyaCookieJar _candidate() =>
      HuyaCookieJar.restore(cookie, metadata: _cookieMetadata, now: _now);

  /// 仅在副本裁剪到期项；已接受的 header/metadata 不随读取而改变。
  Future<void> checkSession({bool force = false}) {
    if (cookie.isEmpty) {
      _trace('check', reason: 'empty_session');
      return Future.value();
    }
    final pending = _checking;
    if (pending != null) {
      _trace('check', reason: 'joined');
      return pending.then<void>((_) {});
    }
    final last = _lastCheck;
    if (!force && last != null && _now().difference(last) < checkInterval) {
      _trace('check', reason: 'throttled');
      return Future.value();
    }
    _lastCheck = _now();
    final generation = _generation;
    final revision = _cookieRevision;
    final future = _check(generation, revision, cookie, _candidate());
    _checking = future;
    unawaited(future.whenComplete(() {
      if (identical(_checking, future)) _checking = null;
    }));
    return future.then<void>((_) {});
  }

  Future<_HuyaSessionState> _check(int generation, int revision,
      String expected, HuyaCookieJar candidate) async {
    if (_identityProblem(expected, expected) != null) {
      _trace('check', reason: 'missing_expected_identity');
      return _HuyaSessionState.unknown;
    }
    var stage = 'check';
    if (_identityProblem(candidate.header, expected) != null) {
      // 只相信已接受快照中的账号锚；过期认证字段不回填到请求副本。
      _trace('check', reason: 'local_identity_pruned');
      final recovered =
          await _harvestCandidate(generation, revision, expected, candidate);
      if (!_isCurrent(generation, revision) || recovered.candidate == null) {
        return _HuyaSessionState.unknown;
      }
      candidate = recovered.candidate!;
      stage = 'local_recover';
    }
    var result = await _validate(generation, revision, expected, candidate,
        stage: stage);
    if (result != _HuyaSessionState.invalid ||
        !_isCurrent(generation, revision)) {
      return result;
    }
    _trace('check', reason: 'first_false_recover', auth: result);
    final recovered =
        await _harvestCandidate(generation, revision, expected, _candidate());
    if (!_isCurrent(generation, revision)) {
      _trace('check', reason: 'stale_after_harvest');
      return _HuyaSessionState.unknown;
    }
    result = await _validate(
        generation, revision, expected, recovered.candidate ?? _candidate(),
        stage: 'recheck');
    if (result == _HuyaSessionState.invalid) {
      _expireIfCurrent(generation, revision, notify: true);
    }
    return result;
  }

  /// 只有同账号候选经主站明确确认后才返回 true，不自动重发弹幕。
  Future<bool> recoverSession() {
    if (cookie.isEmpty) {
      _trace('recover', reason: 'empty_session');
      return Future.value(false);
    }
    final pending = _recovering;
    if (pending != null) {
      _trace('recover', reason: 'joined');
      return pending;
    }
    final future = _recover(_generation);
    _recovering = future;
    unawaited(future.whenComplete(() {
      if (identical(_recovering, future)) _recovering = null;
    }));
    return future;
  }

  Future<bool> _recover(int generation) async {
    final checking = _checking;
    if (checking != null) {
      final checked = await checking;
      if (generation != _generation) return false;
      if (checked != _HuyaSessionState.unknown) {
        _trace('recover', reason: 'joined_check_result', auth: checked);
        return checked == _HuyaSessionState.valid;
      }
    }
    if (generation != _generation) return false;
    final revision = _cookieRevision;
    final expected = cookie;
    final candidate =
        await _harvestCandidate(generation, revision, expected, _candidate());
    if (!_isCurrent(generation, revision)) {
      _trace('recover', reason: 'stale_after_harvest');
      return false;
    }
    if (candidate.rejected) {
      _trace('recover', reason: 'rejected_candidate');
      return false;
    }
    _lastCheck = _now();
    var result = await _validate(
        generation, revision, expected, candidate.candidate ?? _candidate(),
        stage: 'recover');
    if (result == _HuyaSessionState.invalid &&
        _isCurrent(generation, revision)) {
      _trace('recover', reason: 'first_false_recover', auth: result);
      final retried =
          await _harvestCandidate(generation, revision, expected, _candidate());
      if (!_isCurrent(generation, revision)) return false;
      result = await _validate(
          generation, revision, expected, retried.candidate ?? _candidate(),
          stage: 'recover_recheck');
      if (result == _HuyaSessionState.invalid) {
        _expireIfCurrent(generation, revision, notify: false);
      }
    }
    return generation == _generation && result == _HuyaSessionState.valid;
  }

  void _expireIfCurrent(int generation, int revision, {required bool notify}) {
    if (!_isCurrent(generation, revision)) {
      _trace('expire', reason: 'stale');
      return;
    }
    if (_isFreshLogin) {
      _trace('expire',
          reason: 'fresh_login_grace', auth: _HuyaSessionState.invalid);
      return;
    }
    final wasExpired = _knownExpired;
    markSessionExpired(sessionGeneration: generation);
    if (notify && !wasExpired) {
      if (_onExpired != null) {
        _onExpired!();
      } else {
        SmartDialog.showToast('虎牙登录已失效，请重新登录');
      }
    }
  }

  /// 最终明确失效只标记 UI；保留最后一次已接受的 Cookie 和昵称。
  void markSessionExpired({int? sessionGeneration}) {
    if (sessionGeneration != null && sessionGeneration != _generation) {
      _trace('expire', reason: 'stale_generation');
      return;
    }
    _knownExpired = true;
    parseCookie();
    _trace('expire', reason: 'confirmed', auth: _HuyaSessionState.invalid);
  }

  /// 以 udb_uid 判身份；yyuid 属于另一标识，不能拿来等值比较。
  String? _identityProblem(String candidate, String expected) {
    final expectedUid = parseCookieMap(expected)['udb_uid'] ?? '';
    if (expectedUid.isEmpty) return 'missing_expected_identity';
    final actual = parseCookieMap(candidate)['udb_uid'] ?? '';
    for (final part in candidate.split(';')) {
      final index = part.indexOf('=');
      if (index <= 0 || part.substring(0, index).trim() != 'udb_uid') continue;
      if (part.substring(index + 1).trim() != expectedUid) {
        return 'identity_mismatch';
      }
    }
    return actual.isEmpty ? 'missing_identity' : null;
  }

  bool _bodyIdentityMismatch(Map data, String expected) {
    final expectedUid = parseCookieMap(expected)['udb_uid'] ?? '';
    final actual = data['udb_uid'];
    return actual != null && actual.toString() != expectedUid;
  }

  Future<_HuyaSessionState> _validate(
      int generation, int revision, String expected, HuyaCookieJar candidate,
      {required String stage}) async {
    if (!_isCurrent(generation, revision)) {
      _trace(stage, reason: 'stale_before_request');
      return _HuyaSessionState.unknown;
    }
    final inputIdentity = _identityProblem(candidate.header, expected);
    if (inputIdentity != null) {
      _trace(stage, reason: inputIdentity);
      return _HuyaSessionState.unknown;
    }
    try {
      final response = await (_dio ?? HttpClient.instance.dio).get<dynamic>(
        _userInfoUri.toString(),
        queryParameters: {'m': 'User', 'do': 'getUserInfo'},
        options: Options(
            responseType: ResponseType.plain,
            followRedirects: false,
            validateStatus: (status) => status != null,
            sendTimeout: const Duration(seconds: 8),
            receiveTimeout: const Duration(seconds: 8),
            headers: {
              'cookie': candidate.headerFor(_userInfoUri),
              'user-agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
              'referer': 'https://www.huya.com/'
            }),
      );
      if (!_isCurrent(generation, revision)) {
        _trace(stage, reason: 'stale_response', http: response.statusCode);
        return _HuyaSessionState.unknown;
      }
      candidate.collect(
          response.headers['set-cookie'] ?? const [], response.realUri);
      final metadata = candidate.metadata as Map;
      final header = metadata['header'] as String;
      final delta = _safeDelta(expected, header);
      if (response.statusCode != 200) {
        _trace(stage,
            reason: 'http_status', http: response.statusCode, delta: delta);
        return _HuyaSessionState.unknown;
      }
      final dynamic data;
      try {
        data = response.data is String
            ? jsonDecode(response.data as String)
            : response.data;
      } catch (_) {
        _trace(stage,
            reason: 'invalid_json', http: response.statusCode, delta: delta);
        return _HuyaSessionState.unknown;
      }
      if (data is! Map) {
        _trace(stage,
            reason: 'unknown_format', http: response.statusCode, delta: delta);
        return _HuyaSessionState.unknown;
      }
      final state = data['isLogined'] == true
          ? _HuyaSessionState.valid
          : data['isLogined'] == false
              ? _HuyaSessionState.invalid
              : _HuyaSessionState.unknown;
      final identity = _identityProblem(header, expected);
      if (identity == 'identity_mismatch' ||
          _bodyIdentityMismatch(data, expected)) {
        _trace(stage,
            reason: 'identity_mismatch',
            http: response.statusCode,
            auth: state,
            delta: delta);
        return _HuyaSessionState.unknown;
      }
      _trace(stage,
          reason: 'response',
          http: response.statusCode,
          auth: state,
          delta: delta);
      if (state != _HuyaSessionState.valid) return state;
      if (identity != null) {
        _trace(stage,
            reason: identity,
            http: response.statusCode,
            auth: state,
            delta: delta);
        return _HuyaSessionState.unknown;
      }
      if (!_isCurrent(generation, revision)) {
        _trace(stage, reason: 'stale_before_commit');
        return _HuyaSessionState.unknown;
      }
      // 没有 await 的单次内存提交；只在验证成功后发布并排队保存同一快照。
      cookie = header;
      _cookieMetadata = jsonEncode(metadata);
      final nick = (data['userNick'] ?? '').toString().trim();
      if (nick.isNotEmpty) nickname = nick;
      _knownExpired = false;
      _cookieRevision++;
      _publish();
      _trace('commit',
          reason: stage, http: response.statusCode, auth: state, delta: delta);
      await _persist();
      return generation == _generation && _cookieRevision == revision + 1
          ? _HuyaSessionState.valid
          : _HuyaSessionState.unknown;
    } catch (_) {
      // 不打印 DioException、请求/响应正文、UID、昵称或凭据。
      _trace(stage, reason: 'request_failed');
      return _HuyaSessionState.unknown;
    }
  }

  Future<_HuyaHarvestResult> _harvestCandidate(
      int generation, int revision, String expected, HuyaCookieJar base) {
    if (!_isCurrent(generation, revision) ||
        _identityProblem(expected, expected) != null) {
      _trace('harvest', reason: 'stale_or_missing_identity');
      return Future.value(const _HuyaHarvestResult(rejected: true));
    }
    final pending = _harvesting;
    if (pending != null &&
        _harvestGeneration == generation &&
        _harvestRevision == revision) {
      _trace('harvest', reason: 'joined');
      return pending;
    }
    final future = () async {
      try {
        _trace('harvest', reason: 'start');
        var context = base;
        if (_identityProblem(base.header, expected) != null) {
          final expectedUid = parseCookieMap(expected)['udb_uid']!;
          context = HuyaCookieJar.restore('udb_uid=$expectedUid', now: _now);
          _trace('harvest', reason: 'identity_context_only');
        }
        final full = await _harvester(context);
        if (!_isCurrent(generation, revision)) {
          _trace('harvest', reason: 'stale_result');
          return const _HuyaHarvestResult(rejected: true);
        }
        if (full == null) {
          _trace('harvest', reason: 'no_candidate');
          return const _HuyaHarvestResult();
        }
        final metadata = full.metadata as Map;
        final header = metadata['header'] as String;
        final problem = _identityProblem(header, expected);
        if (problem != null) {
          _trace('harvest',
              reason: problem, delta: _safeDelta(expected, header));
          return const _HuyaHarvestResult(rejected: true);
        }
        _trace('harvest',
            reason: 'candidate', delta: _safeDelta(expected, header));
        return _HuyaHarvestResult(
            candidate:
                HuyaCookieJar.restore(header, metadata: metadata, now: _now));
      } catch (_) {
        _trace('harvest', reason: 'failed');
        return const _HuyaHarvestResult();
      }
    }();
    _harvesting = future;
    _harvestGeneration = generation;
    _harvestRevision = revision;
    unawaited(future.whenComplete(() {
      if (identical(_harvesting, future)) _harvesting = null;
    }));
    return future;
  }

  Future<void> fetchNickname() => checkSession(force: true);

  /// 手动/登录补全也必须经过同账号主站验证；失败不提交、不标记失效。
  Future<void> harvestCookie() {
    if (cookie.isEmpty) {
      _trace('complete', reason: 'empty_session');
      return Future.value();
    }
    final pending = _completing;
    if (pending != null) return pending;
    final generation = _generation;
    final revision = _cookieRevision;
    final expected = cookie;
    final future = () async {
      final candidate =
          await _harvestCandidate(generation, revision, expected, _candidate());
      if (candidate.candidate == null || !_isCurrent(generation, revision)) {
        return;
      }
      await _validate(generation, revision, expected, candidate.candidate!,
          stage: 'complete');
    }();
    _completing = future;
    unawaited(future.whenComplete(() {
      if (identical(_completing, future)) _completing = null;
    }));
    return future;
  }

  static const _loggedCookieNames = <String>{
    'udb_uid',
    'yyuid',
    'guid',
    'udb_biztoken',
    'udb_passdata',
    'udb_l',
    'udb_n',
    'username',
    'udb_passport',
    'web_qrlogin_confirm_id',
    'udb_guiddata',
    'sdid',
    '__yamid_new',
    'udb_wession',
  };

  String _safeDelta(String before, String after) {
    final old = parseCookieMap(before);
    final current = parseCookieMap(after);
    final added = current.keys.where((key) => !old.containsKey(key)).toSet();
    final removed = old.keys.where((key) => !current.containsKey(key)).toSet();
    final changed = current.keys
        .where((key) => old.containsKey(key) && old[key] != current[key])
        .toSet();
    String safe(String label, Set<String> names) {
      final allowed = names.where(_loggedCookieNames.contains).toList()..sort();
      final other = names.length - allowed.length;
      return ' $label=$allowed other=$other';
    }

    return safe('added', added) +
        safe('removed', removed) +
        safe('changed', changed);
  }

  void _trace(String stage,
      {required String reason,
      int? http,
      _HuyaSessionState auth = _HuyaSessionState.unknown,
      String delta = ''}) {
    final code = http?.toString() ?? '-';
    final state = auth == _HuyaSessionState.valid
        ? 'true'
        : auth == _HuyaSessionState.invalid
            ? 'false'
            : 'unknown';
    final message =
        'HuyaSession stage=$stage reason=$reason http=$code isLogined=$state'
        ' generation=$_generation revision=$_cookieRevision$delta';
    if (_onSessionLog != null) {
      _onSessionLog!(message);
    } else {
      Log.i(message);
    }
  }

  void logout() {
    unawaited(setCookie(''));
  }
}

enum _HuyaSessionState { valid, invalid, unknown }

class _HuyaHarvestResult {
  const _HuyaHarvestResult({this.candidate, this.rejected = false});
  final HuyaCookieJar? candidate;
  final bool rejected;
}
