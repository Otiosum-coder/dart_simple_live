import 'dart:typed_data';

import 'package:html_unescape/html_unescape.dart';
import 'package:tars_dart/tars/codec/tars_input_stream.dart';
import 'package:tars_dart/tars/codec/tars_output_stream.dart';
import 'package:tars_dart/tars/codec/tars_struct.dart';
import 'package:tars_dart/tars/tup/tars_uni_packet.dart';

import '../model/live_message.dart';

/// 虎牙 URI 2001314：GameEventMessageBoardPanel。
/// 字段以官网 HUYA.GameEventMessageBoardInfo / Messageboard 组件为准：
/// iCostPay / 100 的单位是虎牙币，iCost 不能据字段名推断成人民币。
class HuyaSuperChatDecoder {
  static const messageUri = 2001314;
  static const maxRememberedMessages = 2048;

  final DateTime Function() _now;
  final _seen = <String, DateTime>{};
  final _unescape = HtmlUnescape();

  HuyaSuperChatDecoder({DateTime Function()? now}) : _now = now ?? DateTime.now;

  void clear() => _seen.clear();

  List<LiveSuperChatMessage> decodePanel(
    List<int> payload, {
    required int presenterUid,
  }) {
    final entries = TarsInputStream(
      Uint8List.fromList(payload),
    ).readList<_MessageBoardInfo>([_MessageBoardInfo()], 1, false);
    return _decodeEntries(entries, presenterUid);
  }

  /// 官网 wupui.getHeadLineMessageBoard 的 WUPv3 响应。
  List<LiveSuperChatMessage> decodeInitialResponse(
    List<int> payload, {
    required int presenterUid,
  }) {
    final packet = TarsUniPacket()..decode(Uint8List.fromList(payload));
    if (packet.getTarsResultCode() != 0 || !packet.containsKey('tRsp')) {
      throw const FormatException('虎牙头条列表响应失败');
    }
    final response = packet.getByClass('tRsp', _HeadlineResponse());
    return _decodeEntries(response.panel.entries, presenterUid);
  }

  List<LiveSuperChatMessage> _decodeEntries(
    List<_MessageBoardInfo> entries,
    int presenterUid,
  ) {
    final now = _now();
    _seen.removeWhere((_, end) => !end.isAfter(now));
    // 调用者必须先校验外层 live:<主播 UID> 分组或绑定请求的主播。
    if (presenterUid <= 0) return [];
    final result = <LiveSuperChatMessage>[];
    for (final entry in entries) {
      // 条目内的用户/房间字段并非路由，不能据此排除正常留言。
      if (entry.messageId <= 0) continue;
      final text = _unescape.convert(entry.content).trim();
      if (text.isEmpty ||
          entry.totalSeconds <= 0 ||
          entry.remainingSeconds <= 0) {
        continue;
      }
      final remaining = entry.remainingSeconds > entry.totalSeconds
          ? entry.totalSeconds
          : entry.remainingSeconds;
      final endTime = now.add(Duration(seconds: remaining));
      final id = 'huya:$presenterUid:${entry.messageId}';
      if (_seen.containsKey(id)) continue;

      final colors = switch (entry.level) {
        2 => ('#EDE9FE', '#7C3AED'),
        3 => ('#FFEDD5', '#C2410C'),
        4 => ('#FEF3C7', '#A16207'),
        _ => ('#DBEAFE', '#2563EB'),
      };
      final userName = _unescape.convert(entry.sender.nickName).trim();
      result.add(
        LiveSuperChatMessage(
          id: id,
          userName: userName.isEmpty ? '虎牙用户' : userName,
          face: _avatarUrl(entry.sender.avatar),
          message: text,
          // 跨平台的 price 仍保留人民币语义；虎牙币用独立标签展示。
          price: 0,
          priceLabel: entry.hasCostPay && entry.costPay >= 0
              ? '${_coinAmount(entry.costPay)}虎牙币'
              : '上头条',
          startTime: now.subtract(
            Duration(seconds: entry.totalSeconds - remaining),
          ),
          endTime: endTime,
          backgroundColor: colors.$1,
          backgroundBottomColor: colors.$2,
        ),
      );
      // 校验房间、正文、时长后才占用 ID，空/串房消息不能挡住有效消息。
      _seen[id] = endTime;
      while (_seen.length > maxRememberedMessages) {
        _seen.remove(_seen.keys.first);
      }
    }
    return result;
  }

