import 'dart:convert';
import 'dart:typed_data';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/web_socket_util.dart';
import 'package:test/test.dart';

String _stt(DouyuDanmaku danmaku, Map<String, String> fields) => fields.entries
    .map((entry) => '${entry.key}@=${danmaku.scapeSlashAt(entry.value)}/')
    .join();

List<int> _packet(DouyuDanmaku danmaku, Map<String, String> fields) =>
    danmaku.serializeDouyu(_stt(danmaku, fields), type: 690);

List<int> _comm(DouyuDanmaku danmaku, String id, {String roomId = '12306'}) =>
    _packet(danmaku, {
      'type': 'comm_chatmsg',
      'btype': 'voiceDanmu',
      'rid': roomId,
      'vrid': id,
      'chatmsg': _stt(danmaku, {'nn': '观众', 'txt': '合包中文😀/@'}),
      'cprice': '3000',
      'crealPrice': '3000',
      'cet': '60',
    });

List<int> _voice(DouyuDanmaku danmaku, String id, {int mtype = 2}) =>
    _packet(danmaku, {
      'type': 'voice_trlt',
      'mtype': '$mtype',
      'list': json.encode([
        {
          'vrId': id,
          'un': '观众',
          'content': '语音留言',
          'realPrice': '3000',
          'stime': '60',
        },
      ]),
    });

List<String> _ids(List<LiveMessage> messages) => messages
    .where((message) => message.type == LiveMessageType.superChat)
    .map((message) => (message.data as LiveSuperChatMessage).id)
    .toList();

List<int> _pendingHeader() {
  final bytes = Uint8List(12);
  final header = ByteData.sublistView(bytes);
  header.setUint32(0, 65532, Endian.little);
  header.setUint32(4, 65532, Endian.little);
  header.setUint16(8, 690, Endian.little);
  return bytes;
}

class _FakeSocket extends WebScoketUtils {
  _FakeSocket({
    required super.url,
    required super.heartBeatTime,
    required super.headers,
    required super.onMessage,
    required super.onReady,
    required super.onHeartBeat,
    required super.onReconnect,
    required super.onClose,
  });

  final sent = <dynamic>[];
  int closes = 0;

  @override
  void connect({bool retry = false}) {
    status = SocketStatus.connected;
  }

  @override
  void close() {
    closes++;
    status = SocketStatus.closed;
  }

  @override
  void sendMessage(dynamic message) => sent.add(message);
}

class _SenderHarness {
  final sockets = <_FakeSocket>[];

  WebScoketUtils create({
    required String url,
    required int heartBeatTime,
    required Map<String, dynamic> headers,
    required void Function(dynamic) onMessage,
    required void Function() onReady,
    required void Function() onHeartBeat,
    required void Function() onReconnect,
    required void Function(String) onClose,
  }) {
    final socket = _FakeSocket(
      url: url,
      heartBeatTime: heartBeatTime,
      headers: headers,
      onMessage: onMessage,
      onReady: onReady,
      onHeartBeat: onHeartBeat,
      onReconnect: onReconnect,
      onClose: onClose,
    );
    sockets.add(socket);
    return socket;
  }
}

DouyuDanmaku _sender(_SenderHarness harness) =>
    DouyuDanmaku(
        senderSocketFactory: harness.create,
        senderPreheatDelay: Duration.zero,
      )
      ..danmakuArgs = DouyuDanmakuArgs(
        roomId: '12306',
        uid: '12345',
        devid: 'fixture-device',
        jwt: 'fixture-jwt',
        ltkid: 'fixture-ltkid',
        stk: 'fixture-stk',
      );

Future<void> _tick() => Future<void>.delayed(Duration.zero);

