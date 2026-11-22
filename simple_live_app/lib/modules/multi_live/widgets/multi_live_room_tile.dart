import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'multi_live_view_model.dart';

Future<void> runMultiLiveAction(
    BuildContext context, Future<void> Function() action) async {
  try {
    await action();
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(const SnackBar(content: Text('操作失败，请重试')));
    }
  }
}

class MultiLiveRoomTile extends StatelessWidget {
  const MultiLiveRoomTile(
      {super.key, required this.model, required this.data, required this.body});
  final MultiLiveViewModel model;
  final MultiLiveTileData data;
  final Widget body;
  double get _volume =>
      data.volume.isFinite ? data.volume.clamp(0, 100).toDouble() : 100;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final selected = model.selectedRoomId == data.id;
    final maximized = model.maximizedRoomId == data.id;
    return DragTarget<String>(
      onWillAcceptWithDetails: (details) =>
          details.data != data.id &&
          model.rooms.any((r) => r.id == details.data),
      onAcceptWithDetails: (details) => model.swapRooms(details.data, data.id),
      builder: (context, candidates, rejected) => Semantics(
        selected: selected,
        label: '直播画面 ${data.displayTitle}',
        child: Container(
          key: ValueKey('tile:${data.id}'),
          decoration: BoxDecoration(
              color: colors.surfaceContainerLowest,
              borderRadius: AppStyle.radius8,
              border: Border.all(
                  color: candidates.isNotEmpty || selected
                      ? colors.primary
                      : colors.outlineVariant,
                  width: selected || candidates.isNotEmpty ? 2 : 1)),
          clipBehavior: Clip.antiAlias,
          child: LayoutBuilder(builder: (context, constraints) {
            final hasFooter =
                constraints.maxHeight >= 112 && constraints.maxWidth >= 180;
            final headerHeight = math.min(32.0, constraints.maxHeight);
            return Column(children: [
              SizedBox(
                  height: headerHeight,
                  child: Material(
                    color: selected
                        ? colors.primaryContainer
                        : colors.surfaceContainerHigh,
                    child: Row(children: [
                      Expanded(
                          child: Draggable<String>(
                        data: data.id,
                        feedback: Material(
                            elevation: 4,
                            borderRadius: AppStyle.radius8,
                            color: colors.primaryContainer,
                            child: Padding(
                                padding: AppStyle.edgeInsetsA12,
                                child: ConstrainedBox(
                                    constraints:
                                        const BoxConstraints(maxWidth: 240),
                                    child: Text('交换 · ${data.displayTitle}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis)))),
                        child: InkWell(
                          key: ValueKey('title:${data.id}'),
                          onTap: () => model.selectRoom(data.id),
                          onDoubleTap: () =>
                              model.maximizeRoom(maximized ? null : data.id),
                          child: Tooltip(
                              message:
                                  '${data.displayTitle} · 单击选择聊天；拖动到另一画面交换',
                              child: Padding(
                                  padding: AppStyle.edgeInsetsH4,
                                  child: Row(children: [
                                    if (constraints.maxWidth >= 140) ...[
                                      const Icon(Remix.drag_move_2_line,
                                          size: 14),
                                      const SizedBox(width: 4)
                                    ],
                                    Expanded(
                                        child: Text(data.displayTitle,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: Theme.of(context)
                                                .textTheme
                                                .labelMedium)),
                                  ]))),
                        ),
                      )),
                      if (!hasFooter && constraints.maxWidth >= 110)
                        _icon(
                            data.muted
                                ? Remix.volume_mute_line
                                : Remix.volume_up_line,
                            '音量与静音 ${data.displayTitle}',
                            () => _showAudio(context)),
                      if (constraints.maxWidth >= 150)
                        _icon(
                            maximized
                                ? Remix.fullscreen_exit_line
                                : Remix.fullscreen_line,
                            maximized
                                ? '恢复分屏 ${data.displayTitle}'
                                : '放大 ${data.displayTitle}',
                            () =>
                                model.maximizeRoom(maximized ? null : data.id)),
                      if (constraints.maxWidth >= 36)
                        PopupMenuButton<String>(
                          key: ValueKey('room-menu:${data.id}'),
                          tooltip: '房间操作 ${data.displayTitle}',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 190),
                          iconSize: 18,
                          icon: const Icon(Remix.more_2_fill),
                          onSelected: (action) {
                            switch (action) {
                              case 'select':
                                model.selectRoom(data.id);
                              case 'maximize':
                                model.maximizeRoom(maximized ? null : data.id);
                              case 'audio':
                                _showAudio(context);
                              case 'danmaku':
                                model.toggleDanmaku(data.id);
                              case 'settings':
                                _showSettings(context);
                              case 'replace':
                                runMultiLiveAction(
                                    context, () => model.replaceRoom(data.id));
                              case 'close':
                                runMultiLiveAction(
                                    context, () => model.closeRoom(data.id));
                            }
                          },
                          itemBuilder: (_) => [
                            const PopupMenuItem(
                                value: 'select', child: Text('选择为聊天目标')),
                            PopupMenuItem(
                                value: 'maximize',
                                child: Text(maximized ? '恢复分屏' : '临时放大')),
                            const PopupMenuItem(
                                value: 'audio', child: Text('音量与静音')),
                            PopupMenuItem(
                                value: 'danmaku',
                                child: Text(
                                    data.danmakuVisible ? '隐藏弹幕' : '显示弹幕')),
                            PopupMenuItem(
                                value: 'settings',
                                enabled: data.settingsBuilder != null,
                                child: const Text('清晰度与线路')),
                            const PopupMenuDivider(),
                            const PopupMenuItem(
                                value: 'replace', child: Text('更换房间')),
                            const PopupMenuItem(
                                value: 'close', child: Text('关闭房间')),
                          ],
                        ),
                    ]),
                  )),
              Expanded(child: ClipRect(child: body)),
              if (hasFooter)
                SizedBox(
                    height: 34,
                    child: Material(
                        color: colors.surfaceContainerLow,
                        child: Row(children: [
                          _icon(
                              data.muted
                                  ? Remix.volume_mute_line
                                  : Remix.volume_up_line,
                              '${data.muted ? '取消静音' : '静音'} ${data.displayTitle}',
                              () => _changeAudio(
                                  context, () => model.toggleMute(data.id))),
                          Expanded(
                              child: Semantics(
                                  label: '${data.displayTitle} 音量',
                                  child: Slider(
                                      key: ValueKey('volume:${data.id}'),
                                      value: _volume,
                                      min: 0,
                                      max: 100,
                                      label: '${_volume.round()}%',
                                      semanticFormatterCallback: (value) =>
                                          '${value.round()}%',
                                      onChanged: (value) => _changeAudio(
                                          context,
                                          () => model.setVolume(
                                              data.id, value))))),
                          if (constraints.maxWidth >= 280)
                            Text('${_volume.round()}%',
                                style: Theme.of(context).textTheme.labelSmall),
                          _icon(
                              data.danmakuVisible
                                  ? Remix.chat_3_line
                                  : Remix.chat_off_line,
                              '${data.danmakuVisible ? '隐藏弹幕' : '显示弹幕'} ${data.displayTitle}',
                              () => model.toggleDanmaku(data.id)),
                        ]))),
            ]);
          }),
        ),
      ),
    );
  }

  Widget _icon(IconData icon, String tooltip, VoidCallback action) =>
      IconButton(
          tooltip: tooltip,
          onPressed: action,
          icon: Icon(icon, size: 18),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 32, height: 32),
          visualDensity: VisualDensity.compact);
  Future<void> _changeAudio(
          BuildContext context, Future<void> Function() action) =>
      runMultiLiveAction(context, () async {
        if (model.rooms.any((room) => room.id == data.id)) await action();
      });

  void _showAudio(BuildContext context) {
    showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (context) => SafeArea(
              child: ListenableBuilder(
                  listenable: model,
                  builder: (context, _) {
                    final current = model.rooms
                        .where((room) => room.id == data.id)
                        .firstOrNull;
                    if (current == null) {
                      return const Padding(
                          padding: AppStyle.edgeInsetsA16,
                          child: Text('房间已关闭'));
                    }
                    final volume = current.volume.isFinite
                        ? current.volume.clamp(0, 100).toDouble()
                        : 100.0;
                    return Padding(
                        padding: AppStyle.edgeInsetsA16,
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                          Text(current.displayTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleMedium),
                          SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('静音'),
                              value: current.muted,
                              onChanged: (_) => _changeAudio(
                                  context, () => model.toggleMute(data.id))),
                          Row(children: [
                            const Text('音量'),
                            Expanded(
                                child: Slider(
                                    value: volume,
                                    min: 0,
                                    max: 100,
                                    key: ValueKey(
                                        'room-audio-volume:${data.id}'),
                                    label: '${volume.round()}%',
                                    semanticFormatterCallback: (value) =>
                                        '${value.round()}%',
                                    onChanged: (value) => _changeAudio(
                                        context,
                                        () =>
                                            model.setVolume(data.id, value)))),
                            Text('${volume.round()}%')
                          ]),
                          Text('每路声音独立，允许同时播放',
                              style: Theme.of(context).textTheme.bodySmall),
                        ]));
                  }),
            ));
  }

  void _showSettings(BuildContext context) {
    final builder = data.settingsBuilder;
    if (builder == null) return;
    showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (context) => SafeArea(
            child: SizedBox(
                height: MediaQuery.sizeOf(context).height * .75,
                child: Column(children: [
                  ListTile(
                      title: Text('${data.displayTitle} · 清晰度与线路',
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: IconButton(
                          tooltip: '关闭设置',
                          icon: const Icon(Remix.close_line),
                          onPressed: () => Navigator.pop(context))),
                  Expanded(child: builder(context)),
                ]))));
  }
}
