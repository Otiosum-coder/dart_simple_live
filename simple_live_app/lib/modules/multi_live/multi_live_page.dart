import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'widgets/multi_live_audio_panel.dart';
import 'widgets/multi_live_fullscreen_control.dart';
import 'widgets/multi_live_view_model.dart';
import 'widgets/multi_live_room_tile.dart';
import 'widgets/multi_live_viewport.dart';

/// Builds only the composer for a fixed room. The host owns its draft, IME
/// handling and guarded send operation; the page owns the prompt and focus.
typedef MultiLiveQuickDanmakuBuilder = Widget Function(
    BuildContext context,
    String roomId,
    FocusNode focusNode,
    bool Function() isCurrent,
    VoidCallback close);

class MultiLivePage extends StatefulWidget {
  const MultiLivePage(
      {super.key,
      required this.model,
      this.fullscreenControl,
      this.quickDanmakuBuilder,
      this.bottomDanmakuBuilder});
  final MultiLiveViewModel model;
  final MultiLiveFullscreenControl? fullscreenControl;
  final MultiLiveQuickDanmakuBuilder? quickDanmakuBuilder;

  /// Mobile-only persistent composer below the rooms; null keeps the hint row.
  final MultiLiveQuickDanmakuBuilder? bottomDanmakuBuilder;
  @override
  State<MultiLivePage> createState() => _MultiLivePageState();
}

class _MultiLivePageState extends State<MultiLivePage> {
  bool _chatVisible = true;
  final _workspaceFocus = FocusNode(debugLabel: 'multi-live-workspace');
  final _bottomFocus = FocusNode(debugLabel: 'multi-live-bottom-danmaku');
  DialogRoute<void>? _quickRoute;
  String? _quickRoomId;

  @override
  void initState() {
    super.initState();
    widget.model.addListener(_roomsChanged);
    FocusManager.instance.addEarlyKeyEventHandler(_workspaceKey);
  }

