import 'dart:collection';
import 'dart:math' as math;
import 'package:flutter/widgets.dart';

enum MultiLiveLayoutPreset {
  sideBySide,
  stacked,
  leftMain,
  topMain,
  grid,
  leftMainThree
}

extension MultiLiveLayoutPresetInfo on MultiLiveLayoutPreset {
  int get roomCount => switch (this) {
        MultiLiveLayoutPreset.sideBySide || MultiLiveLayoutPreset.stacked => 2,
        MultiLiveLayoutPreset.leftMain || MultiLiveLayoutPreset.topMain => 3,
        MultiLiveLayoutPreset.grid || MultiLiveLayoutPreset.leftMainThree => 4,
      };
  String get label => switch (this) {
        MultiLiveLayoutPreset.sideBySide => '左右双屏',
        MultiLiveLayoutPreset.stacked => '上下双屏',
        MultiLiveLayoutPreset.leftMain => '左一右二',
        MultiLiveLayoutPreset.topMain => '上一下二',
        MultiLiveLayoutPreset.grid => '四宫格',
        MultiLiveLayoutPreset.leftMainThree => '左一右三',
      };
}

sealed class MultiLiveLayoutNode {
  const MultiLiveLayoutNode({required this.id});
  final String id;
  List<String> get roomIds => switch (this) {
        MultiLiveLeaf(:final roomId) => [roomId],
        MultiLiveSplit(:final first, :final second) => [
            ...first.roomIds,
            ...second.roomIds
          ],
      };
  Map<String, Object?> toJson() => switch (this) {
        MultiLiveLeaf(:final roomId) => {
            'type': 'leaf',
            'id': id,
            'roomId': roomId
          },
        MultiLiveSplit(
          :final axis,
          :final ratio,
          :final first,
          :final second
        ) =>
          {
            'type': 'split',
            'id': id,
            'axis': axis.name,
            'ratio': ratio,
            'first': first.toJson(),
            'second': second.toJson(),
          },
      };
  static MultiLiveLayoutNode? tryFromJson(Object? value) {
    final visited = HashSet<Object>.identity();
    var count = 0;
    MultiLiveLayoutNode? parse(Object? raw, int depth) {
      if (raw is! Map || depth > 6 || ++count > 7 || !visited.add(raw)) {
        return null;
      }
      final id = raw['id'];
      if (id is! String || id.isEmpty || id.length > 256) return null;
      if (raw['type'] == 'leaf') {
        final room = raw['roomId'];
        return room is String && room.isNotEmpty && room.length <= 256
            ? MultiLiveLeaf(id: id, roomId: room)
            : null;
      }
      final ratio = raw['ratio'];
      final axis = raw['axis'];
      if (raw['type'] != 'split' ||
          ratio is! num ||
          !ratio.isFinite ||
          ratio < .1 ||
          ratio > .9 ||
          (axis != 'horizontal' && axis != 'vertical')) {
        return null;
      }
      final first = parse(raw['first'], depth + 1);
      final second = parse(raw['second'], depth + 1);
      if (first == null || second == null) return null;
      return MultiLiveSplit(
          id: id,
          axis: axis == 'horizontal' ? Axis.horizontal : Axis.vertical,
          ratio: ratio.toDouble(),
          first: first,
          second: second);
    }

    final node = parse(value, 0);
    return node != null && MultiLiveLayouts.validate(node, node.roomIds)
        ? node
        : null;
  }
}

final class MultiLiveLeaf extends MultiLiveLayoutNode {
  const MultiLiveLeaf({required super.id, required this.roomId});
  final String roomId;
}

final class MultiLiveSplit extends MultiLiveLayoutNode {
  const MultiLiveSplit(
      {required super.id,
      required this.axis,
      required this.ratio,
      required this.first,
      required this.second});
  final Axis axis;
  final double ratio;
  final MultiLiveLayoutNode first;
  final MultiLiveLayoutNode second;
  MultiLiveSplit copyWith(
          {Axis? axis,
          double? ratio,
          MultiLiveLayoutNode? first,
          MultiLiveLayoutNode? second}) =>
      MultiLiveSplit(
          id: id,
          axis: axis ?? this.axis,
          ratio: ratio ?? this.ratio,
          first: first ?? this.first,
          second: second ?? this.second);
}

