import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/web_socket_util.dart';
import 'package:simple_live_core/src/danmaku/huya_emoticon.dart';
import 'package:simple_live_core/src/danmaku/huya_headline_client.dart';
import 'package:simple_live_core/src/danmaku/huya_superchat.dart';
import 'package:simple_live_core/src/model/tars/huya_danmaku.dart';
import 'package:tars_dart/tars/codec/tars_input_stream.dart';
import 'package:tars_dart/tars/codec/tars_output_stream.dart';
import 'package:tars_dart/tars/codec/tars_struct.dart';

class HuyaDanmakuArgs {
  final int ayyuid;
  final int topSid;
  final int subSid;

  /// 主播用户 UID（tProfileInfo.lUid），与频道 ID / YY 号不是同一字段。
  final int presenterUid;

  /// 登录 Cookie（空 = 未登录，只能看弹幕不能发）
  final String cookie;
  HuyaDanmakuArgs({
    required this.ayyuid,
    required this.topSid,
    required this.subSid,
    this.presenterUid = 0,
    this.cookie = "",
  });
  @override
  String toString() {
    return json.encode({
      "ayyuid": ayyuid,
      "topSid": topSid,
      "subSid": subSid,
      "presenterUid": presenterUid,
      "logined": cookie.isNotEmpty,
    });
  }
}

/// 虎牙 sendMessage 请求体里的 userInfo（Tars struct）
class _HuyaSendUserInfo extends TarsStruct {
  int uid = 0;
  String guid = "";
  String cookie = "";

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(uid, 0);
    _os.write(guid, 1);
    _os.write("", 2);
    _os.write("webh5&2610260926&websocket", 3);
    _os.write(cookie, 4);
    _os.write(0, 5);
    _os.write("chrome", 6);
    _os.write("", 7);
  }

  @override
  void readFrom(TarsInputStream _is) {}

  @override
  Object deepCopy() => _HuyaSendUserInfo()
    ..uid = uid
    ..guid = guid
    ..cookie = cookie;

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

/// 发送 body 的 tag10（抓包是 3 个零字段的结构）
class _HuyaSendTail extends TarsStruct {
  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(0, 0);
    _os.write(0, 1);
    _os.write(0, 2);
  }

  @override
  void readFrom(TarsInputStream _is) {}

  @override
  Object deepCopy() => _HuyaSendTail();

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

/// 发送 body 的 tag6（抓包里的第二组格式，字段比 tag5 多）
class _HuyaFormatEx extends TarsStruct {
  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(-1, 0);
    _os.write(4, 1);
    _os.write(0, 2);
    _os.write(1, 3);
    _os.write(0, 4);
    _os.write(_HuyaPalette(), 5);
    _os.write(<int>[], 6);
    _os.write(0, 7);
    _os.write(-1, 8);
  }

  @override
  void readFrom(TarsInputStream _is) {}

  @override
  Object deepCopy() => _HuyaFormatEx();

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

class _HuyaPalette extends TarsStruct {
  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(0, 0);
    _os.write(0, 1);
    _os.write(-1, 2);
    _os.write(100, 3);
    _os.write(-1, 4);
    _os.write(100, 5);
    _os.write("", 6);
    _os.write(-1, 7);
    _os.write(-1, 8);
  }

  @override
  void readFrom(TarsInputStream _is) {}

  @override
  Object deepCopy() => _HuyaPalette();

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

/// 虎牙 sendMessage 请求体（body.tReq）
class _HuyaSendBody extends TarsStruct {
  int presenterUid = 0;
  int topSid = 0;
  String content = "";
  _HuyaSendUserInfo userInfo = _HuyaSendUserInfo();

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(userInfo, 0);
    _os.write(presenterUid, 1);
    _os.write(topSid, 2);
    _os.write(content, 3);
    _os.write(0, 4);
    _os.write(_HuyaBulletFormat(), 5);
    _os.write(_HuyaFormatEx(), 6);
    _os.write(<int>[], 7);
    _os.write(topSid, 8);
    _os.write(<int>[], 9);
    _os.write(_HuyaSendTail(), 10);
    _os.write(0, 11);
  }

  @override
  void readFrom(TarsInputStream _is) {}

  @override
  Object deepCopy() => _HuyaSendBody();

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