  @override
  void didUpdateWidget(MultiLivePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.model != widget.model) {
      oldWidget.model.removeListener(_roomsChanged);
      widget.model.addListener(_roomsChanged);
      _closeQuickDanmaku();
    }
    if (widget.quickDanmakuBuilder == null) _closeQuickDanmaku();
  }

  void _roomsChanged() {
    final id = _quickRoomId;
    if (id != null &&
        (widget.model.selectedRoomId != id ||
            !widget.model.rooms.any((room) => room.id == id))) {
      _closeQuickDanmaku();
    }
  }

  void _closeQuickDanmaku() {
    final route = _quickRoute;
    if (route == null || _quickRoomId == null) return;
    // Revoke sending now. Remove only our prompt after the frame, even if
    // another modal has since opened.
    _quickRoomId = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (route.isActive) route.navigator?.removeRoute(route);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _openQuickDanmaku() {
    final builder = widget.quickDanmakuBuilder;
    if (!mounted ||
        builder == null ||
        _quickRoute != null ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    final selected = widget.model.rooms
        .where((room) => room.id == widget.model.selectedRoomId)
        .firstOrNull;
    if (selected == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先选择一个直播画面，再发送弹幕')));
      return;
    }
    _quickRoomId = selected.id;
    late final DialogRoute<void> route;
    route = DialogRoute<void>(
        context: context,
        builder: (context) => _QuickDanmakuPrompt(
            model: widget.model,
            roomId: selected.id,
            builder: builder,
            isCurrent: () =>
                identical(_quickRoute, route) &&
                _quickRoomId == selected.id &&
                route.isCurrent,
            close: () {
              if (identical(_quickRoute, route)) _closeQuickDanmaku();
            }));
    _quickRoute = route;
    unawaited(Navigator.of(context).push(route).whenComplete(() {
      if (identical(_quickRoute, route)) {
        _quickRoute = null;
        _quickRoomId = null;
      }
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        _workspaceFocus.requestFocus();
      }
    }));
  }

  bool get _editingText {
    final focusContext = FocusManager.instance.primaryFocus?.context;
    return focusContext != null &&
        (focusContext.widget is EditableText ||
            focusContext.findAncestorWidgetOfExactType<EditableText>() != null);
  }

  void _restoreWorkspaceFocus() {
    if (mounted) _workspaceFocus.requestFocus();
  }

  /// Mobile-only persistent composer for the selected room's danmaku.
  Widget _bottomDanmaku(BuildContext context) {
    final builder = widget.bottomDanmakuBuilder;
    if (builder == null) return const SizedBox.shrink();
    final model = widget.model;
    final id = model.selectedRoomId;
    final selected =
        id == null ? null : model.rooms.where((r) => r.id == id).firstOrNull;
    bool isCurrent() =>
        mounted &&
        ModalRoute.of(context)?.isCurrent == true &&
        model.selectedRoomId == id;
    if (id == null || selected == null) {
      return Text('选择一个画面后即可发送弹幕',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant));
    }
    return builder(
        context, id, _bottomFocus, isCurrent, _restoreWorkspaceFocus);
  }

  // A popup or slider can leave focus outside the workspace subtree. Handle
  // workspace shortcuts before focus dispatch, but only while our route is
  // current; editors and modal routes retain their own keyboard behavior.
  KeyEventResult _workspaceKey(KeyEvent event) {
    if (!mounted ||
        event is! KeyDownEvent ||
        event.synthesized ||
        ModalRoute.of(context)?.isCurrent != true) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed ||
        keyboard.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    final model = widget.model;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (model.maximizedRoomId != null) {
        model.maximizeRoom(null);
        return KeyEventResult.handled;
      }
      final control = widget.fullscreenControl;
      if (control?.supported == true) {
        // Also queues an exit behind an in-flight enter operation.
        runMultiLiveAction(context, control!.exit);
        return KeyEventResult.handled;
      }
    }
    final desktop = switch (Theme.of(context).platform) {
      TargetPlatform.windows ||
      TargetPlatform.macOS ||
      TargetPlatform.linux =>
        true,
      _ => false,
    };
    if (!desktop) return KeyEventResult.ignored;
    final control = widget.fullscreenControl;
    if (event.logicalKey == LogicalKeyboardKey.f11 &&
        control?.supported == true) {
      runMultiLiveAction(context, control!.toggle);
      return KeyEventResult.handled;
    }
    if ((event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter) &&
        widget.quickDanmakuBuilder != null &&
        !_editingText) {
      _openQuickDanmaku();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_workspaceKey);
    widget.model.removeListener(_roomsChanged);
    _closeQuickDanmaku();
    _workspaceFocus.dispose();
    _bottomFocus.dispose();
    // fullscreenControl is owned and closed by the route, never by this page.
    super.dispose();
  }

  void _addRoom() {
    final model = widget.model;
    if (model.rooms.length >= model.maxRooms) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('最多同时观看 ${model.maxRooms} 个房间，请先关闭或更换房间')));
      return;
    }
    runMultiLiveAction(context, model.addRoom);
  }

  void _chat(BuildContext context, bool wide) {
    if (wide) {
      setState(() => _chatVisible = !_chatVisible);
      return;
    }
    showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (context) => SafeArea(
            child: SizedBox(
                height: MediaQuery.sizeOf(context).height * .75,
                child: ListenableBuilder(
                    listenable: widget.model,
                    builder: (context, _) =>
                        _ChatPanel(model: widget.model)))));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: Listenable.merge([widget.model, widget.fullscreenControl]),
      builder: (context, _) {
        final model = widget.model;
        return Focus(
          focusNode: _workspaceFocus,
          autofocus: true,
          child: LayoutBuilder(builder: (context, pageConstraints) {
            final wide = pageConstraints.maxWidth >= 980;
            final compactToolbar = switch (Theme.of(context).platform) {
              TargetPlatform.windows ||
              TargetPlatform.macOS ||
              TargetPlatform.linux =>
                true,
              _ => false,
            };
            final fullscreen = widget.fullscreenControl;
            final showFullscreen =
                compactToolbar && fullscreen?.supported == true;
            final controlSize = compactToolbar ? 32.0 : 40.0;
            final controlStyle = IconButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: Size.square(controlSize),
                maximumSize: Size.square(controlSize),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.standard);
            final count = '${model.rooms.length}/${model.maxRooms}';
            final title = '多开直播 $count';
            final hasBackButton = Navigator.canPop(context);
            final titleStyle = compactToolbar
                ? Theme.of(context).textTheme.titleMedium
                : Theme.of(context).textTheme.titleSmall;
            final countStyle = Theme.of(context).textTheme.labelSmall;
            final textScaler = MediaQuery.textScalerOf(context);
            // Reserve the same leading, actions and spacing as the AppBar.
            final titleWidth = math.max(
                1.0,
                pageConstraints.maxWidth -
                    (hasBackButton ? controlSize : 0) -
                    controlSize * (showFullscreen ? 5 : 4) -
                    4 -
                    16);
            final titleSize = _measureTitle(context, title, titleStyle);
            final stackedHeight = _measureTitle(context, '多开直播', titleStyle,
                        maxWidth: titleWidth)
                    .height +
                _measureTitle(context, count, countStyle, maxWidth: titleWidth)
                    .height;
            // Large text gets its own full-width row, keeping every action
            // visible without clipping the title or reducing text scaling.
            final separateTitle = compactToolbar &&
                (titleSize.height > controlSize ||
                    (titleSize.width > titleWidth &&
                        stackedHeight > controlSize));
            final titleRowHeight = separateTitle
                ? _measureTitle(context, title, titleStyle,
                            maxWidth:
                                math.max(1.0, pageConstraints.maxWidth - 24))
                        .height +
                    8
                : 0.0;
            return PopScope(
              canPop: model.maximizedRoomId == null,
              onPopInvokedWithResult: (didPop, _) {
                if (!didPop) model.maximizeRoom(null);
              },
              child: Scaffold(
                appBar: AppBar(
                  toolbarHeight: compactToolbar ? 32 : 44,
                  leadingWidth: controlSize,
                  leading:
                      hasBackButton ? BackButton(style: controlStyle) : null,
                  titleSpacing: 8,
                  title: separateTitle
                      ? null
                      : LayoutBuilder(builder: (context, constraints) {
                          // 手机端固定单行标题（数量与标题同一行），空间不足时
                          // 等比缩小而不是换行，避免顶栏被撑成两层。
                          if (!compactToolbar) {
                            return Semantics(
                                label: title,
                                excludeSemantics: true,
                                child: Align(
                                    alignment: AlignmentDirectional.centerStart,
                                    child: FittedBox(
                                        fit: BoxFit.scaleDown,
                                        alignment:
                                            AlignmentDirectional.centerStart,
                                        child: Text(title,
                                            maxLines: 1,
                                            softWrap: false,
                                            style: titleStyle))));
                          }
                          if (constraints.maxWidth < 110) {
                            return Semantics(
                                label: title,
                                excludeSemantics: true,
                                child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text('多开直播',
                                          style: titleStyle,
                                          textScaler: compactToolbar
                                              ? textScaler
                                              : null),
                                      Text(count,
                                          style: countStyle,
                                          textScaler: compactToolbar
                                              ? textScaler
                                              : null),
                                    ]));
                          }
                          return Text(title,
                              maxLines: 1,
                              style: titleStyle,
                              textScaler: compactToolbar ? textScaler : null);
                        }),
                  bottom: separateTitle
                      ? PreferredSize(
                          preferredSize: Size.fromHeight(titleRowHeight),
                          child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 4),
                              child: Align(
                                  alignment: AlignmentDirectional.centerStart,
                                  child: Text(title,
                                      style: titleStyle,
                                      textScaler: textScaler))))
                      : null,
                  actions: [
                    SizedBox.square(
                        dimension: controlSize,
                        child: PopupMenuButton<MultiLiveLayoutPreset>(
                          padding: EdgeInsets.zero,
                          iconSize: 20,
                          key: const ValueKey('layout-presets'),
                          tooltip: '分屏布局',
                          icon: const Icon(Remix.layout_grid_line),
                          itemBuilder: (_) => [
                            for (final preset in MultiLiveLayoutPreset.values)
                              PopupMenuItem(
                                  value: preset,
                                  enabled:
                                      model.rooms.length == preset.roomCount,
                                  child: Text(
                                      '${preset.label} · ${preset.roomCount}路'))
                          ],
                          onSelected: model.setPreset,
                        )),
                    IconButton(
                        key: const ValueKey('audio-panel'),
                        style: controlStyle,
                        tooltip: '各直播间音量',
                        icon: Icon(model.allMuted
                            ? Remix.volume_mute_line
                            : Remix.volume_up_line),
                        onPressed: () => showMultiLiveAudioPanel(context, model,
                            compactToolbar: compactToolbar)),
                    IconButton(
                        key: const ValueKey('chat-panel'),
                        style: controlStyle,
                        tooltip: widget.quickDanmakuBuilder == null
                            ? '查看选中房间聊天'
                            : '聊天与弹幕（回车输入）',
                        icon: const Icon(Remix.chat_3_line),
                        onPressed: () => _chat(context, wide)),
                    if (showFullscreen)
                      IconButton(
                          key: const ValueKey('workspace-fullscreen'),
                          style: controlStyle,
                          tooltip: fullscreen!.isFullscreen
                              ? '退出整窗全屏（F11 / Esc）'
                              : '整窗全屏（F11）',
                          icon: Icon(fullscreen.isFullscreen
                              ? Icons.fullscreen_exit
                              : Icons.fullscreen),
                          onPressed: () =>
                              runMultiLiveAction(context, fullscreen.toggle)),
                    IconButton(
                        key: const ValueKey('add-room'),
                        style: controlStyle,
                        tooltip: '添加房间',
                        icon: const Icon(Remix.add_line),
                        onPressed: model.busy ? null : _addRoom),
                    const SizedBox(width: 4),
                  ],
                ),
                body: SafeArea(
                    top: false,
                    child: Column(children: [
                      SizedBox(
                          height: 2,
                          child: model.busy
                              ? const LinearProgressIndicator()
                              : null),
                      Expanded(
                          child: model.rooms.isEmpty
                              ? _empty(context)
                              : Padding(
                                  padding: AppStyle.edgeInsetsA8,
                                  child: LayoutBuilder(
                                      builder: (context, constraints) =>
                                          Column(children: [
                                            Expanded(
                                                child: Row(children: [
                                              Expanded(
                                                  child: MultiLiveViewport(
                                                      model: model)),
                                              if (wide && _chatVisible) ...[
                                                const SizedBox(width: 8),
                                                SizedBox(
                                                    width: math.min(
                                                        320,
                                                        constraints.maxWidth *
                                                            .28),
                                                    child: _ChatPanel(
                                                        model: model)),
                                              ],
                                            ])),
                                            if (widget.bottomDanmakuBuilder != null && !compactToolbar)
                                              Padding(
                                                  padding: const EdgeInsets.fromLTRB(
                                                      8, 4, 8, 6),
                                                  child:
                                                      _bottomDanmaku(context))
                                            else if (constraints.maxHeight >=
                                                240)
                                              Padding(
                                                  padding:
                                                      AppStyle.edgeInsetsT4,
                                                  child: Text(
                                                      model.maximizedRoomId == null
                                                          ? (compactToolbar && widget.quickDanmakuBuilder != null
                                                              ? '回车输入弹幕 · F11 整窗全屏 · 拖动标题栏交换 · 每路音量独立'
                                                              : '拖动标题栏交换 · 拖动分割线调整 · 每路音量独立')
                                                          : '临时放大 · 其余房间继续播放 · Esc 恢复分屏',
                                                      style: Theme.of(context)
                                                          .textTheme
                                                          .labelSmall
                                                          ?.copyWith(
                                                              color: Theme.of(context)
                                                                  .colorScheme
                                                                  .onSurfaceVariant),
                                                      maxLines: 1,
                                                      overflow: TextOverflow.ellipsis)),
                                          ])),
                                )),
                    ])),
              ),
            );
          }),
        );
      });
  Size _measureTitle(BuildContext context, String text, TextStyle? style,
      {double maxWidth = double.infinity}) {
    final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        locale: Localizations.maybeLocaleOf(context))
      ..layout(maxWidth: maxWidth);
    final size = painter.size;
    painter.dispose();
    return size;
  }

  Widget _empty(BuildContext context) => Center(
          child: SingleChildScrollView(
        padding: AppStyle.edgeInsetsA24,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Remix.live_line,
              size: 44, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 16),
          Text('一起看，随心排', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text('最多同时观看 ${widget.model.maxRooms} 个直播间，每路音量独立。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 20),
          FilledButton.icon(
              onPressed: widget.model.busy ? null : _addRoom,
              icon: const Icon(Remix.add_line),
              label: const Text('添加直播间')),
        ]),
      ));
}

