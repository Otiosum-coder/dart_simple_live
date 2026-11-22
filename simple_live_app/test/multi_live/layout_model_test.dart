import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/modules/multi_live/layout/multi_live_layout.dart';

void main() {
  List<String> ids(int count) => List.generate(count, (i) => 'room$i');
  for (final preset in MultiLiveLayoutPreset.values) {
    test('${preset.name} preserves exact leaves and round trips', () {
      final rooms = ids(preset.roomCount);
      final layout = MultiLiveLayouts.create(preset, rooms)!;
      expect(MultiLiveLayouts.validate(layout, rooms), isTrue);
      expect(layout.roomIds.toSet(), rooms.toSet());
      final restored = MultiLiveLayoutNode.tryFromJson(layout.toJson());
      expect(restored?.toJson(), layout.toJson());
      for (final size in [
        Size.zero,
        const Size(1, 1),
        const Size(320, 180),
        const Size(1400, 900)
      ]) {
        final geometry = MultiLiveLayouts.geometry(layout, size);
        expect(geometry.rooms.keys.toSet(), rooms.toSet());
        final rectangles = geometry.rooms.values.toList();
        for (final rect in rectangles) {
          expect(rect.width.isFinite && rect.height.isFinite, isTrue);
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.top, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(size.width + .0001));
          expect(rect.bottom, lessThanOrEqualTo(size.height + .0001));
          expect(rect.width, greaterThanOrEqualTo(0));
          expect(rect.height, greaterThanOrEqualTo(0));
        }
        for (var a = 0; a < rectangles.length; a++) {
          for (var b = a + 1; b < rectangles.length; b++) {
            expect(rectangles[a].overlaps(rectangles[b]), isFalse);
          }
        }
      }
    });
  }
  test('every preset adapts safely to zero through four rooms', () {
    for (var count = 0; count <= 4; count++) {
      for (final preset in MultiLiveLayoutPreset.values) {
        expect(
            MultiLiveLayouts.validate(
                MultiLiveLayouts.create(preset, ids(count)), ids(count)),
            isTrue);
      }
      expect(
          MultiLiveLayouts.presetsForCount(count)
              .every((p) => p.roomCount == count),
          isTrue);
    }
    expect(() => MultiLiveLayouts.create(MultiLiveLayoutPreset.grid, ids(5)),
        throwsArgumentError);
    expect(
        () => MultiLiveLayouts.create(MultiLiveLayoutPreset.grid, ['a', 'a']),
        throwsArgumentError);
    expect(() => MultiLiveLayouts.create(MultiLiveLayoutPreset.grid, ['']),
        throwsArgumentError);
  });
  test(
      'validation rejects missing extra duplicate leaves and duplicate node ids',
      () {
    final layout = MultiLiveLayouts.create(MultiLiveLayoutPreset.grid, ids(4))!;
    expect(MultiLiveLayouts.validate(layout, ids(3)), isFalse);
    expect(MultiLiveLayouts.validate(layout, [...ids(4), 'extra']), isFalse);
    expect(
        MultiLiveLayouts.validate(layout, ['room0', 'room1', 'room2', 'room2']),
        isFalse);
    const duplicate = MultiLiveSplit(
        id: 'root',
        axis: Axis.horizontal,
        ratio: .5,
        first: MultiLiveLeaf(id: 'same', roomId: 'a'),
        second: MultiLiveLeaf(id: 'same', roomId: 'b'));
    expect(MultiLiveLayouts.validate(duplicate, ['a', 'b']), isFalse);
    expect(MultiLiveLayoutNode.tryFromJson(duplicate.toJson()), isNull);
  });
  test('ratios reject malformed saved values and clamp interactive extremes',
      () {
    final original =
        MultiLiveLayouts.create(MultiLiveLayoutPreset.sideBySide, ids(2))!;
    for (final invalid in [
      double.nan,
      double.infinity,
      double.negativeInfinity,
      -.1,
      0,
      1,
      '0.5',
      null
    ]) {
      final json = original.toJson()..['ratio'] = invalid;
      expect(MultiLiveLayoutNode.tryFromJson(json), isNull);
    }
    for (final ratio in [-100.0, 100.0, double.nan, double.infinity, .1, .9]) {
      final resized =
          MultiLiveLayouts.resize(original, 'root', ratio) as MultiLiveSplit;
      expect(MultiLiveLayouts.validate(resized, ids(2)), isTrue);
      expect(resized.ratio, inInclusiveRange(.1, .9));
      final geometry = MultiLiveLayouts.geometry(resized, const Size(800, 400));
      expect(geometry.rooms.values.every((r) => r.width >= 96), isTrue);
    }
    expect((original as MultiLiveSplit).ratio, .5);
    final cyclic = <String, Object?>{
      'type': 'split',
      'id': 'cycle',
      'axis': 'horizontal',
      'ratio': .5
    };
    cyclic['first'] = cyclic;
    cyclic['second'] = const MultiLiveLeaf(id: 'leaf', roomId: 'a').toJson();
    expect(MultiLiveLayoutNode.tryFromJson(cyclic), isNull);
  });
  test('swap and removal only change placement and collapse empty splits', () {
    final original =
        MultiLiveLayouts.create(MultiLiveLayoutPreset.grid, ids(4))!;
    final swapped = MultiLiveLayouts.swap(original, 'room0', 'room3');
    expect(swapped.roomIds, ['room3', 'room2', 'room1', 'room0']);
    expect(original.roomIds, ['room0', 'room2', 'room1', 'room3']);
    expect(
        identical(
            MultiLiveLayouts.swap(original, 'unknown', 'room1'), original),
        isTrue);
    MultiLiveLayoutNode? reduced = swapped;
    for (var i = 0; i < 4; i++) {
      reduced = MultiLiveLayouts.remove(reduced, 'room$i');
      expect(MultiLiveLayouts.validate(reduced, ids(4).skip(i + 1)), isTrue);
    }
    expect(reduced, isNull);
  });
}
