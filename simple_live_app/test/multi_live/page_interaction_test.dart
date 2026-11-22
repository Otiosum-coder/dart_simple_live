import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/modules/multi_live/multi_live_page.dart';
import 'package:simple_live_app/modules/multi_live/widgets/multi_live_view_model.dart';

class Probe extends StatefulWidget {
  const Probe(
      {super.key,
      required this.id,
      required this.created,
      required this.destroyed});
  final String id;
  final Map<String, int> created;
  final Map<String, int> destroyed;
  @override
  State<Probe> createState() => _ProbeState();
}

class _ProbeState extends State<Probe> {
  @override
  void initState() {
    super.initState();
    widget.created.update(widget.id, (n) => n + 1, ifAbsent: () => 1);
  }

  @override
  void dispose() {
    widget.destroyed.update(widget.id, (n) => n + 1, ifAbsent: () => 1);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      const ColoredBox(color: Color(0xff152330));
}

class FakeModel extends ChangeNotifier implements MultiLiveViewModel {
  FakeModel(int count, {this.maxRooms = 4}) {
    for (var i = 0; i < count; i++) {
      ids.add('room$i');
    }
    selectedRoomId = ids.firstOrNull;
    layout = MultiLiveLayouts.create(MultiLiveLayoutPreset.grid, ids);
  }
  final ids = <String>[];
  final created = <String, int>{};
  final destroyed = <String, int>{};
  final volume = <String, double>{};
  final muted = <String, bool>{};
  final danmaku = <String, bool>{};
  int adds = 0;
  int replacements = 0;
  @override
  final int maxRooms;
  @override
  bool busy = false;
  @override
  MultiLiveLayoutNode? layout;
  @override
  String? selectedRoomId;
  @override
  String? maximizedRoomId;
  @override
  bool get allMuted => ids.isNotEmpty && ids.every((id) => muted[id] ?? false);
  @override
  List<MultiLiveTileData> get rooms => ids
      .map((id) => MultiLiveTileData(
          id: id,
          title: '房间 ${id.substring(4)}',
          subtitle: '主播 $id',
          volume: volume[id] ?? 100,
          muted: muted[id] ?? false,
          danmakuVisible: danmaku[id] ?? true,
          bodyBuilder: (_) =>
              Probe(id: id, created: created, destroyed: destroyed),
          settingsBuilder: (_) => Center(child: Text('settings:$id'))))
      .toList();
  @override
  WidgetBuilder? get selectedRoomChatBuilder => selectedRoomId == null
      ? null
      : (_) => Center(child: Text('chat:$selectedRoomId'));
  @override
  Future<void> addRoom() async {
    adds++;
    ids.add('room${ids.length}');
    layout = MultiLiveLayouts.create(MultiLiveLayoutPreset.grid, ids);
    selectedRoomId ??= ids.last;
    notifyListeners();
  }

  @override
  Future<void> closeRoom(String id) async {
    ids.remove(id);
    layout = MultiLiveLayouts.remove(layout, id);
    if (selectedRoomId == id) selectedRoomId = ids.firstOrNull;
    if (maximizedRoomId == id) maximizedRoomId = null;
    notifyListeners();
  }

  @override
  Future<void> replaceRoom(String id) async {
    replacements++;
    final index = ids.indexOf(id);
    ids[index] = '${id}new';
    layout = MultiLiveLayouts.create(MultiLiveLayoutPreset.grid, ids);
    if (selectedRoomId == id) selectedRoomId = ids[index];
    notifyListeners();
  }

  @override
  Future<void> setVolume(String id, double value) async {
    volume[id] = value;
    notifyListeners();
  }

  @override
  Future<void> toggleMute(String id) async {
    muted[id] = !(muted[id] ?? false);
    notifyListeners();
  }

  @override
  Future<void> setAllMuted(bool value) async {
    for (final id in ids) {
      muted[id] = value;
    }
    notifyListeners();
  }