/// 弹幕样式（发送时带白色、常规字号）
class _HuyaBulletFormat extends TarsStruct {
  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(-1, 0);
    _os.write(4, 1);
    _os.write(0, 2);
    _os.write(-1, 3);
    _os.write(-1, 4);
    _os.write(-1, 5);
  }

  @override
  void readFrom(TarsInputStream _is) {}

  @override
  Object deepCopy() => _HuyaBulletFormat();

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

/// wsLaunch 使用的设备信息（抓包结构）
class _HuyaLaunchDevice extends TarsStruct {
  String guid = "";

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(0, 0);
    _os.write(guid, 1);
    _os.write("webh5&1.0.0&huya", 2);
    _os.write("WEBH5&ZH&2052", 3);
    var empty = _HuyaEmpty();
    _os.write(empty, 4);
  }

  @override
  void readFrom(TarsInputStream _is) {}

  @override
  Object deepCopy() => _HuyaLaunchDevice()..guid = guid;

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

/// 空结构（占位）
class _HuyaEmpty extends TarsStruct {
  @override
  void writeTo(TarsOutputStream _os) {
    _os.write("", 0);
    _os.write("", 1);
    _os.write("", 2);
    _os.write("", 3);
    _os.write("", 4);
  }

  @override
  void readFrom(TarsInputStream _is) {}

  @override
  Object deepCopy() => _HuyaEmpty();

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

/// wsLaunch 请求体
class _HuyaLaunchTReq extends TarsStruct {
  String guid = "";

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(_HuyaLaunchDevice()..guid = guid, 0);
    // 抓包帧里还有两个空 map（tag9 / tag10），少了总长会差 4 字节
    _os.write(<String, String>{}, 9);
    _os.write(<String, String>{}, 10);
  }

  @override
  void readFrom(TarsInputStream _is) {}

  @override
  Object deepCopy() => _HuyaLaunchTReq()..guid = guid;

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

class HuyaDanmaku implements LiveDanmaku {
  HuyaDanmaku({
    HuyaHeadlineLoader? headlineLoader,
    DateTime Function()? superChatNow,
  }) : _headlineLoader = headlineLoader ?? fetchHuyaHeadlines,
       _superChats = HuyaSuperChatDecoder(now: superChatNow);

  final HuyaHeadlineLoader _headlineLoader;
  final HuyaSuperChatDecoder _superChats;
  int _headlineGeneration = 0;

  @override
  int heartbeatTime = 60 * 1000;

  @override
  Function(LiveMessage msg)? onMessage;
  @override
  Function(String msg)? onClose;
  @override
  Function()? onReady;
  String serverUrl = "wss://cdnws.api.huya.com";

  WebScoketUtils? webScoketUtils;

  final heartbeatData = base64.decode("ABQdAAwsNgBM");

  HuyaDanmakuArgs danmakuArgs = HuyaDanmakuArgs(
    ayyuid: 0,
    topSid: 0,
    subSid: 0,
  );

  /// 发送专用连接（网页同款 -ws.va + wsLaunch）；
  /// 接收继续走 cdnws，两条连接互不影响
  WebScoketUtils? _sendSocket;
  bool _running = false;

  /// 自己的 yyuid / guid（从 Cookie 解析，发送弹幕要用）
  int selfUid = 0;
  String guid = "";

  /// 发送序号 + 等待回执
  int _seq = 70;
  int? _pendingSeq;
  Completer<String?>? _sendCompleter;

