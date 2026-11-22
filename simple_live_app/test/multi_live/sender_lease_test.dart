import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/web_socket_util.dart';

class FakeSocket extends WebScoketUtils {
  FakeSocket(
      {required super.url,
      required super.heartBeatTime,
      required super.headers,
      required super.onMessage,
      required super.onReady,
      required super.onHeartBeat,
      required super.onReconnect,
      required super.onClose});
  int connects = 0;
  int closes = 0;
  final sent = <dynamic>[];
  @override
  void connect({bool retry = false}) {
    connects++;
    status = SocketStatus.connected;
  }

  @override
  void close() {
    closes++;
    status = SocketStatus.closed;
  }

  @override
  void sendMessage(dynamic message) {
    sent.add(message);
  }
}

class SocketHarness {
  final sockets = <FakeSocket>[];
  WebScoketUtils create(
      {required String url,
      required int heartBeatTime,
      required Map<String, dynamic> headers,
      required void Function(dynamic) onMessage,
      required void Function() onReady,
      required void Function() onHeartBeat,
      required void Function() onReconnect,
      required void Function(String) onClose}) {
    final socket = FakeSocket(
        url: url,
        heartBeatTime: heartBeatTime,
        headers: headers,
        onMessage: onMessage,
        onReady: onReady,
        onHeartBeat: onHeartBeat,
        onReconnect: onReconnect,
        onClose: onClose);
    sockets.add(socket);
    return socket;
  }
}

DouyuDanmaku room(SocketHarness h) => DouyuDanmaku(
    senderSocketFactory: h.create, senderPreheatDelay: Duration.zero)
  ..danmakuArgs = DouyuDanmakuArgs(
      roomId: '1',
      uid: '12345',
      devid: 'fixture-device',
      jwt: 'fixture-jwt',
      ltkid: 'fixture-ltkid',
      stk: 'fixture-stk');
Future<void> tick() => Future<void>.delayed(Duration.zero);
void main() {
  test('single room sender defaults active and can log in', () async {
    final h = SocketHarness();
    final d = room(h);
    expect(d.senderActive, true);
    final sending = d.sendDanmaku('hello');
    await tick();
    final socket = h.sockets.single;
    socket.onReady!();
    expect(socket.sent, hasLength(1));
    socket.onMessage!(d.serializeDouyu('type@=loginres/userid@=12345/'));
    await tick();
    expect(socket.sent, hasLength(2));
    socket.onMessage!(d.serializeDouyu('type@=chatres/res@=0/'));
    expect(await sending, isNull);
    await d.stop();
  });
  test('release prevents delayed preheat and preserves receiver', () async {
    final h = SocketHarness();
    final d = room(h);
    final receiver = FakeSocket(
        url: 'wss://fixture.invalid',
        heartBeatTime: 1,
        headers: {},
        onMessage: (_) {},
        onReady: () {},
        onHeartBeat: () {},
        onReconnect: () {},
        onClose: (_) {});
    d.webScoketUtils = receiver;
    await d.setSenderActive(false);
    await d.setSenderActive(true);
    await d.setSenderActive(false);
    await tick();
    expect(h.sockets, isEmpty);
    expect(receiver.closes, 0);
    expect(await d.sendDanmaku('hello'), contains('切换'));
    await d.stop();
  });
  test('late login and ready from old lease cannot take over new sender',
      () async {
    final h = SocketHarness();
    final d = room(h);
    final oldSend = d.sendDanmaku('old');
    await tick();
    final old = h.sockets.single;
    await d.setSenderActive(false);
    expect(await oldSend, contains('切换'));
    await d.setSenderActive(true);
    await tick();
    await tick();
    final current = h.sockets.last;
    expect(identical(current, old), false);
    old.onReady!();
    old.onMessage!(d.serializeDouyu('type@=loginres/userid@=12345/'));
    expect(old.sent, isEmpty);
    expect(old.closes, greaterThan(0));
    current.onReady!();
    current.onMessage!(d.serializeDouyu('type@=loginres/userid@=12345/'));
    await tick();
    final sending = d.sendDanmaku('new');
    await tick();
    expect(current.sent.length, 2);
    current.onMessage!(d.serializeDouyu('type@=chatres/res@=0/'));
    expect(await sending, isNull);
    await d.stop();
  });
}
