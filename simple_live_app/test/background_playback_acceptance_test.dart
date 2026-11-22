import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/services/background_playback.dart';

// 独立验收测试：Android 后台/锁屏媒体控件（MediaSession + MediaStyle 通知）。
//
// 覆盖三块：
//  1) EventChannel -> commands 的命令映射（play/pause/stop、空事件过滤、广播、非 Android 空流）；
//  2) Dart -> 原生的状态回写（updateState / updateMetadata / start / stop，非 Android 静默）；
//  3) 源码契约核对：原生 Service / MainActivity、Dart 桥接与直播间控制器的双向同步、
//     多开(embedded) 守卫、AndroidManifest 前台服务声明、pubspec 版本号。
//
// 本测试只读取生产源码做静态断言，不修改任何生产代码。

Directory _resolveRoot() {
  final candidates = <Directory>[];
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    candidates.add(dir);
    candidates.add(Directory('${dir.path}/simple_live_app'));
    final parent = dir.parent;
    if (parent.path == dir.path) {
      break;
    }
    dir = parent;
  }
  const marker =
      'android/app/src/main/kotlin/com/xycz/simple_live/PlaybackService.kt';
  for (final c in candidates) {
    if (File('${c.path}/$marker').existsSync()) {
      return c;
    }
  }
  return Directory.current;
}