  @override
  Future start(dynamic args) async {
    danmakuArgs = args as HuyaDanmakuArgs;
    _running = true;
    _headlineGeneration++;
    _superChats.clear();
    unawaited(loadSuperChats());
    // 游客目录独立于账号和 WS，后台加载，不拖慢进房或弹幕连接。
    unawaited(HuyaEmoticon.load());
    selfUid = int.tryParse(_cookieValue("udb_uid")) ?? 0;
    if (selfUid == 0) {
      selfUid = int.tryParse(_cookieValue("yyuid")) ?? 0;
    }
    guid = _cookieValue("guid");
    // 重连/刷新时会再次调用 start()：必须先关闭旧连接，
    // 否则旧 socket 仍在接收消息 → 聊天列表和滚动弹幕都会重复出现
    webScoketUtils?.close();
    _sendSocket?.close();
    // ① 接收连接：cdnws（项目原有流程，稳定，能收到弹幕推送）
    webScoketUtils = WebScoketUtils(
      url: serverUrl,
      heartBeatTime: heartbeatTime,
      onMessage: (e) {
        decodeMessage(e);
      },
      onReady: () {
        onReady?.call();
        joinRoom();
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

    _connectSendSocket();
  }

  void _connectSendSocket() {
    _sendSocket?.close();
    _sendSocket = null;
    // 发送凭据轮换只重建发送连接，保留接收连接和房间状态。
    if (selfUid > 0 && guid.isNotEmpty) {
      var wsUrl = buildWsUrl();
      CoreLog.d("虎牙发送连接：${wsUrl.split("?baseinfo=").first}");
      _sendSocket = WebScoketUtils(
        url: wsUrl,
        heartBeatTime: heartbeatTime,
        onMessage: (e) {
          decodeMessage(e);
        },
        onReady: () {
          sendLaunch();
          sendAuth();
        },
        onHeartBeat: () {
          _sendSocket?.sendMessage(heartbeatData);
        },
      );
      _sendSocket?.connect();
    }
  }

  /// 账号服务接受新 Cookie 后同步已有房间，不重新进房或自动重发消息。
  void updateCookie(String cookie) {
    if (danmakuArgs.cookie == cookie) return;
    final previous = danmakuArgs;
    danmakuArgs = HuyaDanmakuArgs(
      ayyuid: previous.ayyuid,
      topSid: previous.topSid,
      subSid: previous.subSid,
      presenterUid: previous.presenterUid,
      cookie: cookie,
    );
    selfUid =
        int.tryParse(_cookieValue('udb_uid')) ??
        int.tryParse(_cookieValue('yyuid')) ??
        0;
    guid = _cookieValue('guid');
    final pending = _sendCompleter;
    if (pending != null && !pending.isCompleted) {
      pending.complete('登录状态已更新，请确认上一条发送结果后重试');
    }
    if (_running) _connectSendSocket();
  }

  /// 仅识别已知的精确业务错误码；其它 biz exception 或包含 905 的文本不代表掉线。
  static bool isSessionExpiredError(String description) => RegExp(
    r'\bbiz\s+exception\s*:\s*905\b',
    caseSensitive: false,
  ).hasMatch(description);

  /// 从登录 Cookie 里取字段值
  String _cookieValue(String key) {
    for (var part in danmakuArgs.cookie.split(';')) {
      var item = part.trim();
      var index = item.indexOf('=');
      if (index <= 0) {
        continue;
      }
      if (item.substring(0, index).trim() == key) {
        return item.substring(index + 1).trim();
      }
    }
    return "";
  }

  /// 网页端发送弹幕走的是 `wss://<8位随机串>-ws.va.huya.com/?baseinfo=<base64>`，
  /// baseinfo 是 Tars 结构（yyuid / guid / ua / 语言 / 坐标等），
  /// 实测 `cdnws.api.huya.com` 上发 cmdId=3 收不到回执，所以登录后优先用这个地址。
  String buildWsUrl() {
    if (selfUid == 0 || guid.isEmpty) {
      return serverUrl;
    }
    try {
      var oos = TarsOutputStream();
      oos.write(selfUid, 0);
      oos.write(guid, 1);
      oos.write("webh5&2610260926&websocket", 2);
      oos.write("HUYA&ZH&2052", 3);
      oos.write("", 4);
      oos.write("44299.76949,58664.107264,58955.107754", 5);
      oos.write(0, 6);
      oos.write("", 7);
      oos.write("", 8);
      oos.write("", 9);
      var base64Info = base64.encode(oos.toUint8List());
      var prefix = vaHostCandidates.first;
      return "wss://$prefix-ws.va.huya.com/?baseinfo=${Uri.encodeComponent(base64Info)}";
    } catch (e) {
      CoreLog.error(e);
      return serverUrl;
    }
  }

  /// 网页端连的是 `wss://<8位hex>-ws.va.huya.com`，但前缀不是随机的：
  /// 只有虎牙 DNS 里登记过的节点名才能解析（随机名直接解析失败）。
  /// 这里放抓包里验证可连的节点，连不上会自动回退到 cdnws（只收不发）。
  static const List<String> vaHostCandidates = [
    "9d7ad622",
    "9dff46be",
    "a3b1d877",
    "a3b1d8d2",
  ];

  /// wsLaunch：网页连接进房（cmdId=3 / tag6="wsLaunch"）
  void sendLaunch() {
    try {
      var tReq = _HuyaLaunchTReq()..guid = guid;
      var tReqStream = TarsOutputStream();
      tReq.writeTo(tReqStream);

      var bodyStream = TarsOutputStream();
      bodyStream.write({"tReq": tReqStream.toUint8List()}, 0);

      var inner = TarsOutputStream();
      inner.write(3, 1);
      inner.write(0, 2);
      inner.write(0, 3);
      inner.write(-1, 4);
      inner.write("launch", 5);
      inner.write("wsLaunch", 6);
      inner.write(bodyStream.toUint8List(), 7);
      inner.write(0, 8);

      var payload = withLengthPrefix(inner.toUint8List());
      var cmd = TarsOutputStream();
      cmd.write(3, 0);
      cmd.write(payload, 1);
      cmd.write(0, 2);
      cmd.write("", 3);
      cmd.write(0, 4);
      cmd.write(0, 5);
      cmd.write("", 6);
      var frame = cmd.toUint8List();
      webScoketUtils?.sendMessage(frame);
    } catch (e) {
      CoreLog.error(e);
    }
  }

  /// 网页连接鉴权帧（cmdId=10）：把 Cookie / guid 绑到这条连接上，
  /// 抓包里它紧跟在 wsLaunch 后面；不发给的话服务端不认 sendMessage
  void sendAuth() {
    try {
      var inner = TarsOutputStream();
      inner.write(0, 0);
      inner.write("webh5&1.0.0&huya", 1);
      inner.write(danmakuArgs.cookie, 2);
      inner.write(guid, 3);
      inner.write(1, 4);
      inner.write("WEBH5&ZH&2052", 5);

      var cmd = TarsOutputStream();
      cmd.write(10, 0);
      cmd.write(inner.toUint8List(), 1);
      cmd.write(0, 2);
      cmd.write("", 3);
      cmd.write(0, 4);
      cmd.write(0, 5);
      cmd.write("", 6);
      var frame = cmd.toUint8List();
      _sendSocket?.sendMessage(frame);
    } catch (e) {
      CoreLog.error(e);
    }
  }

  /// payload 需要 4 字节大端长度前缀（含自身），抓包帧就是这样
  Uint8List withLengthPrefix(Uint8List inner) {
    var length = inner.length + 4;
    var payload = Uint8List(4 + inner.length);
    payload[0] = (length >> 24) & 0xFF;
    payload[1] = (length >> 16) & 0xFF;
    payload[2] = (length >> 8) & 0xFF;
    payload[3] = length & 0xFF;
    payload.setAll(4, inner);
    return payload;
  }

  void joinRoom() {
    var joinData = getJoinData(
      danmakuArgs.ayyuid,
      danmakuArgs.topSid,
      danmakuArgs.topSid,
    );
    webScoketUtils?.sendMessage(joinData);
    final groups = getGroupData(danmakuArgs.presenterUid);
    if (groups.isNotEmpty) webScoketUtils?.sendMessage(groups);
  }

  /// 头条广播下发到 live:<主播 UID>；不能用频道号或 YY 号订阅。
  List<int> getGroupData(int presenterUid) {
    if (presenterUid <= 0) return [];
    // 普通弹幕已由旧频道注册接收，再订阅 chat 分组会重复收到同一条弹幕。
    final request = TarsOutputStream()..write(['live:$presenterUid'], 0);
    final frame = TarsOutputStream()
      ..write(16, 0)
      ..write(request.toUint8List(), 1);
    return frame.toUint8List();
  }

  /// 首次列表和实时广播共用解码器，收到相同头条不会重复弹出。
  Future<void> loadSuperChats() async {
    final generation = _headlineGeneration;
    final args = danmakuArgs;
    if (args.presenterUid <= 0) return;
    try {
      final response = await _headlineLoader(args.presenterUid);
      if (generation != _headlineGeneration ||
          !identical(args, danmakuArgs) ||
          onMessage == null) {
        return;
      }
      _emitSuperChats(
        _superChats.decodeInitialResponse(
          response,
          presenterUid: args.presenterUid,
        ),
      );
    } catch (e) {
      // 头条失败不能阻止普通弹幕，也不把接口错误当成断线重连。
      if (generation == _headlineGeneration) {
        CoreLog.w('虎牙头条列表读取失败：$e');
      }
    }
  }

  void _emitSuperChats(List<LiveSuperChatMessage> messages) {
    for (final sc in messages) {
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
  }

  List<int> getJoinData(int ayyuid, int tid, int sid) {
    try {
      var oos = TarsOutputStream();
      oos.write(ayyuid, 0);
      oos.write(true, 1);
      oos.write("", 2);
      oos.write("", 3);
      oos.write(tid, 4);
      oos.write(sid, 5);
      oos.write(0, 6);
      oos.write(0, 7);

      var wscmd = TarsOutputStream();
      wscmd.write(1, 0);
      wscmd.write(oos.toUint8List(), 1);
      return wscmd.toUint8List();
    } catch (e) {
      CoreLog.error(e);
      return [];
    }
  }

  @override
  void heartbeat() {
    webScoketUtils?.sendMessage(heartbeatData);
  }

  /// 虎牙支持发送（未登录/缺 Cookie 时会在发送阶段报错，
  /// 这样先验证 cmdId=3/sendMessage 协议是否可用）
  @override
  bool get canSendDanmaku => true;

  /// 组装一条 cmdId=3 / sendMessage 帧
  ///
  /// 外层 WSCmd：tag0=3, tag1=payload(bytes), tag3=traceId, tag6=md5(payload)
  /// payload：tag1=3, tag4=序号, tag5=liveui, tag6=sendMessage, tag7=body(bytes)
  /// body：map{"tReq": 请求结构}
  Uint8List buildSendFrame(String content, int seq) {
    var body = _HuyaSendBody()
      ..content = content
      // 抓包验证：房间 1995 里浏览器发弹幕时 tag1/tag2/tag8 都是 2272316519，
      // 而 App 该房间的 topSid 正是 2272316519（主播 uid 是 2272348727）→ 用 topSid
      ..presenterUid = danmakuArgs.topSid
      ..topSid = danmakuArgs.topSid;
    body.userInfo
      ..uid = selfUid
      ..guid = guid
      ..cookie = danmakuArgs.cookie;

    // tReq（结构体字节）：必须带 STRUCT_BEGIN/END 包装，
    // 抓包帧就是 0a … 0b；缺了服务端会报 "read 'struct' type mismatch"
    var tReqStream = TarsOutputStream();
    tReqStream.writeHead(TarsStructType.STRUCT_BEGIN.index, 0);
    body.writeTo(tReqStream);
    tReqStream.writeHead(TarsStructType.STRUCT_END.index, 0);

    // body = map{ "tReq": bytes }
    var bodyStream = TarsOutputStream();
    bodyStream.write({"tReq": tReqStream.toUint8List()}, 0);

    // payload 内层
    var innerStream = TarsOutputStream();
    innerStream.write(3, 1);
    innerStream.write(0, 2);
    innerStream.write(0, 3);
    innerStream.write(seq, 4);
    innerStream.write("liveui", 5);
    innerStream.write("sendMessage", 6);
    innerStream.write(bodyStream.toUint8List(), 7);
    innerStream.write(0, 8);
    // 抓包帧里还有两个空 map（tag9/tag10），补齐后总长度与浏览器一致
    innerStream.write(<String, String>{}, 9);
    innerStream.write(<String, String>{}, 10);
    var inner = innerStream.toUint8List();

    // payload = 4 字节大端长度（含自身）+ 内层，抓包帧就是这个格式
    var length = inner.length + 4;
    var payload = Uint8List(4 + inner.length);
    payload[0] = (length >> 24) & 0xFF;
    payload[1] = (length >> 16) & 0xFF;
    payload[2] = (length >> 8) & 0xFF;
    payload[3] = length & 0xFF;
    payload.setAll(4, inner);

    var cmdStream = TarsOutputStream();
    cmdStream.write(3, 0);
    cmdStream.write(payload, 1);
    cmdStream.write(0, 2);
    var tracePrefix = guid.length >= 16 ? guid.substring(0, 16) : guid;
    cmdStream.write("$tracePrefix:$tracePrefix:0:0", 3);
    cmdStream.write(0, 4);
    cmdStream.write(0, 5);
    cmdStream.write(md5.convert(payload).toString(), 6);
    return cmdStream.toUint8List();
  }

  @override
  Future<String?> sendDanmaku(String message) async {
    if (!canSendDanmaku) {
      return "请先登录虎牙账号";
    }
    var socket = _sendSocket ?? webScoketUtils;
    if (socket?.status != SocketStatus.connected) {
      return "发送通道连接中，请稍候重试";
    }
    var seq = ++_seq;
    _pendingSeq = seq;
    var completer = Completer<String?>();
    _sendCompleter = completer;
    try {
      var frame = buildSendFrame(message, seq);
      socket?.sendMessage(frame);
      return await completer.future.timeout(
        const Duration(seconds: 6),
        onTimeout: () => "发送超时，请确认登录状态和网络",
      );
    } catch (e) {
      return "发送失败：$e";
    } finally {
      _sendCompleter = null;
      _pendingSeq = null;
    }
  }

  @override
  Future stop() async {
    _running = false;
    _headlineGeneration++;
    _superChats.clear();
    onMessage = null;
    onClose = null;
    webScoketUtils?.close();
    _sendSocket?.close();
  }

  void _dispatchPush(int uri, List<int> payload, String groupId) {
    if (uri == HuyaSuperChatDecoder.messageUri) {
      // HYPushMessage tag4=sGroupId；条目里的用户房间号不是路由。
      final presenterUid = danmakuArgs.presenterUid;
      if (presenterUid > 0 && groupId == 'live:$presenterUid') {
        _emitSuperChats(
          _superChats.decodePanel(payload, presenterUid: presenterUid),
        );
      }
    } else if (uri == 1400) {
      HYMessage messageNotice = HYMessage();
      messageNotice.readFrom(TarsInputStream(Uint8List.fromList(payload)));
      var uname = messageNotice.userInfo.nickName;
      var content = messageNotice.content;

      var color = messageNotice.bulletFormat.fontColor;

      // 正文里的 [大笑] / /{dx 之类标记换成图片表情
      final spans = HuyaEmoticon.parseSpans(content);
      onMessage?.call(
        LiveMessage(
          type: LiveMessageType.chat,
          color: color <= 0
              ? LiveMessageColor.white
              : LiveMessageColor.numberToColor(color),
          message: content,
          userName: uname,
          spans: spans,
          imageUrls: spans
              ?.where((e) => e.isImage)
              .map((e) => e.imageUrl!)
              .toList(),
          isRoomEmoji: spans != null && HuyaEmoticon.isOnlyEmoticon(spans),
        ),
      );
    } else if (uri == 8006) {
      int online = 0;
      var s = TarsInputStream(Uint8List.fromList(payload));
      online = s.read(online, 0, false);
      onMessage?.call(
        LiveMessage(
          type: LiveMessageType.online,
          data: online,
          color: LiveMessageColor.white,
          message: "",
          userName: "",
        ),
      );
    }
  }

  void decodeMessage(List<int> data) {
    try {
      var stream = TarsInputStream(Uint8List.fromList(data));
      var type = stream.read(0, 0, false);
      if (type == 7) {
        stream = TarsInputStream(stream.readBytes(1, false));
        final push = HYPushMessage()..readFrom(stream);
        final group = push.uri == HuyaSuperChatDecoder.messageUri
            ? stream.readString(4, false)
            : '';
        _dispatchPush(push.uri, push.msg, group);
      } else if (type == 22) {
        final batch = _HuyaPushBatch()
          ..readFrom(TarsInputStream(stream.readBytes(1, false)));
        for (final item in batch.items) {
          try {
            _dispatchPush(item.uri, item.payload, batch.groupId);
          } catch (e) {
            // 一个损坏的业务包不能吞掉同批次后面的普通弹幕。
            CoreLog.error(e);
          }
        }
      } else if (type == 4) {
        // 通用调用的回执：cmdId=4，payload 里 tag4=序号、tag6=方法名。
        // 注意 payload 可能带 4 字节大端长度前缀（浏览器回执就是这种），要先剥掉
        var payload = stream.readBytes(1, false);
        if (payload.length >= 4) {
          var prefixLength =
              (payload[0] << 24) |
              (payload[1] << 16) |
              (payload[2] << 8) |
              payload[3];
          if (prefixLength == payload.length) {
            payload = payload.sublist(4);
          }
        }
        var ps = TarsInputStream(Uint8List.fromList(payload));
        var seq = ps.read(0, 4, false);
        var method = ps.read("", 6, false);
        if (method == "sendMessage" && seq == _pendingSeq) {
          // 回执里若出现 STATUS_RESULT_DESC，说明其实是错误回执，把原因带回界面
          var text = utf8.decode(payload, allowMalformed: true);
          var errorIndex = text.indexOf("STATUS_RESULT_DESC");
          String? error;
          if (errorIndex >= 0) {
            var tail = text.substring(errorIndex + "STATUS_RESULT_DESC".length);
            // 跳过控制字符后取错误描述
            error = tail.replaceAll(RegExp(r"[^ -~一-龥]+"), " ").trim();
            if (error.isEmpty) {
              error = "发送失败（服务端返回错误）";
            }
          }
          // 已知凭据失效回执归一化；未知业务错误继续展示原始原因。
          if (error != null && isSessionExpiredError(error)) {
            error = "虎牙登录已失效，请重新登录";
          }
          _sendCompleter?.complete(error);
        }
      }
    } catch (e) {
      CoreLog.error(e);
    }
  }
}

// 官网 WSPushMessage_V2：tag0 分组，tag1 为不同 URI 的业务消息列表。
class _HuyaPushBatch extends TarsStruct {
  String groupId = '';
  List<_HuyaPushItem> items = [];

  @override
  void readFrom(TarsInputStream stream) {
    groupId = stream.readString(0, false);
    items = stream.readList<_HuyaPushItem>([_HuyaPushItem()], 1, false);
  }

  @override
  Object deepCopy() => _HuyaPushBatch();
  @override
  void writeTo(TarsOutputStream stream) {}
  @override
  void displayAsString(StringBuffer buffer, int level) {}
}

class _HuyaPushItem extends TarsStruct {
  int uri = 0;
  List<int> payload = [];

  @override
  void readFrom(TarsInputStream stream) {
    uri = stream.readInt(0, false);
    payload = stream.readBytes(1, false);
  }

  @override
  Object deepCopy() => _HuyaPushItem();
  @override
  void writeTo(TarsOutputStream stream) {}
  @override
  void displayAsString(StringBuffer buffer, int level) {}
}