  String _coinAmount(int hundredths) {
    final integer = hundredths ~/ 100;
    final fraction = hundredths % 100;
    if (fraction == 0) return '$integer';
    final decimals = fraction
        .toString()
        .padLeft(2, '0')
        .replaceFirst(RegExp(r'0$'), '');
    return '$integer.$decimals';
  }

  String _avatarUrl(String raw) {
    final value = raw.trim();
    if (value.startsWith('//')) return 'https:$value';
    final uri = Uri.tryParse(value);
    return uri != null &&
            (uri.scheme == 'https' || uri.scheme == 'http') &&
            uri.host.isNotEmpty
        ? value
        : '';
  }
}

// 本地 Tars 的单字节整数使用 getUint8，头条的 int32/int64 字段仍须
// 按有符号 BYTE 解释（例如倒计时 -1 不能被读成 255 而重新显示）。
int _readSignedInt(TarsInputStream stream, int tag) {
  if (!stream.skipToTag(tag)) return 0;
  final head = HeadData();
  stream.peakHead(head);
  final value = stream.readInt(tag, true);
  return head.type == TarsStructType.BYTE.index && value >= 128
      ? value - 256
      : value;
}

class _MessageBoardPanel extends TarsStruct {
  List<_MessageBoardInfo> entries = [];

  @override
  void readFrom(TarsInputStream stream) {
    entries = stream.readList<_MessageBoardInfo>(
      [_MessageBoardInfo()],
      1,
      false,
    );
  }

  @override
  Object deepCopy() => _MessageBoardPanel();

  @override
  void writeTo(TarsOutputStream stream) {}

  @override
  void displayAsString(StringBuffer buffer, int level) {}
}

class _HeadlineResponse extends TarsStruct {
  _MessageBoardPanel panel = _MessageBoardPanel();

  @override
  void readFrom(TarsInputStream stream) {
    panel =
        stream.readTarsStruct(_MessageBoardPanel(), 1, true)
            as _MessageBoardPanel;
  }

  @override
  Object deepCopy() => _HeadlineResponse();

  @override
  void writeTo(TarsOutputStream stream) {}

  @override
  void displayAsString(StringBuffer buffer, int level) {}
}

class _MessageUser extends TarsStruct {
  int uid = 0;
  String nickName = '';
  String avatar = '';
  int roomId = 0;

  @override
  void readFrom(TarsInputStream stream) {
    uid = stream.readInt(0, false);
    nickName = stream.readString(1, false);
    avatar = stream.readString(2, false);
    roomId = stream.readInt(3, false);
  }

  @override
  Object deepCopy() => _MessageUser();

  @override
  void writeTo(TarsOutputStream stream) {}

  @override
  void displayAsString(StringBuffer buffer, int level) {}
}

class _MessageBoardInfo extends TarsStruct {
  _MessageUser sender = _MessageUser();
  String content = '';
  int totalSeconds = 0;
  int remainingSeconds = 0;
  int messageId = 0;
  int level = 0;
  int costPay = 0;
  bool hasCostPay = false;

  @override
  void readFrom(TarsInputStream stream) {
    sender = stream.readTarsStruct(_MessageUser(), 0, false) as _MessageUser;
    content = stream.readString(1, false);
    totalSeconds = _readSignedInt(stream, 4);
    remainingSeconds = _readSignedInt(stream, 5);
    messageId = _readSignedInt(stream, 9);
    level = _readSignedInt(stream, 11);
    hasCostPay = stream.skipToTag(12);
    if (hasCostPay) costPay = _readSignedInt(stream, 12);
  }

  @override
  Object deepCopy() => _MessageBoardInfo();

  @override
  void writeTo(TarsOutputStream stream) {}

  @override
  void displayAsString(StringBuffer buffer, int level) {}
}
