import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:brotli/brotli.dart';
import 'package:dio/dio.dart';
// 这个文件 import 了 dart:io，直接用 HttpClient 会被 dart:io 的同名类遮蔽
import 'package:simple_live_core/src/common/http_client.dart' as core_http;
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/convert_helper.dart';
import 'package:simple_live_core/src/common/web_socket_util.dart';

import '../common/binary_writer.dart';

class BiliBiliDanmakuArgs {
  final int roomId;
  final String token;
  final String buvid;
  final String serverHost;
  final int uid;
  final String cookie;
  BiliBiliDanmakuArgs({
    required this.roomId,
    required this.token,
    required this.serverHost,
    required this.buvid,
    required this.uid,
    required this.cookie,
  });
  @override
  String toString() {
    return json.encode({
      "roomId": roomId,
      "token": token,
      "serverHost": serverHost,
      "buvid": buvid,
      "uid": uid,
      "cookie": cookie,
    });
  }
}

class BiliBiliDanmaku implements LiveDanmaku {
  @override
  int heartbeatTime = 60 * 1000;

  @override
  Function(LiveMessage msg)? onMessage;
  @override
  Function(String msg)? onClose;
  @override
  Function()? onReady;

  //String serverUrl = "wss://broadcastlv.chat.bilibili.com/sub";

  WebScoketUtils? webScoketUtils;
  late BiliBiliDanmakuArgs danmakuArgs;

  /// 房间专属表情：触发关键词（形如 "[妙]"）→ 图片地址
  ///
  /// 弹幕本身带的 URL 只是兜底来源之一，房间表情（含舰队/粉丝牌表情）
  /// 大多只在文本里给关键词，需要靠 GetEmoticons 拉到的这张表还原成图片。
  Map<String, ({String url, double scale})> _roomEmojiMap = const {};


