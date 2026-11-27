import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/danmaku/huya_superchat.dart';
import 'package:tars_dart/tars/codec/tars_input_stream.dart';
import 'package:tars_dart/tars/codec/tars_output_stream.dart';
import 'package:tars_dart/tars/codec/tars_struct.dart';
import 'package:tars_dart/tars/tup/const.dart';
import 'package:tars_dart/tars/tup/tars_uni_packet.dart';
import 'package:test/test.dart';

// 非空条目按当前官网 GameEventMessageBoardServant 字段构造，
// 不能把它们称为真实用户付费消息录制。真实录制的空面板另行覆盖。
class _Struct extends TarsStruct {
  final Map<int, Object> fields;
  _Struct(this.fields);
  @override
  void writeTo(TarsOutputStream stream) {
    for (final entry in fields.entries) {
      stream.write(entry.value, entry.key);
    }
  }

  @override
  void readFrom(TarsInputStream stream) => throw UnimplementedError();
  @override
  Object deepCopy() => _Struct(fields);
  @override
  void displayAsString(StringBuffer buffer, int level) {}
}

const _presenter = 294636272;
const _messageId = 2120815116315275264;
final _now = DateTime.utc(2026, 11, 25, 12);

_Struct _entry({
  int id = _messageId,
  String content = '加油 &amp; 谢谢！',
  int total = 300,
  int remaining = 120,
  int? costPay = 150,
  int level = 2,
  String avatar = '//example.com/avatar.png',
}) => _Struct({
  0: _Struct({0: 1234, 1: '观众 &amp; 粉丝', 2: avatar, 3: 999999, 4: 1}),
  1: content,
  2: 999999, // iCost 语义未证，不可当人民币或优先覆盖 iCostPay。
  3: 'camp-icon',
  4: total,
  5: remaining,
  6: 'offset',
  7: 100,
  8: <String, String>{'unknown': 'field'},
  9: id,
  10: _Struct({0: 9876, 1: '目标用户', 2: '', 3: 888888, 4: 0}),
  11: level,
  if (costPay != null) 12: costPay,
});

_Struct _panelStruct(List<_Struct> entries, {int state = 1}) => _Struct({
  0: _Struct({
    0: _Struct({0: 'left', 1: '', 2: 0}),
    1: _Struct({0: 'right', 1: '', 2: 0}),
    2: '',
    3: '',
    4: '',
  }),
  1: entries,
  2: state,
});

Uint8List _panel(List<_Struct> entries, {int state = 1}) {
  final stream = TarsOutputStream();
  _panelStruct(entries, state: state).writeTo(stream);
  return stream.toUint8List();
}

Uint8List _initial(List<_Struct> entries) {
  final packet = TarsUniPacket()
    ..setTarsVersion(Const.PACKET_TYPE_TUP3)
    ..requestId = 1
    ..servantName = 'wupui'
    ..funcName = 'getHeadLineMessageBoard';
  packet.put('tRsp', _Struct({1: _panelStruct(entries), 2: 'support', 6: 0}));
  return packet.encode();
}

Uint8List _push(
  List<int> payload, {
  String? group = 'live:$_presenter',
  int uri = 2001314,
}) {
  final body = TarsOutputStream()
    ..write(0, 0)
    ..write(uri, 1)
    ..write(Uint8List.fromList(payload), 2)
    ..write(0, 3);
  if (group != null) body.write(group, 4);
  final frame = TarsOutputStream()
    ..write(7, 0)
    ..write(body.toUint8List(), 1);
  return frame.toUint8List();
}

Uint8List _chat() {
  final stream = TarsOutputStream();
  _Struct({
    0: _Struct({0: 123, 1: 0, 2: '普通观众'}),
    3: '普通弹幕',
    6: _Struct({0: 0xffffff}),
  }).writeTo(stream);
  return _push(stream.toUint8List(), uri: 1400);
}

HuyaDanmakuArgs _args({int uid = _presenter}) => HuyaDanmakuArgs(
  ayyuid: 229813522,
  topSid: 123,
  subSid: 456,
  presenterUid: uid,
);

