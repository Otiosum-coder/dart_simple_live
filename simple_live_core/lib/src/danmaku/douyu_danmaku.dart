import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/http_client.dart' as core_http;
import 'package:simple_live_core/src/common/web_socket_util.dart';

import '../common/binary_writer.dart';

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
  @override
  String toString() {
    return json.encode({
      "roomId": roomId,
      "uid": uid,
      "devid": devid,
    });
  }
}

class DouyuDanmaku implements LiveDanmaku {
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

  @override
  Future start(dynamic args) async {
    danmakuArgs = args is DouyuDanmakuArgs
        ? args
        : DouyuDanmakuArgs(roomId: args.toString());
    CoreLog.i("斗鱼弹幕：发送能力 canSend=${danmakuArgs.canSend} "
        "${danmakuArgs.sendReadyDesc} 缺字段=${danmakuArgs.missingSendFields}");
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

  /// 建立发送连接并登录：成功返回 null，失败返回错误文案
  Future<String?> _ensureSender() async {
    if (danmakuArgs.jwtExpired) {
      return "斗鱼登录已过期（dmjwt 失效），请重新登录斗鱼";
    }
    if (_senderReady && _senderSocket?.status == SocketStatus.connected) {
      return null;
    }
    if (_senderSocket == null) {
      _senderSocket = WebScoketUtils(
        url: senderUrl,
        heartBeatTime: 30 * 1000,
        // 带上浏览器的 Cookie/Origin/UA：让斗鱼把这条连接视为同一会话，
        // 而不是"另一个地点登录"（从而尽量避免把用户的浏览器/客户端踢下线）
        headers: {
          "Origin": "https://www.douyu.com",
          "Referer": "https://www.douyu.com/${danmakuArgs.roomId}",
          "User-Agent": DouyuSite.kUserAgent,
          if (danmakuArgs.cookie.isNotEmpty) "Cookie": danmakuArgs.cookie,
        },
        onMessage: (e) => _decodeSenderMessage(e),
        onReady: () => _loginSender(),
        onHeartBeat: () => _sendSenderHeartbeat(),
        onReconnect: () => _senderReady = false,
        onClose: (e) => _senderReady = false,
      );
      // 发送连接不做自动重连：被踢后只在用户再次发送时才重新登录，
      // 避免"自动重连→再踢对方→对方重试→再踢我们"的互踢循环
      _senderSocket?.maxReconnectTime = 0;
    }
    var login = _senderLoginCompleter = Completer<void>();
    _senderReady = false;
    _senderSocket?.connect();
    try {
      await login.future.timeout(const Duration(seconds: 8));
    } on TimeoutException {
      return "斗鱼发送连接登录超时，请稍后重试";
    } finally {
      if (identical(_senderLoginCompleter, login)) {
        _senderLoginCompleter = null;
      }
    }
    if (!_senderReady) {
      return "斗鱼发送连接登录失败：登录态可能已过期，请重新登录斗鱼";
    }
    return null;
  }

  /// 发送连接登录（loginreq + vk 防重放签名）
  void _loginSender() {
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
  Future<void> _loadHeartbeatKey() async {
    try {
      var res = await core_http.HttpClient.instance.getJson(
        "https://www.douyu.com/wgapi/livenc/liveweb/websec/getEncryption",
        queryParameters: {"did": danmakuArgs.devid},
        header: {
          "referer": "https://www.douyu.com/${danmakuArgs.roomId}",
          "user-agent": DouyuSite.kUserAgent,
        },
      );
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
  Future<void> _sendSenderHeartbeat() async {
    if (_hbKey == null) {
      await _loadHeartbeatKey();
    }
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
        _senderReady = userid.isNotEmpty && userid != "0";
        CoreLog.i("斗鱼发送：wsproxy loginres userid=${userid.length} "
            "ready=$_senderReady sessionid=${(jsonData["sessionid"]?.toString() ?? "").length}");
        var login = _senderLoginCompleter;
        if (login != null && !login.isCompleted) {
          login.complete();
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
        CoreLog.i("斗鱼发送：收到 chatres res=$res");
        _chatresCompleter?.complete(res == 0 ? null : "发送失败（res=$res）");
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
    CoreLog.i("斗鱼发送：开始建立/复用发送连接（room=${danmakuArgs.roomId}）");
    var senderError = await _ensureSender();
    if (senderError != null) {
      CoreLog.i("斗鱼发送：发送连接不可用 → $senderError");
      return senderError;
    }
    CoreLog.i("斗鱼发送：发送连接就绪，开始发送（长度=${text.length}）");
    var args = danmakuArgs;
    var completer = _chatresCompleter = Completer<String?>();
    _lastSendAt = DateTime.now();
    // 抓包实证的上行帧（包类型 689）：content 放正文，dy/sender 等字段照抄网页
    var body = "pe@=0/content@=${scapeSlashAt(text)}/col@=0/type@=chatmessage"
        "/dy@=${args.devid}/sender@=${args.uid}"
        "/ifs@=0/nc@=0/dat@=0/rev@=0/tts@=$_nowSec/admzq@=0"
        "/cst@=${DateTime.now().millisecondsSinceEpoch}/";
    _senderSocket?.sendMessage(serializeDouyu(body));
    try {
      // 唯一可信的成功判据：同一条 wsproxy 连接回 type@=chatres/res@=0
      return await completer.future.timeout(const Duration(seconds: 8));
    } on TimeoutException {
      if (identical(_chatresCompleter, completer)) {
        _chatresCompleter = null;
      }
      return "发送超时：内容可能重复或发送过快，换一条内容再试";
    }
  }

  @override
  Future stop() async {
    onMessage = null;
    onClose = null;
    webScoketUtils?.close();
    // 发送连接也要一起关，避免残留连接继续重连
    _senderSocket?.close();
    _senderSocket = null;
    _senderReady = false;
    _senderLoginCompleter = null;
    _chatresCompleter = null;
  }

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
        var liveMsg = LiveMessage(
          type: LiveMessageType.chat,
          userName: jsonData["nn"].toString(),
          message: jsonData["txt"].toString(),
          color: getColor(col),
          // 自己发的弹幕：画面弹幕会加描边突出
          isSelf: danmakuArgs.uid.isNotEmpty &&
              jsonData["uid"]?.toString() == danmakuArgs.uid,
        );

        onMessage?.call(liveMsg);
      }
    } catch (e) {
      CoreLog.error(e);
    }
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