void main() {
  group('斗鱼接收流解包', () {
    late DouyuDanmaku danmaku;
    late List<LiveMessage> messages;

    setUp(() {
      messages = [];
      danmaku = DouyuDanmaku()
        ..danmakuArgs = DouyuDanmakuArgs(roomId: '12306')
        ..onMessage = messages.add;
    });

    tearDown(() async {
      await danmaku.stop();
    });

    test('心跳、登录和多条 SC 合包全部按顺序解析', () {
      danmaku.decodeMessage([
        ..._packet(danmaku, {'type': 'keeplive'}),
        ..._packet(danmaku, {'type': 'loginres'}),
        ..._comm(danmaku, 'first'),
        ..._voice(danmaku, 'second'),
      ]);
      expect(_ids(messages), ['first', 'second']);
      expect(messages.first.message, '合包中文😀/@');
    });

    test('合包内两个来源仍只接纳一次，不续期', () {
      danmaku.decodeMessage([
        ..._voice(danmaku, 'shared'),
        ..._comm(danmaku, 'shared'),
        ..._comm(danmaku, 'next'),
      ]);
      expect(_ids(messages), ['shared', 'next']);
    });

    test('前面的串房、全量和非展示消息不会截断后面的合法 SC', () {
      danmaku.decodeMessage([
        ..._comm(danmaku, 'same', roomId: '999'),
        ..._voice(danmaku, 'snapshot', mtype: 1),
        ..._packet(danmaku, {'type': 'chatmsg', 'txt': 'no-dms'}),
        ..._comm(danmaku, 'same'),
      ]);
      expect(_ids(messages), ['same']);
    });

    test('包头、正文以及 UTF-8 多字节中的任意截断都可以续接', () async {
      final packet = _comm(danmaku, 'split');
      for (var split = 1; split < packet.length; split++) {
        final received = <LiveMessage>[];
        final decoder = DouyuDanmaku()
          ..danmakuArgs = DouyuDanmakuArgs(roomId: '12306')
          ..onMessage = received.add;
        try {
          decoder.decodeMessage(packet.sublist(0, split));
          expect(received, isEmpty, reason: 'split=$split');
          decoder.decodeMessage(packet.sublist(split));
          expect(_ids(received), ['split'], reason: 'split=$split');
          expect(received.single.message, '合包中文😀/@');
        } finally {
          await decoder.stop();
        }
      }
    });

    test('完整包之后的半包留待下一次消息，不重复前一包', () {
      final second = _voice(danmaku, 'second');
      danmaku.decodeMessage([
        ..._comm(danmaku, 'first'),
        ...second.sublist(0, 17),
      ]);
      expect(_ids(messages), ['first']);
      danmaku.decodeMessage(second.sublist(17));
      expect(_ids(messages), ['first', 'second']);
    });

    test('非法长度、重复长度、包类型、标志或结束符不阻止后续完整包', () {
      final corruptions = <void Function(Uint8List)>[
        (bytes) =>
            ByteData.sublistView(bytes).setUint32(0, 0xffffffff, Endian.little),
        (bytes) => ByteData.sublistView(bytes).setUint32(0, 8, Endian.little),
        (bytes) => ByteData.sublistView(
          bytes,
        ).setUint32(0, 1024 * 1024, Endian.little),
        (bytes) => ByteData.sublistView(bytes).setUint32(4, 9, Endian.little),
        (bytes) => ByteData.sublistView(bytes).setUint16(8, 0, Endian.little),
        (bytes) => bytes[10] = 1,
        (bytes) => bytes[11] = 1,
        (bytes) => bytes[bytes.length - 1] = 1,
      ];
      for (var i = 0; i < corruptions.length; i++) {
        final malformed = Uint8List.fromList(
          _packet(danmaku, {'type': 'noop'}),
        );
        corruptions[i](malformed);
        expect(
          () => danmaku.decodeMessage([
            ...malformed,
            ..._comm(danmaku, 'valid-$i'),
          ]),
          returnsNormally,
        );
      }
      expect(
        _ids(messages),
        List.generate(corruptions.length, (i) => 'valid-$i'),
      );
    });

    test('错误 UTF-8 和非对象 STT 正文不会丢掉后续 SC', () {
      final invalidUtf8 = _packet(danmaku, {'type': 'noop'});
      invalidUtf8[12] = 0xff;
      danmaku.decodeMessage([
        ...invalidUtf8,
        ...danmaku.serializeDouyu('not-a-map'),
        ...danmaku.serializeDouyu('one//two'),
        ..._comm(danmaku, 'after-malformed'),
      ]);
      expect(_ids(messages), ['after-malformed']);
    });

    test('大于缓冲上限的坏数据可以分批丢弃，并继续识别尾部 SC', () {
      final garbage = Uint8List(2 * 1024 * 1024 + 11);
      garbage.fillRange(0, garbage.length, 0xff);
      danmaku.decodeMessage([
        ...garbage,
        ..._comm(danmaku, 'after-large-input'),
      ]);
      expect(_ids(messages), ['after-large-input']);
    });

    test('不同实例的半包不会互相拼接', () async {
      final otherMessages = <LiveMessage>[];
      final other = DouyuDanmaku()
        ..danmakuArgs = DouyuDanmakuArgs(roomId: '12306')
        ..onMessage = otherMessages.add;
      try {
        danmaku.decodeMessage(_pendingHeader());
        other.decodeMessage(_comm(other, 'other-room-instance'));
        expect(messages, isEmpty);
        expect(_ids(otherMessages), ['other-room-instance']);
      } finally {
        await other.stop();
      }
    });

    test('stop 清空待续半包，不污染下一个会话', () async {
      danmaku.decodeMessage(_pendingHeader());
      await danmaku.stop();
      danmaku.onMessage = messages.add;
      danmaku.decodeMessage(_comm(danmaku, 'new-session'));
      expect(_ids(messages), ['new-session']);
    });

    test('首包回调停止会话后，同批剩余包不继续派发', () async {
      Future? stopping;
      danmaku.onMessage = (message) {
        messages.add(message);
        stopping = danmaku.stop();
      };
      danmaku.decodeMessage([
        ..._comm(danmaku, 'first'),
        ..._comm(danmaku, 'should-not-dispatch'),
      ]);
      await stopping;
      expect(_ids(messages), ['first']);
    });

    test('单包兼容入口不持有流状态，合包返回第一条完整正文', () {
      final first = _packet(danmaku, {'type': 'keeplive'});
      expect(danmaku.deserializeDouyu(first.sublist(0, 5)), isNull);
      expect(
        danmaku.deserializeDouyu([...first, ..._comm(danmaku, 'next')]),
        'type@=keeplive/',
      );
      danmaku.decodeMessage(_comm(danmaku, 'next'));
      expect(_ids(messages), ['next']);
    });
  });

  group('斗鱼发送流解包', () {
    test('心跳后的 loginres 和 chatres 都被处理', () async {
      final harness = _SenderHarness();
      final danmaku = _sender(harness);
      try {
        final sending = danmaku.sendDanmaku('hello');
        await _tick();
        final socket = harness.sockets.single;
        socket.onReady!();
        socket.onMessage!([
          ..._packet(danmaku, {'type': 'keeplive', 'nonce': 'fixture-nonce'}),
          ..._packet(danmaku, {'type': 'loginres', 'userid': '12345'}),
        ]);
        await _tick();
        expect(socket.sent, hasLength(2));
        socket.onMessage!([
          ..._packet(danmaku, {'type': 'keeplive'}),
          ..._packet(danmaku, {'type': 'chatres', 'res': '0'}),
        ]);
        expect(await sending, isNull);
      } finally {
        await danmaku.stop();
      }
    });

    test('发送和接收各自续接半包，接收心跳不干扰发送回执', () async {
      final harness = _SenderHarness();
      final danmaku = _sender(harness);
      final messages = <LiveMessage>[];
      danmaku.onMessage = messages.add;
      try {
        final sending = danmaku.sendDanmaku('hello');
        await _tick();
        final socket = harness.sockets.single;
        socket.onReady!();
        final login = _packet(danmaku, {'type': 'loginres', 'userid': '12345'});
        final receive = _comm(danmaku, 'receive');
        socket.onMessage!(login.sublist(0, 9));
        danmaku.decodeMessage(receive.sublist(0, 15));
        socket.onMessage!(login.sublist(9));
        danmaku.decodeMessage(receive.sublist(15));
        await _tick();
        expect(socket.sent, hasLength(2));
        expect(_ids(messages), ['receive']);
        final receipt = _packet(danmaku, {'type': 'chatres', 'res': '13'});
        socket.onMessage!(receipt.sublist(0, receipt.length - 1));
        danmaku.decodeMessage(_packet(danmaku, {'type': 'keeplive'}));
        socket.onMessage!(receipt.sublist(receipt.length - 1));
        expect(await sending, contains('发言等级不足'));
      } finally {
        await danmaku.stop();
      }
    });

    test('释放发送租约清空半包，旧连接回调不能污染新连接', () async {
      final harness = _SenderHarness();
      final danmaku = _sender(harness);
      try {
        final first = danmaku.sendDanmaku('first');
        await _tick();
        final old = harness.sockets.single;
        old.onReady!();
        old.onMessage!(_pendingHeader());
        await danmaku.setSenderActive(false);
        expect(await first, contains('切换'));
        await danmaku.setSenderActive(true);
        await _tick();
        await _tick();
        final current = harness.sockets.last;
        expect(identical(old, current), isFalse);
        old.onMessage!(
          _packet(danmaku, {'type': 'loginres', 'userid': '12345'}),
        );
        current.onReady!();
        current.onMessage!(
          _packet(danmaku, {'type': 'loginres', 'userid': '12345'}),
        );
        await _tick();
        final second = danmaku.sendDanmaku('second');
        await _tick();
        expect(current.sent, hasLength(2));
        current.onMessage!(_packet(danmaku, {'type': 'chatres', 'res': '0'}));
        expect(await second, isNull);
      } finally {
        await danmaku.stop();
      }
    });
  });
}
