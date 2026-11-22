import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/modules/multi_live/integration/multi_live_picker.dart';
import 'package:simple_live_app/modules/multi_live/session/multi_live_room_spec.dart';
import 'package:simple_live_app/services/follow_service.dart';

class _Follows extends FollowService {
  _Follows(Iterable<FollowUser> users) {
    followList.addAll(users);
  }
  @override
  Future<void> loadData({bool updateStatus = true}) async {}
}

FollowUser _follow(int n,
        {int status = 2, String site = 'douyu', String face = ''}) =>
    FollowUser(
        id: '$site-$n',
        roomId: '$n',
        siteId: site,
        userName: '关注主播 $n',
        face: face,
        addTime: DateTime(2026))
      ..liveStatus.value = status;

const _input = ValueKey('multi-live-room-link');
const _confirm = ValueKey('multi-live-confirm-selection');
const _stage = ValueKey('multi-live-stage-link');
const _browse = ValueKey('multi-live-browse-follows');
const _return = ValueKey('multi-live-return-link');
const _url = 'https://www.huya.com/456';

Future<void> _open(WidgetTester tester, _Follows follows,
    {Size size = const Size(1280, 800),
    double scale = 1,
    int max = 3,
    Set<String> existing = const {},
    ValueNotifier<int>? capacity,
    ValueNotifier<Set<String>>? opened,
    Future<MultiLiveRoomSpec> Function(String)? resolve,
    ValueChanged<List<MultiLiveRoomSpec>?>? onPicked}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetViewInsets);
  await tester.pumpWidget(MaterialApp(
    theme: AppStyle.lightTheme.copyWith(platform: TargetPlatform.android),
    builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!),
    home: Builder(
        builder: (context) => Scaffold(
            body: TextButton(
                onPressed: () async {
                  Widget picker(int limit, Set<String> keys) =>
                      MultiLiveRoomPicker(
                          sites: Sites.allSites.values.toList(),
                          follow: follows,
                          multiSelect: true,
                          maxSelection: limit,
                          existingRoomKeys: keys,
                          resolveLink: resolve);
                  final result = await showDialog<List<MultiLiveRoomSpec>>(
                    context: context,
                    builder: (_) => capacity == null
                        ? picker(max, existing)
                        : ValueListenableBuilder<int>(
                            valueListenable: capacity,
                            builder: (_, limit, __) => opened == null
                                ? picker(limit, existing)
                                : ValueListenableBuilder<Set<String>>(
                                    valueListenable: opened,
                                    builder: (_, keys, __) =>
                                        picker(limit, keys))),
                  );
                  onPicked?.call(result);
                },
                child: const Text('open')))),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Finder _tile(int n) => find.byKey(ValueKey('multi-live-follow-douyu-$n'));
Finder _vertical() => find
    .descendant(
        of: find.byType(CustomScrollView), matching: find.byType(Scrollable))
    .first;
Future<void> _select(WidgetTester tester, int n) async {
  await tester.tap(_tile(n));
  await tester.pumpAndSettle();
}

Future<void> _confirmSelection(WidgetTester tester) async {
  await tester.tap(find.byKey(_confirm));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'desktop has eight complete avatar tiles, selection stays open up to remaining three',
      (tester) async {
    final follows = _Follows(List.generate(1000, _follow));
    List<MultiLiveRoomSpec>? result;
    await _open(tester, follows, onPicked: (value) => result = value);
    final viewport = tester.getRect(find.byType(CustomScrollView));
    for (var i = 0; i < 8; i++) {
      expect(_tile(i), findsOneWidget);
      final rect = tester.getRect(_tile(i));
      expect(rect.top, greaterThanOrEqualTo(viewport.top));
      expect(rect.bottom, lessThanOrEqualTo(viewport.bottom));
      expect(find.descendant(of: _tile(i), matching: find.byType(CircleAvatar)),
          findsOneWidget);
    }
    expect(tester.getRect(_tile(0)).top, tester.getRect(_tile(1)).top);
    expect(_tile(999), findsNothing);
    await _select(tester, 0);
    await _select(tester, 1);
    await _select(tester, 2);
    expect(result, isNull);
    expect(find.text('已选 3 · 还可选 0'), findsOneWidget);
    expect(find.byIcon(Icons.check_box), findsNWidgets(3));
    await _select(tester, 3);
    expect(find.text('选择已满，请先取消一位已选主播'), findsOneWidget);
    await _select(tester, 1);
    await _select(tester, 3);
    await _confirmSelection(tester);
    expect(result!.map((r) => r.roomId), ['0', '2', '3']);
    expect(result!.map((r) => r.streamerName), ['关注主播 0', '关注主播 2', '关注主播 3']);
    expect(tester.takeException(), isNull);
  });

  for (final max in [0, 1, 2, 4]) {
    testWidgets(
        'batch limit $max and already-open rooms prevent extra selection',
        (tester) async {
      final follows = _Follows(List.generate(10, _follow));
      List<MultiLiveRoomSpec>? result;
      await _open(tester, follows,
          max: max, existing: {'douyu:0'}, onPicked: (v) => result = v);
      final siteName = Sites.allSites['douyu']!.name;
      expect(find.text('$siteName · 已打开'), findsOneWidget);
      await _select(tester, 0);
      for (var i = 1; i <= max + 1; i++) {
        await _select(tester, i);
      }
      expect(find.text('确认添加 $max 个'), findsOneWidget);
      await _confirmSelection(tester);
      if (max == 0) {
        expect(result, isNull);
        expect(find.text('请先选择主播或粘贴一个直播间链接'), findsOneWidget);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
      } else {
        expect(result!.map((r) => r.roomId),
            [for (var i = 1; i <= max; i++) '$i']);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('live changes and unfollowing are revalidated before confirming',
      (tester) async {
    final users = List.generate(5, _follow);
    final follows = _Follows(users);
    List<MultiLiveRoomSpec>? result;
    await _open(tester, follows, onPicked: (v) => result = v);
    await _select(tester, 0);
    await _select(tester, 1);
    await _select(tester, 2);
    users[0].liveStatus.value = 1;
    follows.followList.remove(users[1]);
    await tester.pumpAndSettle();
    expect(_tile(0), findsNothing);
    expect(_tile(1), findsNothing);
    await _confirmSelection(tester);
    expect(result, isNull);
    expect(find.textContaining('已移出待选'), findsOneWidget);
    expect(find.text('确认添加 1 个'), findsOneWidget);
    await _confirmSelection(tester);
    expect(result!.single.roomId, '2');
  });

  testWidgets(
      'capacity and opened changes are rechecked without rebuilding picker state',
      (tester) async {
    final capacity = ValueNotifier(3);
    final opened = ValueNotifier(<String>{});
    addTearDown(capacity.dispose);
    addTearDown(opened.dispose);
    List<MultiLiveRoomSpec>? result;
    await _open(tester, _Follows(List.generate(6, _follow)),
        capacity: capacity, opened: opened, onPicked: (v) => result = v);
    await _select(tester, 0);
    await _select(tester, 1);
    await _select(tester, 2);
    capacity.value = 1;
    await tester.pumpAndSettle();
    await _confirmSelection(tester);
    expect(result, isNull);
    expect(find.text('剩余空位已变化，请减少到 1 个'), findsOneWidget);
    await _select(tester, 0);
    await _select(tester, 1);
    opened.value = {'douyu:2'};
    await tester.pumpAndSettle();
    await _confirmSelection(tester);
    expect(find.text('确认添加 0 个'), findsOneWidget);
    expect(result, isNull);
    await _select(tester, 3);
    await _confirmSelection(tester);
    expect(result!.single.roomId, '3');
  });

  testWidgets(
      'single-link IME stages, removes, deduplicates and confirms with follows',
      (tester) async {
    List<MultiLiveRoomSpec>? result;
    await _open(tester, _Follows([_follow(1)]), onPicked: (v) => result = v);
    await _select(tester, 1);
    await tester.enterText(find.byKey(_input), _url);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(find.text('确认添加 2 个'), findsOneWidget);
    expect(
        tester.widget<TextField>(find.byKey(_input)).controller!.text, isEmpty);
    expect(find.byKey(const ValueKey('multi-live-selected-link-huya:456')),
        findsOneWidget);
    await tester.enterText(find.byKey(_input), _url);
    await tester.tap(find.byKey(_stage));
    await tester.pumpAndSettle();
    expect(find.text('此直播间已在待选列表中'), findsOneWidget);
    await tester.enterText(find.byKey(_input), '');
    await tester.tap(find.byTooltip('移出待选'));
    await tester.pumpAndSettle();
    expect(find.text('确认添加 1 个'), findsOneWidget);
    await tester.enterText(find.byKey(_input), _url);
    await _confirmSelection(tester);
    expect(result!.map((r) => r.roomKey), ['douyu:1', 'huya:456']);
  });

  testWidgets(
      'link errors, existing links and ambiguous multiple links stay inline',
      (tester) async {
    await _open(tester, _Follows([_follow(1)]), existing: {'huya:456'});
    for (final text in [
      '12345',
      'https://example.test/1',
      '$_url https://www.douyu.com/123'
    ]) {
      await tester.enterText(find.byKey(_input), text);
      await _confirmSelection(tester);
      expect(find.byType(MultiLiveRoomPicker), findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(_input)).decoration!.errorText,
          isNotNull);
    }
    await tester.enterText(find.byKey(_input), _url);
    await _confirmSelection(tester);
    expect(find.text('此直播间已打开'), findsOneWidget);
    expect(find.text('确认添加 0 个'), findsOneWidget);
  });

  testWidgets('pending link double-click and confirm cancel ignore late result',
      (tester) async {
    final pending = Completer<MultiLiveRoomSpec>();
    var calls = 0;
    var dismissals = 0;
    List<MultiLiveRoomSpec>? result;
    await _open(tester, _Follows([_follow(1)]), resolve: (_) {
      calls++;
      return pending.future;
    }, onPicked: (v) {
      result = v;
      dismissals++;
    });
    await _select(tester, 1);
    await tester.enterText(find.byKey(_input), _url);
    await tester.tap(find.byKey(_confirm));
    await tester.tap(find.byKey(_confirm));
    await tester.pump();
    expect(calls, 1);
    expect(tester.widget<TextField>(find.byKey(_input)).enabled, isFalse);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(dismissals, 1);
    expect(result, isNull);
    pending.complete(const MultiLiveRoomSpec(siteId: 'huya', roomId: '456'));
    await tester.pumpAndSettle();
    expect(dismissals, 1);
    expect(find.text('open'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'pending link rechecks newly filled capacity and already-open response',
      (tester) async {
    for (final existing in [false, true]) {
      final pending = Completer<MultiLiveRoomSpec>();
      final capacity = ValueNotifier(2);
      final opened = ValueNotifier(<String>{});
      await _open(tester, _Follows([_follow(1)]),
          capacity: capacity, opened: opened, resolve: (_) => pending.future);
      await _select(tester, 1);
      await tester.enterText(find.byKey(_input), _url);
      await tester.tap(find.byKey(_stage));
      await tester.pump();
      if (existing) {
        opened.value = {'huya:456'};
      } else {
        capacity.value = 1;
      }
      await tester.pump();
      pending.complete(const MultiLiveRoomSpec(siteId: 'huya', roomId: '456'));
      await tester.pumpAndSettle();
      expect(
          find.text(existing ? '此直播间已打开' : '选择已满，请先取消一位已选主播'), findsOneWidget);
      expect(find.text('确认添加 1 个'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      capacity.dispose();
      opened.dispose();
    }
  });

  testWidgets('barrier dismissal and reopen discard selections and late error',
      (tester) async {
    final pending = Completer<MultiLiveRoomSpec>();
    var dismissals = 0;
    await _open(tester, _Follows([_follow(1)]),
        resolve: (_) => pending.future, onPicked: (_) => dismissals++);
    await _select(tester, 1);
    await tester.enterText(find.byKey(_input), _url);
    await tester.tap(find.byKey(_stage));
    await tester.pump();
    await tester.tapAt(const Offset(3, 3));
    await tester.pumpAndSettle();
    expect(dismissals, 1);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('确认添加 0 个'), findsOneWidget);
    pending.completeError(StateError('late fixture'));
    await tester.pumpAndSettle();
    expect(find.byType(MultiLiveRoomPicker), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(_input)).decoration!.errorText,
        isNull);
    expect(tester.takeException(), isNull);
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets(
        '1000 follows rotation keyboard scale $scale retain draft focus and batch selection',
        (tester) async {
      List<MultiLiveRoomSpec>? result;
      final follows = _Follows(List.generate(1000, _follow));
      await _open(tester, follows,
          size: const Size(320, 568),
          scale: scale,
          max: 2,
          onPicked: (v) => result = v);
      await _select(tester, 0);
      await tester.enterText(find.byKey(_input), 'https://www.huya.com/');
      tester.view.physicalSize = const Size(568, 320);
      tester.view.viewInsets = const FakeViewPadding(bottom: 180);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byKey(_input)).focusNode!.hasFocus,
          isTrue);
      tester.testTextInput.updateEditingValue(const TextEditingValue(
          text: _url, selection: TextSelection.collapsed(offset: 24)));
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('确认添加 2 个'), findsOneWidget);
      final cancel = tester.getRect(find.text('取消'));
      expect(cancel.bottom, lessThanOrEqualTo(140));
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      tester.view.physicalSize = const Size(320, 568);
      await tester.pumpAndSettle();
      await _confirmSelection(tester);
      expect(result!.map((r) => r.roomKey), ['douyu:0', 'huya:456']);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        '280 minimum scale $scale keeps cancel confirm and virtual last selection reachable',
        (tester) async {
      List<MultiLiveRoomSpec>? result;
      final follows = _Follows([
        ...List.generate(1000, _follow),
        _follow(1000, status: 1),
        _follow(1001, status: 0),
        _follow(1002, site: 'unsupported'),
      ]);
      await _open(tester, follows,
          size: const Size(280, 280),
          scale: scale,
          max: 1,
          onPicked: (v) => result = v);
      await tester.scrollUntilVisible(find.byKey(_browse), 80,
          scrollable: _vertical());
      expect(find.byKey(_browse).hitTestable(), findsOneWidget);
      await tester.tap(find.byKey(_browse));
      await tester.pumpAndSettle();
      final scroll = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!;
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -100));
      await tester.pumpAndSettle();
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(_tile(999), findsOneWidget);
      expect(_tile(1000), findsNothing);
      expect(_tile(0), findsNothing);
      await tester.ensureVisible(_tile(999));
      await tester.pumpAndSettle();
      expect(_tile(999).hitTestable(), findsOneWidget);
      await _select(tester, 999);
      expect(find.text('确认添加 1 个'), findsOneWidget);
      expect(tester.getRect(find.text('取消')).bottom, lessThanOrEqualTo(280));
      if (find.byKey(_return).evaluate().isNotEmpty) {
        await tester.tap(find.byKey(_return));
        await tester.pumpAndSettle();
      }
      await _confirmSelection(tester);
      expect(result!.single.roomId, '999');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('avatar failure fallback remains selectable in batch',
      (tester) async {
    List<MultiLiveRoomSpec>? result;
    await _open(
        tester, _Follows([_follow(1, face: 'https://avatar.invalid/1.png')]),
        onPicked: (v) => result = v);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('multi-live-avatar-fallback-douyu-1')),
        findsOneWidget);
    await _select(tester, 1);
    await _confirmSelection(tester);
    expect(result!.single.streamerName, '关注主播 1');
    expect(tester.takeException(), isNull);
  });
}