class _QuickDanmakuPrompt extends StatefulWidget {
  const _QuickDanmakuPrompt(
      {required this.model,
      required this.roomId,
      required this.builder,
      required this.isCurrent,
      required this.close});
  final MultiLiveViewModel model;
  final String roomId;
  final MultiLiveQuickDanmakuBuilder builder;
  final bool Function() isCurrent;
  final VoidCallback close;

  @override
  State<_QuickDanmakuPrompt> createState() => _QuickDanmakuPromptState();
}

class _QuickDanmakuPromptState extends State<_QuickDanmakuPrompt> {
  final _focus = FocusNode(debugLabel: 'multi-live-quick-danmaku');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          widget.close();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Dialog(
          key: const ValueKey('quick-danmaku-prompt'),
          alignment: Alignment.bottomCenter,
          insetPadding: const EdgeInsets.all(12),
          // Keep static prompt content inside the editing region. Interactive
          // controls still choose focus and handle their own keyboard actions.
          child: TextFieldTapRegion(
              child: ConstrainedBox(
                  constraints: BoxConstraints(
                      maxWidth: 600,
                      maxHeight: MediaQuery.sizeOf(context).height * .7),
                  child: SingleChildScrollView(
                      padding: AppStyle.edgeInsetsA12,
                      child: ListenableBuilder(
                          listenable: widget.model,
                          builder: (context, _) {
                            final room = widget.model.rooms
                                .where((room) => room.id == widget.roomId)
                                .firstOrNull;
                            final active = room != null &&
                                widget.model.selectedRoomId == widget.roomId;
                            return Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Row(children: [
                                    Expanded(
                                        child: Text(
                                            active
                                                ? '发送弹幕 · ${room.displayTitle}'
                                                : '发送目标已变更，草稿已保留',
                                            key: const ValueKey(
                                                'quick-danmaku-target'),
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleSmall,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis)),
                                    IconButton(
                                        tooltip: '收起弹幕输入（Esc）',
                                        onPressed: widget.close,
                                        icon: const Icon(Icons.close)),
                                  ]),
                                  if (active)
                                    widget.builder(context, widget.roomId,
                                        _focus, widget.isCurrent, widget.close),
                                ]);
                          }))))));
}

class _ChatPanel extends StatelessWidget {
  const _ChatPanel({required this.model});
  final MultiLiveViewModel model;
  @override
  Widget build(BuildContext context) {
    final selected = model.rooms
        .where((room) => room.id == model.selectedRoomId)
        .firstOrNull;
    final builder = model.selectedRoomChatBuilder;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: AppStyle.radius8,
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
            padding: AppStyle.edgeInsetsA12,
            child: Row(children: [
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(
                        selected == null
                            ? '房间聊天'
                            : '聊天 · ${selected.displayTitle}',
                        key: const ValueKey('chat-target'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall),
                    if (selected != null && selected.subtitle.isNotEmpty)
                      Text(selected.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelSmall),
                  ])),
            ])),
        const Divider(height: 1),
        Expanded(
            child: ClipRect(
                child: builder == null
                    ? const Center(
                        child: Padding(
                            padding: AppStyle.edgeInsetsA12,
                            child: Text('选择一个画面查看聊天',
                                textAlign: TextAlign.center)))
                    : KeyedSubtree(
                        key: ValueKey('chat:${model.selectedRoomId}'),
                        child: Builder(builder: builder)))),
      ]),
    );
  }
}
