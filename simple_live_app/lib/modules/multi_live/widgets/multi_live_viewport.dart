import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'multi_live_view_model.dart';
import 'multi_live_room_tile.dart';

/// Flat keyed children retain room elements even when their split ancestry changes.
class MultiLiveViewport extends StatefulWidget {
  const MultiLiveViewport({super.key, required this.model});
  final MultiLiveViewModel model;
  @override
  State<MultiLiveViewport> createState() => _MultiLiveViewportState();
}

class _MultiLiveViewportState extends State<MultiLiveViewport> {
  final Map<String, Widget> _bodies = {};
  @override
  void didUpdateWidget(covariant MultiLiveViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.model, widget.model)) _bodies.clear();
  }

  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        final model = widget.model;
        final rooms = model.rooms;
        final ids = rooms.map((r) => r.id).toSet();
        _bodies.removeWhere((id, _) => !ids.contains(id));
        for (final room in rooms) {
          _bodies.putIfAbsent(
              room.id, () => Builder(builder: room.bodyBuilder));
        }
        var layout = model.layout;
        if (!MultiLiveLayouts.validate(layout, ids)) {
          layout = MultiLiveLayouts.create(MultiLiveLayoutPreset.grid, ids);
        }
        // The host supplies a platform capacity. A narrow desktop keeps all four.
        if (model.maxRooms <= 2 &&
            rooms.length == 2 &&
            layout is MultiLiveSplit) {
          layout = layout.copyWith(
              axis: MediaQuery.orientationOf(context) == Orientation.landscape
                  ? Axis.horizontal
                  : Axis.vertical);
        }
        final size = Size(math.max(0, constraints.maxWidth),
            math.max(0, constraints.maxHeight));
        final geometry = MultiLiveLayouts.geometry(layout, size);
        final maximized =
            ids.contains(model.maximizedRoomId) ? model.maximizedRoomId : null;
        return Stack(
            key: const ValueKey('multi-live-canvas'),
            clipBehavior: Clip.hardEdge,
            children: [
              for (final room in rooms)
                Positioned.fromRect(
                  key: ValueKey('position:${room.id}'),
                  rect: maximized == room.id
                      ? Offset.zero & size
                      : geometry.rooms[room.id] ?? Rect.zero,
                  child: Offstage(
                    offstage: maximized != null && maximized != room.id,
                    child: TickerMode(
                      enabled: maximized == null || maximized == room.id,
                      child: MultiLiveRoomTile(
                          model: model, data: room, body: _bodies[room.id]!),
                    ),
                  ),
                ),
              if (maximized == null)
                for (final split in geometry.splits)
                  Positioned.fromRect(
                      key: ValueKey('divider-position:${split.nodeId}'),
                      rect: split.divider,
                      child: _SplitHandle(
                          split: split,
                          onRatio: (ratio) =>
                              model.resizeSplit(split.nodeId, ratio))),
            ]);
      });
}

class _SplitHandle extends StatefulWidget {
  const _SplitHandle({required this.split, required this.onRatio});
  final MultiLiveSplitGeometry split;
  final ValueChanged<double> onRatio;
  @override
  State<_SplitHandle> createState() => _SplitHandleState();
}

class _SplitHandleState extends State<_SplitHandle> {
  double? _dragRatio;
  double get _ratio {
    final split = widget.split;
    return split.ratioAt(split.divider.center);
  }

  void _step(double delta) =>
      widget.onRatio(MultiLiveLayouts.normalizeRatio(_ratio + delta));
  @override
  Widget build(BuildContext context) {
    final horizontal = widget.split.axis == Axis.horizontal;
    return Semantics(
      label: '调整分屏比例',
      value: '${(_ratio * 100).round()}%',
      increasedValue:
          '${(MultiLiveLayouts.normalizeRatio(_ratio + .03) * 100).round()}%',
      decreasedValue:
          '${(MultiLiveLayouts.normalizeRatio(_ratio - .03) * 100).round()}%',
      onIncrease: () => _step(.03),
      onDecrease: () => _step(-.03),
      child: Tooltip(
          message: '拖动调整分屏；方向键微调',
          child: FocusableActionDetector(
            shortcuts: {
              SingleActivator(horizontal
                  ? LogicalKeyboardKey.arrowLeft
                  : LogicalKeyboardKey.arrowUp): const _ResizeIntent(-.03),
              SingleActivator(horizontal
                  ? LogicalKeyboardKey.arrowRight
                  : LogicalKeyboardKey.arrowDown): const _ResizeIntent(.03),
            },
            actions: {
              _ResizeIntent: CallbackAction<_ResizeIntent>(onInvoke: (intent) {
                _step(intent.delta);
                return null;
              })
            },
            mouseCursor: horizontal
                ? SystemMouseCursors.resizeColumn
                : SystemMouseCursors.resizeRow,
            child: GestureDetector(
              key: ValueKey('divider:${widget.split.nodeId}'),
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => _dragRatio = _ratio,
              onPanUpdate: (details) {
                if (widget.split.available <= 0) return;
                final delta = horizontal ? details.delta.dx : details.delta.dy;
                _dragRatio = MultiLiveLayouts.normalizeRatio(
                    (_dragRatio ?? _ratio) + delta / widget.split.available);
                widget.onRatio(_dragRatio!);
              },
              onPanEnd: (_) => _dragRatio = null,
              onPanCancel: () => _dragRatio = null,
              child: Center(
                  child: Container(
                      width: horizontal ? 2 : 28,
                      height: horizontal ? 28 : 2,
                      decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.outlineVariant,
                          borderRadius: BorderRadius.circular(2)))),
            ),
          )),
    );
  }
}

class _ResizeIntent extends Intent {
  const _ResizeIntent(this.delta);
  final double delta;
}