/// All operations are pure. A preset never discards a room to make it fit.
abstract final class MultiLiveLayouts {
  static List<MultiLiveLayoutPreset> presetsForCount(int count) =>
      MultiLiveLayoutPreset.values
          .where((p) => p.roomCount == count)
          .toList(growable: false);
  static double normalizeRatio(double ratio) =>
      ratio.isFinite ? ratio.clamp(.1, .9).toDouble() : .5;
  static bool validate(
      MultiLiveLayoutNode? node, Iterable<String> activeRooms) {
    final expected = activeRooms.toList();
    if (expected.length > 4 ||
        expected.toSet().length != expected.length ||
        expected.any((id) => id.isEmpty)) {
      return false;
    }
    if (node == null) return expected.isEmpty;
    final nodeIds = <String>{};
    final rooms = <String>{};
    var count = 0;
    bool visit(MultiLiveLayoutNode current) {
      if (++count > 7 || current.id.isEmpty || !nodeIds.add(current.id)) {
        return false;
      }
      return switch (current) {
        MultiLiveLeaf(:final roomId) => roomId.isNotEmpty && rooms.add(roomId),
        MultiLiveSplit(:final ratio, :final first, :final second) =>
          ratio.isFinite &&
              ratio >= .1 &&
              ratio <= .9 &&
              visit(first) &&
              visit(second),
      };
    }

    return visit(node) &&
        rooms.length == expected.length &&
        rooms.containsAll(expected);
  }

  static MultiLiveLayoutNode? create(
      MultiLiveLayoutPreset preset, Iterable<String> roomIds) {
    final ids = roomIds.toList(growable: false);
    if (ids.length > 4 ||
        ids.toSet().length != ids.length ||
        ids.any((id) => id.isEmpty)) {
      throw ArgumentError('Expected zero to four distinct room ids');
    }
    if (ids.isEmpty) return null;
    MultiLiveLeaf leaf(int i) =>
        MultiLiveLeaf(id: 'room:${ids[i]}', roomId: ids[i]);
    if (ids.length == 1) return leaf(0);
    final supported = presetsForCount(ids.length);
    if (!supported.contains(preset)) preset = supported.first;
    MultiLiveSplit split(
            String id, Axis axis, MultiLiveLayoutNode a, MultiLiveLayoutNode b,
            [double ratio = .5]) =>
        MultiLiveSplit(id: id, axis: axis, ratio: ratio, first: a, second: b);
    return switch (preset) {
      MultiLiveLayoutPreset.sideBySide =>
        split('root', Axis.horizontal, leaf(0), leaf(1)),
      MultiLiveLayoutPreset.stacked =>
        split('root', Axis.vertical, leaf(0), leaf(1)),
      MultiLiveLayoutPreset.leftMain => split('root', Axis.horizontal, leaf(0),
          split('right', Axis.vertical, leaf(1), leaf(2)), .62),
      MultiLiveLayoutPreset.topMain => split('root', Axis.vertical, leaf(0),
          split('bottom', Axis.horizontal, leaf(1), leaf(2)), .62),
      MultiLiveLayoutPreset.grid => split(
          'root',
          Axis.horizontal,
          split('left', Axis.vertical, leaf(0), leaf(2)),
          split('right', Axis.vertical, leaf(1), leaf(3))),
      MultiLiveLayoutPreset.leftMainThree => split(
          'root',
          Axis.horizontal,
          leaf(0),
          split('right', Axis.vertical, leaf(1),
              split('rightBottom', Axis.vertical, leaf(2), leaf(3)), 1 / 3),
          .62),
    };
  }

  static MultiLiveLayoutNode resize(
          MultiLiveLayoutNode node, String nodeId, double ratio) =>
      switch (node) {
        MultiLiveLeaf() => node,
        MultiLiveSplit() => node.id == nodeId
            ? node.copyWith(ratio: normalizeRatio(ratio))
            : node.copyWith(
                first: resize(node.first, nodeId, ratio),
                second: resize(node.second, nodeId, ratio)),
      };
  static MultiLiveLayoutNode swap(
      MultiLiveLayoutNode node, String sourceId, String targetId) {
    if (sourceId == targetId ||
        !node.roomIds.contains(sourceId) ||
        !node.roomIds.contains(targetId)) {
      return node;
    }
    MultiLiveLayoutNode visit(MultiLiveLayoutNode current) => switch (current) {
          MultiLiveLeaf(:final roomId) => MultiLiveLeaf(
              id: current.id,
              roomId: roomId == sourceId
                  ? targetId
                  : roomId == targetId
                      ? sourceId
                      : roomId),
          MultiLiveSplit() => current.copyWith(
              first: visit(current.first), second: visit(current.second)),
        };
    return visit(node);
  }