  /// 直播间专属表情（emoticon_unique 前缀 room_）的图片地址，
  /// 用于识别「整条都是房间专属图片表情」的弹幕。
  Set<String> _roomEmojiUrls = <String>{};
  @override
  Future start(dynamic args) async {
    danmakuArgs = args as BiliBiliDanmakuArgs;
    // 重连/刷新时会再次调用 start()：必须先关闭旧连接，
    // 否则旧 socket 仍在接收消息 → 聊天列表和滚动弹幕都会重复出现
    webScoketUtils?.close();
    webScoketUtils = WebScoketUtils(
      url: "wss://${args.serverHost}/sub",
      heartBeatTime: heartbeatTime,
      headers: args.cookie.isEmpty
          ? null
          : {
              "cookie": args.cookie,
            },
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
    CoreLog.d(
      "B站弹幕：host=${args.serverHost} roomId=${args.roomId} uid=${args.uid} "
      "token=${args.token.isEmpty ? "空" : "有"} buvid=${args.buvid.isEmpty ? "空" : "有"} "
      "cookie=${args.cookie.isEmpty ? "无" : "有"}",
    );
    // 房间表情表是异步拉的，晚到一点点不影响：先连弹幕，拿到后新消息就能用
    unawaited(_loadRoomEmoticons(danmakuArgs));
    webScoketUtils?.connect();
  }

  /// 拉「本房间可用的表情包」：「关键词 → 图片地址」
  ///
  /// 接口：GET https://api.live.bilibili.com/xlive/web-ucenter/v2/emoticon/GetEmoticons
  /// 需要登录 Cookie（未登录返回 {"code":-101,"message":"账号未登录"}），
  /// 失败时静默跳过——弹幕自带 URL 的那部分表情仍然能渲染。
  Future<void> _loadRoomEmoticons(BiliBiliDanmakuArgs args) async {
    try {
      var url =
          "https://api.live.bilibili.com/xlive/web-ucenter/v2/emoticon/GetEmoticons"
          "?room_id=${args.roomId}&platform=pc";
      var result = await core_http.HttpClient.instance.getRaw(
        url,
        header: {
          if (args.cookie.isNotEmpty) "Cookie": args.cookie,
          "User-Agent": BiliBiliSite.kDefaultUserAgent,
          "Referer": "https://live.bilibili.com/${args.roomId}",
        },
      );
      var obj = json.decode(result.body);
      var code = asT<int?>(obj["code"]) ?? -1;
      if (code != 0) {
        CoreLog.d("B站房间表情：接口返回 code=$code，跳过（未登录或无权限）");
        return;
      }
      var map = <String, ({String url, double scale})>{};
      var roomUrls = <String>{};
      var packages = obj["data"]?["data"];
      if (packages is List) {
        for (var pkg in packages) {
          if (pkg is! Map) {
            continue;
          }
          var emoticons = pkg["emoticons"];
          if (emoticons is! List) {
            continue;
          }
          for (var emot in emoticons) {
            if (emot is! Map) {
              continue;
            }
            var imageUrl = _normalizeEmojiUrl(emot["url"]);
            if (imageUrl.isEmpty) {
              continue;
            }
            var token = _normalizeEmojiToken(emot["emoji"]?.toString() ?? "");
            if (token.isEmpty) {
              continue;
            }
            map[token] = (
              url: imageUrl,
              scale: _emojiScaleFromSize(emot["width"], emot["height"]),
            );
            // 接口里「全站表情」和「房间专属表情」混在一起返回，
            // 只有 room_ 前缀的是本房间专属的
            var unique = emot["emoticon_unique"]?.toString() ?? "";
            if (unique.startsWith("room_")) {
              roomUrls.add(imageUrl);
            }
          }
        }
      }
      _roomEmojiMap = map;
      _roomEmojiUrls = roomUrls;
      CoreLog.d(
        "B站房间表情：拉取到 ${map.length} 个表情（roomId=${args.roomId}）："
        "${map.keys.take(120).join(" ")}",
      );
    } catch (e) {
      CoreLog.d("B站房间表情：拉取失败 $e");
    }
  }

  /// 图片地址统一成 https（接口给的是 http://i0.hdslb.com/...，App 不允许明文 http）
  String _normalizeEmojiUrl(dynamic raw) {
    var value = raw?.toString().trim() ?? "";
    if (value.startsWith("http://")) {
      value = "https://${value.substring(7)}";
    }
    return value;
  }

  /// 表情图片相对普通表情的放大倍数
  ///
  /// B站普通表情约 48px 高，房间/大表情 100~162px；聊天区一行文字才十几 px，
  /// 按真实像素还原会顶出两行多，所以压成「约 2 行文字高」比较接近官方观感。
  double _emojiScaleFromSize(dynamic width, dynamic height) {
    final h = double.tryParse(height?.toString() ?? "") ?? 0;
    if (h <= 0) {
      return 1;
    }
    return (h / 80).clamp(1.0, 2.2);
  }

  /// 统一成 "[关键词]" 形态（接口里的 emoji 有时带方括号、有时不带）
  String _normalizeEmojiToken(String raw) {
    var token = raw.trim();
    if (token.isEmpty) {
      return "";
    }
    token = token.replaceAll("[", "").replaceAll("]", "").trim();
    if (token.isEmpty) {
      return "";
    }
    return "[$token]";
  }

  void joinRoom(BiliBiliDanmakuArgs args) {
    var joinData = encodeData(
      json.encode({
        "uid": args.uid,
        "roomid": args.roomId,
        "protover": 3,
        "buvid": args.buvid,
        "platform": "web",
        "type": 2,
        "key": args.token,
      }),
      7,
    );
    CoreLog.d("B站弹幕：发送 join 包（${joinData.length} 字节）");
    webScoketUtils?.sendMessage(joinData);
  }

  @override
  void heartbeat() {
    webScoketUtils?.sendMessage(encodeData(
      "",
      2,
    ));
  }

  @override
  Future stop() async {
    onMessage = null;
    onClose = null;
    webScoketUtils?.close();
  }

  @override
  bool get canSendDanmaku => true;

  /// 从 cookie 里取 csrf（bili_jct）
  String? _csrfToken() {
    for (var part in danmakuArgs.cookie.split(';')) {
      var kv = part.trim().split('=');
      if (kv.length >= 2 && kv[0].trim() == 'bili_jct') {
        return kv.sublist(1).join('=').trim();
      }
    }
    return null;
  }

  /// 把平台返回的错误码翻成人话
  String _sendErrorText(int code, String? message) {
    switch (code) {
      case 1003212:
        return "发送太频繁了，请稍后再试";
      case -101:
      case -400:
        return "登录状态已失效，请重新登录哔哩哔哩";
      case 1003:
        return "发送失败：内容可能包含敏感词";
      case 10030:
        return "发送失败：弹幕内容太长";
      default:
        if (message != null && message.isNotEmpty) {
          return "发送失败：" + message;
        }
        return "发送失败（错误码 " + code.toString() + "）";
    }
  }

  /// 发送弹幕
  ///
  /// 走官方 HTTP 接口（POST /msg/send）。
  /// 注意：不要在弹幕长连接上发 SEND_DANMU —— 服务器会直接断开连接，
  /// 而且拿不到回应（实测就是一直重连 + 发送超时）。
  /// 该接口需要 cookie 里的 bili_jct 作为 csrf，失败时有明确错误码。
  @override
  Future<String?> sendDanmaku(String message) async {
    var text = message.trim();
    if (text.isEmpty) {
      return "弹幕内容不能为空";
    }
    if (danmakuArgs.cookie.isEmpty || danmakuArgs.uid <= 0) {
      return "请先登录哔哩哔哩";
    }
    var csrf = _csrfToken();
    if (csrf == null || csrf.isEmpty) {
      return "登录信息里缺少 csrf，请重新登录哔哩哔哩";
    }
    try {
      var res = await core_http.HttpClient.instance.dio.post(
        "https://api.live.bilibili.com/msg/send",
        data: {
          "bubble": "0",
          "color": "16777215",
          "fontsize": "25",
          "mode": "1",
          "msg": text,
          "rnd": DateTime.now().millisecondsSinceEpoch ~/ 1000,
          "roomid": danmakuArgs.roomId.toString(),
          "csrf": csrf,
          "csrf_token": csrf,
        },
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          responseType: ResponseType.plain,
          validateStatus: (status) => status != null && status < 500,
          headers: {
            "cookie": danmakuArgs.cookie,
            "referer": "https://live.bilibili.com/" +
                danmakuArgs.roomId.toString(),
            "user-agent":
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
          },
        ),
      );
      var body = json.decode(res.data.toString());
      var code = asT<int?>(body["code"]) ?? -1;
      if (code == 0) {
        return null;
      }
      var msg = body["message"]?.toString();
      if (msg == null || msg.isEmpty) {
        msg = body["msg"]?.toString();
      }
      return _sendErrorText(code, msg);
    } catch (e) {
      CoreLog.error(e);
      return "发送失败：请检查网络后重试";
    }
  }

