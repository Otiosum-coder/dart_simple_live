import 'dart:async';
import 'dart:ui' as ui;

import 'package:canvas_danmaku/danmaku_screen.dart';
import 'package:canvas_danmaku/models/danmaku_content_item.dart';
import 'package:canvas_danmaku/scroll_danmaku_painter.dart';
import 'package:canvas_danmaku/special_danmaku_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/multi_live/integration/multi_live_media.dart';
import 'package:simple_live_app/modules/multi_live/session/multi_live_room_session.dart';

class _SettingsBoundary implements MultiLiveRoomDriver {
  final volumeStarted = Completer<void>();
  final volumeReply = Completer<void>();
  final volumes = <double>[];
  final visibility = <bool>[];

  @override
  LiveRoomController? get room => null;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> setVolume(double volume) async {
    volumes.add(volume);
    if (volume == 24 && !volumeStarted.isCompleted) {
      volumeStarted.complete();
      await volumeReply.future;
    }
  }

  @override
  Future<void> setDanmakuVisible(bool visible) async => visibility.add(visible);

  @override
  Future<void> setSenderActive(bool active) async {}

  @override
  Future<String?> sendDanmaku(String text) async =>
      throw UnsupportedError('Unexpected send in settings probe');

  @override
  Future<void> close() async {}
}

Future<Object?> _settingsOutcome(Future<void> operation) => operation
    .then<Object?>((_) => null, onError: (Object error, StackTrace _) => error);

class _OfflineSettings extends AppSettingsController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

class _NativeBoundary extends PlatformPlayer {
  _NativeBoundary() : super(configuration: const PlayerConfiguration());

  final opens = <String>[];
  final firstOpen = Completer<void>();
  final firstOpenStarted = Completer<void>();
  int activeOpens = 0;
  int peakOpens = 0;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opens.add((playable as Playlist).medias.single.uri);
    activeOpens++;
    if (activeOpens > peakOpens) peakOpens = activeOpens;
    try {
      if (opens.length == 1) {
        firstOpenStarted.complete();
        await firstOpen.future;
      }
    } finally {
      activeOpens--;
    }
  }
}

class _OfflineVideo implements VideoController {
  _OfflineVideo(this.player);

  @override
  final Player player;
  @override
  final notifier = ValueNotifier<PlatformVideoController?>(null);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _OfflineRoom extends LiveRoomController {
  _OfflineRoom(String id)
      : super(pSite: Sites.allSites['huya']!, pRoomId: id, embedded: true) {
    showDanmakuState.value = true;
    currentLineIndex = 0;
  }

  final boundary = _NativeBoundary();
  late final _player = Player(platformPlayer: boundary);
  late final _video = _OfflineVideo(_player);
  int audioApplications = 0;

  @override
  Player get player => _player;
  @override
  VideoController get videoController => _video;

  @override
  Future<void> initializePlayer() async {}
  @override
  Future<void> applyNetworkBuffering() async {}
  @override
  Future<void> applyAudioOnly() async => audioApplications++;

  Future<void> disposeInjectedPlayer() async {
    // The injected player bypasses the production native factory.
    await _player.dispose();
    _video.notifier.dispose();
  }
}

T _painter<T extends CustomPainter>(WidgetTester tester, _OfflineRoom room) =>
    tester
        .widgetList<CustomPaint>(find.descendant(
          of: find.byKey(ObjectKey(room)),
          matching: find.byType(CustomPaint),
        ))
        .map((widget) => widget.painter)
        .whereType<T>()
        .single;

SpecialDanmakuContentItem _special(int duration) => SpecialDanmakuContentItem(
      '相同内容，不同显示实例',
      duration: duration,
      color: Colors.orange,
      fontSize: 20,
      translateXTween: Tween(begin: 0.05, end: 0.7),
      translateYTween: Tween(begin: 0.1, end: 0.3),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final duringVolume in [false, true]) {
    final timing =
        duringVolume ? 'while volume is pending' : 'in the same batch';
    test('volume failure preserves visibility requested $timing', () async {
      final boundary = _SettingsBoundary();
      final session = MultiLiveRoomSession(
        id: 'settings-failure',
        spec: const MultiLiveRoomSpec(siteId: 'huya', roomId: '501'),
        driverFactory: (_) => boundary,
      );
      addTearDown(() async {
        if (!boundary.volumeReply.isCompleted) boundary.volumeReply.complete();
        await session.close();
      });

      await session.initialize();
      expect(boundary.visibility, [true]);
      final volume = _settingsOutcome(session.setVolume(24));
      if (duringVolume) await boundary.volumeStarted.future;
      final hide = _settingsOutcome(session.setDanmakuVisible(false));
      await boundary.volumeStarted.future;

      final failure = StateError('injected native volume failure');
      boundary.volumeReply.completeError(failure);
      expect(await volume, same(failure));
      final visibilityFailure = await hide;
      expect(session.spec.danmakuVisible, isFalse);
      expect(boundary.visibility, [true, false],
          reason:
              'The latest visibility must reach the overlay without another input');
      expect(visibilityFailure, isNull,
          reason: 'The visibility request must report its own outcome');
      await session.setVolume(16);
      expect(boundary.volumes, [100, 24, 16]);
    });
  }