  @override
  void selectRoom(String id) {
    selectedRoomId = id;
    notifyListeners();
  }

  @override
  void toggleDanmaku(String id) {
    danmaku[id] = !(danmaku[id] ?? true);
    notifyListeners();
  }

  @override
  void maximizeRoom(String? id) {
    maximizedRoomId = id;
    notifyListeners();
  }

  @override
  void setPreset(MultiLiveLayoutPreset preset) {
    layout = MultiLiveLayouts.create(preset, ids);
    notifyListeners();
  }

  @override
  void resizeSplit(String nodeId, double ratio) {
    layout = MultiLiveLayouts.resize(layout!, nodeId, ratio);
    notifyListeners();
  }

  @override
  void swapRooms(String sourceId, String targetId) {
    layout = MultiLiveLayouts.swap(layout!, sourceId, targetId);
    notifyListeners();
  }
}

Future<void> mount(WidgetTester tester, FakeModel model,
    [Size size = const Size(1200, 800)]) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
      theme: ThemeData(useMaterial3: true), home: MultiLivePage(model: model)));
  await tester.pumpAndSettle();
}

Future<void> roomMenu(WidgetTester tester, String id, String item) async {
  await tester.tap(find.byKey(ValueKey('room-menu:$id')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(item));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'dragging split, swapping and maximize preserve all mounted room bodies',
      (tester) async {
    final model = FakeModel(4);
    await mount(tester, model);
    expect(model.created, {'room0': 1, 'room1': 1, 'room2': 1, 'room3': 1});
    final ratio = (model.layout as MultiLiveSplit).ratio;
    await tester.drag(
        find.byKey(const ValueKey('divider:root')), const Offset(75, 0));
    await tester.pumpAndSettle();
    expect((model.layout as MultiLiveSplit).ratio, greaterThan(ratio));
    final before = model.layout!.roomIds;
    final start = tester.getCenter(find.byKey(const ValueKey('title:room0')));
    final end = tester.getCenter(find.byKey(const ValueKey('title:room1')));
    await tester.dragFrom(start, end - start);
    await tester.pumpAndSettle();
    expect(model.layout!.roomIds, isNot(before));
    expect(model.layout!.roomIds.toSet(), before.toSet());
    await tester.tap(find.byTooltip('放大 房间 0'));
    await tester.pumpAndSettle();
    expect(model.maximizedRoomId, 'room0');
    expect(find.byType(Probe, skipOffstage: false), findsNWidgets(4));
    expect(find.byType(Probe), findsOneWidget);
    expect(model.created.values, everyElement(1));
    expect(model.destroyed, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(model.maximizedRoomId, isNull);
    expect(find.byType(Probe), findsNWidgets(4));
    expect(model.created.values, everyElement(1));
    expect(model.destroyed, isEmpty);
  });
  testWidgets('zero to four rooms and fifth attempt gives clear feedback',
      (tester) async {
    final model = FakeModel(0);
    await mount(tester, model);
    expect(find.text('添加直播间'), findsOneWidget);
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.byKey(const ValueKey('add-room')));
      await tester.pumpAndSettle();
      expect(model.ids.length, i + 1);
    }
    await tester.tap(find.byKey(const ValueKey('add-room')));
    await tester.pump();
    expect(model.adds, 4);
    expect(find.text('最多同时观看 4 个房间，请先关闭或更换房间'), findsOneWidget);
  });
  testWidgets(
      'volume mute selection danmaku settings replace and close are independent',
      (tester) async {
    final model = FakeModel(2);
    await mount(tester, model);
    tester
        .widget<Slider>(find.byKey(const ValueKey('volume:room0')))
        .onChanged!(27);
    await tester.pump();
    await tester.tap(find.byTooltip('静音 房间 0'));
    await tester.pump();
    expect(model.volume['room0'], 27);
    expect(model.muted['room0'], isTrue);
    expect(model.muted['room1'] ?? false, isFalse);
    await tester.tap(find.byKey(const ValueKey('title:room1')));
    await tester.pumpAndSettle();
    expect(model.selectedRoomId, 'room1');
    expect(find.text('chat:room1'), findsOneWidget);
    expect(find.text('主播 room1'), findsOneWidget);
    expect(find.text('chat:room0'), findsNothing);
    expect(find.text('主播 room0'), findsNothing);
    expect(model.muted['room0'], isTrue);
    await tester.tap(find.byTooltip('隐藏弹幕 房间 1'));
    await tester.pump();
    expect(model.danmaku['room1'], isFalse);
    await roomMenu(tester, 'room1', '清晰度与线路');
    expect(find.text('settings:room1'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭设置'));
    await tester.pumpAndSettle();
    await roomMenu(tester, 'room0', '更换房间');
    expect(model.replacements, 1);
    expect(model.created['room0new'], 1);
    expect(model.destroyed['room0'], 1);
    expect(model.created['room1'], 1);
    await roomMenu(tester, 'room0new', '关闭房间');
    expect(model.ids, ['room1']);
    expect(model.destroyed['room0new'], 1);
  });
  testWidgets('all six presets expose room count eligibility', (tester) async {
    for (var count = 2; count <= 4; count++) {
      final model = FakeModel(count);
      await mount(tester, model);
      await tester.tap(find.byKey(const ValueKey('layout-presets')));
      await tester.pumpAndSettle();
      final items = tester
          .widgetList<PopupMenuItem<MultiLiveLayoutPreset>>(
              find.byType(PopupMenuItem<MultiLiveLayoutPreset>))
          .toList();
      expect(items.length, 6);
      for (final item in items) {
        expect(item.enabled, item.value!.roomCount == count);
      }
      final selected = MultiLiveLayouts.presetsForCount(count).last;
      await tester.tap(find.text('${selected.label} · ${selected.roomCount}路'));
      await tester.pumpAndSettle();
      expect(MultiLiveLayouts.validate(model.layout, model.ids), isTrue);
      expect(tester.takeException(), isNull);
    }
  });
  testWidgets('narrow desktop retains four and all presets avoid overflow',
      (tester) async {
    final model = FakeModel(4);
    await mount(tester, model, const Size(320, 240));
    for (final size in [
      const Size(320, 240),
      const Size(480, 320),
      const Size(320, 568),
      const Size(1000, 420)
    ]) {
      tester.view.physicalSize = size;
      for (final preset in MultiLiveLayouts.presetsForCount(4)) {
        model.setPreset(preset);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull,
            reason: '${preset.name} at $size');
        expect(model.ids.length, 4);
        expect(find.byType(Probe, skipOffstage: false), findsNWidgets(4));
      }
    }
    expect(model.created.values, everyElement(1));
    expect(model.destroyed, isEmpty);
  });
  testWidgets(
      'mobile portrait landscape preserves two bodies and rejects third',
      (tester) async {
    final model = FakeModel(2, maxRooms: 2);
    await mount(tester, model, const Size(400, 800));
    final top = tester.getRect(find.byKey(const ValueKey('tile:room0')));
    final bottom = tester.getRect(find.byKey(const ValueKey('tile:room1')));
    expect(bottom.top, greaterThan(top.bottom));
    tester.view.physicalSize = const Size(800, 400);
    await tester.pumpAndSettle();
    final left = tester.getRect(find.byKey(const ValueKey('tile:room0')));
    final right = tester.getRect(find.byKey(const ValueKey('tile:room1')));
    expect(right.left, greaterThan(left.right));
    expect(model.created, {'room0': 1, 'room1': 1});
    await tester.tap(find.byKey(const ValueKey('add-room')));
    await tester.pump();
    expect(model.adds, 0);
    expect(find.text('最多同时观看 2 个房间，请先关闭或更换房间'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