String _read(String relative) {
  final root = _resolveRoot();
  final file = File('${root.path}/$relative');
  if (!file.existsSync()) {
    fail('找不到源码文件: $relative (root=${root.path})');
  }
  return file.readAsStringSync();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannelName = 'com.xycz.simple_live/background_playback';
  const eventChannelName = 'com.xycz.simple_live/background_playback_events';
  const methodChannel = MethodChannel(methodChannelName);
  const eventChannel = EventChannel(eventChannelName);
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

  group('EventChannel -> commands 命令映射', () {
    test('原生 play/pause/stop 依次映射为命令流', () async {
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
      final sub = BackgroundPlayback.commands.listen(received.add);
      await Future<void>.delayed(Duration.zero);
      expect(sink, isNotNull);

      sink!.success('play');
      sink!.success('pause');
      sink!.success('stop');
      sink!.success('previous');
      sink!.success('next');
      await Future<void>.delayed(Duration.zero);

      expect(received, <String>['play', 'pause', 'stop', 'previous', 'next']);
      await sub.cancel();
    });

    test('空/无效事件被过滤，只保留有意义的命令', () async {
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
      final sub = BackgroundPlayback.commands.listen(received.add);
      await Future<void>.delayed(Duration.zero);

      sink!.success('');
      sink!.success(null);
      sink!.success('play');
      await Future<void>.delayed(Duration.zero);

      expect(received, <String>['play']);
      await sub.cancel();
    });

    test('命令流是广播流，多个监听者都能收到同一命令', () async {
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

      final a = <String>[];
      final b = <String>[];
      final subA = BackgroundPlayback.commands.listen(a.add);
      final subB = BackgroundPlayback.commands.listen(b.add);
      await Future<void>.delayed(Duration.zero);

      sink!.success('pause');
      await Future<void>.delayed(Duration.zero);

      expect(a, <String>['pause']);
      expect(b, <String>['pause']);
      await subA.cancel();
      await subB.cancel();
    });

    test('非 Android 平台 commands 为空流且不订阅原生', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(BackgroundPlayback.isSupported, isFalse);
      expect(await BackgroundPlayback.commands.isEmpty, isTrue);
    });
  });

  group('Dart -> 原生 状态回写', () {
    test('updateState 对 playing/paused/buffering 逐项回写正确参数', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(methodChannel, (call) async {
        calls.add(call);
        return true;
      });

      for (final state in <String>['playing', 'paused', 'buffering']) {
        await BackgroundPlayback.updateState(state);
      }

      expect(calls.length, 3);
      expect(calls.map((c) => c.method), everyElement('updateState'));
      expect(
        calls.map((c) => (c.arguments as Map)['state']).toList(),
        <String>['playing', 'paused', 'buffering'],
      );
    });

    test('updateMetadata 携带直播标题、主播名、头像与平台图标字节', () async {
      MethodCall? captured;
      messenger.setMockMethodCallHandler(methodChannel, (call) async {
        captured = call;
        return true;
      });

      final bytes = Uint8List.fromList(<int>[1, 2, 3, 4]);
      final platform = Uint8List.fromList(<int>[7, 8]);
      await BackgroundPlayback.updateMetadata(
        title: '今晚八点直播',
        artist: '主播小明',
        source: '斗鱼直播',
        avatarBytes: bytes,
        platformIconBytes: platform,
      );

      expect(captured?.method, 'updateMetadata');
      final args = captured?.arguments as Map;
      expect(args['title'], '今晚八点直播');
      expect(args['artist'], '主播小明');
      expect(args['source'], '斗鱼直播');
      expect(args['avatar'], bytes);
      expect(args['platformIcon'], platform);
    });

    test('updateMetadata 无头像时仍回传标题与主播名', () async {
      MethodCall? captured;
      messenger.setMockMethodCallHandler(methodChannel, (call) async {
        captured = call;
        return true;
      });

      await BackgroundPlayback.updateMetadata(title: '标题', artist: '主播');

      final args = captured?.arguments as Map;
      expect(args['title'], '标题');
      expect(args['artist'], '主播');
      expect(args['avatar'], isNull);
    });

    test('start 携带标题、artist、头像与平台图标字节', () async {
      MethodCall? captured;
      messenger.setMockMethodCallHandler(methodChannel, (call) async {
        captured = call;
        return true;
      });

      final bytes = Uint8List.fromList(<int>[9, 9, 9]);
      final platform = Uint8List.fromList(<int>[5, 6]);
      await BackgroundPlayback.start(
        '直播标题',
        artist: '主播名',
        source: '哔哩哔哩',
        avatarBytes: bytes,
        platformIconBytes: platform,
      );

      expect(captured?.method, 'start');
      final args = captured?.arguments as Map;
      expect(args['title'], '直播标题');
      expect(args['artist'], '主播名');
      expect(args['source'], '哔哩哔哩');
      expect(args['avatar'], bytes);
      expect(args['platformIcon'], platform);
    });

    test('stop 触发 stop 方法调用', () async {
      MethodCall? captured;
      messenger.setMockMethodCallHandler(methodChannel, (call) async {
        captured = call;
        return true;
      });

      await BackgroundPlayback.stop();
      expect(captured?.method, 'stop');
    });

    test('非 Android 平台不调用任何通道方法', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(methodChannel, (call) async {
        calls.add(call);
        return true;
      });

      await BackgroundPlayback.start('标题');
      await BackgroundPlayback.stop();
      await BackgroundPlayback.updateState('playing');
      await BackgroundPlayback.updateMetadata(title: '标题', artist: '主播');

      expect(calls, isEmpty);
    });
  });

  group('源码契约核对（设计一致性）', () {
    test('PlaybackService 含 MediaSession / MediaStyle / 播放暂停停止 / 封面 / 释放', () {
      final kt = _read(
          'android/app/src/main/kotlin/com/xycz/simple_live/PlaybackService.kt');
      expect(kt.contains('import android.media.session.MediaSession'), isTrue);
      expect(kt.contains('import android.media.session.PlaybackState'), isTrue);
      expect(kt.contains('MediaSession(this, MEDIA_SESSION_TAG)'), isTrue);
      expect(kt.contains('Notification.MediaStyle()'), isTrue);
      expect(
          kt.contains('setMediaSession(mediaSession?.sessionToken)'), isTrue);
      expect(kt.contains('setShowActionsInCompactView'), isTrue);
      expect(kt.contains('PlaybackState.ACTION_PLAY'), isTrue);
      expect(kt.contains('PlaybackState.ACTION_PAUSE'), isTrue);
      expect(kt.contains('PlaybackState.ACTION_STOP'), isTrue);
      expect(kt.contains('METADATA_KEY_ALBUM_ART'), isTrue);
      expect(kt.contains('mediaSession?.release()'), isTrue);
      expect(kt.contains('PendingIntent.getActivity'), isTrue);
      expect(kt.contains('MainActivity::class.java'), isTrue);
      expect(kt.contains('FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK'), isTrue);
      expect(kt.contains('dispatchCommand("play"'), isTrue);
      expect(kt.contains('dispatchCommand("pause"'), isTrue);
      expect(kt.contains('onCommand?.invoke("stop")'), isTrue);
      expect(kt.contains('fun updateState'), isTrue);
      expect(kt.contains('fun updateMetadata'), isTrue);
      expect(kt.contains('EXTRA_SOURCE'), isTrue);
      expect(kt.contains('EXTRA_STARTED_AT'), isTrue);
      expect(kt.contains('METADATA_KEY_ALBUM'), isTrue);
      expect(kt.contains('setSubText('), isTrue);
      expect(kt.contains('setUsesChronometer(true)'), isTrue);
      expect(kt.contains('EXTRA_PLATFORM_ICON'), isTrue);
      expect(kt.contains('ACTION_PREVIOUS'), isTrue);
      expect(kt.contains('ACTION_NEXT'), isTrue);
      expect(kt.contains('onSkipToPrevious'), isTrue);
      expect(kt.contains('onSkipToNext'), isTrue);
      expect(kt.contains('dispatchNavigation'), isTrue);
      expect(kt.contains('setLargeIcon(artworkBitmap)'), isTrue);
      expect(kt.contains('setShowActionsInCompactView(0, 1, 2)'), isTrue);
      expect(kt.contains('composeArtwork('), isTrue);
    });

    test('MainActivity 暴露 EventChannel 回传与 updateState/updateMetadata', () {
      final kt = _read(
          'android/app/src/main/kotlin/com/xycz/simple_live/MainActivity.kt');
      expect(kt.contains('com.xycz.simple_live/background_playback_events'),
          isTrue);
      expect(kt.contains('EventChannel('), isTrue);
      expect(
          kt.contains(
              'PlaybackService.onCommand = { command -> events?.success(command) }'),
          isTrue);
      expect(kt.contains('"updateState"'), isTrue);
      expect(kt.contains('"updateMetadata"'), isTrue);
      expect(kt.contains('cleanUpFlutterEngine'), isTrue);
    });

    test('live_room_controller 双向同步且对 embedded 多开路径守卫', () {
      final dart = _read('lib/modules/live_room/live_room_controller.dart');
      expect(dart.contains('BackgroundPlayback.commands.listen'), isTrue);
      expect(dart.contains("case 'play':"), isTrue);
      expect(dart.contains("case 'pause':"), isTrue);
      expect(dart.contains("case 'stop':"), isTrue);
      expect(dart.contains("case 'previous':"), isTrue);
      expect(dart.contains("case 'next':"), isTrue);
      expect(dart.contains('_switchBackgroundRoom'), isTrue);
      expect(dart.contains('_loadPlatformIconBytes'), isTrue);
      expect(dart.contains('platformIconBytes: platformIconBytes'), isTrue);
      expect(
          dart.contains("unawaited(BackgroundPlayback.updateState('playing'))"),
          isTrue);
      expect(dart.contains('BackgroundPlayback.updateState'), isTrue);
      expect(dart.contains('syncBackgroundPlayback'), isTrue);
      expect(
          dart.contains('if (!embedded) BackgroundPlayback.stop();'), isTrue);
      expect(dart.contains('if (isClosed || _roomClosing || embedded) return;'),
          isTrue);
      expect(dart.contains('_bgSubscriptionGeneration'), isTrue);
    });

    test('AndroidManifest 声明 mediaPlayback 前台服务与必要权限', () {
      final manifest = _read('android/app/src/main/AndroidManifest.xml');
      expect(manifest.contains('android:foregroundServiceType="mediaPlayback"'),
          isTrue);
      expect(manifest.contains('.PlaybackService'), isTrue);
      expect(manifest.contains('FOREGROUND_SERVICE_MEDIA_PLAYBACK'), isTrue);
      expect(manifest.contains('POST_NOTIFICATIONS'), isTrue);
    });

    test('pubspec 版本号已升到 1.12.0+13120', () {
      final pubspec = _read('pubspec.yaml');
      expect(pubspec.contains('version: 1.12.0+13120'), isTrue);
    });
  });
}
