import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/services/background_playback.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel =
      MethodChannel('com.xycz.simple_live/background_playback');
  const eventChannel =
      EventChannel('com.xycz.simple_live/background_playback_events');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(methodChannel, null);
    messenger.setMockStreamHandler(eventChannel, null);
  });

  test('updateState 通过 MethodChannel 把播放状态回写原生', () async {
    MethodCall? captured;
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      if (call.method == 'updateState') captured = call;
      return true;
    });

    await BackgroundPlayback.updateState('playing');

    expect(captured?.method, 'updateState');
    expect(captured?.arguments, {'state': 'playing'});
  });

  test('updateMetadata 携带直播标题、主播名、开播时间与头像字节', () async {
    MethodCall? captured;
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      if (call.method == 'updateMetadata') captured = call;
      return true;
    });

    final bytes = Uint8List.fromList(<int>[1, 2, 3, 4]);
    final platform = Uint8List.fromList(<int>[7, 8]);
    await BackgroundPlayback.updateMetadata(
      title: '今晚八点直播',
      artist: '主播小明',
      source: '斗鱼直播',
      startedAtMillis: 1720000000000,
      avatarBytes: bytes,
      platformIconBytes: platform,
    );

    expect(captured?.method, 'updateMetadata');
    final args = captured?.arguments as Map;
    expect(args['title'], '今晚八点直播');
    expect(args['artist'], '主播小明');
    expect(args['source'], '斗鱼直播');
    expect(args['startedAtMillis'], 1720000000000);
    expect(args['avatar'], bytes);
    expect(args['platformIcon'], platform);
  });

  test('start 携带标题、artist、开播时间与头像字节', () async {
    MethodCall? captured;
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      if (call.method == 'start') captured = call;
      return true;
    });

    final bytes = Uint8List.fromList(<int>[9, 9, 9]);
    final platform = Uint8List.fromList(<int>[5, 6]);
    await BackgroundPlayback.start('直播标题',
        artist: '主播名',
        source: '哔哩哔哩',
        startedAtMillis: 1720000000001,
        avatarBytes: bytes,
        platformIconBytes: platform);

    expect(captured?.method, 'start');
    final args = captured?.arguments as Map;
    expect(args['title'], '直播标题');
    expect(args['artist'], '主播名');
    expect(args['source'], '哔哩哔哩');
    expect(args['startedAtMillis'], 1720000000001);
    expect(args['avatar'], bytes);
    expect(args['platformIcon'], platform);
  });

  test('commands 把原生媒体事件映射为 play/pause/stop/previous/next 命令', () async {
    MockStreamHandlerEventSink? sink;
    messenger.setMockStreamHandler(
      eventChannel,
      MockStreamHandler.inline(
        onListen: (Object? arguments, MockStreamHandlerEventSink events) {
          sink = events;
        },
        onCancel: (Object? arguments) {},
      ),
    );

    final received = <String>[];
    final subscription = BackgroundPlayback.commands.listen(received.add);
    // 等待 EventChannel 的 listen 完成注册
    await Future<void>.delayed(Duration.zero);

    expect(sink, isNotNull);
    sink!.success('play');
    sink!.success('pause');
    sink!.success('stop');
    sink!.success('previous');
    sink!.success('next');
    await Future<void>.delayed(Duration.zero);

    expect(received, <String>['play', 'pause', 'stop', 'previous', 'next']);
    await subscription.cancel();
  });

  test('非 Android 平台不推送命令（不注册 EventChannel）', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(BackgroundPlayback.isSupported, isFalse);
    expect(await BackgroundPlayback.commands.isEmpty, isTrue);
  });
}