  testWidgets(
      'four embedded views release owned layouts independently on hide, expiry and removal',
      (tester) async {
    Get.put<AppSettingsController>(_OfflineSettings());
    final rooms = List.generate(4, (i) => _OfflineRoom('offline-$i'));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      for (final room in rooms) {
        await room.disposeInjectedPlayer();
        room.scrollController.dispose();
      }
      Get.reset();
    });

    await tester.pumpWidget(MaterialApp(
        home: Column(children: [
      for (final room in rooms)
        Expanded(child: MultiLiveMedia(key: ObjectKey(room), room: room)),
    ])));
    expect(find.byType(DanmakuScreen), findsNWidgets(4));
    final controllers = rooms.map((room) => room.danmakuController!).toList();
    expect(controllers.toSet(), hasLength(4));
    final shared = _special(60000);
    const pressure = 240;
    for (final controller in controllers) {
      for (var i = 0; i < pressure; i++) {
        controller.addDanmaku(DanmakuContentItem('滚动测试 $i'));
      }
      // More than the production batch threshold of ten.
      for (var i = 0; i < 12; i++) {
        controller.addDanmaku(shared);
      }
    }
    await tester.pump();

    final scroll = rooms
        .map((room) =>
            _painter<ScrollDanmakuPainter>(tester, room).scrollDanmakuItems)
        .toList();
    final paragraphs = scroll.map((items) {
      expect(items.length, allOf(greaterThan(0), lessThan(pressure)));
      return items
          .expand((item) => [item.paragraph!, item.strokeParagraph!])
          .toList();
    }).toList();
    final special = rooms
        .map((room) => _painter<SpecialDanmakuPainter>(tester, room))
        .toList();
    final layouts = special.map((painter) {
      expect(painter.specialDanmakuItems, hasLength(12));
      return painter.specialDanmakuItems.map((item) {
        expect(item.content, same(shared));
        return item.painterCache!;
      }).toList();
    }).toList();
    expect(layouts.expand((group) => group).toSet(), hasLength(48));

    final pictures = <ui.Picture>[];
    final previousCreate = ui.Picture.onCreate;
    ui.Picture.onCreate = (picture) {
      previousCreate?.call(picture);
      pictures.add(picture);
    };
    try {
      for (var frame = 0; frame < 5; frame++) {
        for (final painter in special) {
          final recorder = ui.PictureRecorder();
          painter.paint(Canvas(recorder), const Size(800, 150));
          recorder.endRecording().dispose();
        }
      }
    } finally {
      ui.Picture.onCreate = previousCreate;
    }
    // One batched and one enclosing picture for each pane and each paint.
    expect(pictures, hasLength(40));
    expect(pictures.every((picture) => picture.debugDisposed), isTrue);

    final expired = _special(0);
    controllers[1].addDanmaku(expired);
    final expiredLayout = special[1]
        .specialDanmakuItems
        .singleWhere((item) => identical(item.content, expired))
        .painterCache!;
    controllers[1].pause();
    await tester.pump(const Duration(milliseconds: 120));
    expect(expiredLayout.debugDisposed, isFalse);
    controllers[1].resume();
    await tester.pump(const Duration(milliseconds: 100));
    expect(expiredLayout.debugDisposed, isTrue);
    expect(special[1].specialDanmakuItems, hasLength(12));

