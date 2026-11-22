import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/modules/multi_live/integration/multi_live_picker.dart';
import 'package:simple_live_app/modules/multi_live/integration/multi_live_room_link.dart';
import 'package:simple_live_app/modules/multi_live/session/multi_live_room_spec.dart';
import 'package:simple_live_app/services/follow_service.dart';

class _Follows extends FollowService {
  _Follows(Iterable<FollowUser> rooms) {
    followList.addAll(rooms);
  }
  final loads = <bool>[];
  Completer<void>? refreshPending;
  @override
  Future<void> loadData({bool updateStatus = true}) async {
    loads.add(updateStatus);
    if (updateStatus) await refreshPending?.future;
  }
}

FollowUser _room(int index,
        {int status = 2, String site = 'bilibili', String face = ''}) =>
    FollowUser(
      id: '$site$index',
      roomId: '$index',
      siteId: site,
      userName: '主播$index',
      face: face,
      addTime: DateTime(2026),
    )..liveStatus.value = status;

Future<void> _open(
  WidgetTester tester,
  _Follows follows, {
  Size size = const Size(1280, 800),
  double textScale = 1,
  Future<MultiLiveRoomSpec> Function(String)? resolve,
  ValueChanged<MultiLiveRoomSpec?>? onPicked,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(useMaterial3: true),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: Builder(
        builder: (context) => Scaffold(
              body: FilledButton(
                onPressed: () async {
                  final picked = await showDialog<MultiLiveRoomSpec>(
                    context: context,
                    builder: (_) => MultiLiveRoomPicker(
                      sites: Sites.allSites.values.toList(),
                      follow: follows,
                      resolveLink: resolve,
                    ),
                  );
                  onPicked?.call(picked);
                },
                child: const Text('open'),
              ),
            )),
  ));
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

