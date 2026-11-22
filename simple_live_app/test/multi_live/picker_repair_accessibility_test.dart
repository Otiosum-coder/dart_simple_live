import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/modules/multi_live/integration/multi_live_picker.dart';
import 'package:simple_live_app/modules/multi_live/integration/multi_live_room_link.dart';
import 'package:simple_live_app/modules/multi_live/session/multi_live_room_spec.dart';
import 'package:simple_live_app/services/follow_service.dart';

class _Follows extends FollowService {
  _Follows(Iterable<FollowUser> rooms, {this.failLoad = false}) {
    followList.addAll(rooms);
  }

  final bool failLoad;
  final loads = <bool>[];

  @override
  Future<void> loadData({bool updateStatus = true}) async {
    loads.add(updateStatus);
    if (failLoad) throw StateError('unavailable cached follows');
  }
}

FollowUser _follow(int index, {int status = 2, String site = 'douyu'}) =>
    FollowUser(
      id: '$site-$index',
      roomId: '$index',
      siteId: site,
      userName: '关注主播 $index',
      face: '',
      addTime: DateTime(2026),
    )..liveStatus.value = status;

const _inputKey = ValueKey('multi-live-room-link');
const _closeKey = ValueKey('multi-live-close');

Future<void> _open(
  WidgetTester tester,
  _Follows follows, {
  required double scale,
  Future<MultiLiveRoomSpec> Function(String)? resolveLink,
  ValueChanged<MultiLiveRoomSpec?>? onPicked,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(320, 568);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetViewInsets);
  await tester.pumpWidget(MaterialApp(
    theme: AppStyle.lightTheme.copyWith(platform: TargetPlatform.android),
    builder: (context, child) => MediaQuery(
      data:
          MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            final result = await showDialog<MultiLiveRoomSpec>(
              context: context,
              builder: (_) => MultiLiveRoomPicker(
                sites: Sites.allSites.values.toList(),
                follow: follows,
                resolveLink: resolveLink,
              ),
            );
            onPicked?.call(result);
          },
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

ScrollPosition _listPosition(WidgetTester tester) => tester
    .state<ScrollableState>(find.descendant(
      of: find.byType(CustomScrollView),
      matching: find.byType(Scrollable),
    ))
    .position;

void _expectActions(WidgetTester tester, {double bottomInset = 0}) {
  final usable = Rect.fromLTWH(0, 0, 320, 568 - bottomInset);
  for (final finder in [
    find.byKey(_inputKey),
    find.text('添加直播间'),
    find.text('取消'),
    find.byKey(_closeKey),
  ]) {
    expect(finder.hitTestable(), findsOneWidget);
    final rect = tester.getRect(finder);
    expect(usable.contains(rect.topLeft), isTrue,
        reason: '$rect within $usable');
    expect(usable.contains(rect.bottomRight - const Offset(.01, .01)), isTrue,
        reason: '$rect within $usable');
  }
  expect(tester.takeException(), isNull);
}

void main() {
  for (final scale in [1.5, 2.0]) {
    testWidgets(
        '1000 follows keep fixed actions and the full lazy list at $scale',
        (tester) async {
      final follows = _Follows([
        for (var i = 0; i < 1000; i++) _follow(i),
        _follow(1000, status: 0),
        _follow(1001, status: 1),
        _follow(1002, site: 'unsupported'),
      ]);
      final results = <MultiLiveRoomSpec?>[];
      await _open(tester, follows, scale: scale, onPicked: results.add);
      _expectActions(tester);
      expect(
          find.byKey(const ValueKey('multi-live-follow-douyu-0')).hitTestable(),
          findsOneWidget);
      expect(find.byKey(const ValueKey('multi-live-follow-douyu-999')),
          findsNothing);
      expect(find.byKey(const ValueKey('multi-live-follow-douyu-1000')),
          findsNothing);
      expect(find.byKey(const ValueKey('multi-live-follow-douyu-1001')),
          findsNothing);
      expect(find.byKey(const ValueKey('multi-live-follow-unsupported-1002')),
          findsNothing);
      expect(follows.loads, isEmpty);
      final inputRect = tester.getRect(find.byKey(_inputKey));
      final cancelRect = tester.getRect(find.text('取消'));
      final position = _listPosition(tester);
      expect(position.maxScrollExtent, greaterThan(50000));
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -320));
      await tester.pumpAndSettle();
      expect(position.pixels, greaterThan(0));
      expect(tester.getRect(find.byKey(_inputKey)), inputRect);
      expect(tester.getRect(find.text('取消')), cancelRect);
      _expectActions(tester);
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('multi-live-follow-douyu-0')),
          findsNothing);
      expect(find.text('关注主播 999').hitTestable(), findsOneWidget);
      _expectActions(tester);
      await tester.tap(find.text('关注主播 999'));
      await tester.pumpAndSettle();
      expect(results.single?.roomKey, 'douyu:999');
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        '210px keyboard permits correction, submit and cancellation at $scale',
        (tester) async {
      final pending = Completer<MultiLiveRoomSpec>();
      final calls = <String>[];
      final results = <MultiLiveRoomSpec?>[];
      await _open(tester, _Follows(List.generate(1000, _follow)),
          scale: scale, onPicked: results.add, resolveLink: (text) async {
        calls.add(text);
        if (text == 'invalid') {
          throw const MultiLiveRoomLinkException('链接无效，请检查后重试');
        }
        return pending.future;
      });
      final input = find.byKey(_inputKey);
      await tester.tap(input);
      tester.view.viewInsets = const FakeViewPadding(bottom: 210);
      await tester.pumpAndSettle();
      _expectActions(tester, bottomInset: 210);
      expect(_listPosition(tester).viewportDimension, greaterThan(0));
      await tester.enterText(input, 'invalid');
      expect(tester.widget<TextField>(input).controller!.text, 'invalid');
      await tester.tap(find.text('添加直播间'));
      await tester.pumpAndSettle();
      expect(find.text('链接无效，请检查后重试'), findsOneWidget);
      _expectActions(tester, bottomInset: 210);
      await tester.enterText(input, 'https://www.huya.com/456');
      await tester.pumpAndSettle();
      expect(find.text('链接无效，请检查后重试'), findsNothing);
      _expectActions(tester, bottomInset: 210);
      await tester.tap(find.text('添加直播间'));
      await tester.tap(find.text('添加直播间'));
      await tester.pump();
      expect(calls, ['invalid', 'https://www.huya.com/456']);
      expect(tester.widget<TextField>(input).enabled, isFalse);
      expect(find.text('解析中…'), findsOneWidget);
      expect(find.text('取消').hitTestable(), findsOneWidget);
      expect(find.byKey(_closeKey).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(results, [null]);
      pending.complete(const MultiLiveRoomSpec(siteId: 'huya', roomId: '456'));
      await tester.pumpAndSettle();
      expect(results, [null]);
      expect(find.text('open'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('210px keyboard can submit an unfollowed direct link at $scale',
        (tester) async {
      final results = <MultiLiveRoomSpec?>[];
      await _open(tester, _Follows(List.generate(1000, _follow)),
          scale: scale, onPicked: results.add);
      final input = find.byKey(_inputKey);
      await tester.tap(input);
      tester.view.viewInsets = const FakeViewPadding(bottom: 210);
      await tester.pumpAndSettle();
      _expectActions(tester, bottomInset: 210);
      await tester.enterText(input, 'https://www.huya.com/456?share=copy');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(results.single?.roomKey, 'huya:456');
      expect(find.byType(MultiLiveRoomPicker), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'fixed close survives keyboard, scrolled list and late failure after reopening',
      (tester) async {
    final pending = Completer<MultiLiveRoomSpec>();
    final results = <MultiLiveRoomSpec?>[];
    await _open(tester, _Follows(List.generate(1000, _follow)),
        scale: 2, onPicked: results.add, resolveLink: (_) => pending.future);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -320));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_inputKey));
    tester.view.viewInsets = const FakeViewPadding(bottom: 210);
    await tester.pumpAndSettle();
    _expectActions(tester, bottomInset: 210);
    await tester.enterText(find.byKey(_inputKey), 'https://b23.tv/pending');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.tap(find.byKey(_closeKey));
    await tester.pumpAndSettle();
    expect(results, [null]);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    pending.completeError(const MultiLiveRoomLinkException('late failure'));
    await tester.pumpAndSettle();
    expect(results, [null]);
    _expectActions(tester, bottomInset: 210);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(results, [null, null]);
    expect(tester.takeException(), isNull);
  });

  for (final empty in [true, false]) {
    testWidgets(
        'failed ${empty ? 'cache load' : 'refresh'} preserves keyboard actions',
        (tester) async {
      final follows =
          _Follows(empty ? [] : List.generate(1000, _follow), failLoad: true);
      await _open(tester, follows, scale: 2);
      if (!empty) {
        await tester.tap(find.byTooltip('刷新直播状态'));
        await tester.pumpAndSettle();
      }
      expect(follows.loads, [!empty]);
      expect(
          find.text(empty ? '关注列表读取失败，请刷新重试' : '刷新失败，请稍后重试'), findsOneWidget);
      await tester.tap(find.byKey(_inputKey));
      tester.view.viewInsets = const FakeViewPadding(bottom: 210);
      await tester.pumpAndSettle();
      _expectActions(tester, bottomInset: 210);
      await tester.enterText(
          find.byKey(_inputKey), 'https://live.bilibili.com/12');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.byType(MultiLiveRoomPicker), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
