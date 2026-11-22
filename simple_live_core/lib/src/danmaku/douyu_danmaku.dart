import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/http_client.dart' as core_http;
import 'package:simple_live_core/src/common/web_socket_util.dart';

import '../common/binary_writer.dart';
import 'douyu_emoticon.dart';

class DouyuDanmakuArgs {
  /// 房间号
  final String roomId;

  /// 登录后的 uid（发言必需；未登录为空）
  final String uid;

  /// 设备 id（斗鱼弹幕登录要求带上）
  final String devid;

  /// 昵称（自己发的弹幕本地补一条时显示用）
  final String nickname;

  /// 头像（发弹幕要带 ic 字段）
  final String avatar;

  /// 聊天用户名（cookie 的 acf_username，形如 qq_xxxxxx）
  /// 网页版 loginreq 会带上它，缺了可能被当成未认证会话
  final String username;

  /// 发弹幕令牌：cookie 的 acf_dmjwt_token（只有约 7 天有效期）
  final String jwt;

  /// cookie 的 acf_ltkid
  final String ltkid;

  /// cookie 的 acf_biz（通常为 1）
  final String biz;

  /// cookie 的 acf_stk
  final String stk;

  /// 完整 cookie：发送连接握手时带上，让斗鱼认为是同一个浏览器会话
  /// （否则会触发「账号在另一地点登录」，把用户的浏览器/客户端踢下线）
  final String cookie;
  DouyuDanmakuArgs({
    required this.roomId,
    this.uid = "",
    this.devid = "",
    this.nickname = "",
    this.avatar = "",
    this.username = "",
    this.jwt = "",
    this.ltkid = "",
    this.biz = "",
    this.stk = "",
    this.cookie = "",
  });

  /// 是否具备发弹幕条件（抓包实证：uid + devid + jwt + ltkid + stk 缺一不可）
  bool get canSend =>
      uid.isNotEmpty &&
      devid.isNotEmpty &&
      jwt.isNotEmpty &&
      ltkid.isNotEmpty &&
      stk.isNotEmpty;

  /// 发弹幕缺失的凭证字段（用于提示和日志诊断）
  List<String> get missingSendFields => [
        if (uid.isEmpty) "acf_uid",
        if (devid.isEmpty) "acf_did/dy_did",
        if (jwt.isEmpty) "acf_dmjwt_token",
        if (ltkid.isEmpty) "acf_ltkid",
        if (stk.isEmpty) "acf_stk",
      ];

  /// 诊断用：只打印各字段长度，不泄露内容
  String get sendReadyDesc =>
      "uid=${uid.length} devid=${devid.length} jwt=${jwt.length} "
      "ltkid=${ltkid.length} stk=${stk.length} biz=${biz.length}";

  /// dmjwt 是否已过期（解析 JWT payload 的 exp；解析失败按未过期处理）
  bool get jwtExpired {
    if (jwt.isEmpty) return false;
    try {
      var parts = jwt.split('.');
      if (parts.length < 2) return false;
      var payload = parts[1].replaceAll('-', '+').replaceAll('_', '/');
      while (payload.length % 4 != 0) {
        payload += '=';
      }
      var payloadJson = json.decode(utf8.decode(base64.decode(payload)));
      var exp = payloadJson['exp'];
      if (exp is! num) return false;
      return DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000)
          .isBefore(DateTime.now());
    } catch (_) {
      return false;
    }
  }
  /// 用新 cookie 重建发送凭证（dmjwt 刷新后调用）
  ///
  /// 只更新与发送相关的字段：房间号保持不变，
  /// devid 在 cookie 里没有时沿用旧值（本地生成过的设备号）。
  DouyuDanmakuArgs refreshedCookie(String cookie) {
    var map = <String, String>{};
    for (var part in cookie.split(";")) {
      var index = part.indexOf("=");
      if (index <= 0) {
        continue;
      }
      map[part.substring(0, index).trim()] = part.substring(index + 1).trim();
    }
    String value(String key) {
      var raw = map[key] ?? "";
      try {
        return Uri.decodeComponent(raw);
      } catch (_) {
        return raw;
      }
    }

    var did = map["acf_did"] ?? map["dy_did"] ?? "";
    var nick = value("acf_nickname");
    var face = value("acf_avatar");
    return DouyuDanmakuArgs(
      roomId: roomId,
      uid: map["acf_uid"] ?? uid,
      devid: did.isNotEmpty ? did : devid,
      nickname: nick.isNotEmpty ? nick : nickname,
      avatar: face.isNotEmpty ? face : avatar,
      username: map["acf_username"] ?? username,
      jwt: value("acf_dmjwt_token"),
      ltkid: value("acf_ltkid"),
      biz: map["acf_biz"] ?? biz,
      stk: value("acf_stk"),
      cookie: cookie,
    );
  }

  @override
  String toString() {
    return json.encode({
      "roomId": roomId,
      "uid": uid,
      "devid": devid,
    });
  }
}

typedef DouyuSenderSocketFactory = WebScoketUtils Function({
  required String url, required int heartBeatTime,
  required Map<String, dynamic> headers,
  required void Function(dynamic) onMessage,
  required void Function() onReady, required void Function() onHeartBeat,
  required void Function() onReconnect, required void Function(String) onClose,
});

class DouyuDanmaku implements LiveDanmaku, LiveDanmakuSenderControl {
  DouyuDanmaku({DouyuSenderSocketFactory? senderSocketFactory,
    this.senderPreheatDelay = const Duration(milliseconds: 1500)})
      : _senderSocketFactory = senderSocketFactory ?? WebScoketUtils.new;
  final DouyuSenderSocketFactory _senderSocketFactory;
  final Duration senderPreheatDelay;
  bool _senderActive = true;
  int _senderGeneration = 0;
  bool get senderActive => _senderActive;
  bool _ownsSender(int generation) => !_stopped && _senderActive && generation == _senderGeneration;
  @override
  Future<void> setSenderActive(bool active) async {
    if (_senderActive == active) return;
    _senderActive = active;
    _invalidateSender();
    if (active && !_stopped) unawaited(_preheatSender());
  }
  void _invalidateSender() {
    _senderGeneration++;
    final socket = _senderSocket;
    _senderSocket = null;
    _senderReady = false;
    socket?.close();
    final login = _senderLoginCompleter;
    _senderLoginCompleter = null;
    if (login != null && !login.isCompleted) login.complete();
    final chat = _chatresCompleter;
    _chatresCompleter = null;
    if (chat != null && !chat.isCompleted) chat.complete('发送房间已切换或关闭');
    _senderFuture = null;
    _broadcastCompleter = null;
    _pendingBroadcastText = null;
    _hbKey = null;
    _hbNonce = null;
    _hbRand = null;
    _hbIts = 0;
  }

