import 'dart:async';

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';

class MultiLiveMedia extends StatelessWidget {
  const MultiLiveMedia({super.key, required this.room});
  final LiveRoomController room;

  @override
  Widget build(BuildContext context) {
    final settings = AppSettingsController.instance;
    return Stack(
      fit: StackFit.expand,
      children: [
        _EmbeddedVideo(key: ObjectKey(room), room: room, settings: settings),
        IgnorePointer(
          child: Obx(() => room.showDanmakuState.value
              ? _EmbeddedDanmaku(
                  key: ObjectKey(room), room: room, settings: settings)
              : const SizedBox.shrink()),
        ),
        Obx(() {
          final detail = room.detail.value;
          final error = room.errorMsg.value;
          final message =
              switch ((room.loadError.value, room.playUrlEmpty.value)) {
            (true, _) => '加载房间失败',
            (_, true) => '当前账号无法播放此直播',
            _ when detail?.roomNotFound == true => '房间不存在',
            _ when detail?.status == false && !room.playerPlaying.value =>
              '未开播',
            _ when error.isNotEmpty => error,
            _ => null,
          };
          if (message != null) {
            return Center(
              child: Material(
                color: Colors.black87,
                child: Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text(message,
                          style: const TextStyle(color: Colors.white)),
                    ),
                    IconButton(
                      tooltip: '刷新房间',
                      color: Colors.white,
                      icon: const Icon(Icons.refresh),
                      onPressed: room.refreshRoom,
                    ),
                  ],
                ),
              ),
            );
          }
          return StreamBuilder<bool>(
            stream: room.player.stream.buffering,
            initialData: room.player.state.buffering,
            builder: (context, snapshot) =>
                detail == null || snapshot.data == true
                    ? const Center(child: CircularProgressIndicator())
                    : const SizedBox.shrink(),
          );
        }),
      ],
    );
  }
}

class _EmbeddedDanmaku extends StatefulWidget {
  const _EmbeddedDanmaku(
      {super.key, required this.room, required this.settings});

  final LiveRoomController room;
  final AppSettingsController settings;

  @override
  State<_EmbeddedDanmaku> createState() => _EmbeddedDanmakuState();
}

class _EmbeddedDanmakuState extends State<_EmbeddedDanmaku> {
  DanmakuController? _controller;

  @override
  void dispose() {
    if (identical(widget.room.danmakuController, _controller)) {
      widget.room.danmakuController = null;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    return DanmakuScreen(
      createdController: (controller) {
        _controller = controller;
        widget.room.initDanmakuController(controller);
      },
      option: DanmakuOption(
        fontSize: settings.danmuSize.value,
        area: settings.danmuArea.value,
        duration: settings.danmuSpeed.value.toInt(),
        opacity: settings.danmuOpacity.value,
        fontWeight: settings.danmuFontWeight.value,
      ),
    );
  }
}

class _EmbeddedVideo extends StatefulWidget {
  const _EmbeddedVideo({super.key, required this.room, required this.settings});

  final LiveRoomController room;
  final AppSettingsController settings;

  @override
  State<_EmbeddedVideo> createState() => _EmbeddedVideoState();
}

class _EmbeddedVideoState extends State<_EmbeddedVideo>
    with WidgetsBindingObserver {
  late final Worker _preference;
  late final StreamSubscription<bool> _playing;
  bool _background = false;
  bool _detached = false;
  bool _pausedByLifecycle = false;
  bool _running = false;
  bool _pending = false;

  bool get _shouldPause => _background && widget.settings.playerAutoPause.value;

  @override
  void initState() {
    super.initState();
    final binding = WidgetsBinding.instance;
    final state = binding.lifecycleState;
    _background =
        state == AppLifecycleState.hidden || state == AppLifecycleState.paused;
    binding.addObserver(this);
    _preference = ever(widget.settings.playerAutoPause, (_) => _schedule());
    // Streams may start or reconnect after the app has already gone to the background.
    _playing = widget.room.player.stream.playing.listen((playing) {
      if (playing && _shouldPause) _schedule();
    });
    _schedule();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _background = true;
      case AppLifecycleState.resumed:
        _background = false;
        _detached = false;
      case AppLifecycleState.detached:
        _detached = true;
        _pausedByLifecycle = false;
      case AppLifecycleState.inactive:
        // Phone system overlays and window focus are not a background cycle.
        return;
    }
    _schedule();
  }