  List<int> encodeData(String msg, int action) {
    var data = utf8.encode(msg);
    //头部长度固定16
    var length = data.length + 16;
    var buffer = Uint8List(length);

    var writer = BinaryWriter([]);

    //数据包长度
    writer.writeInt(buffer.length, 4);
    //数据包头部长度,固定16
    writer.writeInt(16, 2);

    //协议版本，0=JSON,1=Int32,2=Buffer
    writer.writeInt(0, 2);

    //操作类型
    writer.writeInt(action, 4);

    //数据包头部长度,固定1

    writer.writeInt(1, 4);

    writer.writeBytes(data);

    return writer.buffer;
  }

  void decodeMessage(List<int> data) {
    try {
      //协议版本。0为JSON，可以直接解析；1为房间人气值,Body为4位Int32；2为压缩过Buffer，需要解压再处理
      int protocolVersion = readInt(data, 6, 2);
      //操作类型。3=心跳回应，内容为房间人气值；5=通知，弹幕、广播等全部信息；8=进房回应，空
      int operation = readInt(data, 8, 4);
      //内容
      var body = data.skip(16).toList();
      if (operation == 3) {
        var online = readInt(body, 0, 4);

        onMessage?.call(
          LiveMessage(
            type: LiveMessageType.online,
            data: online,
            color: LiveMessageColor.white,
            message: "",
            userName: "",
          ),
        );
      } else if (operation == 5) {
        if (protocolVersion == 2) {
          body = zlib.decode(body);
        } else if (protocolVersion == 3) {
          body = brotli.decode(body);
        }

        var text = utf8.decode(body, allowMalformed: true);

        var group =
            text.split(RegExp(r"[\x00-\x1f]+", unicode: true, multiLine: true));
        for (var item
            in group.where((x) => x.length > 2 && x.startsWith('{'))) {
          parseMessage(item);
        }
      }
    } catch (e) {
      CoreLog.error(e);
    }
  }

