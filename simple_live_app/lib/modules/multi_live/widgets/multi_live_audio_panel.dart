import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:remixicon/remixicon.dart';
import 'multi_live_room_tile.dart' show runMultiLiveAction;
import 'multi_live_view_model.dart';

/// A presentation of the existing per-session audio state, never a player owner.
Future<void> showMultiLiveAudioPanel(
    BuildContext context, MultiLiveViewModel model,
    {required bool compactToolbar}) {
  if (!compactToolbar) {
    return showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        constraints: const BoxConstraints(maxWidth: 480),
        builder: (context) => ConstrainedBox(
            constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * .85),
            child: SafeArea(child: MultiLiveAudioPanel(model: model))));
  }
  return showDialog<void>(
      context: context,
      builder: (context) {
        final size = MediaQuery.sizeOf(context);
        final top = MediaQuery.paddingOf(context).top + 48;
        return Dialog(
            alignment: Alignment.topRight,
            insetPadding: EdgeInsets.fromLTRB(12, top, 12, 12),
            child: ConstrainedBox(
                constraints: BoxConstraints(
                    maxWidth: math.min(400, math.max(0, size.width - 24)),
                    maxHeight: math.max(0, size.height - top - 12)),
                child: MultiLiveAudioPanel(model: model)));
      });
}

class MultiLiveAudioPanel extends StatelessWidget {
  const MultiLiveAudioPanel({super.key, required this.model});
  final MultiLiveViewModel model;

  Future<void> _changeRoom(
          BuildContext context, String id, Future<void> Function() action) =>
      runMultiLiveAction(context, () async {
        // A drag callback can outlive the row if a session closes mid-gesture.
        if (model.rooms.any((room) => room.id == id)) await action();
      });

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        final rooms = model.rooms;
        final theme = Theme.of(context);
        return Column(
            key: const ValueKey('multi-live-audio-panel'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                  child: Row(children: [
                    Expanded(
                        child:
                            Text('各直播间音量', style: theme.textTheme.titleMedium)),
                    IconButton(
                        tooltip: '关闭音量面板',
                        icon: const Icon(Remix.close_line),
                        onPressed: () => Navigator.pop(context)),
                  ])),
              Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 12, 8),
                  child: Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      children: [
                        Text('${rooms.length} 路 · 音量独立',
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant)),
                        TextButton.icon(
                            key: const ValueKey('audio-all-muted'),
                            onPressed: rooms.isEmpty
                                ? null
                                : () => runMultiLiveAction(context,
                                    () => model.setAllMuted(!model.allMuted)),
                            icon: Icon(
                                model.allMuted
                                    ? Remix.volume_up_line
                                    : Remix.volume_mute_line,
                                size: 18),
                            label: Text(model.allMuted ? '恢复所有声音' : '全部静音')),
                      ])),
              const Divider(height: 1),
              if (rooms.isEmpty)
                const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('暂无直播间，添加后可独立调节音量'))
              else
                Flexible(
                    child: ListView.separated(
                        shrinkWrap: true,
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        itemCount: rooms.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final room = rooms[index];
                          final volume = room.volume.isFinite
                              ? room.volume.clamp(0, 100).toDouble()
                              : 100.0;
                          final selected = model.selectedRoomId == room.id;
                          return Semantics(
                              key: ValueKey('audio-row:${room.id}'),
                              selected: selected,
                              child: Padding(
                                  padding:
                                      const EdgeInsets.fromLTRB(16, 4, 8, 4),
                                  child: Column(children: [
                                    Row(children: [
                                      Expanded(
                                          child: Text(room.displayTitle,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style:
                                                  theme.textTheme.bodyMedium)),
                                      if (selected)
                                        Padding(
                                            key: ValueKey(
                                                'audio-selected:${room.id}'),
                                            padding:
                                                const EdgeInsets.only(left: 8),
                                            child: Text('聊天中',
                                                style: theme
                                                    .textTheme.labelSmall
                                                    ?.copyWith(
                                                        color: theme.colorScheme
                                                            .primary))),
                                      IconButton(
                                          key:
                                              ValueKey('audio-mute:${room.id}'),
                                          tooltip:
                                              '${room.muted ? '取消静音' : '静音'} ${room.displayTitle}',
                                          isSelected: room.muted,
                                          icon: const Icon(Remix.volume_up_line,
                                              size: 20),
                                          selectedIcon: const Icon(
                                              Remix.volume_mute_line,
                                              size: 20),
                                          onPressed: () => _changeRoom(
                                              context,
                                              room.id,
                                              () => model.toggleMute(room.id))),
                                    ]),
                                    Row(children: [
                                      Expanded(
                                          child: Semantics(
                                              label: '${room.displayTitle} 音量',
                                              child: Slider(
                                                  key: ValueKey(
                                                      'audio-volume:${room.id}'),
                                                  value: volume,
                                                  min: 0,
                                                  max: 100,
                                                  label: '${volume.round()}%',
                                                  semanticFormatterCallback:
                                                      (value) =>
                                                          '${value.round()}%',
                                                  onChanged: (value) =>
                                                      _changeRoom(
                                                          context,
                                                          room.id,
                                                          () => model.setVolume(
                                                              room.id,
                                                              value))))),
                                      SizedBox(
                                          width: 48,
                                          child: Text('${volume.round()}%',
                                              key: ValueKey(
                                                  'audio-percent:${room.id}'),
                                              textAlign: TextAlign.center,
                                              style:
                                                  theme.textTheme.labelMedium)),
                                    ]),
                                  ])));
                        })),
            ]);
      });
}