  @override
  int heartbeatTime = 45 * 1000;

  @override
  Function(LiveMessage msg)? onMessage;
  @override
  Function(String msg)? onClose;
  @override
  Function()? onReady;
  String serverUrl = "wss://danmuproxy.douyu.com:8506";

  WebScoketUtils? webScoketUtils;
  // 注意：页面可能在 start() 之前就读 canSendDanmaku，所以不能是 late
  DouyuDanmakuArgs danmakuArgs = DouyuDanmakuArgs(roomId: "");
  Completer<void>? _loginCompleter;

  /// 当前房间的表情表（表情名 -> 图片地址），用于把 [表情名] 渲染成图片
  Map<String, String> _emoticons = const {};

  @override
  Future start(dynamic args) async {
    // 重新 start（换房 / 刷新 / 重连）要复位，否则预热会被 stop() 的标记挡住
    _stopped = false;
    _invalidateSender();
    danmakuArgs = args is DouyuDanmakuArgs
        ? args
        : DouyuDanmakuArgs(roomId: args.toString());
    CoreLog.i("斗鱼弹幕：发送能力 canSend=${danmakuArgs.canSend} "
        "${danmakuArgs.sendReadyDesc} 缺字段=${danmakuArgs.missingSendFields}");
    // 表情表是异步拉的，不能阻塞弹幕连接；拉到之前弹幕先按纯文本显示
    unawaited(_loadEmoticons(danmakuArgs.roomId));
    // 进房就把发送连接预热好：等你点发送时不用再建连+登录（那一段容易卡 4 秒）
    if (_senderActive) unawaited(_preheatSender());
    // 重连/刷新时会再次调用 start()：必须先关闭旧连接，
    // 否则旧 socket 仍在接收消息 → 聊天列表和滚动弹幕都会重复出现
    webScoketUtils?.close();
    webScoketUtils = WebScoketUtils(
      url: serverUrl,
      heartBeatTime: heartbeatTime,
      onMessage: (e) {
        decodeMessage(e);
      },
      onReady: () {
        onReady?.call();
        joinRoom(danmakuArgs);
      },
      onHeartBeat: () {
        heartbeat();
      },
      onReconnect: () {
        onClose?.call("与服务器断开连接，正在尝试重连");
      },
      onClose: (e) {
        onClose?.call("服务器连接失败$e");
      },
    );
    webScoketUtils?.connect();
  }

  /// 拉取房间表情表（钻粉专属表情 / 房间表情）
  ///
  /// 斗鱼弹幕正文里的 [表情名] 需要靠这张表换成图片；拉取失败就退化成纯文本。
  Future<void> _loadEmoticons(String roomId) async {
    if (roomId.isEmpty) {
      return;
    }
    try {
      final items = await DouyuEmoticon.load(roomId, cookie: danmakuArgs.cookie);
      if (items.isNotEmpty) {
        _emoticons = items;
      }
    } catch (e) {
      CoreLog.error(e);
    }
  }

  /// 登录弹幕服务器并加入房间
  ///
  /// 斗鱼靠 uid + devid 识别身份（实测：带上 uid 后 loginres 会返回该 userid，
  /// 不需要额外 token），这样才有权限发言。
  Future<void> joinRoom(DouyuDanmakuArgs args) async {
    // 必须先建好 completer 再发 loginreq。
    // 之前漏了这行：下面的 await 直接对 null 做 ! → NPE，
    // joinRoom 在 joingroup 之前就中断，表现为「服务器连上了但一条弹幕都收不到」
    var login = _loginCompleter = Completer<void>();
    // 按网页版抓包的真实格式（username + uid + ver/aver/ct）
    webScoketUtils?.sendMessage(serializeDouyu(
      "type@=loginreq/roomid@=${args.roomId}"
      "/username@=${args.username}/uid@=${args.uid}"
      "/devid@=${args.devid}/ver@=20220825/aver@=218101901/ct@=0/",
    ));
    // 公开协议的常见做法：等 loginres 回来再 joingroup
    try {
      await login.future.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      CoreLog.error("斗鱼弹幕：未收到 loginres，仍继续分组");
    }
    if (identical(_loginCompleter, login)) {
      _loginCompleter = null;
    }
    webScoketUtils?.sendMessage(serializeDouyu(
        "type@=joingroup/rid@=${args.roomId}/gid@=-9999/"));
  }

  @override
  void heartbeat() {
    var data = serializeDouyu("type@=mrkl/");
    webScoketUtils?.sendMessage(data);
  }

  // ============================================================ 发送弹幕
  // 2026-10 抓包实证：
  //   接收：wss://danmuproxy.douyu.com:8506  包类型 690，type@=chatmsg（广播）
  //   发送：wss://wsproxy.douyu.com:6674     包类型 689，type@=chatmessage
  //   回执：同一条 wsproxy 连接返回 type@=chatres/res@=0
  // 三个关键点（都实测验证过）：
  //   1. 发送必须用「独立连接」——往接收连接发 chatmsg 会被服务端静默丢弃
  //   2. 发送连接登录要带 jwt（cookie acf_dmjwt_token）+ ltkid/biz/stk + vk 签名
  //   3. 心跳必须带签名（getEncryption 取密钥 + nonce/its），否则会被踢下线
  /// 登录 cookie 刷新后更新发送凭证（接收连接不用重连）
  void updateCookie(String cookie) {
    if (cookie.isEmpty) {
      return;
    }
    danmakuArgs = danmakuArgs.refreshedCookie(cookie);
    // A refreshed credential invalidates only this room's sender generation.
    _invalidateSender();
    CoreLog.i("斗鱼弹幕：cookie 已刷新 ${danmakuArgs.sendReadyDesc}");
  }