  /// 从弹幕 info 里抽「表情文本 → 图片URL」映射
  ///
  /// B站有两种形态：
  /// 1) 纯表情弹幕：整条消息就是一个表情 key，URL 在 info[0][13]["url"]
  /// 2) 文字混排：info[0][15]["extra"] 里带 emots 表，key 会出现在消息里
  Map<String, ({String url, double scale})> _extractEmojiMap(
    dynamic info,
    String message,
  ) {
    final emojiMap = <String, ({String url, double scale})>{};

    void addEmoji(String key, dynamic url, {double scale = 1}) {
      final emojiKey = key.trim();
      final value = _normalizeEmojiUrl(url);
      if (emojiKey.isEmpty || value.isEmpty) {
        return;
      }
      emojiMap[emojiKey] = (url: value, scale: scale);
    }

    final trimmed = message.trim();

    // 房间专属表情：只在消息里真的出现这个关键词时才加进来，避免键表膨胀
    for (final entry in _roomEmojiMap.entries) {
      if (message.contains(entry.key)) {
        emojiMap[entry.key] = entry.value;
        continue;
      }
      // 实测房间表情弹幕的文本不带方括号：msg=[善意的笑]、info[0][13].emoticon_unique=room_10265_5562
      final raw = entry.key.substring(1, entry.key.length - 1);
      if (raw.isNotEmpty && trimmed == raw) {
        emojiMap[raw] = entry.value;
      }
    }

    try {
      if (info is List &&
          info.length > 13 &&
          info[0] is List &&
          info[0].length > 13 &&
          info[0][13] is Map) {
        final emot = info[0][13] as Map;
        // 纯表情弹幕：文本就是表情名（可能带方括号也可能不带），URL 直接给在 info[0][13]
        if (trimmed.isNotEmpty) {
          addEmoji(
            trimmed,
            emot["url"],
            scale: _emojiScaleFromSize(emot["width"], emot["height"]),
          );
        }
      }
    } catch (_) {}

    try {
      if (info is List &&
          info.isNotEmpty &&
          info[0] is List &&
          info[0].length > 15 &&
          info[0][15] is Map) {
        final extra = info[0][15]["extra"];
        if (extra is String && extra.isNotEmpty) {
          final extraObj = json.decode(extra);
          final emots = extraObj["emots"];
          if (emots is Map) {
            for (final entry in emots.entries) {
              final key = entry.key.toString();
              if (key.isEmpty || !message.contains(key)) {
                continue;
              }
              final emot = entry.value;
              if (emot is Map) {
                addEmoji(
                  key,
                  emot["url"],
                  scale: _emojiScaleFromSize(emot["width"], emot["height"]),
                );
              }
            }
          }
        }
      }
    } catch (_) {}

    return emojiMap;
  }

  /// 判断这条弹幕是不是「整条都是直播间专属图片表情」
  ///
  /// 依据两条，任一命中即可：
  /// 1. 纯表情弹幕的 info[0][13].emoticon_unique 以 room_ 开头（最可靠，不依赖表情表是否拉到）；
  /// 2. 片段全是图片，且每个图片地址都命中本房间的 room_ 表情（表拉取成功时的兜底）。
  bool _isRoomEmojiDanmaku(dynamic info, List<LiveMessageSpan> spans) {
    try {
      final info0 = (info is List && info.isNotEmpty) ? info[0] : null;
      final emojiInfo =
          (info0 is List && info0.length > 13) ? info0[13] : null;
      if (emojiInfo is Map) {
        final unique = emojiInfo["emoticon_unique"]?.toString() ?? "";
        if (unique.startsWith("room_")) {
          return true;
        }
      }
    } catch (_) {}
    if (spans.isEmpty || !spans.every((span) => span.isImage)) {
      return false;
    }
    return spans.every(
      (span) => _roomEmojiUrls.contains((span.imageUrl ?? "").trim()),
    );
  }