    rooms.first.showDanmakuState.value = false;
    await tester.pump();
    expect(rooms.first.danmakuController, isNull);
    expect(controllers.first.running, isFalse);
    expect(find.byType(DanmakuScreen), findsNWidgets(3));
    expect(layouts.first.every((layout) => layout.debugDisposed), isTrue);
    expect(
        paragraphs.first.every((paragraph) => paragraph.debugDisposed), isTrue);
    expect(
        layouts
            .skip(1)
            .expand((group) => group)
            .every((layout) => !layout.debugDisposed),
        isTrue);
    expect(
        paragraphs
            .skip(1)
            .expand((group) => group)
            .every((paragraph) => !paragraph.debugDisposed),
        isTrue);

    rooms.first.showDanmakuState.value = true;
    await tester.pump();
    final fresh = rooms.first.danmakuController!;
    expect(fresh, isNot(same(controllers.first)));
    fresh.addDanmaku(shared);
    await tester.pump();
    final freshLayout = _painter<SpecialDanmakuPainter>(tester, rooms.first)
        .specialDanmakuItems
        .single
        .painterCache!;
    controllers.first.clear();
    controllers.first.addDanmaku(shared);
    await tester.pump();
    expect(freshLayout.debugDisposed, isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 350));
    expect(rooms.every((room) => room.danmakuController == null), isTrue);
    expect(fresh.running, isFalse);
    expect(freshLayout.debugDisposed, isTrue);
    expect(
        layouts
            .expand((group) => group)
            .every((layout) => layout.debugDisposed),
        isTrue);
    expect(
        paragraphs
            .expand((group) => group)
            .every((paragraph) => paragraph.debugDisposed),
        isTrue);
    expect(tester.takeException(), isNull);
  });

  test(
      'obsolete pending native open serializes replacement and error during close',
      () async {
    Get.put<AppSettingsController>(_OfflineSettings());
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const toggle =
        'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle';
    messenger.setMockMessageHandler(toggle,
        (_) async => const StandardMessageCodec().encodeMessage([null]));
    final rooms = List.generate(2, (i) => _OfflineRoom('late-open-$i'));
    addTearDown(() async {
      for (final room in rooms) {
        if (!room.boundary.firstOpen.isCompleted) {
          room.boundary.firstOpen.complete();
        }
        await room.closeRoom();
        await room.disposeInjectedPlayer();
      }
      messenger.setMockMessageHandler(toggle, null);
      Get.reset();
    });
    const initial = 'https://offline.invalid/initial';
    const latest = 'https://offline.invalid/revision-127';
    final drained = <Future<void>>[];
    for (final room in rooms) {
      room.playUrls.assignAll([initial]);
      drained.add(room.initPlaylist());
    }
    await Future.wait(
        rooms.map((room) => room.boundary.firstOpenStarted.future));
    for (var i = 0; i < rooms.length; i++) {
      final room = rooms[i];
      expect(room.boundary.opens, [initial]);
      for (var revision = 0; revision < 128; revision++) {
        room.playUrls.assignAll(['https://offline.invalid/revision-$revision']);
        expect(room.initPlaylist(), same(drained[i]));
      }
    }
    await Future<void>.delayed(const Duration(seconds: 13));
    final closingRoom = rooms.first;
    final keptRoom = rooms.last;
    for (final room in rooms) {
      expect(room.boundary.opens, [initial]);
      expect(room.boundary.activeOpens, 1);
    }
    final closing = closingRoom.closeRoom();
    expect(closingRoom.closeRoom(), same(closing));
    var closeCompleted = false;
    unawaited(closing.then((_) => closeCompleted = true));
    await Future<void>.delayed(Duration.zero);
    expect(closeCompleted, isFalse);

    keptRoom.boundary.firstOpen
        .completeError(StateError('late offline open failure'));
    await drained[1];
    expect(keptRoom.boundary.opens, [initial, latest]);
    expect(keptRoom.boundary.peakOpens, 1);
    expect(keptRoom.audioApplications, 1);
    expect(closeCompleted, isFalse);

    closingRoom.boundary.firstOpen
        .completeError(StateError('late offline close failure'));
    await Future.wait([drained[0], closing]);
    expect(closeCompleted, isTrue);
    expect(closingRoom.boundary.opens, [initial]);
    expect(closingRoom.boundary.activeOpens, 0);
    expect(closingRoom.boundary.peakOpens, 1);
    expect(closingRoom.audioApplications, 0);
  }, timeout: const Timeout(Duration(seconds: 30)));
}