  /// 是否显示输入框：斗鱼始终允许输入，
  /// 凭证不全时在 sendDanmaku 里给出「缺少哪些 cookie 字段」的明确提示，
  /// 比直接隐藏输入框更利于用户发现问题。
  @override
  bool get canSendDanmaku => true;

  /// 发送网关（独立连接，与接收连接互不影响）
  String senderUrl = "wss://wsproxy.douyu.com:6674/";
  WebScoketUtils? _senderSocket;
  bool _senderReady = false;
  Completer<void>? _senderLoginCompleter;
  Completer<String?>? _chatresCompleter;

  /// 第二判据：接收连接上收到「自己这条弹幕」的广播（多设备抢会话时
  /// chatres 经常丢失，但广播一定会到）
  Completer<void>? _broadcastCompleter;
  String? _pendingBroadcastText;
  DateTime? _lastSendAt;

  /// 登录 vk 签名的固定盐值（网页 JS 常量，不是账号密钥）
  static const String _vkSecret = r"r5*^5;}2#${XF[h+;'./.Q'1;,-]f'p[";

  /// 心跳签名密钥（getEncryption 下发，nonce/its 用一次即作废）
  String? _hbKey;
  String _hbKeyVer = "1.1";
  String? _hbRand;
  int _hbEncTime = 1;
  String? _hbNonce;
  int _hbIts = 0;

  int get _nowSec => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// 斗鱼 STT 转义：@ 和 / 是分隔符，必须先转义
  String scapeSlashAt(String str) {
    return str.replaceAll("@", "@A").replaceAll("/", "@S");
  }

  /// 是否已被 stop()（避免预热任务在关房后又把发送连接连起来）
  bool _stopped = false;

  /// 预热发送连接：进房后后台建连 + loginreq，让第一条弹幕不用现连现登录。
  ///
  /// * 延迟 1.5 秒再动手：刚进房时关注刷新会打出一波并发请求，先错峰；
  /// * 失败静默：wsproxy 偶发不回 loginres 是常态，不能因此弹提示，
  ///   真正发送时 [sendDanmaku] 还会按原有逻辑重试三次；
  /// * 用户不发弹幕的房间里，这就是一条空闲 WS（心跳 30 秒），可接受。
  Future<void> _preheatSender() async {
    final generation = _senderGeneration;
    await Future.delayed(senderPreheatDelay);
    if (!_ownsSender(generation) || !danmakuArgs.canSend || _senderReady) {
      return;
    }
    try {
      final error = await _ensureSender();
      if (error != null) {
        CoreLog.d("斗鱼发送：进房预热未成功（不影响观看，发送时会重试）→ $error");
      }
    } catch (e) {
      CoreLog.d("斗鱼发送：进房预热异常（忽略）$e");
    }
  }

  /// 正在进行的建连/登录任务：预热和真正发送可能同时触发，
  /// 必须串行复用同一个 Future，否则两条路径会互相覆盖 completer。
  Future<String?>? _senderFuture;

  /// 建立发送连接并登录：成功返回 null，失败返回错误文案
  ///
  /// 斗鱼的会话是「单点登录」：这套凭证在哪台设备上用，服务端就把弹幕会话
  /// 切到哪台（旧设备会被断开）。所以这里不弹任何「重新登录」提示，
  /// 每次发送都自动（重）登录，必要时重连一次再试，实现无缝接管。
  Future<String?> _ensureSender() {
    if (!_ownsSender(_senderGeneration)) return Future.value("发送房间已切换或关闭");
    final running = _senderFuture;
    if (running != null) {
      return running;
    }
    late final Future<String?> future;
    future = _ensureSenderInner(_senderGeneration).whenComplete(() {
      if (identical(_senderFuture, future)) _senderFuture = null;
    });
    _senderFuture = future;
    return future;
  }