void main() {
  late DateTime now;
  late HuyaSuperChatDecoder decoder;
  setUp(() {
    now = _now;
    decoder = HuyaSuperChatDecoder(now: () => now);
  });

  test('官网字段：64位ID、解转义、平台币和剩余时长', () {
    final message = decoder
        .decodePanel(_panel([_entry()]), presenterUid: _presenter)
        .single;
    expect(message.id, 'huya:$_presenter:$_messageId');
    expect(message.message, '加油 & 谢谢！');
    expect(message.userName, '观众 & 粉丝');
    expect(message.face, 'https://example.com/avatar.png');
    expect(message.displayPrice, '1.5虎牙币');
    expect(message.price, 0);
    expect(message.startTime, now.subtract(const Duration(seconds: 180)));
    expect(message.endTime, now.add(const Duration(seconds: 120)));
    expect(message.backgroundColor, '#EDE9FE');
    // 用户结构的房间号属于该用户，不能据此排除当前主播分组内的留言。
  });

  for (final value in <int?, String>{
    100: '1虎牙币',
    101: '1.01虎牙币',
    150: '1.5虎牙币',
    199: '1.99虎牙币',
    0: '0虎牙币',
    null: '上头条',
    -1: '上头条',
  }.entries) {
    test('iCostPay=${value.key} 的单位和未知金额标签', () {
      final message = decoder
          .decodePanel(
            _panel([_entry(costPay: value.key)]),
            presenterUid: _presenter,
          )
          .single;
      expect(message.displayPrice, value.value);
      expect(message.displayPrice, isNot(contains('￥')));
      expect(message.displayPrice, isNot('免费'));
    });
  }

  test('列表与广播去重共用稳定ID，空面板不伪造清空', () {
    expect(
      decoder.decodeInitialResponse(
        _initial([_entry()]),
        presenterUid: _presenter,
      ),
      hasLength(1),
    );
    expect(
      decoder.decodePanel(_panel([_entry()]), presenterUid: _presenter),
      isEmpty,
    );
    expect(
      decoder.decodePanel(_panel([], state: 0), presenterUid: _presenter),
      isEmpty,
    );
    expect(
      decoder.decodePanel(_panel([_entry()]), presenterUid: _presenter),
      isEmpty,
    );
    decoder.clear();
    expect(
      decoder.decodePanel(_panel([_entry()]), presenterUid: _presenter),
      hasLength(1),
    );
  });

  test('无效正文/时长/ID不占去重位置，剩余时长不超过总时长', () {
    for (final entry in [
      _entry(content: '  '),
      _entry(total: 0),
      _entry(remaining: 0),
      _entry(remaining: -1),
      _entry(id: 0),
    ]) {
      expect(
        decoder.decodePanel(_panel([entry]), presenterUid: _presenter),
        isEmpty,
      );
    }
    final message = decoder
        .decodePanel(
          _panel([_entry(total: 60, remaining: 100)]),
          presenterUid: _presenter,
        )
        .single;
    expect(message.startTime, now);
    expect(message.endTime, now.add(const Duration(seconds: 60)));
  });

  test('未知主播不产生头条，也不预占ID', () {
    expect(decoder.decodePanel(_panel([_entry()]), presenterUid: 0), isEmpty);
    expect(
      decoder.decodePanel(_panel([_entry()]), presenterUid: _presenter),
      hasLength(1),
    );
  });

  test('头像只接受HTTP图片地址；缺失金额不改作iCost', () {
    final message = decoder
        .decodePanel(
          _panel([_entry(avatar: 'javascript:invalid', costPay: null)]),
          presenterUid: _presenter,
        )
        .single;
    expect(message.face, isEmpty);
    expect(message.priceLabel, '上头条');
  });

  test('去重记录按到期时间释放并受容量限制', () {
    final entries = List.generate(
      HuyaSuperChatDecoder.maxRememberedMessages + 1,
      (index) => _entry(id: index + 1),
    );
    expect(
      decoder.decodePanel(_panel(entries), presenterUid: _presenter),
      hasLength(entries.length),
    );
    expect(
      decoder.decodePanel(_panel([_entry(id: 1)]), presenterUid: _presenter),
      hasLength(1),
    );
    expect(
      decoder.decodePanel(
        _panel([_entry(id: entries.length)]),
        presenterUid: _presenter,
      ),
      isEmpty,
    );
    now = now.add(const Duration(seconds: 121));
    expect(
      decoder.decodePanel(
        _panel([_entry(id: entries.length)]),
        presenterUid: _presenter,
      ),
      hasLength(1),
    );
  });

  test('相同消息ID在不同主播分组中独立', () {
    expect(
      decoder.decodePanel(_panel([_entry()]), presenterUid: _presenter),
      hasLength(1),
    );
    expect(
      decoder.decodePanel(_panel([_entry()]), presenterUid: 333393123),
      hasLength(1),
    );
  });

  test('真实公开S19空面板帧兼容，不能据此声称非空实测', () {
    const recorded =
        'AAcdAABGAAUSAB6Joi0AAB8KCgYAFgAsTFYACxoGABYALExWAAsmADYARgALGQwsPEYPbGl2ZToxODY3NDg5Njk4Uxx3hNMv07QAbCw2AExcZgA=';
    final danmaku = HuyaDanmaku()..danmakuArgs = _args(uid: 1867489698);
    final messages = <LiveMessage>[];
    danmaku.onMessage = messages.add;
    expect(
      () => danmaku.decodeMessage(base64Decode(recorded)),
      returnsNormally,
    );
    expect(messages, isEmpty);
  });

  test('真实匿名初始列表响应兼容，跳过官网样式扩展字段', () {
    const response =
        'AAAFbxADLDxAAVYFd3VwdWlmF2dldEhlYWRMaW5lTWVzc2FnZUJvYXJkfQABBTsIAAIGAB0AAAEMBgR0UnNwHQABBSYKGgoKBgAWACxMVgALGgYAFgAsTFYACyYANgBGAAsZDCABCyYANkdodHRwczovL2RpeS1hc3NldHMubXNzdGF0aWMuY29tL3N1c2hlbmdtYW8vaHVkb25ndG9uZ2Rhby9sb3ZlYmFubmVyLnBuZ0gABQABGgZHaHR0cHM6Ly96dC5tc3N0YXRpYy5jb20vZGl5X2NvbW1vbi80NDRhNjZiMDMyOTM0ZThhYTIwN2E4NTk1Y2Y1NGU2NS5wbmcWR2h0dHBzOi8venQubXNzdGF0aWMuY29tL2RpeV9jb21tb24vY2IzMzc0MDZkNTI4NDM5YTgzZDQ3MWYyMjAwM2YwNGYucG5nIjP/qMcyJv+ox0LM/6jHUib/qMdi//OIrnJ//9Tjgkz/1OOSzP/U46JM/9Tjsv/ziK7CzPSFq9Jm9IWr4sz0havyD2b0havyEP/0havwEf/wEv/yE//NTHsLAAIaBkdodHRwczovL3p0Lm1zc3RhdGljLmNvbS9kaXlfY29tbW9uLzQ0NGE2NmIwMzI5MzRlOGFhMjA3YTg1OTVjZjU0ZTY1LnBuZxZHaHR0cHM6Ly96dC5tc3N0YXRpYy5jb20vZGl5X2NvbW1vbi9jYjMzNzQwNmQ1Mjg0MzlhODNkNDcxZjIyMDAzZjA0Zi5wbmciM/+oxzIm/6jHQsz/qMdSJv+ox2L/84iucn//1OOCTP/U45LM/9Tjokz/1OOy//OIrsLM9IWr0mb0havizPSFq/IPZvSFq/IQ//SFq/AR//AS//IT/81MewsAAxoGR2h0dHBzOi8venQubXNzdGF0aWMuY29tL2RpeV9jb21tb24vY2IzMzc0MDZkNTI4NDM5YTgzZDQ3MWYyMjAwM2YwNGYucG5nFkdodHRwczovL3p0Lm1zc3RhdGljLmNvbS9kaXlfY29tbW9uL2UyYzFhZTI0ZTI1ZjRlNDZiOGI0MDM0YjFhMWMzZDczLnBuZyIz/6jHMib/qMdCzP+ox1Im/6jHYv/zfcRyf//U44JM/9Tjksz/1OOiTP/U47L/833Ewsz0havSZvSFq+LM9IWr8g9m9IWr8hD/9IWr8BH/8BL/8hP/zUx7CwAEGgZHaHR0cHM6Ly96dC5tc3N0YXRpYy5jb20vZGl5X2NvbW1vbi9jYjMzNzQwNmQ1Mjg0MzlhODNkNDcxZjIyMDAzZjA0Zi5wbmcWR2h0dHBzOi8venQubXNzdGF0aWMuY29tL2RpeV9jb21tb24vZTJjMWFlMjRlMjVmNGU0NmI4YjQwMzRiMWExYzNkNzMucG5nIjP/qMcyJv+ox0LM/6jHUib/qMdi//N9xHJ//9Tjgkz/1OOSzP/U46JM/9Tjsv/zfcTCzPSFq9Jm9IWr4sz0havyD2b0havyEP/0havwEf/wEv/yE//US3oLAAUaBkdodHRwczovL3p0Lm1zc3RhdGljLmNvbS9kaXlfY29tbW9uLzE5OTk4MjNlODMyODRjMDViMWNjYWZmZmU1YjA5NjRhLnBuZxZHaHR0cHM6Ly96dC5tc3N0YXRpYy5jb20vZGl5X2NvbW1vbi9iODM2MjUzZGJhYmY0OWE5YjFmZGQ5ZTczZGY2OWYxMS5wbmciM/+oxzIm/6jHQsz/qMdSJv+ox2L/9EyJcn//1OOCTP/U45LM/9Tjokz/1OOy//RMicLM9IWr0mb0havizPSFq/IPZvSFq/IQ//SFq/AR//AS//IT/81MewtaCQwLYefzcAELjJgMqAw=';
    expect(
      decoder.decodeInitialResponse(
        base64Decode(response),
        presenterUid: _presenter,
      ),
      isEmpty,
    );
  });

  test('真实房间付费头条还原虎牙币和剩余时长', () {
    final fixture =
        jsonDecode(
              File(
                'test/fixtures/huya_headline_room60066.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    now = DateTime.parse(fixture['capturedAt'] as String);
    final message = decoder
        .decodeInitialResponse(
          base64Decode(fixture['responseBase64'] as String),
          presenterUid: 1867489698,
        )
        .single;
    expect(message.id, 'huya:1867489698:3551299');
    expect(message.message, '靠嫩一 杨哥');
    expect(message.userName, isNotEmpty);
    expect(message.displayPrice, '1虎牙币');
    expect(message.startTime, now.subtract(const Duration(seconds: 48)));
    expect(message.endTime, now.add(const Duration(seconds: 12)));
  });

  test('实时推送先到、初始列表后到也只展示一次', () async {
    final response = Completer<List<int>>();
    final danmaku = HuyaDanmaku(
      headlineLoader: (_) => response.future,
      superChatNow: () => now,
    )..danmakuArgs = _args();
    final messages = <LiveMessage>[];
    danmaku.onMessage = messages.add;
    final loading = danmaku.loadSuperChats();
    danmaku.decodeMessage(_push(_panel([_entry()])));
    response.complete(_initial([_entry()]));
    await loading;
    expect(messages, hasLength(1));
  });

  test('SC日志包含可序列化时间与平台币标签', () {
    final message = decoder
        .decodePanel(_panel([_entry()]), presenterUid: _presenter)
        .single;
    final json = jsonDecode(message.toString()) as Map<String, dynamic>;
    expect(json['priceLabel'], '1.5虎牙币');
    expect(DateTime.parse(json['endTime'] as String), message.endTime);
  });

  test('接收端按外层live分组隔离且不影响普通弹幕', () {
    final danmaku = HuyaDanmaku(superChatNow: () => now)..danmakuArgs = _args();
    final messages = <LiveMessage>[];
    danmaku.onMessage = messages.add;
    final payload = _panel([_entry()]);
    danmaku.decodeMessage(_push(payload, group: 'live:1867489698'));
    danmaku.decodeMessage(_push(payload, group: null));
    danmaku.decodeMessage(_push(payload, group: 'chat:$_presenter'));
    expect(messages, isEmpty);
    danmaku.decodeMessage(_push(payload));
    danmaku.decodeMessage(_push(payload));
    danmaku.decodeMessage(_chat());
    expect(messages.map((e) => e.type), [
      LiveMessageType.superChat,
      LiveMessageType.chat,
    ]);
    expect(messages.last.message, '普通弹幕');
  });

  test('cmd22批量消息内坏头条不吞后续聊天，单双包共用去重', () {
    final danmaku = HuyaDanmaku(superChatNow: () => now)..danmakuArgs = _args();
    final messages = <LiveMessage>[];
    danmaku.onMessage = messages.add;
    final chatFrame = TarsInputStream(_chat());
    chatFrame.readInt(0, true);
    final chatPush = TarsInputStream(chatFrame.readBytes(1, true));
    final chatPayload = chatPush.readBytes(2, true);
    final body = TarsOutputStream();
    _Struct({
      0: 'live:$_presenter',
      1: [
        _Struct({
          0: 2001314,
          1: Uint8List.fromList([0xff]),
          2: 1,
        }),
        _Struct({0: 1400, 1: chatPayload, 2: 2}),
        _Struct({
          0: 2001314,
          1: _panel([_entry()]),
          2: 3,
        }),
      ],
    }).writeTo(body);
    final frame = TarsOutputStream()
      ..write(22, 0)
      ..write(body.toUint8List(), 1);
    expect(() => danmaku.decodeMessage(frame.toUint8List()), returnsNormally);
    expect(messages.map((e) => e.type), [
      LiveMessageType.chat,
      LiveMessageType.superChat,
    ]);
    danmaku.decodeMessage(_push(_panel([_entry()])));
    expect(messages, hasLength(2));
  });

  test('仅注册主播live分组，避免重复订阅普通弹幕', () {
    final danmaku = HuyaDanmaku();
    final frame = TarsInputStream(
      Uint8List.fromList(danmaku.getGroupData(_presenter)),
    );
    expect(frame.readInt(0, true), 16);
    final body = TarsInputStream(frame.readBytes(1, true));
    expect(body.readList<String>([''], 0, true), ['live:$_presenter']);
    expect(danmaku.getGroupData(0), isEmpty);
  });

  test('首次列表迟到时忽略停止的房间', () async {
    final response = Completer<List<int>>();
    final danmaku = HuyaDanmaku(headlineLoader: (_) => response.future)
      ..danmakuArgs = _args();
    final messages = <LiveMessage>[];
    danmaku.onMessage = messages.add;
    final loading = danmaku.loadSuperChats();
    await danmaku.stop();
    danmaku.onMessage = messages.add;
    response.complete(_initial([_entry()]));
    await loading;
    expect(messages, isEmpty);
  });

  test('首次列表迟到时忽略已更换的房间参数', () async {
    final response = Completer<List<int>>();
    final danmaku = HuyaDanmaku(headlineLoader: (_) => response.future)
      ..danmakuArgs = _args();
    final messages = <LiveMessage>[];
    danmaku.onMessage = messages.add;
    final loading = danmaku.loadSuperChats();
    danmaku.danmakuArgs = _args(uid: 333393123);
    response.complete(_initial([_entry()]));
    await loading;
    expect(messages, isEmpty);
  });

  test('首次列表与实时推送合流只展示一次，stop清理去重', () async {
    final danmaku = HuyaDanmaku(
      headlineLoader: (_) async => _initial([_entry()]),
      superChatNow: () => now,
    )..danmakuArgs = _args();
    final messages = <LiveMessage>[];
    danmaku.onMessage = messages.add;
    await danmaku.loadSuperChats();
    danmaku.decodeMessage(_push(_panel([_entry()])));
    expect(messages, hasLength(1));
    await danmaku.stop();
    danmaku.onMessage = messages.add;
    danmaku.decodeMessage(_push(_panel([_entry()])));
    expect(messages, hasLength(2));
  });

  test('列表读取失败与损坏头条不阻断普通聊天', () async {
    final danmaku = HuyaDanmaku(
      headlineLoader: (_) async => throw const FormatException('offline'),
    )..danmakuArgs = _args();
    final messages = <LiveMessage>[];
    var closes = 0;
    danmaku.onMessage = messages.add;
    danmaku.onClose = (_) => closes++;
    await danmaku.loadSuperChats();
    expect(() => danmaku.decodeMessage(_push([0xff])), returnsNormally);
    danmaku.decodeMessage(_chat());
    expect(messages.single.type, LiveMessageType.chat);
    expect(closes, 0);
  });
}
