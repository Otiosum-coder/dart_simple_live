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
  _Follows(Iterable<FollowUser> rooms) {
    followList.addAll(rooms);
  }

  final loads = <bool>[];

  @override
  Future<void> loadData({bool updateStatus = true}) async {
    loads.add(updateStatus);
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
const _browseKey = ValueKey('multi-live-browse-follows');
const _returnKey = ValueKey('multi-live-return-link');
const _valid = 'https://www.huya.com/456?share=copy';

Future<void> _open(
  WidgetTester tester,
  _Follows follows, {
  required Size size,
  TargetPlatform platform = TargetPlatform.android,
  double scale = 1,
  Future<MultiLiveRoomSpec> Function(String)? resolveLink,
  ValueChanged<MultiLiveRoomSpec?>? onPicked,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetViewInsets);
  await tester.pumpWidget(MaterialApp(
    theme: AppStyle.lightTheme.copyWith(platform: platform),
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

Finder get _input => find.byKey(_inputKey);
Finder get _panel => find.byType(CustomScrollView);

ScrollPosition _position(WidgetTester tester) => tester
    .state<ScrollableState>(find
        .descendant(
          of: _panel,
          matching: find.byType(Scrollable),
        )
        .first)
    .position;

Rect _usable(WidgetTester tester) => Rect.fromLTWH(
      0,
      0,
      tester.view.physicalSize.width,
      tester.view.physicalSize.height - tester.view.viewInsets.bottom,
    );

void _inside(WidgetTester tester, Finder target, {bool full = true}) {
  expect(target.hitTestable(), findsOneWidget);
  final rect = tester.getRect(target);
  final bounds = _usable(tester).inflate(.1);
  expect(bounds.contains(rect.center), isTrue, reason: '$rect in $bounds');
  if (full) {
    expect(bounds.contains(rect.topLeft), isTrue, reason: '$rect in $bounds');
    expect(bounds.contains(rect.bottomRight), isTrue,
        reason: '$rect in $bounds');
  }
}

void _actions(WidgetTester tester, {String primary = '添加直播间'}) {
  _inside(tester, find.text(primary));
  _inside(tester, find.text('取消'));
  expect(tester.takeException(), isNull);
}

Future<void> _reveal(WidgetTester tester, Finder target,
    {double delta = -70}) async {
  for (var i = 0; i < 4 && target.hitTestable().evaluate().isEmpty; i++) {
    await tester.drag(_panel, Offset(0, delta));
    await tester.pumpAndSettle();
  }
  expect(target.hitTestable(), findsOneWidget,
      reason: 'The short panel must be reachable in at most four gestures.');
  expect(tester.takeException(), isNull);
}

Future<void> _keyboard(WidgetTester tester, double bottom) async {
  await tester.tap(_input);
  tester.view.viewInsets = FakeViewPadding(bottom: bottom);
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

void main() {
  for (final count in [16, 1000]) {
    testWidgets(
        '568x320 with 180px keyboard: errors and real submission for $count follows',
        (tester) async {
      final follows = _Follows(List.generate(count, _follow));
      final results = <MultiLiveRoomSpec?>[];
      await _open(tester, follows,
          size: const Size(568, 320), onPicked: results.add);
      await _keyboard(tester, 180);
      _inside(tester, _input);
      _actions(tester);
      expect(_position(tester).maxScrollExtent, lessThan(160));
      expect(find.byKey(ValueKey('multi-live-follow-douyu-${count - 1}')),
          findsNothing);
      await tester.enterText(_input, 'invalid');
      await tester.tap(find.text('添加直播间'));
      await tester.pumpAndSettle();
      final error = tester.widget<TextField>(_input).decoration!.errorText;
      expect(error, isNotNull);
      expect(results, isEmpty);
      await tester.drag(_panel, const Offset(0, -36));
      await tester.pumpAndSettle();
      await _reveal(tester, find.text(error!));
      _inside(tester, find.text(error));
      _actions(tester);
      await tester.drag(_panel, const Offset(0, 100));
      await tester.pumpAndSettle();
      await _reveal(tester, _input, delta: 70);
      await tester.enterText(_input, _valid);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(_input).decoration!.errorText, isNull);
      _actions(tester);
      if (count == 16) {
        await tester.tap(find.text('添加直播间'));
      } else {
        await tester.testTextInput.receiveAction(TextInputAction.done);
      }
      await tester.pumpAndSettle();
      expect(results.single?.roomKey, 'huya:456');
      expect(find.byType(MultiLiveRoomPicker), findsNothing);
      expect(follows.loads, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  for (final scale in [1.0, 2.0]) {
    testWidgets(
        '280x280 desktop at $scale: visible inline error, correction and button submit',
        (tester) async {
      final results = <MultiLiveRoomSpec?>[];
      await _open(tester, _Follows(List.generate(16, _follow)),
          size: const Size(280, 280),
          platform: TargetPlatform.windows,
          scale: scale,
          onPicked: results.add);
      _inside(tester, _input);
      _inside(tester, find.byKey(_closeKey));
      _actions(tester);
      expect(MediaQuery.textScalerOf(tester.element(_input)).scale(14),
          14 * scale);
      await tester.enterText(_input, 'invalid');
      await tester.tap(find.text('添加直播间'));
      await tester.pumpAndSettle();
      final error = tester.widget<TextField>(_input).decoration!.errorText;
      expect(error, isNotNull);
      if (scale == 2) await _reveal(tester, find.text(error!));
      _inside(tester, find.text(error!));
      _actions(tester);
      await tester.enterText(_input, _valid);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(_input).decoration!.errorText, isNull);
      await tester.tap(find.text('添加直播间'));
      await tester.pumpAndSettle();
      expect(results.single?.roomKey, 'huya:456');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'short form scroll extent and cancel stay independent of 16 or 1000 follows',
      (tester) async {
    final extents = <double>[];
    final inputs = <Rect>[];
    final cancels = <Rect>[];
    for (final count in [16, 1000]) {
      final pending = Completer<MultiLiveRoomSpec>();
      final calls = <String>[];
      final results = <MultiLiveRoomSpec?>[];
      await _open(tester, _Follows(List.generate(count, _follow)),
          size: const Size(568, 320),
          onPicked: results.add, resolveLink: (link) {
        calls.add(link);
        return pending.future;
      });
      await _keyboard(tester, 180);
      extents.add(_position(tester).maxScrollExtent);
      inputs.add(tester.getRect(_input));
      cancels.add(tester.getRect(find.text('取消')));
      await tester.enterText(_input, _valid);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(calls, [_valid]);
      expect(tester.widget<TextField>(_input).enabled, isFalse);
      _actions(tester, primary: '解析中…');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(results, [null]);
      pending.complete(const MultiLiveRoomSpec(siteId: 'huya', roomId: '456'));
      await tester.pumpAndSettle();
      expect(results, [null]);
      expect(find.text('open'), findsOneWidget);
      expect(tester.takeException(), isNull);
      tester.view.viewInsets = const FakeViewPadding();
    }
    expect(extents[1], extents[0]);
    expect(inputs[1], inputs[0]);
    expect(cancels[1], cancels[0]);
  });

  for (final count in [16, 1000]) {
    testWidgets(
        'short desktop browse and fixed return work at the last of $count follows',
        (tester) async {
      final follows = _Follows([
        ...List.generate(count, _follow),
        _follow(count, status: 0),
        _follow(count + 1, status: 1),
        _follow(count + 2, site: 'unsupported'),
      ]);
      await _open(tester, follows,
          size: const Size(280, 280),
          platform: TargetPlatform.windows,
          scale: 2);
      await tester.enterText(_input, 'draft retained through browsing');
      await _reveal(tester, find.byKey(_browseKey));
      await tester.tap(find.byKey(_browseKey));
      await tester.pumpAndSettle();
      _actions(tester, primary: '返回链接添加');
      final returnBounds = tester.getRect(find.byKey(_returnKey));
      expect(_input, findsNothing);
      expect(find.text('$count 位'), findsOneWidget);
      expect(find.byType(CircleAvatar).evaluate().length, lessThan(8));
      final position = _position(tester);
      await tester.drag(_panel, const Offset(0, -100));
      await tester.pumpAndSettle();
      expect(position.pixels, greaterThan(0));
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.text('关注主播 ${count - 1}').hitTestable(), findsOneWidget);
      expect(find.text('关注主播 $count'), findsNothing);
      expect(tester.getRect(find.byKey(_returnKey)), returnBounds);
      _actions(tester, primary: '返回链接添加');
      await tester.tap(find.byKey(_returnKey));
      await tester.pumpAndSettle();
      _inside(tester, _input);
      expect(tester.widget<TextField>(_input).controller!.text,
          'draft retained through browsing');
      expect(_position(tester).maxScrollExtent, lessThan(250));
      _actions(tester);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.byType(MultiLiveRoomPicker), findsNothing);
      expect(follows.loads, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('short browse can select the last live follow and leave once',
      (tester) async {
    final results = <MultiLiveRoomSpec?>[];
    await _open(tester, _Follows(List.generate(1000, _follow)),
        size: const Size(280, 280),
        platform: TargetPlatform.windows,
        scale: 2,
        onPicked: results.add);
    await _reveal(tester, find.byKey(_browseKey));
    await tester.tap(find.byKey(_browseKey));
    await tester.pumpAndSettle();
    final position = _position(tester);
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    await tester.tap(find.text('关注主播 999'));
    await tester.pumpAndSettle();
    expect(results.single?.roomKey, 'douyu:999');
    expect(tester.takeException(), isNull);
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets(
        'rotation and keyboard dismissal preserve typed link and errors at $scale',
        (tester) async {
      final results = <MultiLiveRoomSpec?>[];
      await _open(tester, _Follows(List.generate(1000, _follow)),
          size: const Size(320, 568), scale: scale, onPicked: results.add);
      await tester.enterText(_input, 'invalid partial share');
      tester.view.viewInsets = const FakeViewPadding(bottom: 210);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(_input).focusNode!.hasFocus, isTrue);
      tester.view.physicalSize = const Size(568, 320);
      tester.view.viewInsets = const FakeViewPadding(bottom: 180);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(_input).controller!.text,
          'invalid partial share');
      expect(tester.widget<TextField>(_input).focusNode!.hasFocus, isTrue);
      _actions(tester);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(_input).decoration!.errorText, isNotNull);
      expect(tester.widget<TextField>(_input).focusNode!.hasFocus, isFalse);
      tester.view.viewInsets = const FakeViewPadding();
      await tester.pumpAndSettle();
      _actions(tester);
      tester.view.physicalSize = const Size(320, 568);
      await tester.pumpAndSettle();
      _inside(tester, _input);
      _actions(tester);
      expect(tester.widget<TextField>(_input).controller!.text,
          'invalid partial share');
      expect(tester.widget<TextField>(_input).decoration!.errorText, isNotNull);
      await tester.enterText(_input, _valid);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(results.single?.roomKey, 'huya:456');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'short desktop close during parse protects a reopened dialog from late failure',
      (tester) async {
    final pending = Completer<MultiLiveRoomSpec>();
    final results = <MultiLiveRoomSpec?>[];
    await _open(tester, _Follows(List.generate(1000, _follow)),
        size: const Size(280, 280),
        platform: TargetPlatform.windows,
        scale: 2,
        onPicked: results.add,
        resolveLink: (_) => pending.future);
    await tester.enterText(_input, _valid);
    await tester.tap(find.text('添加直播间'));
    await tester.pump();
    _inside(tester, find.byKey(_closeKey));
    await tester.tap(find.byKey(_closeKey));
    await tester.pumpAndSettle();
    expect(results, [null]);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    pending.completeError(const MultiLiveRoomLinkException('late failure'));
    await tester.pumpAndSettle();
    _inside(tester, _input);
    _actions(tester);
    expect(tester.widget<TextField>(_input).decoration!.errorText, isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(results, [null, null]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty short picker has a browse return and working link input',
      (tester) async {
    final results = <MultiLiveRoomSpec?>[];
    final follows = _Follows([]);
    await _open(tester, follows,
        size: const Size(280, 280),
        platform: TargetPlatform.windows,
        scale: 2,
        onPicked: results.add);
    await _reveal(tester, find.byKey(_browseKey));
    await tester.tap(find.byKey(_browseKey));
    await tester.pumpAndSettle();
    _actions(tester, primary: '返回链接添加');
    await _reveal(tester, find.text('暂无正在直播的关注主播'));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(_returnKey));
    await tester.pumpAndSettle();
    await tester.enterText(_input, _valid);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(results.single?.roomKey, 'huya:456');
    expect(follows.loads, [false]);
    expect(tester.takeException(), isNull);
  });
}
