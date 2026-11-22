import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/routes/app_navigation.dart';

import '../multi_live_controller.dart';
import '../multi_live_device_policy.dart';
import '../multi_live_page.dart';
import '../session/multi_live_room_session.dart';
import '../storage/multi_live_workspace_store.dart';
import 'multi_live_chat.dart';
import 'multi_live_media.dart';
import 'multi_live_fullscreen.dart';
import 'multi_live_quick_danmaku.dart';
import 'multi_live_picker.dart';

class MultiLiveRoute extends StatefulWidget {
  const MultiLiveRoute(
      {super.key,
      this.initialRoom,
      this.controller,
      this.store,
      this.sessionFactory,
      this.fullscreenControl,
      this.onNotice});
  final MultiLiveRoomSpec? initialRoom;
  final MultiLiveController? controller;

  /// Allows exercising the production controller without disk and live streams.
  final MultiLiveWorkspaceStore? store;
  final MultiLiveSessionFactory? sessionFactory;

  /// The route owns, initializes and closes an injected control as well.
  final MultiLiveWindowFullscreenController? fullscreenControl;
  final ValueChanged<String>? onNotice;

  @override
  State<MultiLiveRoute> createState() => _MultiLiveRouteState();
}

class _MultiLiveRouteState extends State<MultiLiveRoute> {
  late final MultiLiveController _model;
  late final MultiLiveWindowFullscreenController _fullscreen;
  Future<void>? _shutdownFuture;
  bool _starting = true;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _fullscreen =
        widget.fullscreenControl ?? MultiLiveWindowFullscreenController();
    _model = widget.controller ??
        MultiLiveController(
          policy: MultiLiveDevicePolicy(defaultTargetPlatform),
          sites: Sites.allSites.map((id, site) => MapEntry(id, site.name)),
          store: widget.store ?? MultiLiveWorkspaceStore.local(),
          sessionFactory: widget.sessionFactory,
          pickRoom: () async {
            if (!_workspaceIsCurrent) return null;
            final spec = await pickMultiLiveRoom(context);
            if (spec == null) return null;
            final approved = await _approveRooms([spec]);
            return approved?.single;
          },
          pickRooms: (remaining, existing) async {
            if (!_workspaceIsCurrent) return null;
            final specs = await pickMultiLiveRooms(context,
                maxSelection: remaining, existingRoomKeys: existing);
            return specs == null ? null : _approveRooms(specs);
          },
          roomBuilder: (_, session) => MultiLiveMedia(room: session.room!),
          settingsBuilder: (_, session) =>
              MultiLivePlaybackSettings(room: session.room!),
          chatBuilder: (_, session, send) =>
              MultiLiveChat(room: session.room!, send: send),
          notice: _notice,
        );
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_start()));
  }

  Future<List<MultiLiveRoomSpec>?> _approveRooms(
      List<MultiLiveRoomSpec> specs) async {
    final approved = <MultiLiveRoomSpec>[];
    final checkedSites = <String>{};
    for (final spec in specs) {
      if (!_workspaceIsCurrent) return null;
      final site = Sites.allSites[spec.siteId];
      if (site == null) continue;
      if (checkedSites.add(spec.siteId)) {
        await AppNavigator.showLiveRoomLoginTip(site);
      }
      if (!_workspaceIsCurrent) return null;
      approved.add(spec);
    }
    return approved;
  }

  Widget _quickDanmaku(BuildContext context, String id, FocusNode focus,
      bool Function() promptIsCurrent, VoidCallback close) {
    final session = _model.sessionFor(id);
    final room = session?.room;
    if (_leaving || room == null || _model.selectedRoomId != id) {
      return const Text('发送目标已变更，草稿已保留');
    }
    bool isCurrent() =>
        mounted &&
        !_leaving &&
        promptIsCurrent() &&
        _model.selectedRoomId == id &&
        identical(_model.sessionFor(id), session);
    return MultiLiveDanmakuComposer(
        key: ValueKey('quick-composer:$id'),
        room: room,
        focusNode: focus,
        onSent: close,
        onEmptySubmit: close,
        isCurrent: isCurrent,
        send: (text) => _model.sendDanmaku(id, text, isCurrent: isCurrent));
  }

  /// Mobile-only persistent composer for the currently selected room.
  Widget _bottomDanmaku(BuildContext context, String id, FocusNode focus,
      bool Function() contextIsCurrent, VoidCallback onClose) {
    final session = _model.sessionFor(id);
    final room = session?.room;
    if (_leaving || room == null || _model.selectedRoomId != id) {
      return const SizedBox.shrink();
    }
    bool isCurrent() =>
        mounted &&
        !_leaving &&
        contextIsCurrent() &&
        _model.selectedRoomId == id &&
        identical(_model.sessionFor(id), session);
    return MultiLiveDanmakuComposer(
        key: ValueKey('bottom-composer:$id'),
        room: room,
        focusNode: focus,
        inputKey: const ValueKey('multi-live-bottom-danmaku-input'),
        sendKey: const ValueKey('multi-live-bottom-danmaku-send'),
        isCurrent: isCurrent,
        send: (text) => _model.sendDanmaku(id, text, isCurrent: isCurrent));
  }

  void _notice(String text) {
    final notice = widget.onNotice;
    if (notice != null) {
      notice(text);
    } else {
      SmartDialog.showToast(text);
    }
  }

  bool get _workspaceIsCurrent =>
      mounted && !_leaving && ModalRoute.of(context)?.isCurrent == true;

  Future<void> _start() async {
    if (!mounted || _leaving) return;
    try {
      try {
        await _fullscreen.initialize();
      } catch (_) {
        if (mounted && !_leaving) _notice('整窗全屏暂不可用，请稍后重试');
      }
      if (!mounted || _leaving) return;
      final saved = await _model.loadSavedWorkspace();
      if (!mounted || _leaving) return;
      if (saved.status == MultiLiveRestoreStatus.overCapacity) {
        _notice(
            '已保存 ${saved.savedCount} 路，本设备最多支持 ${_model.maxRooms} 路。原布局未修改。');
      } else if (saved.status == MultiLiveRestoreStatus.invalid) {
        _notice('无法读取已保存布局，可重新添加房间');
      }
      final snapshot = saved.snapshot;
      if (snapshot != null && snapshot.rooms.isNotEmpty) {
        final restore = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('恢复多开布局？'),
            content: Text('上次保存了 ${snapshot.rooms.length} 个直播间。'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('暂不恢复')),
              FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('恢复布局')),
            ],
          ),
        );
        if (!mounted || _leaving) return;
        if (restore == true) {
          await _model.restore(snapshot);
          return;
        }
      }
      final initialRoom = widget.initialRoom;
      if (initialRoom != null) await _model.openInitialRoom(initialRoom);
    } catch (_) {
      if (mounted && !_leaving) _notice('无法打开多开直播，请重试');
    } finally {
      if (mounted && !_leaving) setState(() => _starting = false);
    }
  }

  Future<void> _leave() async {
    if (_leaving) return;
    final navigator = Navigator.of(context);
    final route = ModalRoute.of(context);
    setState(() => _leaving = true);
    try {
      await _shutdown();
    } finally {
      if (navigator.mounted && route != null && route.isActive) {
        if (route.isCurrent) {
          navigator.pop();
        } else {
          navigator.removeRoute(route);
        }
      }
    }
  }

  Future<void> _shutdown() => _shutdownFuture ??= _closeResources();

  Future<void> _closeRooms() async {
    try {
      await _model.close();
    } catch (_) {
      if (mounted) _notice('关闭多开直播时发生错误');
    }
  }

  Future<void> _closeResources() async {
    // Revoke the sender immediately, while native window cleanup is pending.
    final rooms = _closeRooms();
    try {
      await _fullscreen.close();
    } catch (_) {
      if (mounted) _notice('恢复窗口时发生错误，直播间已关闭');
    } finally {
      await rooms;
      _fullscreen.dispose();
    }
  }

  @override
  void dispose() {
    _leaving = true;
    unawaited(_shutdown().whenComplete(_model.dispose));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: _model,
        builder: (context, _) {
          // Use the state at the start of the pop, before the inner PopScope
          // clears maximization in its own callback for the same event.
          final wasMaximized = _model.maximizedRoomId != null;
          return PopScope<Object?>(
            canPop: false,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop && !wasMaximized) unawaited(_leave());
            },
            child: _starting || _leaving
                ? Scaffold(
                    appBar: AppBar(title: const Text('多开直播')),
                    body: const Center(child: CircularProgressIndicator()))
                : MultiLivePage(
                    model: _model,
                    fullscreenControl: _fullscreen,
                    quickDanmakuBuilder: _quickDanmaku,
                    bottomDanmakuBuilder: _bottomDanmaku),
          );
        },
      );
}
