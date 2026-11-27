import 'dart:convert';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

String _stt(DouyuDanmaku danmaku, Map<String, String> fields) {
  return fields.entries
      .map((entry) => '${entry.key}@=${danmaku.scapeSlashAt(entry.value)}/')
      .join();
}

void _decode(DouyuDanmaku danmaku, Map<String, String> fields) {
  danmaku.decodeMessage(danmaku.serializeDouyu(_stt(danmaku, fields)));
}

void _comm(
  DouyuDanmaku danmaku,
  String id, {
  String text = ' 高能留言 ',
  int cents = 3000,
  String roomId = '12306',
  String btype = 'voiceDanmu',
  String? rawChat,
  bool omitChat = false,
  int color = 1,
  int seconds = 60,
}) {
  _decode(danmaku, {
    'type': 'comm_chatmsg',
    'btype': btype,
    'rid': roomId,
    'vrid': id,
    if (!omitChat)
      'chatmsg':
          rawChat ??
          _stt(danmaku, {'nn': ' 观众 ', 'txt': text, 'ic': 'avatar/default/15'}),
    'cprice': '$cents',
    'crealPrice': '$cents',
    'cet': '$seconds',
    'danmucr': '$color',
  });
}

void _voice(
  DouyuDanmaku danmaku,
  String id, {
  String? text = ' 高能留言 ',
  int cents = 3000,
  int mtype = 2,
  int? expiresAt,
  String? staySeconds = '60',
  String? hoverTime,
  String? roomId,
  String? itemRoomId,
}) {
  _decode(danmaku, {
    'type': 'voice_trlt',
    if (roomId != null) 'rid': roomId,
    'mtype': '$mtype',
    'list': json.encode([
      {
        'vrId': id,
        'un': ' 观众 ',
        'uat': 'avatar/default/15',
        if (text != null) 'content': text,
        'price': '$cents',
        'realPrice': '$cents',
        if (staySeconds != null) 'stime': staySeconds,
        if (hoverTime != null) 'hoverTime': hoverTime,
        if (itemRoomId != null) 'rid': itemRoomId,
        if (expiresAt != null) 'etimeV2': '$expiresAt',
      },
    ]),
  });
}