  /// 按「表情 key 长的优先」把消息切成 文字/图片 片段
  List<LiveMessageSpan> _extractSpans(dynamic info, String message) {
    final emojiMap = _extractEmojiMap(info, message);
    if (emojiMap.isEmpty) {
      return const [];
    }
    final spans = <LiveMessageSpan>[];
    final keys = emojiMap.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    var index = 0;
    while (index < message.length) {
      String? matchedKey;
      for (final key in keys) {
        if (key.isEmpty) {
          continue;
        }
        if (message.startsWith(key, index)) {
          matchedKey = key;
          break;
        }
      }
      if (matchedKey == null) {
        final nextIndex = _nextEmojiIndex(message, keys, index + 1);
        spans.add(LiveMessageSpan.text(message.substring(index, nextIndex)));
        index = nextIndex;
        continue;
      }
      final emoji = emojiMap[matchedKey];
      if (emoji != null && emoji.url.isNotEmpty) {
        spans.add(
          LiveMessageSpan.image(
            emoji.url,
            imageScale: emoji.scale == 1 ? null : emoji.scale,
          ),
        );
      }
      index += matchedKey.length;
    }
    return spans;
  }

  int _nextEmojiIndex(String message, List<String> keys, int start) {
    var next = message.length;
    for (final key in keys) {
      if (key.isEmpty) {
        continue;
      }
      final index = message.indexOf(key, start);
      if (index >= 0 && index < next) {
        next = index;
      }
    }
    return next;
  }

  void parseMessage(String jsonMessage) {
    try {
      var obj = json.decode(jsonMessage);
      var cmd = obj["cmd"].toString();
      if (cmd.contains("DANMU_MSG")) {
        if (obj["info"] != null && obj["info"].length != 0) {
          var message = obj["info"][1].toString();
          var color = asT<int?>(obj["info"][0][3]) ?? 0;
          if (obj["info"][2] != null && obj["info"][2].length != 0) {
            var username = obj["info"][2][1].toString();
            // info[2][0] = 发送者 uid，用来标记「自己发的弹幕」
            var senderUid = asT<int?>(obj["info"][2][0]) ?? 0;
            // 表情弹幕：把表情图片插回原文位置（纯表情 / 文字混排都走这里）
            final spans = _extractSpans(obj["info"], message);
            final imageUrls = spans
                .where((span) => span.isImage)
                .map((span) => span.imageUrl!.trim())
                .toList();
            var liveMsg = LiveMessage(
              isRoomEmoji: _isRoomEmojiDanmaku(obj["info"], spans),
              type: LiveMessageType.chat,
              userName: username,
              message: message,
              isSelf: senderUid != 0 && senderUid == danmakuArgs.uid,
              imageUrls: imageUrls.isEmpty ? null : imageUrls,
              spans: spans.isEmpty ? null : spans,
              color: color == 0
                  ? LiveMessageColor.white
                  : LiveMessageColor.numberToColor(color),
            );
            onMessage?.call(liveMsg);
          }
        }
      } else if (cmd == "SUPER_CHAT_MESSAGE") {
        if (obj["data"] == null) {
          return;
        }

        LiveSuperChatMessage sc = LiveSuperChatMessage(
          backgroundBottomColor:
              obj["data"]["background_bottom_color"].toString(),
          backgroundColor: obj["data"]["background_color"].toString(),
          endTime: DateTime.fromMillisecondsSinceEpoch(
            obj["data"]["end_time"] * 1000,
          ),
          face: "${obj["data"]["user_info"]["face"]}@200w.jpg",
          message: obj["data"]["message"].toString(),
          price: obj["data"]["price"],
          startTime: DateTime.fromMillisecondsSinceEpoch(
            obj["data"]["start_time"] * 1000,
          ),
          userName: obj["data"]["user_info"]["uname"].toString(),
        );
        var liveMsg = LiveMessage(
          type: LiveMessageType.superChat,
          userName: "SUPER_CHAT_MESSAGE",
          message: "SUPER_CHAT_MESSAGE",
          color: LiveMessageColor.white,
          data: sc,
        );
        onMessage?.call(liveMsg);
      }
    } catch (e) {
      CoreLog.error(e);
    }
  }

  int readInt(List<int> buffer, int start, int len) {
    var bytes =
        Uint8List.fromList(buffer.getRange(start, start + len).toList());
    var byteBuffer = bytes.buffer;
    var data = ByteData.view(byteBuffer);
    var result = 0;

    if (len == 1) {
      result = data.getUint8(0);
    }
    if (len == 2) {
      result = data.getInt16(0, Endian.big);
    }
    if (len == 4) {
      result = data.getInt32(0, Endian.big);
    }
    if (len == 8) {
      result = data.getInt64(0, Endian.big);
    }

    return result;
  }
}