void main() {
  testWidgets(
      'only supported live follows, and cached Rx status changes are immediate',
      (tester) async {
    final live = _room(1);
    final offline = _room(2, status: 1);
    final unknown = _room(3, status: 0);
    final follows =
        _Follows([live, offline, unknown, _room(4, site: 'unsupported')]);
    await _open(tester, follows);
    expect(find.text('主播1'), findsOneWidget);
    expect(find.text('主播2'), findsNothing);
    expect(find.text('主播3'), findsNothing);
    expect(find.text('主播4'), findsNothing);
    expect(find.text('哔哩哔哩 · 直播中'), findsOneWidget);
    expect(follows.loads, isEmpty);
    offline.liveStatus.value = 2;
    live.liveStatus.value = 1;
    await tester.pump();
    expect(find.text('主播1'), findsNothing);
    expect(find.text('主播2'), findsOneWidget);
    offline.liveStatus.value = 1;
    await tester.pump();
    expect(find.text('暂无正在直播的关注主播'), findsOneWidget);
    expect(follows.loads, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'desktop shows at least eight complete avatars and rows with lazy scrolling',
      (tester) async {
    final follows = _Follows(List.generate(1000, _room));
    await _open(tester, follows);
    final viewport = tester.getRect(find.byType(CustomScrollView));
    for (var i = 0; i < 8; i++) {
      final tile = find.byKey(ValueKey('multi-live-follow-bilibili$i'));
      final rect = tester.getRect(tile);
      expect(viewport.contains(rect.topLeft), isTrue, reason: 'tile $i top');
      expect(
          viewport.contains(rect.bottomRight - const Offset(.01, .01)), isTrue,
          reason: 'tile $i bottom');
      expect(find.byKey(ValueKey('multi-live-avatar-fallback-bilibili$i')),
          findsOneWidget);
    }
    expect(tester.getTopLeft(find.text('主播0')).dy,
        tester.getTopLeft(find.text('主播1')).dy);
    expect(find.text('主播999'), findsNothing);
    expect(find.byType(CustomScrollView), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    expect(find.text('直播间链接'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'mobile, short viewport, and large text keep a single usable scroll surface',
      (tester) async {
    for (final config in [
      (const Size(360, 640), 1.0),
      (const Size(360, 400), 1.0),
      (const Size(360, 640), 2.0),
    ]) {
      await _open(tester, _Follows(List.generate(12, _room)),
          size: config.$1, textScale: config.$2);
      expect(find.byType(CustomScrollView), findsOneWidget);
      final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
      expect(
          (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
              .crossAxisCount,
          1);
      await tester.scrollUntilVisible(
        find.text('添加直播间'),
        200,
        scrollable: find
            .descendant(
                of: find.byType(CustomScrollView),
                matching: find.byType(Scrollable))
            .first,
        maxScrolls: 30,
      );
      await tester.pumpAndSettle();
      expect(find.text('添加直播间').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets(
      'empty cache loads without querying live status and offers next steps',
      (tester) async {
    final follows = _Follows([]);
    await _open(tester, follows);
    expect(follows.loads, [false]);
    expect(find.text('暂无正在直播的关注主播'), findsOneWidget);
    expect(find.text('可刷新状态，或在下方粘贴直播间链接'), findsOneWidget);
    expect(find.byTooltip('刷新直播状态'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('refresh reuses service and deduplicates rapid clicks',
      (tester) async {
    final follows = _Follows([_room(1)])..refreshPending = Completer<void>();
    await _open(tester, follows);
    await tester.tap(find.byTooltip('刷新直播状态'));
    await tester.tap(find.byTooltip('刷新直播状态'));
    expect(follows.loads, [true]);
    await tester.pump();
    expect(find.byTooltip('正在刷新直播状态'), findsOneWidget);
    follows.refreshPending!.complete();
    await tester.pumpAndSettle();
    expect(find.byTooltip('刷新直播状态'), findsOneWidget);
  });

  testWidgets(
      'avatar errors show a placeholder and the room remains selectable',
      (tester) async {
    MultiLiveRoomSpec? result;
    await _open(tester,
        _Follows([_room(1, face: 'https://avatar.invalid/not-found.png')]),
        onPicked: (room) => result = room);
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    expect(find.byKey(const ValueKey('multi-live-avatar-fallback-bilibili1')),
        findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('主播1'));
    await tester.pumpAndSettle();
    expect(result?.roomKey, 'bilibili:1');
    expect(result?.title, '主播1');
  });

  testWidgets(
      'unfollowed supported room can be added using the default resolver',
      (tester) async {
    MultiLiveRoomSpec? result;
    await _open(tester, _Follows([_room(1)]),
        onPicked: (room) => result = room);
    await tester.enterText(
        find.byType(TextField), 'https://www.huya.com/456?share=copy');
    await tester.tap(find.text('添加直播间'));
    await tester.pumpAndSettle();
    expect(result?.roomKey, 'huya:456');
    expect(find.byType(MultiLiveRoomPicker), findsNothing);
  });

  testWidgets('invalid link stays inline and can be corrected', (tester) async {
    await _open(tester, _Follows([_room(1)]));
    await tester.enterText(find.byType(TextField), '12345');
    await tester.tap(find.text('添加直播间'));
    await tester.pumpAndSettle();
    expect(find.text('请输入一个完整的 http 或 https 直播间链接'), findsOneWidget);
    expect(find.byType(MultiLiveRoomPicker), findsOneWidget);
    await tester.enterText(
        find.byType(TextField), 'https://live.bilibili.com/12');
    await tester.pumpAndSettle();
    expect(find.text('请输入一个完整的 http 或 https 直播间链接'), findsNothing);
  });

  testWidgets('pending resolution prevents duplicate clicks and allows cancel',
      (tester) async {
    final pending = Completer<MultiLiveRoomSpec>();
    var calls = 0;
    var results = 0;
    MultiLiveRoomSpec? result;
    await _open(
      tester,
      _Follows([_room(1)]),
      resolve: (_) {
        calls++;
        return pending.future;
      },
      onPicked: (room) {
        results++;
        result = room;
      },
    );
    await tester.enterText(find.byType(TextField), 'https://b23.tv/pending');
    await tester.tap(find.text('添加直播间'));
    await tester.tap(find.text('添加直播间'));
    expect(calls, 1);
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    expect(find.text('解析中…'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pump();
    pending.complete(const MultiLiveRoomSpec(siteId: 'huya', roomId: '456'));
    await tester.pumpAndSettle();
    expect(results, 1);
    expect(result, isNull);
    expect(find.text('open'), findsOneWidget);
    expect(find.byType(MultiLiveRoomPicker), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'barrier dismissal ignores a late failure during reverse animation',
      (tester) async {
    final pending = Completer<MultiLiveRoomSpec>();
    var results = 0;
    await _open(
      tester,
      _Follows([_room(1)]),
      resolve: (_) => pending.future,
      onPicked: (_) => results++,
    );
    await tester.enterText(find.byType(TextField), 'https://b23.tv/pending');
    await tester.tap(find.text('添加直播间'));
    await tester.pump();
    await tester.tapAt(const Offset(4, 4));
    await tester.pump();
    pending.completeError(const MultiLiveRoomLinkException('late failure'));
    await tester.pumpAndSettle();
    expect(results, 1);
    expect(find.text('open'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
