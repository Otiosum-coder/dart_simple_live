import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:simple_live_core/simple_live_core.dart';
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
  DouyuDanmakuArgs({
    required this.roomId,
    this.uid = "",
    this.devid = "",
    this.nickname = "",
    this.avatar = "",
    this.username = "",
  });
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
  /// 是否已收到 loginres（登录成功），而不是「连接已建立」
  bool _ready = false;
  Completer<void>? _loginCompleter;

  @override
  Future start(dynamic args) async {
    danmakuArgs = args is DouyuDanmakuArgs
        ? args
        : DouyuDanmakuArgs(roomId: args.toString());
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
        _ready = false;
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

  // 结论（2026-10 全面实测）：独立连接无法在斗鱼发言，服务器把 chatmsg 静默丢弃。
  // 已逐项排除（每一项都对应一次真实探测，不是推测）：
  //   1. 包体：与网页抓包逐字节同构（包类型 690 + type@=chatmsg + rid/uid/nn/txt/cid/
  //      ic/level/sahf/cst/bnn/bl/brid/hc/lk/dms/pdg/pdk/ext/ufs/if）
  //   2. 账号：改用与网页完全相同的账号（loginres 回显同一 userid），已绑手机
  //      (acf_phonestatus=1)、未禁言 (is_illegal=0)、房间有发言权限
  //   3. 鉴权字段：username / uid / ver=20220825 / aver / ct / dfl 全部带上；
  //      stt=dmjwt / token=dmjwt / dmjwt_token cookie / 握手 Cookie+Origin 都试过
  //   4. 分组：joingroup gid=1（网页发送连接用的就是 gid=1）与 gid=-9999 都试过；
  //      也复刻了网页的 sub/mt@=dfansrk、sub/mt@=fansnum 订阅帧
  //   5. 包类型：689 与 690 都试过；长度按 UTF-8 字节数（已修正 String.length 的缺陷）
  //   6. 测量：双连接旁观者方案（旁观连接 6 秒能收到房间内别人的弹幕，
  //      测试期间共 9 条），但我们发出的两条（ASCII + 中文）旁观者一条都收不到
  //   7. 旁证：最流行的第三方斗鱼工具（DouyuEx-RL）的"循环发送弹幕"实现是
  //      ChatSend-txt.value=文本 → ChatSend-button.click()，即驱动网页输入框，
  //      它们同样没有复刻协议 —— 说明发送依赖页面会话上下文（网页 JS 读 dmjwt_token
  //      后在混淆代码里完成认证），第三方独立连接拿不到。
  // 因此斗鱼保持「只读弹幕」。若日后一定要发，只能内嵌 WebView 驱动网页（DouyuEx 思路）。
  @override
  bool get canSendDanmaku => false;

  Completer<String?>? _sendCompleter;
  String? _sendingText;

  /// 斗鱼 STT 转义：@ 和 / 是分隔符，必须先转义
  String scapeSlashAt(String str) {
    return str.replaceAll("@", "@A").replaceAll("/", "@S");
  }

  String _randomHex(int length) {
    var random = Random();
    var buffer = StringBuffer();
    for (var i = 0; i < length; i++) {
      buffer.write(random.nextInt(16).toRadixString(16));
    }
    return buffer.toString();
  }

  @override
  Future<String?> sendDanmaku(String message) async {
    var text = message.trim();
    if (text.isEmpty) {
      return "弹幕内容不能为空";
    }
    if (danmakuArgs.uid.isEmpty) {
      return "请先登录斗鱼";
    }
    if (_sendCompleter != null) {
      return "上一条弹幕还在发送中，请稍后再试";
    }
    var completer = Completer<String?>();
    _sendCompleter = completer;
    _sendingText = text;
    // 网页版真实格式（抓包解码得到，2026-10 实测）：
    //   type@=chatmsg/rid@=房间/uid@=uid/nn@=昵称/txt@=内容/cid@=32位随机hex/
    //   ic@=头像/level@=等级/sahf@=0/cst@=毫秒时间戳/.../ufs@=1/if@=1/
    // 注意：不是 chatmessage、不是 receiver/content，上行包类型是 690
    var body = "type@=chatmsg/rid@=${danmakuArgs.roomId}"
        "/uid@=${danmakuArgs.uid}"
        "/nn@=${scapeSlashAt(danmakuArgs.nickname)}"
        "/txt@=${scapeSlashAt(text)}"
        "/cid@=${_randomHex(32)}"
        "/ic@=${scapeSlashAt(danmakuArgs.avatar)}"
        "/level@=0/sahf@=0/cst@=${DateTime.now().millisecondsSinceEpoch}"
        "/bnn@=/bl@=0/brid@=0/hc@=/lk@=/dms@=4/pdg@=27/pdk@=75"
        "/ext@=/ufs@=1/if@=1/";
    webScoketUtils?.sendMessage(serializeDouyu(body, type: 690));
    try {
      // 优先用服务器回显确认（斗鱼会把自己的弹幕推回来）
      return await completer.future.timeout(const Duration(seconds: 4));
    } on TimeoutException {
      _sendCompleter = null;
      _sendingText = null;
      // 关键：没有可信回执就不能算成功。
      // 之前这里会本地补一条自己的弹幕并返回成功，导致「只有自己能看到」的假成功。
      if (!_ready) {
        return "发送失败：斗鱼弹幕未登录成功（未收到 loginres）";
      }
      return "未收到服务器回显，无法确认弹幕是否发送成功";
    }
  }

  @override
  Future stop() async {
    onMessage = null;
    onClose = null;
    webScoketUtils?.close();
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
        _ready = true;
        var login = _loginCompleter;
        if (login != null && !login.isCompleted) {
          login.complete();
        }
        return;
      }
      // 发送过程中的错误包（如果有）
      if (type == "error" && _sendCompleter != null) {
        var msg = jsonData["msg"]?.toString() ??
            jsonData["txt"]?.toString() ??
            "服务器返回错误";
        _sendCompleter?.complete("发送失败：$msg");
        _sendCompleter = null;
        _sendingText = null;
        return;
      }
      //斗鱼好像不会返回人气值
      if (type == "chatmsg") {
        // 自己发的弹幕回显 = 发送成功（斗鱼没有发送回执）
        var txt = jsonData["txt"]?.toString() ?? "";
        if (_sendCompleter != null && _sendingText != null && txt == _sendingText) {
          _sendCompleter?.complete(null);
          _sendCompleter = null;
          _sendingText = null;
        }
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
