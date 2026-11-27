import 'dart:async';

import 'package:simple_live_core/src/common/core_log.dart';
import 'package:simple_live_core/src/common/web_socket_util.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// Exercise handshake, stream and timer ordering without real sockets or time.
class _ManualTimer implements Timer {
  _ManualTimer(this.duration, this.periodic, this.callback);
  final Duration duration;
  final bool periodic;
  final void Function(Timer) callback;
  bool _active = true;
  int _tick = 0;

  @override
  bool get isActive => _active;
  @override
  int get tick => _tick;
  @override
  void cancel() => _active = false;

  void fire() {
    if (!_active) return;
    _tick++;
    if (!periodic) _active = false;
    callback(this);
  }
}

class _ManualTimers {
  final created = <_ManualTimer>[];
  List<_ManualTimer> get active => created.where((t) => t.isActive).toList();
  List<_ManualTimer> get retries => active.where((t) => !t.periodic).toList();
  List<_ManualTimer> get heartbeats => active.where((t) => t.periodic).toList();

  T run<T>(T Function() action) => runZoned(
    action,
    zoneSpecification: ZoneSpecification(
      createTimer: (self, parent, zone, duration, callback) {
        final timer = _ManualTimer(
          duration,
          false,
          (_) => zone.runGuarded(callback),
        );
        created.add(timer);
        return timer;
      },
      createPeriodicTimer: (self, parent, zone, duration, callback) {
        final timer = _ManualTimer(
          duration,
          true,
          (timer) => zone.runGuarded(() => callback(timer)),
        );
        created.add(timer);
        return timer;
      },
    ),
  );
}

class _FakeSink implements WebSocketSink {
  final sent = <dynamic>[];
  int closes = 0;
  bool failAdd = false;
  bool failClose = false;
  @override
  void add(dynamic data) {
    if (failAdd) throw StateError('send failed');
    sent.add(data);
  }

  @override
  Future<void> close([int? closeCode, String? closeReason]) {
    closes++;
    return failClose
        ? Future<void>.error(StateError('close failed'))
        : Future<void>.value();
  }

  @override
  Future<void> get done => Future<void>.value();
  @override
  void addError(Object error, [StackTrace? stackTrace]) => throw error;
  @override
  Future<void> addStream(Stream<dynamic> stream) async {
    await for (final data in stream) {
      add(data);
    }
  }
}

class _FakeChannel implements IOWebSocketChannel {
  _FakeChannel() {
    incoming.onListen = () => listens++;
    incoming.onCancel = () {
      cancels++;
      if (failCancel) return Future<void>.error(StateError('cancel failed'));
    };
  }
  final handshake = Completer<void>();
  final incoming = StreamController<dynamic>(sync: true);
  @override
  final _FakeSink sink = _FakeSink();
  _FakeSink get fakeSink => sink;
  int listens = 0;
  int cancels = 0;
  bool failCancel = false;

  @override
  Future<void> get ready => handshake.future;
  @override
  Stream<dynamic> get stream => incoming.stream;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Fixture {
  _Fixture({
    Function()? onReady,
    Function()? onHeartBeat,
    Function(dynamic)? onMessage,
    Function()? onReconnect,
    Function(String)? onClose,
  }) {
    socket = WebScoketUtils(
      url: 'wss://primary.invalid',
      backupUrl: 'wss://backup.invalid',
      headers: {'fixture': 'header'},
      heartBeatTime: 1000,
      channelFactory: (url, {connectTimeout, headers}) {
        urls.add(url);
        expect(connectTimeout, const Duration(seconds: 10));
        expect(headers, {'fixture': 'header'});
        final channel = _FakeChannel();
        channels.add(channel);
        return channel;
      },
      onReady: () {
        readyCalls++;
        return onReady?.call();
      },
      onHeartBeat: () {
        heartbeatCalls++;
        return onHeartBeat?.call();
      },
      onMessage: (data) {
        messages.add(data);
        return onMessage?.call(data);
      },
      onReconnect: () {
        reconnectCalls++;
        return onReconnect?.call();
      },
      onClose: (message) {
        closes.add(message);
        return onClose?.call(message);
      },
    );
  }
  late final WebScoketUtils socket;
  final timers = _ManualTimers();
  final channels = <_FakeChannel>[];
  final urls = <String>[];
  final messages = <dynamic>[];
  final closes = <String>[];
  int readyCalls = 0;
  int heartbeatCalls = 0;
  int reconnectCalls = 0;

  void connect({bool retry = false}) =>
      timers.run(() => socket.connect(retry: retry));

  Future<void> dispose() async {
    socket.close();
    for (final channel in channels) {
      if (!channel.handshake.isCompleted) channel.handshake.complete();
      await channel.incoming.close();
    }
    await _pump();
    expect(timers.active, isEmpty);
  }
}

Future<void> _pump() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.value();
  }
}