  void _schedule() {
    _pending = true;
    if (!_running) unawaited(_reconcile());
  }

  Future<void> _reconcile() async {
    _running = true;
    final room = widget.room;
    final player = room.player;
    try {
      // A resume can arrive before the native pause has completed. Wait for
      // that pause before deciding which playback this view should restore.
      while (_pending &&
          mounted &&
          !_detached &&
          !room.isClosed &&
          !room.playerClosing) {
        _pending = false;
        if (_shouldPause) {
          if (!player.state.playing) continue;
          await room.runPlayerOperation(player.pause);
          if (mounted && !_detached && !room.isClosed && !room.playerClosing) {
            _pausedByLifecycle = !player.state.playing;
          }
        } else if (_pausedByLifecycle) {
          _pausedByLifecycle = false;
          if (!player.state.playing) await room.runPlayerOperation(player.play);
        }
      }
    } catch (_) {
      // A backend operation can fail during teardown. Do not resurrect a room.
      _pausedByLifecycle = false;
    } finally {
      _running = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _preference.dispose();
    unawaited(_playing.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Video(
        controller: widget.room.videoController,
        controls: NoVideoControls,
        wakelock: false,
        pauseUponEnteringBackgroundMode: false,
        resumeUponEnteringForegroundMode: false,
      );
}

class MultiLivePlaybackSettings extends StatefulWidget {
  const MultiLivePlaybackSettings({super.key, required this.room});
  final LiveRoomController room;

  @override
  State<MultiLivePlaybackSettings> createState() =>
      _MultiLivePlaybackSettingsState();
}

class _MultiLivePlaybackSettingsState extends State<MultiLivePlaybackSettings> {
  bool _changing = false;

  Future<void> _changeQuality(int index) async {
    final room = widget.room;
    if (_changing || room.isClosed || index >= room.qualites.length) return;
    setState(() => _changing = true);
    try {
      room.currentQuality = index;
      await room.getPlayUrl();
    } finally {
      if (mounted) setState(() => _changing = false);
    }
  }

  @override
  Widget build(BuildContext context) => Obx(() {
        final room = widget.room;
        final quality = room.currentQualityInfo.value;
        final line = room.currentLineInfo.value;
        final qualities = room.qualites.toList();
        final lineCount = room.playUrls.length;
        return ListView(children: [
          ListTile(
              title: const Text('清晰度'),
              subtitle: Text(quality.isEmpty ? '暂无可选清晰度' : quality)),
          for (var i = 0; i < qualities.length; i++)
            ListTile(
              title: Text(qualities[i].quality),
              selected: room.currentQuality == i,
              trailing:
                  room.currentQuality == i ? const Icon(Icons.check) : null,
              onTap: _changing ? null : () => _changeQuality(i),
            ),
          const Divider(),
          ListTile(
              title: const Text('线路'),
              subtitle: Text(line.isEmpty ? '暂无可选线路' : line)),
          for (var i = 0; i < lineCount; i++)
            ListTile(
              title: Text(room.lineLabel(i)),
              selected: room.currentLineIndex == i,
              trailing:
                  room.currentLineIndex == i ? const Icon(Icons.check) : null,
              onTap: _changing
                  ? null
                  : () {
                      if (i < room.playUrls.length) {
                        room.changePlayLine(i, fromUser: true);
                      }
                    },
            ),
        ]);
      });
}