void main() {
  late DouyuDanmaku danmaku;
  late List<LiveMessage> messages;
  late Duration elapsed;
  late DateTime now;

  setUp(() {
    elapsed = Duration.zero;
    now = DateTime.utc(2026, 11, 27, 12, 0, 0, 500);
    messages = <LiveMessage>[];
    danmaku = DouyuDanmaku(voiceDedupNow: () => elapsed, voiceNow: () => now);
    danmaku.danmakuArgs = DouyuDanmakuArgs(roomId: '12306');
    danmaku.onMessage = messages.add;
  });

  tearDown(() async {
    await danmaku.stop();
  });

  group('斗鱼高能消息原始截止时间', () {
    for (final cents in [0, 3000]) {
      test('已过期的${cents == 0 ? '免费' : '付费'}增量仍上报历史，重复不续期', () {
        const secondsSinceEpoch = 1700000000;
        final deadline = DateTime.fromMillisecondsSinceEpoch(
          secondsSinceEpoch * 1000,
        );
        _voice(danmaku, 'expired', cents: cents, expiresAt: secondsSinceEpoch);
        expect(messages, hasLength(1));
        final card = messages.single.data as LiveSuperChatMessage;
        expect(card.endTime, deadline);
        expect(card.endTime.isBefore(now), isTrue);
        expect(card.startTime, now);
        expect(card.price, cents ~/ 100);

        now = now.add(const Duration(minutes: 1));
        _comm(danmaku, 'expired', cents: cents);
        _voice(danmaku, 'expired', cents: cents);
        expect(messages, hasLength(1));
        expect(card.endTime, deadline);
      });
    }

    test('绝对截止仅余 500 毫秒时不会被整秒截断后重建成 60 秒', () {
      final expiresAt = now.millisecondsSinceEpoch ~/ 1000 + 1;
      _voice(danmaku, 'sub-second', expiresAt: expiresAt);
      final card = messages.single.data as LiveSuperChatMessage;
      expect(card.endTime.millisecondsSinceEpoch, expiresAt * 1000);
      expect(card.endTime.difference(now), const Duration(milliseconds: 500));
    });

    test('etimeV2 是 Unix 秒，优先于 stime 和 hoverTime', () {
      final expiresAt = now.millisecondsSinceEpoch ~/ 1000 + 90;
      _voice(
        danmaku,
        'absolute-seconds',
        expiresAt: expiresAt,
        staySeconds: '900',
        hoverTime: '300',
      );
      final card = messages.single.data as LiveSuperChatMessage;
      expect(card.endTime.millisecondsSinceEpoch, expiresAt * 1000);
      expect(
        card.endTime.difference(now),
        const Duration(seconds: 89, milliseconds: 500),
      );
    });

    test('缺省语音时长从本地接收起算，优先 stime，缺失才读 hoverTime', () {
      final cases = <({String? stay, String? hover, int seconds})>[
        (stay: '90', hover: '180', seconds: 90),
        (stay: null, hover: '75', seconds: 75),
        (stay: null, hover: null, seconds: 30),
        (stay: '', hover: '75', seconds: 30),
        (stay: 'invalid', hover: '75', seconds: 30),
        (stay: '0', hover: null, seconds: 30),
        (stay: '-1', hover: null, seconds: 30),
      ];
      for (var i = 0; i < cases.length; i++) {
        final fixture = cases[i];
        _voice(
          danmaku,
          'fallback-$i',
          staySeconds: fixture.stay,
          hoverTime: fixture.hover,
        );
        final card = messages.last.data as LiveSuperChatMessage;
        expect(card.startTime, now);
        expect(card.endTime, now.add(Duration(seconds: fixture.seconds)));
      }
    });

    test('非正 etimeV2 回退停留秒数，不把它当作过去的绝对截止', () {
      for (final expiresAt in [0, -1]) {
        _voice(danmaku, 'invalid-expiry-$expiresAt', expiresAt: expiresAt);
        final card = messages.last.data as LiveSuperChatMessage;
        expect(card.endTime, now.add(const Duration(seconds: 60)));
      }
    });

    test('广播 cet 从本地接收起算，缺省非法或非正为 60 秒，不读取 now 字段', () {
      final values = <String?>[null, '', 'invalid', '0', '-1', '90'];
      for (var i = 0; i < values.length; i++) {
        final value = values[i];
        _decode(danmaku, {
          'type': 'comm_chatmsg',
          'btype': 'voiceDanmu',
          'rid': '12306',
          'vrid': 'comm-deadline-$i',
          'chatmsg': _stt(danmaku, {'nn': '观众', 'txt': '留言'}),
          'cprice': '3000',
          'crealPrice': '3000',
          'now': '1000',
          if (value != null) 'cet': value,
        });
        final card = messages.last.data as LiveSuperChatMessage;
        final seconds = value == '90' ? 90 : 60;
        expect(card.startTime, now);
        expect(card.endTime, now.add(Duration(seconds: seconds)));
      }
    });
  });

  group('斗鱼高能消息有界去重', () {
    for (final voiceFirst in [false, true]) {
      for (final cents in [0, 3000]) {
        test('${voiceFirst ? 'voice_trlt' : 'comm_chatmsg'} 先到，'
            '${cents == 0 ? '免费' : '付费'}留言跨来源只出一张卡', () {
          const id = 'shared-id';
          if (voiceFirst) {
            _voice(danmaku, id, cents: cents);
            _comm(danmaku, id, cents: cents);
            _voice(danmaku, id, cents: cents);
          } else {
            _comm(danmaku, id, cents: cents);
            _voice(danmaku, id, cents: cents);
            _comm(danmaku, id, cents: cents);
          }

          expect(messages, hasLength(1));
          expect(messages.single.type, LiveMessageType.superChat);
          final card = messages.single.data as LiveSuperChatMessage;
          expect(card.id, id);
          expect(card.price, cents ~/ 100);
          expect(card.userName, '观众');
          expect(card.message, '高能留言');
          expect(
            card.face,
            'https://apic.douyucdn.cn/upload/avatar/default/15_big.jpg',
          );
          expect(
            card.endTime.difference(card.startTime).inSeconds,
            inInclusiveRange(1, 60),
          );
        });
      }
    }

    test('空白正文、缺失或不可解析的内嵌聊天不抢占后续有效消息的 ID', () {
      _comm(danmaku, 'blank', text: '   ');
      _comm(danmaku, 'missing', omitChat: true);
      _comm(danmaku, 'malformed', rawChat: 'not-a-chat');
      expect(messages, isEmpty);

      _voice(danmaku, 'blank');
      _comm(danmaku, 'missing');
      _voice(danmaku, 'malformed', cents: 0);
      expect(messages, hasLength(3));
      expect(
        messages.map((message) => (message.data as LiveSuperChatMessage).id),
        ['blank', 'missing', 'malformed'],
      );
    });

    test('串房、非高能广播、全量和移除消息均不抢占 ID', () {
      _comm(danmaku, 'other-room', roomId: '999');
      _comm(danmaku, 'other-type', btype: 'other');
      _voice(danmaku, 'snapshot', mtype: 1);
      _voice(danmaku, 'removed', mtype: 3);
      _voice(danmaku, 'explicit-other-room', roomId: '999');
      _voice(danmaku, 'item-other-room', itemRoomId: '999');
      _voice(danmaku, 'scoped-snapshot', mtype: 1, roomId: '12306');
      expect(messages, isEmpty);

      for (final id in [
        'other-room',
        'other-type',
        'snapshot',
        'removed',
        'explicit-other-room',
        'item-other-room',
        'scoped-snapshot',
      ]) {
        _comm(danmaku, id);
      }
      expect(messages, hasLength(7));
    });

    test('10 分钟窗口到期后可重新出卡，重复包不会延长窗口', () {
      _comm(danmaku, 'window');
      elapsed = const Duration(minutes: 5);
      _voice(danmaku, 'newer');
      elapsed = const Duration(minutes: 10) - const Duration(microseconds: 1);
      _voice(danmaku, 'window');
      expect(messages, hasLength(2));

      elapsed = const Duration(minutes: 10);
      _voice(danmaku, 'window');
      _comm(danmaku, 'newer');
      expect(messages, hasLength(3));
      expect((messages.last.data as LiveSuperChatMessage).id, 'window');
    });

    test('容量最多 2048 个 ID，满载时先淘汰最早入库项且重复包不刷新顺序', () {
      for (var i = 0; i < 2048; i++) {
        _comm(danmaku, 'id-$i');
      }
      expect(messages, hasLength(2048));

      // 无效报文不应挤掉最早项；重复项也不占用容量或刷新 FIFO 顺序。
      _comm(danmaku, 'invalid', text: '   ');
      _voice(danmaku, 'id-0');
      expect(messages, hasLength(2048));

      _voice(danmaku, 'id-2048');
      _comm(danmaku, 'id-2048');
      _voice(danmaku, 'id-1');
      expect(messages, hasLength(2049));

      _voice(danmaku, 'id-0');
      expect(messages, hasLength(2050));
      expect((messages.last.data as LiveSuperChatMessage).id, 'id-0');
    });

    test('stop 清空会话去重记录，重新使用解析器时可接收同 ID', () async {
      _comm(danmaku, 'session-id');
      _voice(danmaku, 'session-id');
      expect(messages, hasLength(1));

      await danmaku.stop();
      expect(danmaku.onMessage, isNull);
      // 直接重挂解析回调，验证 stop 的清理，不调用 start 建立网络连接。
      danmaku.onMessage = messages.add;
      _voice(danmaku, 'session-id');
      expect(messages, hasLength(2));
    });

    test('不同实例独立去重，适用于多开房间', () async {
      final otherMessages = <LiveMessage>[];
      final other = DouyuDanmaku(voiceDedupNow: () => elapsed);
      other.danmakuArgs = DouyuDanmakuArgs(roomId: '12306');
      other.onMessage = otherMessages.add;
      try {
        _comm(danmaku, 'shared-across-instances');
        _voice(other, 'shared-across-instances');
        expect(messages, hasLength(1));
        expect(otherMessages, hasLength(1));
      } finally {
        await other.stop();
      }
    });

    test('没有 vrid 的消息保持可见，不把所有空 ID 当成同一条', () {
      _comm(danmaku, '', cents: 0);
      _comm(danmaku, '', cents: 0);
      _voice(danmaku, '', cents: 0);
      _voice(danmaku, '', cents: 0);
      expect(messages, hasLength(4));
      expect(
        messages.map((message) => (message.data as LiveSuperChatMessage).price),
        everyElement(0),
      );
    });

    test('免费语音占位正文和广播的颜色、停留时长保持原行为', () {
      _voice(danmaku, 'free-voice', text: null, cents: 0);
      final free = messages.single.data as LiveSuperChatMessage;
      expect(free.message, '（语音弹幕）');
      expect(free.price, 0);

      _comm(danmaku, 'paid-color', color: 2, seconds: 90);
      final paid = messages.last.data as LiveSuperChatMessage;
      expect(paid.price, 30);
      expect(paid.backgroundBottomColor, 'd64545');
      expect(
        paid.endTime.difference(paid.startTime),
        const Duration(seconds: 90),
      );
    });
  });
}