void main() {
  late bool previousLogging;
  setUp(() {
    previousLogging = CoreLog.enableLog;
    CoreLog.enableLog = false;
  });
  tearDown(() => CoreLog.enableLog = previousLogging);

  for (final succeeds in [true, false]) {
    final outcome = succeeds ? 'success' : 'error';
    test('close during handshake ignores late $outcome', () async {
      final f = _Fixture();
      addTearDown(f.dispose);
      f.connect();
      final channel = f.channels.single;
      // Subscribe immediately to consume the stream side of handshake errors.
      expect(channel.listens, 1);
      f.socket.close();
      f.socket.close();
      if (succeeds) {
        channel.handshake.complete();
      } else {
        channel.handshake.completeError(StateError('late handshake failure'));
      }
      await _pump();
      expect(f.readyCalls, 0);
      expect(f.closes, isEmpty);
      expect(f.channels, hasLength(1));
      expect(channel.cancels, 1);
      expect(channel.fakeSink.closes, 1);
      expect(f.socket.status, SocketStatus.closed);
      expect(f.socket.webSocket, isNull);
      expect(f.socket.streamSubscription, isNull);
      expect(f.timers.active, isEmpty);
    });
  }

  for (final oldSucceeds in [true, false]) {
    final outcome = oldSucceeds ? 'success' : 'failure';
    test('old handshake $outcome cannot replace new attempt', () async {
      final f = _Fixture();
      addTearDown(f.dispose);
      f.connect();
      final old = f.channels.single;
      f.connect();
      final current = f.channels.last;
      current.handshake.complete();
      await _pump();
      final heartbeat = f.socket.heartBeatTimer;
      if (oldSucceeds) {
        old.handshake.complete();
      } else {
        old.handshake.completeError(StateError('obsolete handshake'));
      }
      await _pump();
      old.incoming.add('obsolete');
      current.incoming.add('current');
      expect(f.messages, ['current']);
      expect(f.readyCalls, 1);
      expect(current.listens, 1);
      expect(old.cancels, 1);
      expect(old.fakeSink.closes, 1);
      expect(f.socket.webSocket, same(current));
      expect(f.socket.heartBeatTimer, same(heartbeat));
      expect(f.timers.heartbeats, hasLength(1));
      expect(f.timers.retries, isEmpty);
      f.timers.heartbeats.single.fire();
      expect(f.heartbeatCalls, 1);
    });
  }

  test(
    'old success before new handshake does not mark the new socket ready',
    () async {
      final f = _Fixture();
      addTearDown(f.dispose);
      f.connect();
      final old = f.channels.single;
      f.connect();
      old.handshake.complete();
      await _pump();
      expect(f.readyCalls, 0);
      expect(f.timers.active, isEmpty);
      expect(f.socket.status, SocketStatus.closed);
      f.channels.last.handshake.complete();
      await _pump();
      expect(f.readyCalls, 1);
      expect(f.timers.heartbeats, hasLength(1));
    },
  );

  test(
    'handshake error plus stream error/done schedules one backup retry',
    () async {
      final f = _Fixture();
      addTearDown(f.dispose);
      f.connect();
      final old = f.channels.single;
      old.handshake.completeError(StateError('handshake'));
      old.incoming.addError(StateError('same transport failure'));
      final done = old.incoming.close();
      await _pump();
      await done;
      expect(f.closes, hasLength(1));
      expect(f.reconnectCalls, 0);
      expect(f.socket.reconnectTime, 1);
      expect(f.timers.retries, hasLength(1));
      expect(old.cancels, 1);
      final retry = f.timers.retries.single;
      expect(retry.duration, const Duration(seconds: 5));
      retry.fire();
      retry.fire();
      expect(f.urls, ['wss://primary.invalid', 'wss://backup.invalid']);
      f.channels.last.handshake.complete();
      await _pump();
      expect(f.readyCalls, 1);
      expect(f.socket.reconnectTimer, isNull);
      expect(f.timers.retries, isEmpty);
      expect(f.timers.heartbeats, hasLength(1));
      f.channels.last.incoming.add('resumed');
      expect(f.socket.reconnectTime, 0);
    },
  );

  test(
    'disconnect cancels heartbeat and close cancels the pending retry',
    () async {
      final f = _Fixture();
      addTearDown(f.dispose);
      f.connect();
      final channel = f.channels.single;
      channel.handshake.complete();
      await _pump();
      final heartbeat = f.timers.heartbeats.single;
      await channel.incoming.close();
      await _pump();
      expect(f.reconnectCalls, 1);
      expect(heartbeat.isActive, isFalse);
      expect(channel.fakeSink.closes, 1);
      expect(f.timers.retries, hasLength(1));
      final retry = f.timers.retries.single;
      f.socket.close();
      retry.fire();
      heartbeat.fire();
      await _pump();
      expect(f.channels, hasLength(1));
      expect(f.heartbeatCalls, 0);
      expect(f.timers.active, isEmpty);
      f.connect();
      f.channels.last.handshake.complete();
      await _pump();
      expect(f.readyCalls, 2);
      expect(f.socket.status, SocketStatus.connected);
      expect(f.timers.heartbeats, hasLength(1));
    },
  );

  test(
    'retry budget is finite and explicit connect starts a fresh budget',
    () async {
      final f = _Fixture();
      addTearDown(f.dispose);
      f.socket.maxReconnectTime = 2;
      f.connect();
      for (var attempt = 0; attempt < 3; attempt++) {
        f.channels.last.handshake.completeError(StateError('offline'));
        await _pump();
        if (attempt < 2) {
          expect(f.timers.retries, hasLength(1));
          f.timers.retries.single.fire();
        }
      }
      expect(f.channels, hasLength(3));
      expect(f.socket.status, SocketStatus.closed);
      expect(f.socket.reconnectTime, 2);
      expect(f.timers.active, isEmpty);
      f.connect();
      expect(f.socket.reconnectTime, 0);
      f.channels.last.handshake.complete();
      await _pump();
      expect(f.socket.status, SocketStatus.connected);
    },
  );

  test(
    'zero retry budget leaves retry ownership to the platform sender',
    () async {
      final f = _Fixture();
      addTearDown(f.dispose);
      f.socket.maxReconnectTime = 0;
      f.connect();
      f.channels.single.handshake.completeError(StateError('offline'));
      await _pump();
      expect(f.channels, hasLength(1));
      expect(f.timers.active, isEmpty);
      expect(f.socket.status, SocketStatus.closed);
    },
  );

  test(
    'onReady may close synchronously without creating a heartbeat',
    () async {
      late final _Fixture f;
      f = _Fixture(onReady: () => f.socket.close());
      addTearDown(f.dispose);
      f.connect();
      f.channels.single.handshake.complete();
      await _pump();
      expect(f.readyCalls, 1);
      expect(f.socket.status, SocketStatus.closed);
      expect(f.timers.active, isEmpty);
    },
  );

  test(
    'onClose may connect again without the old failure scheduling a retry',
    () async {
      late final _Fixture f;
      f = _Fixture(onClose: (_) => f.connect());
      addTearDown(f.dispose);
      f.connect();
      f.channels.single.handshake.completeError(StateError('offline'));
      await _pump();
      expect(f.channels, hasLength(2));
      expect(f.timers.retries, isEmpty);
      f.channels.last.handshake.complete();
      await _pump();
      expect(f.readyCalls, 1);
      expect(f.timers.heartbeats, hasLength(1));
    },
  );

  test(
    'sync and async callback errors and transport cleanup errors are contained',
    () async {
      final f = _Fixture(
        onReady: () => throw StateError('ready callback'),
        onMessage: (_) => Future<void>.error(StateError('message callback')),
        onHeartBeat: () => Future<void>.error(StateError('heartbeat callback')),
        onClose: (_) => Future<void>.error(StateError('close callback')),
      );
      addTearDown(f.dispose);
      f.connect();
      final channel = f.channels.single;
      channel.handshake.complete();
      await _pump();
      channel.incoming.add('message');
      f.timers.heartbeats.single.fire();
      await _pump();
      expect(f.messages, ['message']);
      expect(f.heartbeatCalls, 1);
      channel.failCancel = true;
      channel.fakeSink.failClose = true;
      channel.fakeSink.failAdd = true;
      // sendMessage runs outside f.connect's timer zone, so the reconnect timer
      // it schedules must be created inside the manual-timer zone too.
      f.timers.run(() => f.socket.sendMessage('cannot write'));
      await _pump();
      expect(f.timers.heartbeats, isEmpty);
      expect(f.timers.retries, hasLength(1));
      expect(channel.cancels, 1);
      expect(channel.fakeSink.closes, 1);
      f.socket.close();
      await _pump();
      expect(f.timers.active, isEmpty);
    },
  );
}
