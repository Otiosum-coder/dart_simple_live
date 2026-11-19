import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../common/core_log.dart';
import 'douyin_abogus.dart';

/// 抖音网页扫码登录（纯 Dart 实现）
///
/// 流程与网页版一致：
/// 落地页取 __ac_nonce -> www/login 两处 ttwid/check -> login_guiding_strategy
/// -> get_qrcode 取二维码（含 a_bogus 之外的 passport 签名）-> check_qrconnect 轮询。
///
/// 注意：get_qrcode 不能带 a_bogus（会 Error 22 非法应用），
/// 只有 check_qrconnect 必须带 a_bogus，否则返回 4031 风控。
const String kDouyinQrUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/155.0.0.0 Safari/537.36';

const String _kHome = 'https://www.douyin.com';
const String _kLogin = 'https://login.douyin.com';
const String _kAppKey = '163e7ce78d58971a41f5b969996d85c2';

final Random _rng = Random.secure();

String _randHex(int n) {
  const cs = '0123456789abcdef';
  final buf = StringBuffer();
  for (var i = 0; i < n; i++) {
    buf.write(cs[_rng.nextInt(16)]);
  }
  return buf.toString();
}

String _uuid4() {
  final b = List<int>.generate(16, (_) => _rng.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  String h(int x) => x.toRadixString(16).padLeft(2, '0');
  final s = b.map(h).join();
  return s.substring(0, 8) +
      '-' +
      s.substring(8, 12) +
      '-' +
      s.substring(12, 16) +
      '-' +
      s.substring(16, 20) +
      '-' +
      s.substring(20);
}

/// 网页 SDK 的时间戳：当天 UTC 12:00 的秒级时间戳（与抓包一致）
String _sdkTs() {
  final now = DateTime.now().toUtc();
  final noon = DateTime.utc(now.year, now.month, now.day, 12);
  return (noon.millisecondsSinceEpoch ~/ 1000).toString();
}

String _xor5(String input) {
  final buf = StringBuffer();
  for (final b in utf8.encode(input)) {
    buf.write((b ^ 5).toRadixString(16));
  }
  return buf.toString();
}

Uint8List _hexToBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// passport 接口的 sign / qs 参数
({String sign, String qs}) _passportSign(
  Map<String, String> query, [
  Map<String, String>? body,
]) {
  const exclude = {'sign', 'qs', 'msToken', 'a_bogus'};
  final signable = <String, String>{};
  query.forEach((k, v) {
    if (!exclude.contains(k)) {
      signable[k] = v;
    }
  });
  final keys = signable.keys.toList()..sort();
  final top = keys.take(10).toList();
  final qstr = top.map((k) => k + '=' + signable[k]!).join('&');
  final bstr = (body == null || body.isEmpty)
      ? ''
      : (body.keys.toList()..sort()).map((k) => k + '=' + body[k]!).join('&');
  final plain = qstr + '&' + bstr + '&app_key=' + _kAppKey;
  return (
    sign: sha256.convert(utf8.encode(plain)).toString(),
    qs: _xor5(top.join(',')),
  );
}

/// x-tt-passport-aid-sign 请求头
String _aidSign(String path, String ts) {
  final prk =
      Hmac(sha256, utf8.encode(_kAppKey)).convert(utf8.encode(ts)).toString();
  final okm = Hmac(sha256, _hexToBytes(prk)).convert(const [0x01]).bytes;
  return Hmac(sha256, okm)
      .convert(utf8.encode('aid=6383&path=' + path + '&ts=' + ts))
      .toString();
}

/// account_sdk_source_info：网页环境指纹（XOR5 混淆的 JSON）
String _sdkSourceInfo() {
  final now = DateTime.now().millisecondsSinceEpoch.toDouble();
  final json = '{"hardwareConcurrency":20,"webdriver":false,"chromedriver":false,'
      '"shelldriver":false,"plugins":5,"innerHeight":1215,"innerWidth":2560,'
      '"outerHeight":1392,"outerWidth":2560,'
      '"webgl":{"vendor":"Google Inc. (NVIDIA)","renderer":"ANGLE (NVIDIA, '
      'NVIDIA GeForce RTX 5060 Ti (0x00002D04) Direct3D11 vs_5_0 ps_5_0, D3D11)"},'
      '"automation":{"s":"00000000","c":"0000","p":"0000000","s1":"00000000",'
      '"c1":"0000","p1":"0"},'
      '"performance":{"timeOrigin":' +
      (now + 120.2).toString() +
      ',"usedJSHeapSize":472537551,'
          '"navigationTiming":{"decodedBodySize":968454,"entryType":"navigation",'
          '"initiatorType":"navigation","name":"https://www.douyin.com/?recommend=1",'
          '"renderBlockingStatus":"non-blocking",'
          '"serverTiming":"cdn-cache,edge,origin,inner,tt_agw",'
          '"guleStart":610.8999999761581,"guleDuration":"none"}},'
          '"browser":{"t":"4558992841922","bit_protocol":"false","bit_helper":false}}';
  return _xor5(json);
}

String _encodeQuery(Map<String, String> p) =>
    p.entries.map((e) => e.key + '=' + Uri.encodeQueryComponent(e.value)).join('&');

class _Jar {
  final Map<String, String> cookies = <String, String>{};

  void absorb(List<String> lines) {
    for (final line in lines) {
      final first = line.split(';').first.trim();
      final idx = first.indexOf('=');
      if (idx <= 0) {
        continue;
      }
      final name = first.substring(0, idx).trim();
      final value = first.substring(idx + 1).trim();
      if (name.isEmpty || value.isEmpty) {
        continue;
      }
      cookies[name] = value;
    }
  }

  static const List<String> wwwOnly = [
    's_v_web_id',
    '__ac_nonce',
    '__ac_signature',
    'x-web-secsdk-uid',
    'dy_swidth',
    'dy_sheight',
    'device_web_cpu_core',
    'device_web_memory_size',
    'architecture',
    'fpk1',
    'fpk2',
  ];

  static const List<String> loginOrder = [
    'enter_pc_once',
    'UIFID_TEMP',
    'odin_tt',
    'is_support_rtm_web_ts',
    'hevc_supported',
    'IsDouyinActive',
    'home_can_add_dy_2_desktop',
    'stream_recommend_feed_params',
    'strategyABtestKey',
    'ttwid',
    'passport_csrf_token',
    'passport_csrf_token_default',
    'biz_trace_id',
    'is_dash_user',
    'csrf_session_id',
    'bd_ticket_guard_client_data',
    'bd_ticket_guard_client_web_domain',
    'bd_ticket_guard_client_data_v2',
    'bd_ticket_guard_regenerate_keys_time',
    '__security_mc_1_s_sdk_crypt_sdk',
    'sdk_source_info',
    'bit_env',
    'gulu_source_res',
    'passport_auth_mix_state',
  ];

  String header({required bool loginDomain}) {
    if (!loginDomain) {
      return cookies.entries.map((e) => e.key + '=' + e.value).join('; ');
    }
    final out = <String, String>{};
    for (final name in loginOrder) {
      final v = cookies[name];
      if (v != null && v.isNotEmpty) {
        out[name] = v;
      }
    }
    cookies.forEach((k, v) {
      if (out.containsKey(k) || v.isEmpty) {
        return;
      }
      if (wwwOnly.contains(k) || k == 'my_rd') {
        return;
      }
      out[k] = v;
    });
    return out.entries.map((e) => e.key + '=' + e.value).join('; ');
  }
}

enum DouyinQrState {
  /// 等待扫码
  waiting,

  /// 已扫码，等待确认
  scanned,

  /// 已确认，可以换取登录态
  confirmed,

  /// 二维码过期
  expired,

  /// 轮询太频繁，可稍后重试
  rateLimited,

  /// 出错（风控 / 网络 / 解析失败）
  failed,
}

class DouyinQrCode {
  const DouyinQrCode({
    required this.token,
    required this.imageBytes,
    required this.expireTime,
  });

  /// 轮询用 token
  final String token;

  /// 二维码 PNG 字节
  final Uint8List imageBytes;

  /// 过期时间（秒级时间戳，可能为 0）
  final int expireTime;
}

class DouyinQrCheck {
  const DouyinQrCheck({
    required this.state,
    required this.cookieString,
    this.redirectUrl = '',
    this.message = '',
    this.httpStatus = 0,
    this.rawBody = '',
    this.errorCode = 0,
  });

  final DouyinQrState state;

  /// 当前 cookie（已合并本次响应的 Set-Cookie）
  final String cookieString;

  /// confirmed 时用于换取登录态的跳转地址
  final String redirectUrl;

  final String message;
  final int httpStatus;

  /// 服务端原始响应（排查风控时用）
  final String rawBody;

  /// passport error_code（0 正常；4031 风控；7 轮询限频）
  final int errorCode;

  bool get isConfirmed => state == DouyinQrState.confirmed;
}

/// 发送短信验证码的结果
class DouyinSmsSendResult {
  const DouyinSmsSendResult({
    required this.errorCode,
    required this.message,
    this.httpStatus = 0,
    this.rawBody = '',
  });

  final int errorCode;
  final String message;
  final int httpStatus;
  final String rawBody;

  bool get ok => errorCode == 0;
}

/// 手机号 + 验证码登录的结果
class DouyinSmsLoginResult {
  const DouyinSmsLoginResult({
    required this.errorCode,
    required this.message,
    required this.cookieString,
    this.httpStatus = 0,
    this.rawBody = '',
    this.needVerify = false,
  });

  final int errorCode;
  final String message;

  /// 登录成功后的完整 Cookie（login 域作用域，可直接存给 AccountService）
  final String cookieString;
  final int httpStatus;
  final String rawBody;

  /// 服务端要求额外身份验证（MFA / 二次验证），此时验证码已经通过但还没有 sessionid
  final bool needVerify;

  bool get ok => errorCode == 0 && cookieString.contains('sessionid');
}

class DouyinQrLogin {
  DouyinQrLogin({this.userAgent = kDouyinQrUserAgent});

  final String userAgent;

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20);
  final _Jar _jar = _Jar();
  final String _traceId = _randHex(8);
  late final String _portrait = _uuid4() + '.login';

  bool _bootstrapped = false;

  /// 当前 cookie 字符串（login 域作用域，可直接存给 AccountService）
  String get cookieString => _jar.header(loginDomain: true);

  /// 游客 ttwid（部分只读接口需要）
  String get ttwid => _jar.cookies['ttwid'] ?? '';

  Future<({int status, String body})> _request(
    String method,
    String url, {
    required Map<String, String> headers,
    String? body,
    bool followRedirects = false,
  }) async {
    final req = await _client.openUrl(method, Uri.parse(url));
    req.followRedirects = followRedirects;
    headers.forEach((k, v) => req.headers.set(k, v, preserveHeaderCase: true));
    if (body != null) {
      final bytes = utf8.encode(body);
      req.contentLength = bytes.length;
      req.add(bytes);
    }
    final resp = await req.close();
    final text = await utf8.decoder.bind(resp).join();
    _jar.absorb(resp.headers['set-cookie'] ?? const <String>[]);
    return (status: resp.statusCode, body: text);
  }

  Map<String, String> _loginHeaders(String apiPath, {bool form = false}) {
    return <String, String>{
      'web-sdk-version': '1',
      'sec-ch-ua-platform': '"Windows"',
      'referer': _kHome + '/',
      'sec-ch-ua':
          '"Google Chrome";v="155", "Chromium";v="155", "Not(A:Brand";v="24"',
      'x-tt-passport-aid-sign': _aidSign(apiPath, _sdkTs()),
      'sec-ch-ua-mobile': '?0',
      'x-tt-passport-csrf-token': _jar.cookies['passport_csrf_token'] ?? '',
      'x-tt-passport-trace-id': _traceId,
      'user-agent': userAgent,
      'accept': 'application/json, text/javascript',
      if (form) 'content-type': 'application/x-www-form-urlencoded',
      'cookie': _jar.header(loginDomain: true),
      'x-tt-passport-verify-portrait': _portrait,
      'accept-language': 'zh-CN,zh;q=0.9',
      'origin': _kHome,
      'priority': 'u=1, i',
      'sec-fetch-dest': 'empty',
      'sec-fetch-mode': 'cors',
      'sec-fetch-site': 'same-site',
    };
  }

  Map<String, String> _params({
    Map<String, String> extra = const {},
    Map<String, String>? body,
    bool withFp = false,
  }) {
    final p = <String, String>{
      'passport_jssdk_version': '3.4.9',
      'passport_jssdk_type': 'normal',
      'is_from_ttaccountsdk': '1',
      'aid': '6383',
      'language': 'zh',
      'account_app_language': 'zh-CN',
      'ts': _sdkTs(),
      'account_sdk_source': 'web',
      'account_sdk_source_info': _sdkSourceInfo(),
      'p_js_v': '3.4.9',
      'p_js_t': 'pro',
      'p_zt': '3.3.30',
      'p_ver': '1.1.4-beta.5',
      'p_ver_real': '0',
      'request_host': Uri.encodeComponent(_kHome),
      'p_bd': '1.0.1.19-fix.01',
      'p_ts': DateTime.now().millisecondsSinceEpoch.toString(),
      'p_no': _randHex(32),
      'biz_trace_id': _traceId,
      'device_platform': 'web_app',
    };
    p.addAll(extra);
    if (withFp) {
      p['p_ca'] = '4.0.26';
      p['p_ca_real'] = '1.0.0.938';
      p['fp'] = _jar.cookies['s_v_web_id'] ?? '';
      p['verifyFp'] = _jar.cookies['s_v_web_id'] ?? '';
    }
    p['p_ui'] = '2.4.10';
    final sig = _passportSign(p, body);
    p['sign'] = sig.sign;
    p['qs'] = sig.qs;
    return p;
  }

  /// 首次进入登录页前的引导：写入游客 cookie（ttwid 等）
  Future<void> bootstrap() async {
    if (_bootstrapped) {
      return;
    }
    await _request('GET', _kHome + '/?recommend=1', headers: {
      'user-agent': userAgent,
      'accept':
          'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      'accept-language': 'zh-CN,zh;q=0.9',
      'sec-fetch-dest': 'document',
      'sec-fetch-mode': 'navigate',
      'sec-fetch-site': 'none',
    });

    _jar.cookies['s_v_web_id'] = 'verify_' +
        _randHex(8) +
        '_' +
        _randHex(6) +
        '_' +
        _randHex(4) +
        '_' +
        _randHex(4) +
        '_' +
        _randHex(24);
    _jar.cookies['enter_pc_once'] = '1';
    _jar.cookies['is_support_rtm_web_ts'] = '1';
    _jar.cookies['hevc_supported'] = 'true';
    _jar.cookies['IsDouyinActive'] = 'true';
    _jar.cookies['home_can_add_dy_2_desktop'] = '%220%22';
    _jar.cookies['is_dash_user'] = '1';
    _jar.cookies['strategyABtestKey'] =
        '%22' + DateTime.now().millisecondsSinceEpoch.toString() + '.473%22';
    _jar.cookies['stream_recommend_feed_params'] =
        Uri.encodeComponent('{"cookie_enabled":true,"screen_width":2560,'
            '"screen_height":1440,"browser_online":true,"cpu_core_num":20,'
            '"device_memory":32,"downlink":10,"effective_type":"4g",'
            '"round_trip_time":0}');
    _jar.cookies['biz_trace_id'] = _traceId;

    await _request('POST', _kHome + '/ttwid/check/', headers: {
      'referer': _kHome + '/jingxuan',
      'user-agent': userAgent,
      'accept': 'application/json, text/plain, */*',
      'x-secsdk-csrf-token': 'DOWNGRADE',
      'content-type': 'application/json',
      'accept-language': 'zh-CN,zh;q=0.9',
      'origin': _kHome,
      'sec-fetch-dest': 'empty',
      'sec-fetch-mode': 'cors',
      'sec-fetch-site': 'same-origin',
      'cookie': _jar.header(loginDomain: false),
    }, body: '{"aid":6383,"service":"www.douyin.com"}');

    await _request('POST', _kLogin + '/ttwid/check/', headers: {
      'referer': _kHome + '/',
      'user-agent': userAgent,
      'accept': 'application/json, text/plain, */*',
      'content-type': 'application/json',
      'accept-language': 'zh-CN,zh;q=0.9',
      'origin': _kHome,
      'sec-fetch-dest': 'empty',
      'sec-fetch-mode': 'cors',
      'sec-fetch-site': 'same-site',
      'cookie': _jar.header(loginDomain: true),
    }, body: '{"aid":6383,"service":"www.douyin.com"}');

    if ((_jar.cookies['ttwid'] ?? '').isEmpty) {
      await _registerTtwid();
    }

    await _request(
      'GET',
      _kHome + '/passport/general/login_guiding_strategy/?' + _encodeQuery(_params()),
      headers: _loginHeaders('/passport/general/login_guiding_strategy/'),
    );

    _bootstrapped = true;
  }

  /// 首页是 acrawler 挑战页，拿不到 ttwid 时走 ttwid 注册接口换一个匿名设备标识
  Future<void> _registerTtwid() async {
    try {
      await _request('POST', 'https://ttwid.bytedance.com/ttwid/union/register/',
          headers: {
            'content-type': 'application/json',
            'user-agent': userAgent,
          },
          body: '{"region":"cn","aid":1768,"needFid":false,'
              '"service":"www.douyin.com","migrate_info":{"ticket":"","source":"node"},'
              '"cbUrlProtocol":"https","union":true}');
    } catch (_) {
      // 换不到就继续，不影响扫码主流程
    }
  }

  /// 取一张新的登录二维码
  Future<DouyinQrCode> fetchQrCode() async {
    await bootstrap();
    final p = _params(withFp: true, extra: {
      'next': _kHome,
      'need_short_url': 'true',
      'need_logo': 'false',
      'is_new_login': '1',
      'is_from_iesaccountsaas': '1',
    });
    final r = await _request(
      'GET',
      _kLogin + '/passport/web/get_qrcode/?' + _encodeQuery(p),
      headers: _loginHeaders('/passport/web/get_qrcode/'),
    );
    final map = _decode(r.body);
    final data = (map['data'] as Map?)?.cast<String, dynamic>() ?? {};
    final token = (data['token'] as String?) ?? '';
    final qr = (data['qrcode'] as String?) ?? '';
    final expire = (data['expire_time'] as num?)?.toInt() ?? 0;
    final code = (data['error_code'] as num?)?.toInt() ?? 0;
    if (token.isEmpty || qr.isEmpty) {
      throw Exception('抖音二维码获取失败（HTTP ' +
          r.status.toString() +
          '，code=' +
          code.toString() +
          ' ' +
          ((data['description'] as String?) ?? '') +
          '）');
    }
    return DouyinQrCode(
      token: token,
      imageBytes: base64Decode(qr),
      expireTime: expire,
    );
  }

  /// 轮询扫码状态
  Future<DouyinQrCheck> checkQrCode(String token) async {
    await bootstrap();
    final form = <String, String>{
      'need_logo': 'false',
      'is_frontier': 'true',
      'token': token,
      'is_new_login': '1',
      'next': _kHome,
      'need_short_url': 'true',
    };
    final p = _params(withFp: true, body: form, extra: {
      'next': _kHome,
      'need_short_url': 'true',
      'need_logo': 'false',
      'is_new_login': '1',
      'is_from_iesaccountsaas': '1',
    });
    final bodyStr = _encodeQuery(form);
    final ab = generateABogus(
      query: _encodeQuery(p),
      body: bodyStr,
      ua: userAgent,
      host: 'login.douyin.com',
    );
    final query = _encodeQuery(p) + '&a_bogus=' + Uri.encodeComponent(ab);
    final r = await _request(
      'POST',
      _kLogin + '/passport/web/check_qrconnect/?' + query,
      headers: _loginHeaders('/passport/web/check_qrconnect/', form: true),
      body: bodyStr,
    );
    final map = _decode(r.body);
    final data = (map['data'] as Map?)?.cast<String, dynamic>() ?? {};
    final code = (data['error_code'] as num?)?.toInt() ?? 0;
    final status = (data['status'] as String?) ?? '';
    final desc = (data['description'] as String?) ?? (map['message'] as String? ?? '');
    final redirect =
        (data['redirect_url'] as String?) ?? (map['redirect_url'] as String?) ?? '';

    var state = DouyinQrState.waiting;
    if (code == 4031) {
      state = DouyinQrState.failed;
    } else if (code == 7) {
      state = DouyinQrState.rateLimited;
    } else if (status == 'confirmed') {
      state = DouyinQrState.confirmed;
    } else if (status == 'scanned') {
      state = DouyinQrState.scanned;
    } else if (status == 'expired') {
      state = DouyinQrState.expired;
    } else if (status.isEmpty && code != 0) {
      state = DouyinQrState.failed;
    }

    return DouyinQrCheck(
      state: state,
      cookieString: cookieString,
      redirectUrl: redirect,
      message: desc,
      httpStatus: r.status,
      rawBody: r.body,
      errorCode: code,
    );
  }

  /// 扫码确认后跟随跳转，把各跳 Set-Cookie（sessionid 等）都收进来
  Future<void> finishLogin(String redirectUrl) async {
    var url = redirectUrl;
    if (url.isEmpty) {
      return;
    }
    for (var i = 0; i < 5; i++) {
      final req = await _client.openUrl('GET', Uri.parse(url));
      req.followRedirects = false;
      req.headers.set('user-agent', userAgent, preserveHeaderCase: true);
      req.headers.set('accept',
          'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          preserveHeaderCase: true);
      req.headers.set('accept-language', 'zh-CN,zh;q=0.9',
          preserveHeaderCase: true);
      req.headers.set('cookie', _jar.header(loginDomain: true),
          preserveHeaderCase: true);
      final resp = await req.close();
      await resp.drain<void>();
      _jar.absorb(resp.headers['set-cookie'] ?? const <String>[]);
      final location = resp.headers.value('location');
      final code = resp.statusCode;
      if (code < 300 || code >= 400 || location == null || location.isEmpty) {
        break;
      }
      url = Uri.parse(url).resolve(location).toString();
    }
    // msToken 有时效，登录后按网页行为丢弃，避免过期值被后续请求带上
    _jar.cookies.remove('msToken');
  }

  /// 发送短信验证码（手机号 + 验证码登录，第一段）
  ///
  /// passport 对表单字段做「UTF-8 每字节 XOR 5 后拼小写 hex」的加密，
  /// 手机号与验证码都要这么处理；type=3731 是浏览器发出的加密值（明文 24）。
  Future<DouyinSmsSendResult> sendSmsCode(String phone) async {
    await bootstrap();
    final form = <String, String>{
      'is6Digits': '1',
      'mix_mode': '1',
      'mobile': _xor5(phone.trim()),
      'type': '3731',
      'fixed_mix_mode': '1',
    };
    final result = await _passportForm(
      apiPath: '/passport/web/send_code/',
      form: form,
    );
    final data = result.data;
    final desc = (data['description'] as String?) ??
        (data['message'] as String?) ??
        (result.map['message'] as String?) ??
        '';
    return DouyinSmsSendResult(
      errorCode: _errorCodeOf(data, result.body),
      message: desc,
      httpStatus: result.status,
      rawBody: result.body,
    );
  }

  /// 提交手机号 + 验证码登录（第二段）
  ///
  /// 必须复用同一个实例（同一条 cookie 会话）：验证码与发码请求绑在一起。
  Future<DouyinSmsLoginResult> smsLogin({
    required String phone,
    required String code,
  }) async {
    await bootstrap();
    final form = <String, String>{
      'service': _kHome,
      'mix_mode': '1',
      'mobile': _xor5(phone.trim()),
      'code': _xor5(code.trim()),
      'fixed_mix_mode': '1',
    };
    final result = await _passportForm(
      apiPath: '/passport/web/sms_login/',
      form: form,
      followRedirectOnSuccess: true,
    );
    final data = result.data;
    final desc = (data['description'] as String?) ??
        (data['message'] as String?) ??
        (result.map['message'] as String?) ??
        '';
    final bizParams = (data['biz_params'] as Map?)?.cast<String, dynamic>();
    // account_flow=verify 或 std_verify_type=MFA：验证码已通过，但账号要额外验证
    final needVerify = data['account_flow'] == 'verify' ||
        bizParams?['std_verify_type'] == 'MFA';
    return DouyinSmsLoginResult(
      errorCode: _errorCodeOf(data, result.body),
      message: desc,
      cookieString: cookieString,
      httpStatus: result.status,
      rawBody: result.body,
      needVerify: needVerify,
    );
  }

  /// 带签名的 passport 表单提交（send_code / sms_login 共用）
  Future<({
    Map<String, dynamic> map,
    Map<String, dynamic> data,
    int status,
    String body,
  })> _passportForm({
    required String apiPath,
    required Map<String, String> form,
    bool followRedirectOnSuccess = false,
  }) async {
    final p = _params(withFp: true, body: form, extra: {
      'next': _kHome,
      'need_short_url': 'true',
      'need_logo': 'false',
      'is_new_login': '1',
      'is_from_iesaccountsaas': '1',
    });
    final bodyStr = _encodeQuery(form);
    final ab = generateABogus(
      query: _encodeQuery(p),
      body: bodyStr,
      ua: userAgent,
      host: 'login.douyin.com',
    );
    final query = _encodeQuery(p) + '&a_bogus=' + Uri.encodeComponent(ab);
    final r = await _request(
      'POST',
      _kLogin + apiPath + '?' + query,
      headers: _loginHeaders(apiPath, form: true),
      body: bodyStr,
    );
    final map = _decode(r.body);
    final data = (map['data'] as Map?)?.cast<String, dynamic>() ?? {};
    // 排查风控用：只保留前 600 字符
    final short = r.body.length > 600 ? r.body.substring(0, 600) : r.body;
    CoreLog.d('抖音passport ' + apiPath + '：http=' +
        r.status.toString() + ' body=' + short);
    if (followRedirectOnSuccess && _errorCodeOf(data, r.body) == 0) {
      final redirect = (data['redirect_url'] as String?) ??
          (map['redirect_url'] as String?) ??
          '';
      if (redirect.isNotEmpty) {
        // 跟随跳转，把 sessionid 等 Set-Cookie 都收进来
        await finishLogin(redirect);
      } else {
        _jar.cookies.remove('msToken');
      }
    }
    return (map: map, data: data, status: r.status, body: r.body);
  }

  int _errorCodeOf(Map<String, dynamic> data, String body) {
    final fromData = (data['error_code'] as num?)?.toInt();
    if (fromData != null) {
      return fromData;
    }
    return (_decode(body)['error_code'] as num?)?.toInt() ?? 0;
  }
  Map<String, dynamic> _decode(String body) {
    try {
      final v = jsonDecode(body);
      if (v is Map<String, dynamic>) {
        return v;
      }
      if (v is Map) {
        return v.cast<String, dynamic>();
      }
    } catch (_) {
      // ignore
    }
    return <String, dynamic>{};
  }

  void dispose() {
    _client.close(force: true);
  }
}