  static MultiLiveLayoutNode? remove(MultiLiveLayoutNode? node, String roomId) {
    if (node == null) return null;
    if (node is MultiLiveLeaf) return node.roomId == roomId ? null : node;
    final split = node as MultiLiveSplit;
    final first = remove(split.first, roomId);
    final second = remove(split.second, roomId);
    if (first == null) return second;
    if (second == null) return first;
    return split.copyWith(first: first, second: second);
  }

  static MultiLiveLayoutGeometry geometry(MultiLiveLayoutNode? node, Size size,
      {double dividerSize = 8, Size minimumPane = const Size(96, 80)}) {
    final rooms = <String, Rect>{};
    final splits = <MultiLiveSplitGeometry>[];
    Size minimum(MultiLiveLayoutNode current) {
      if (current is MultiLiveLeaf) return minimumPane;
      final s = current as MultiLiveSplit;
      final a = minimum(s.first);
      final b = minimum(s.second);
      return s.axis == Axis.horizontal
          ? Size(a.width + b.width + dividerSize, math.max(a.height, b.height))
          : Size(math.max(a.width, b.width), a.height + b.height + dividerSize);
    }

    void visit(MultiLiveLayoutNode current, Rect bounds) {
      if (current is MultiLiveLeaf) {
        rooms[current.roomId] = bounds;
        return;
      }
      final s = current as MultiLiveSplit;
      final horizontal = s.axis == Axis.horizontal;
      final extent = horizontal ? bounds.width : bounds.height;
      final divider = dividerSize.clamp(0, extent).toDouble();
      final available = math.max(0.0, extent - divider);
      final a = minimum(s.first);
      final b = minimum(s.second);
      final minA = horizontal ? a.width : a.height;
      final minB = horizontal ? b.width : b.height;
      var ratio = normalizeRatio(s.ratio);
      if (available > 0) {
        ratio = available >= minA + minB
            ? ratio.clamp(minA / available, 1 - minB / available).toDouble()
            : minA / (minA + minB);
      }
      final firstExtent = available * ratio;
      final first = horizontal
          ? Rect.fromLTWH(bounds.left, bounds.top, firstExtent, bounds.height)
          : Rect.fromLTWH(bounds.left, bounds.top, bounds.width, firstExtent);
      final handle = horizontal
          ? Rect.fromLTWH(
              bounds.left + firstExtent, bounds.top, divider, bounds.height)
          : Rect.fromLTWH(
              bounds.left, bounds.top + firstExtent, bounds.width, divider);
      final second = horizontal
          ? Rect.fromLTWH(
              handle.right, bounds.top, available - firstExtent, bounds.height)
          : Rect.fromLTWH(bounds.left, handle.bottom, bounds.width,
              available - firstExtent);
      splits.add(MultiLiveSplitGeometry(
          nodeId: s.id,
          axis: s.axis,
          bounds: bounds,
          divider: handle,
          available: available));
      visit(s.first, first);
      visit(s.second, second);
    }

    final safe = Size(size.width.isFinite ? math.max(0, size.width) : 0,
        size.height.isFinite ? math.max(0, size.height) : 0);
    if (node != null) visit(node, Offset.zero & safe);
    return MultiLiveLayoutGeometry(
        rooms: Map.unmodifiable(rooms), splits: List.unmodifiable(splits));
  }
}

class MultiLiveLayoutGeometry {
  const MultiLiveLayoutGeometry({required this.rooms, required this.splits});
  final Map<String, Rect> rooms;
  final List<MultiLiveSplitGeometry> splits;
}

class MultiLiveSplitGeometry {
  const MultiLiveSplitGeometry(
      {required this.nodeId,
      required this.axis,
      required this.bounds,
      required this.divider,
      required this.available});
  final String nodeId;
  final Axis axis;
  final Rect bounds;
  final Rect divider;
  final double available;
  double ratioAt(Offset point) => available <= 0
      ? .5
      : MultiLiveLayouts.normalizeRatio((axis == Axis.horizontal
              ? point.dx - bounds.left - divider.width / 2
              : point.dy - bounds.top - divider.height / 2) /
          available);
}