  Future<String?> _ensureSenderInner(int generation) async {
    if (!_ownsSender(generation)) return "发送房间已切换或关闭";
    if (danmakuArgs.jwtExpired) {
      return "斗鱼登录已过期（dmjwt 失效），请重新登录斗鱼";
    }
    if (_senderReady && _senderSocket?.status == SocketStatus.connected) {
      return null;
    }
    // 最多尝试三次：上一次设备的会话可能还没释放，多抢一两次更容易成功
    String? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (!_ownsSender(generation)) return "发送房间已切换或关闭";
      lastError = await _tryLoginSender(generation);
      if (!_ownsSender(generation)) return "发送房间已切换或关闭";
      if (lastError == null) {
        return null;
      }
      CoreLog.i("斗鱼发送：第 ${attempt + 1} 次登录失败 → $lastError");
      // 换一条新连接再试（旧连接可能停在游客会话上）
      try {
        _senderSocket?.close();
      } catch (e) {
        CoreLog.error(e);
      }
      _senderSocket = null;
      _senderReady = false;
      // 给服务端一点时间释放旧会话，再抢下一次
      await Future.delayed(const Duration(milliseconds: 250));
    }
    return lastError;
  }

  /// 单次：建连 + loginreq + 等 loginres
  Future<String?> _tryLoginSender(int generation) async {
    if (!_ownsSender(generation)) return "发送房间已切换或关闭";
    // 旧连接若未就绪（被顶号后会残留一条半死连接），直接丢弃重建，
    // 否则会在上面白等到超时
    if (_senderSocket != null && !_senderReady) {
      try {
        _senderSocket?.close();
      } catch (e) {
        CoreLog.error(e);
      }
      _senderSocket = null;
    }
    if (_senderSocket == null) {
      late final WebScoketUtils socket;
      bool owns() => _ownsSender(generation) && identical(_senderSocket, socket);
      socket = _senderSocketFactory(
        url: senderUrl,
        heartBeatTime: 30 * 1000,
        headers: {
          "Origin": "https://www.douyu.com",
          "Referer": "https://www.douyu.com/${danmakuArgs.roomId}",
          "User-Agent": DouyuSite.kUserAgent,
          if (danmakuArgs.cookie.isNotEmpty) "Cookie": danmakuArgs.cookie,
        },
        onMessage: (e) { if (owns()) _decodeSenderMessage(e); },
        onReady: () { if (owns()) { _loginSender(); } else { socket.close(); } },
        onHeartBeat: () { if (owns()) _sendSenderHeartbeat(generation); },
        onReconnect: () { if (owns()) { _senderReady = false; } else { socket.close(); } },
        onClose: (e) { if (owns()) _senderReady = false; },
      );
      _senderSocket = socket;
      socket.maxReconnectTime = 0;
    }
    var login = _senderLoginCompleter = Completer<void>();
    _senderReady = false;
    _senderSocket?.connect();
    try {
      // 1.5 秒没回 loginres 就换节点重试（原来 4 秒，遇到坏节点要白等 4 秒）
      await login.future.timeout(const Duration(milliseconds: 1500));
    } on TimeoutException {
      return "斗鱼发送连接登录超时";
    } finally {
      if (identical(_senderLoginCompleter, login)) {
        _senderLoginCompleter = null;
      }
    }
    if (!_ownsSender(generation)) return "发送房间已切换或关闭";
    if (!_senderReady) {
      return "斗鱼登录态已失效（jwt 过期或被其它设备接管）";
    }
    return null;
  }

  /// 发送连接登录（loginreq + vk 防重放签名）
  void _loginSender() {
    if (!_ownsSender(_senderGeneration)) return;
    var args = danmakuArgs;
    var rt = _nowSec.toString();
    var vk = md5.convert(utf8.encode(rt + _vkSecret + args.devid)).toString();
    _senderSocket?.sendMessage(serializeDouyu(
      "type@=loginreq/roomid@=${args.roomId}/dfl@=/username@=${args.username}"
      "/password@=/ltkid@=${args.ltkid}/biz@=${args.biz}/stk@=${args.stk}"
      "/devid@=${args.devid}/ct@=0/pt@=2/cvr@=0/tvr@=7/apd@=/jwt@=${args.jwt}"
      "/rt@=$rt/vk@=$vk/ver@=20220825/aver@=218101901/dmbt@=chrome/dmbv@=155/",
    ));
  }

  /// 取心跳签名密钥（getEncryption）
  Future<void> _loadHeartbeatKey(int generation) async {
    try {
      var res = await core_http.HttpClient.instance.getJson(
        "https://www.douyu.com/wgapi/livenc/liveweb/websec/getEncryption",
        queryParameters: {"did": danmakuArgs.devid},
        header: {
          "referer": "https://www.douyu.com/${danmakuArgs.roomId}",
          "user-agent": DouyuSite.kUserAgent,
        },
      );
      if (!_ownsSender(generation)) return;
      var data = (res is Map && res["data"] is Map) ? res["data"] : res;
      if (data is! Map) {
        return;
      }
      _hbRand = data["rand_str"]?.toString();
      _hbEncTime = int.tryParse(data["enc_time"]?.toString() ?? "1") ?? 1;
      var heartbeat = data["cpp"] is Map ? data["cpp"]["heartbeat"] : null;
      if (heartbeat is Map) {
        _hbKey = heartbeat["key"]?.toString();
        var keyVer = heartbeat["key_ver"]?.toString() ?? "";
        if (keyVer.isNotEmpty) {
          _hbKeyVer = keyVer;
        }
      }
    } catch (e) {
      CoreLog.error(e);
    }
  }

  /// 发送连接心跳：必须带签名，否则会被服务端踢掉
  Future<void> _sendSenderHeartbeat(int generation) async {
    if (!_ownsSender(generation)) return;
    if (_hbKey == null) {
      await _loadHeartbeatKey(generation);
    }
    if (!_ownsSender(generation)) return;
    var key = _hbKey;
    if (key == null || key.isEmpty) {
      return;
    }
    var tick = _nowSec.toString();
    var digest = _hbNonce ?? _hbRand ?? "";
    var times = _hbNonce != null ? _hbIts : _hbEncTime;
    if (times <= 0) {
      times = 1;
    }
    for (var i = 0; i < times; i++) {
      digest = md5.convert(utf8.encode(digest + key)).toString();
    }
    var sig = md5
        .convert(utf8.encode(
            digest + key + danmakuArgs.roomId + danmakuArgs.devid + tick))
        .toString();
    _senderSocket?.sendMessage(serializeDouyu(
      "type@=keeplive/vbw@=0/cdn@=/tick@=$tick/kd@=/alg_ver@=1.0/key_ver=$_hbKeyVer/sig@=$sig/",
    ));
    _hbNonce = null;
    _hbIts = 0;
  }

  /// 把聊天回执错误码翻译成人话
  String _chatresErrorText(int res) {
    switch (res) {
      case 356:
        // 服务端明确拒绝这条内容/账号被限流；App 层会按「结果不确定」静默处理
        return "斗鱼限流（res=356），这条可能没上屏";
      case 1:
        return "发送失败：需要登录后发言（res=1）";
      case 12:
        return "发送失败：你已被禁言（res=12）";
      case 13:
        return "发送失败：发言等级不足（res=13）";
      case -1:
        return "发送失败：发送超时或被平台限制";
      default:
        return "发送失败（res=$res）";
    }
  }

  /// 解析发送连接的下行包（loginres / keeplive / chatres / error）
  void _decodeSenderMessage(List<int> data) {
    try {
      var result = deserializeDouyu(data);
      if (result == null) {
        return;
      }
      var jsonData = sttToJObject(result);
      var type = jsonData["type"]?.toString();
      if (type == "loginres") {
        var userid = jsonData["userid"]?.toString() ?? "";
        // 未登录/登录态被接管时，服务端会回一个游客短 uid（如 "8"），
        // 必须和账号真实 uid 比对，否则会把游客会话当成发送就绪
        var expectedUid = danmakuArgs.uid;
        var uidMatches = expectedUid.isEmpty ||
            userid == expectedUid ||
            (int.tryParse(userid) != null &&
                int.tryParse(userid) == int.tryParse(expectedUid));
        _senderReady =
            userid.isNotEmpty && userid != "0" && uidMatches;
        CoreLog.i(
          "斗鱼发送：wsproxy loginres userid=${userid.length} ready=$_senderReady "
          "uidMatch=$uidMatches sessionid=${(jsonData["sessionid"]?.toString() ?? "").length}",
        );
        var login = _senderLoginCompleter;
        if (login != null && !login.isCompleted) {
          login.complete();
        }
        if (!_senderReady) {
          // 登录态无效（过期或被其它设备接管）
          const msg = "斗鱼登录已在其它设备失效（被接管），请重新登录斗鱼";
          _chatresCompleter?.complete(msg);
          _chatresCompleter = null;
        }
        return;
      }
      if (type == "keeplive") {
        // 服务端心跳回包带新的 nonce / its，用一次即作废
        _hbNonce = jsonData["nonce"]?.toString();
        _hbIts = int.tryParse(jsonData["its"]?.toString() ?? "0") ?? 0;
        return;
      }
      if (type == "chatres") {
        var res = int.tryParse(jsonData["res"]?.toString() ?? "") ?? -1;
        if (res != 0) {
          CoreLog.i("斗鱼发送：收到 chatres res=$res");
        }
        _chatresCompleter?.complete(res == 0 ? null : _chatresErrorText(res));
        _chatresCompleter = null;
        return;
      }
      if (type == "error") {
        var code = jsonData["code"]?.toString() ?? "";
        CoreLog.i("斗鱼发送：wsproxy error code=$code");
        var msg = (code == "4206" || code == "4205")
            ? "斗鱼登录已过期，请重新登录斗鱼"
            : "斗鱼发送连接出错${code.isEmpty ? "" : "（$code）"}";
        _senderReady = false;
        // 被顶号（59/51）后这条连接已经废了，主动释放，下次发送直接重建
        if (code == "59" || code == "51") {
          try {
            _senderSocket?.close();
          } catch (e) {
            CoreLog.error(e);
          }
          _senderSocket = null;
        }
        var login = _senderLoginCompleter;
        if (login != null && !login.isCompleted) {
          login.complete();
        }
        _chatresCompleter?.complete(msg);
        _chatresCompleter = null;
        return;
      }
    } catch (e) {
      CoreLog.error(e);
    }
  }

  @override
  Future<String?> sendDanmaku(String message) async {
    final generation = _senderGeneration;
    if (!_ownsSender(generation)) return "发送房间已切换或关闭";
    var text = message.trim();
    if (text.isEmpty) {
      return "弹幕内容不能为空";
    }
    if (!danmakuArgs.canSend) {
      CoreLog.i("斗鱼发送：凭证不全，缺失=${danmakuArgs.missingSendFields}");
      if (danmakuArgs.jwtExpired) {
        return "斗鱼登录已过期（dmjwt 失效），请重新登录斗鱼";
      }
      return "斗鱼登录态不完整（缺少 ${danmakuArgs.missingSendFields.join("、")}），"
          "请在账号管理里重新登录斗鱼，或手动粘贴浏览器里完整的 Cookie";
    }
    if (_chatresCompleter != null) {
      return "上一条弹幕还在发送中，请稍后再试";
    }
    if (_lastSendAt != null &&
        DateTime.now().difference(_lastSendAt!) < const Duration(seconds: 2)) {
      return "发送太频繁，请稍后再试";
    }
    var senderError = await _ensureSender();
    if (!_ownsSender(generation)) return "发送房间已切换或关闭";
    if (senderError != null) {
      CoreLog.i("斗鱼发送：发送连接不可用 → $senderError");
      return senderError;
    }
    var args = danmakuArgs;
    var completer = _chatresCompleter = Completer<String?>();
    _lastSendAt = DateTime.now();
    // 抓包实证的上行帧（包类型 689）：content 放正文，dy/sender 等字段照抄网页
    var body = "pe@=0/content@=${scapeSlashAt(text)}/col@=0/type@=chatmessage"
        "/dy@=${args.devid}/sender@=${args.uid}"
        "/ifs@=0/nc@=0/dat@=0/rev@=0/tts@=$_nowSec/admzq@=0"
        "/cst@=${DateTime.now().millisecondsSinceEpoch}/";
    // 第二判据：接收连接上收到自己的弹幕广播
    var broadcast = _broadcastCompleter = Completer<void>();
    _pendingBroadcastText = text;
    _senderSocket?.sendMessage(serializeDouyu(body));
    try {
      // 成功 = chatres 或 自己的弹幕广播，任一先到即算成功
      return await Future.any([
        completer.future,
        broadcast.future.then<String?>((_) => null),
      ]).timeout(const Duration(seconds: 8));
    } on TimeoutException {
      if (identical(_chatresCompleter, completer)) {
        _chatresCompleter = null;
      }
      return "发送超时：可能被斗鱼冷却了，请等 1-2 分钟再试（刚发的可能已上屏）";
    } finally {
      // 广播先到时 chatres 的 Future 还在挂起，必须一起清掉，
      // 否则下一条会一直提示「上一条弹幕还在发送中」
      if (identical(_chatresCompleter, completer)) {
        _chatresCompleter = null;
      }
      if (identical(_broadcastCompleter, broadcast)) {
        _broadcastCompleter = null;
        _pendingBroadcastText = null;
      }
    }
  }

  @override
  Future stop() async {
    _stopped = true;
    onMessage = null;
    onClose = null;
    webScoketUtils?.close();
    _invalidateSender();
  }

  /// 已入库的付费留言 vrid，避免同一条重复建卡
  final Set<String> _voiceIds = <String>{};

  void decodeMessage(List<int> data) {
    try {
      String? result = deserializeDouyu(data);
      if (result == null) {
        return;
      }
      var jsonData = sttToJObject(result);

      var type = jsonData["type"]?.toString();
      // 登录响应：到这里才算真正登录成功
      if (type == "loginres") {
        var login = _loginCompleter;
        if (login != null && !login.isCompleted) {
          login.complete();
        }
        return;
      }
      //斗鱼好像不会返回人气值
      if (type == "chatmsg") {
        // 屏蔽阴间弹幕
        if (jsonData["dms"] == null) {
          return;
        }
        var col = int.tryParse(jsonData["col"].toString()) ?? 0;
        var isSelf = danmakuArgs.uid.isNotEmpty &&
            jsonData["uid"]?.toString() == danmakuArgs.uid;
        var txt = jsonData["txt"]?.toString() ?? "";
        // 钻粉专属表情 / 房间表情：正文里的 [表情名] 换成图片
        var spans = DouyuEmoticon.parseSpans(txt, _emoticons);
        var liveMsg = LiveMessage(
          type: LiveMessageType.chat,
          userName: jsonData["nn"].toString(),
          message: txt,
          color: getColor(col),
          // 自己发的弹幕：画面弹幕会加描边突出
          isSelf: isSelf,
          spans: spans,
          imageUrls: spans == null
              ? null
              : spans
                  .where((e) => e.isImage)
                  .map((e) => e.imageUrl!.trim())
                  .toList(),
          // 整条弹幕只有表情图片（钻粉表情）时标记出来，供「屏蔽图片表情」过滤
          isRoomEmoji: spans != null && DouyuEmoticon.isOnlyEmoticon(spans),
        );

        // 自己的弹幕被广播回来 → 说明确实发出去了，直接判成功
        if (isSelf &&
            _pendingBroadcastText != null &&
            jsonData["txt"]?.toString() == _pendingBroadcastText) {
          var broadcast = _broadcastCompleter;
          if (broadcast != null && !broadcast.isCompleted) {
            broadcast.complete();
          }
        }

        onMessage?.call(liveMsg);
        return;
      }
      // 付费留言（高能弹幕）：房间内的 comm_chatmsg 广播，btype=voiceDanmu
      // 带 rid 能明确是哪个房间（voice_trlt 不带 rid，会串到别的房间）
      if (type == "comm_chatmsg") {
        _handleCommChatMsg(jsonData);
        return;
      }
      // voice_trlt：兜底来源，真正的卡片优先用上面的 comm_chatmsg（带 rid 不串房）
      if (type == "voice_trlt") {
        _handleVoiceTrlt(jsonData);
        return;
      }
    } catch (e) {
      CoreLog.error(e);
    }
  }

  /// 解析高能弹幕（付费留言 / 语音弹幕）的下发事件。
  ///
  /// 真实报文（2026-11-11 房间 2016309 抓到）：
  /// `danmuShowSwitch=1/mtype=2/totalNum=0/type=voice_trlt/list=<条目的 STT 串>/isShow=1`
  /// * `mtype`：1=进房全量下发，2=新增一条，其它=移除
  /// * 条目字段：`vrId` 唯一 id、`un` 昵称、`uat` 头像、`content` 正文、
  ///   `price`/`realPrice` 单位分（3000 = 30 元）、`stime` 停留秒数、
  ///   `etimeV2` 过期时间戳、`uid`、`vocUrl` 语音文件、`vocNickUrl` 昵称语音、`isVoc`、`mf`
  /// * 坑：STT 解码后 URL 里的 `//` 会被拆成数组（`["https:", "host/path"]`），要拼回去
  void _handleVoiceTrlt(Map<dynamic, dynamic> jsonData) {
    try {
      final mtype = int.tryParse(jsonData["mtype"]?.toString() ?? "") ?? 2;
      final items = _decodeVoiceList(jsonData["list"]);
      for (final item in items) {
        final map = _decodeVoiceItem(item);
        if (map == null) {
          continue;
        }
        final vrid = map["vrId"]?.toString() ?? "";
        final price = _voicePriceYuan(map);
        // 兜底：万一某条付费留言没有 comm_chatmsg（房间广播），用增量下发补一张卡。
        // 注意 voice_trlt 不带 rid，进房全量（mtype=1）可能包含别的房间，只认增量。
        final endTime = _voiceEndTime(map);
        // price=0 是「免费高能弹幕」（平台送的自由留言），同样要出卡，
        // 之前用 price > 0 把免费的整条静默丢掉了。
        if (mtype == 2 && endTime.isAfter(DateTime.now())) {
          if (vrid.isNotEmpty && !_voiceIds.add(vrid)) {
            continue;
          }
          _emitVoiceCard(
            id: vrid,
            userName: _voiceUserName(map),
            face: _voiceFace(map),
            text: _voiceText(map),
            price: price,
            seconds: endTime.difference(DateTime.now()).inSeconds,
            source: "voice_trlt",
          );
        }
      }
    } catch (e) {
      CoreLog.error(e);
    }
  }

  /// 付费留言（高能弹幕）的房间广播：`type=comm_chatmsg&btype=voiceDanmu`。
  ///
  /// 真实报文（2026-11-12 房间 12306 抓到）：
  /// `vrid=2120815116315275264/btype=voiceDanmu/chatmsg=<内嵌 chatmsg>/
  /// range=2/cprice=3000/cmgType=1/type=comm_chatmsg/rid=12306/gbtemp=2/
  /// uid=455987653/crealPrice=3000/cet=60/now=<毫秒>/csuperScreen=0/danmucr=1`
  /// * `cprice`/`crealPrice` 单位分（3000 = 30 元）
  /// * `cet` 画面停留秒数；`danmucr` 1=蓝 2=红 3=黄
  /// * 内嵌 `chatmsg` 里才是内容：`nn` 昵称、`txt` 正文、`uid`、`ic` 头像相对路径
  /// * 关键是带 `rid`：voice_trlt 不带房间号，串房会串到别的房间去
  void _handleCommChatMsg(Map<dynamic, dynamic> jsonData) {
    try {
      if (jsonData["btype"]?.toString() != "voiceDanmu") {
        return;
      }
      final roomId = jsonData["rid"]?.toString() ?? "";
      if (danmakuArgs.roomId.isNotEmpty && roomId != danmakuArgs.roomId) {
        // 斗鱼会把已加入房间的广播都推过来，别的房间的高能弹幕要丢掉
        return;
      }
      final vrid = jsonData["vrid"]?.toString() ?? "";
      if (vrid.isNotEmpty && !_voiceIds.add(vrid)) {
        return;
      }
      final rawChat = jsonData["chatmsg"];
      final Map<String, dynamic>? chat;
      if (rawChat is Map) {
        // 正常情况：STT 已经把内嵌 chatmsg 解成了 Map
        chat = rawChat.map((k, v) => MapEntry(k.toString(), v));
      } else {
        chat = _decodeVoiceItem(sttToJObject(rawChat?.toString() ?? ""));
      }
      final text = (chat?["txt"]?.toString() ?? "").trim();
      if (text.isEmpty) {
        return;
      }
      final userName = (chat?["nn"]?.toString() ?? "").trim();
      final price = _voicePriceYuan({
        "realPrice": jsonData["crealPrice"]?.toString() ?? "",
        "price": jsonData["cprice"]?.toString() ?? "",
      });
      _emitVoiceCard(
        id: vrid,
        userName: userName,
        face: chat == null ? "" : _voiceFace(chat),
        text: text,
        price: price,
        seconds: int.tryParse(jsonData["cet"]?.toString() ?? "") ?? 60,
        color: int.tryParse(jsonData["danmucr"]?.toString() ?? ""),
        source: "comm_chatmsg",
      );
    } catch (e) {
      CoreLog.error(e);
    }
  }

  /// 付费留言统一出口：建 SC 卡片 + 推给上层（两个来源共用，按 id 去重）
  void _emitVoiceCard({
    required String id,
    required String userName,
    required String face,
    required String text,
    required int price,
    required int seconds,
    int? color,
    required String source,
  }) {
    if (text.trim().isEmpty) {
      return;
    }
    final colors = _voiceScColors(price, color: color);
    final now = DateTime.now();
    final endTime = now.add(Duration(seconds: seconds <= 0 ? 60 : seconds));
    final sc = LiveSuperChatMessage(
      id: id,
      userName: userName.trim().isEmpty ? "神秘人" : userName.trim(),
      face: face,
      message: text.trim(),
      price: price,
      startTime: now,
      endTime: endTime,
      backgroundColor: colors.header,
      backgroundBottomColor: colors.body,
    );
    onMessage?.call(
      LiveMessage(
        type: LiveMessageType.superChat,
        userName: sc.userName,
        message: sc.message,
        color: LiveMessageColor.white,
        data: sc,
      ),
    );
  }

  /// 斗鱼头像：ic 是相对路径（avatar/default/15、avatar_v3/202609/xxx），
  /// 拼成 http 地址并补 `_big.jpg`（已验证 200 image/jpeg）
  String _douyuAvatar(dynamic raw) {
    final path = _voiceUrl(raw).trim();
    if (path.isEmpty || path == "0" || path == "null") {
      return "";
    }
    if (path.startsWith("http")) {
      return path;
    }
    final url = "https://apic.douyucdn.cn/upload/$path";
    return path.contains(".") ? url : "${url}_big.jpg";
  }

  /// voice_trlt 的 list 是「字符串套字符串」，最多解两层
  List<dynamic> _decodeVoiceList(dynamic raw) {
    var value = raw;
    for (var i = 0; i < 2; i++) {
      if (value is String) {
        final text = value.trim();
        if (text.isEmpty) {
          return [];
        }
        try {
          value = json.decode(text);
        } catch (_) {
          // 不是 JSON：可能是单个 STT 条目，交给 _decodeVoiceItem 处理
          return text.contains("@=") || text.contains("@A=") ? [text] : [];
        }
      }
    }
    return value is List ? value : [];
  }

  Map<String, dynamic>? _decodeVoiceItem(dynamic item) {
    var value = item;
    if (value is String) {
      final text = value.trim();
      if (text.isEmpty) {
        return null;
      }
      try {
        value = json.decode(text);
      } catch (_) {
        // 实测有些 voice_trlt 的 list 元素是 STT 串而不是 JSON，
        // 以前这里直接 return null → 整条付费留言被丢掉（16:50、17:10 那两条）
        if (text.contains("@=") || text.contains("@A=")) {
          value = sttToJObject(text);
        } else {
          return null;
        }
      }
    }
    if (value is Map) {
      return value.map((k, v) => MapEntry(k.toString(), v));
    }
    return null;
  }

  String _voiceUserName(Map<String, dynamic> item) {
    for (final key in ["un", "nn", "userNick", "nickname", "name"]) {
      final value = item[key]?.toString().trim() ?? "";
      if (value.isNotEmpty && value != "null") {
        return value;
      }
    }
    return "神秘人";
  }

  /// 头像：uat / ic 可能是完整 URL，也可能是相对路径（补 _big.jpg）
  String _voiceFace(Map<String, dynamic> item) {
    for (final key in ["uat", "userIcon", "ic", "avatar", "pic"]) {
      final value = _douyuAvatar(item[key]);
      if (value.isNotEmpty && value != "0") {
        return value;
      }
    }
    return "";
  }

  /// URL 归一化。
  ///
  /// STT 解析会把 `https://host/path` 里的 `//` 当成数组分隔符拆成
  /// `["https:", "host/path"]`，这里再拼回来；字符串则原样返回。
  String _voiceUrl(dynamic raw) {
    if (raw == null) {
      return "";
    }
    if (raw is List) {
      final parts = raw
          .map((e) => e?.toString().trim() ?? "")
          .where((e) => e.isNotEmpty && e != "null")
          .toList();
      if (parts.isEmpty) {
        return "";
      }
      // 首段形如 "https:"，后面补两段斜杠才是完整 URL
      if (parts.first.endsWith(":")) {
        return "${parts.first}//${parts.skip(1).join('/')}";
      }
      return parts.join("/");
    }
    final text = raw.toString().trim();
    return text == "null" ? "" : text;
  }

  /// 高能弹幕的语音文件地址（真实报文里的 vocUrl），暂时只记录不播放
  String _voiceAudioUrl(Map<String, dynamic> item) => _voiceUrl(item["vocUrl"]);

  /// 高能弹幕正文（真实报文里是 `content`）
  String _voiceText(Map<String, dynamic> item) {
    for (final key in ["content", "txt", "text", "msg", "danmu", "dn"]) {
      final value = item[key]?.toString().trim() ?? "";
      if (value.isNotEmpty && value != "null") {
        return value;
      }
    }
    return "（语音弹幕）";
  }

  /// 金额：网页端 price 单位是「分」（Math.floor(price/100) 才是元）
  int _voicePriceYuan(Map<String, dynamic> item) {
    final raw = item["realPrice"] ?? item["price"];
    final value = double.tryParse(raw?.toString() ?? "") ?? 0;
    if (value <= 0) {
      return 0;
    }
    return value >= 100 ? (value / 100).round() : value.round();
  }

  DateTime _voiceEndTime(Map<String, dynamic> item) {
    final now = DateTime.now();
    final expire = int.tryParse(item["etimeV2"]?.toString() ?? "");
    if (expire != null && expire > 0) {
      return DateTime.fromMillisecondsSinceEpoch(expire * 1000);
    }
    final seconds = int.tryParse(
          item["stime"]?.toString() ?? item["hoverTime"]?.toString() ?? "",
        ) ??
        30;
    return now.add(Duration(seconds: seconds <= 0 ? 30 : seconds));
  }

  /// SC 卡片两段色：档位与 App 的 superChatTierColor 保持一致
  ({String header, String body}) _voiceScColors(int price, {int? color}) {
    var rgb = 0x2A60B2;
    if (color == 2) {
      // 网页端 danmucr=2 红
      rgb = 0xD64545;
    } else if (color == 3) {
      // danmucr=3 黄
      rgb = 0xF0A83C;
    } else if (color == 1) {
      rgb = 0x2A60B2;
    } else if (price >= 2000) {
      rgb = 0xA0228C;
    } else if (price >= 1000) {
      rgb = 0xD64545;
    } else if (price >= 500) {
      rgb = 0xE8722C;
    } else if (price >= 100) {
      rgb = 0xF0A83C;
    } else if (price >= 50) {
      rgb = 0x00AEEC;
    }
    final r = (rgb >> 16) & 0xFF;
    final g = (rgb >> 8) & 0xFF;
    final b = rgb & 0xFF;
    String tint(int channel) => (channel + (255 - channel) * 0.82)
        .round()
        .toRadixString(16)
        .padLeft(2, "0");
    return (
      header: "${tint(r)}${tint(g)}${tint(b)}",
      body: rgb.toRadixString(16).padLeft(6, "0"),
    );
  }

  /// 组包。[type] 默认 689（登录/心跳）；发弹幕要用 690（实测网页版如此）
  List<int> serializeDouyu(String body, {int type = 689}) {
    try {
      final int clientSendToServer = type;
      const int encrypted = 0;
      const int reserved = 0;

      List<int> buffer = utf8.encode(body);

      var writer = BinaryWriter([]);
      // 长度语义（从网页抓包反推）：正文 UTF-8 字节数 + 9
      // 注意：绝不能用 body.length —— Dart 的 String.length 是 UTF-16 代码单元数，
      // 中文/emoji 会与 UTF-8 字节数不一致，导致服务器无法解析整包
      var packetLength = buffer.length + 9;
      writer.writeInt(packetLength, 4, endian: Endian.little);
      writer.writeInt(packetLength, 4, endian: Endian.little);
      writer.writeInt(clientSendToServer, 2, endian: Endian.little);
      writer.writeInt(encrypted, 1, endian: Endian.little);
      writer.writeInt(reserved, 1, endian: Endian.little);
      writer.writeBytes(buffer);
      writer.writeInt(0, 1, endian: Endian.little);
      return writer.buffer;
    } catch (e) {
      CoreLog.error(e);
      return [];
    }
  }

  String? deserializeDouyu(List<int> buffer) {
    try {
      var reader = BinaryReader(Uint8List.fromList(buffer));
      int fullMsgLength =
          reader.readInt32(endian: Endian.little); //fullMsgLength
      reader.readInt32(endian: Endian.little); //fullMsgLength2
      int bodyLength = fullMsgLength - 9;
      reader.readShort(endian: Endian.little); //packType
      reader.readByte(endian: Endian.little); //encrypted
      reader.readByte(endian: Endian.little); //reserved

      var bytes = reader.readBytes(bodyLength);

      reader.readByte(endian: Endian.little); //固定为0
      return utf8.decode(bytes);
    } catch (e) {
      CoreLog.error(e);
      return null;
    }
  }

  //辣鸡STT
  dynamic sttToJObject(String str) {
    if (str.contains("//")) {
      var result = [];
      for (var field in str.split("//")) {
        if (field.isEmpty) {
          continue;
        }
        result.add(sttToJObject(field));
      }
      return result;
    }
    if (str.contains("@=")) {
      var result = {};
      for (var field in str.split('/')) {
        if (field.isEmpty) {
          continue;
        }
        var tokens = field.split("@=");
        var k = tokens[0];
        var v = unscapeSlashAt(tokens[1]);
        result[k] = sttToJObject(v);
      }
      return result;
    } else if (str.contains("@A=")) {
      return sttToJObject(unscapeSlashAt(str));
    } else {
      return unscapeSlashAt(str);
    }
  }

  String unscapeSlashAt(String str) {
    return str.replaceAll("@S", "/").replaceAll("@A", "@");
  }

  LiveMessageColor getColor(int type) {
    switch (type) {
      case 1:
        return LiveMessageColor(255, 0, 0);
      case 2:
        return LiveMessageColor(30, 135, 240);
      case 3:
        return LiveMessageColor(122, 200, 75);
      case 4:
        return LiveMessageColor(255, 127, 0);
      case 5:
        return LiveMessageColor(155, 57, 244);
      case 6:
        return LiveMessageColor(255, 105, 180);
      default:
        return LiveMessageColor.white;
    }
  }
}
