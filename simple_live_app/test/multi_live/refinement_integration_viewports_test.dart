import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/modules/multi_live/integration/multi_live_picker.dart';
import 'package:simple_live_app/modules/multi_live/integration/multi_live_room_link.dart';
import 'package:simple_live_app/modules/multi_live/multi_live_page.dart';
import 'package:simple_live_app/modules/multi_live/session/multi_live_room_spec.dart';
import 'package:simple_live_app/services/follow_service.dart';

import 'page_interaction_test.dart' show FakeModel;

class _Follows extends FollowService {
  _Follows(Iterable<FollowUser> rows) {
    followList.addAll(rows);
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

Future<void> _mount(WidgetTester tester,
    {required Size size,
    required TargetPlatform platform,
    required double scale,
    required WidgetBuilder route}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
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
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: route),
          ),
          child: const Text('Open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

Future<void> _openPicker(WidgetTester tester, _Follows follows,
    {required Size size,
    required TargetPlatform platform,
    double scale = 1,
    Future<MultiLiveRoomSpec> Function(String)? resolveLink,
    ValueChanged<MultiLiveRoomSpec?>? onPicked}) async {
  await _mount(tester,
      size: size,
      platform: platform,
      scale: scale,
      route: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                final picked = await showDialog<MultiLiveRoomSpec>(
                  context: context,
                  builder: (_) => MultiLiveRoomPicker(
                    sites: Sites.allSites.values.toList(),
                    follow: follows,
                    resolveLink: resolveLink,
                  ),
                );
                onPicked?.call(picked);
              },
              child: const Text('Choose'),
            ),
          ));
  await tester.tap(find.text('Choose'));
  await tester.pumpAndSettle();
}

bool _contains(Rect outer, Rect inner) =>
    outer.inflate(0.1).contains(inner.topLeft) &&
    outer.inflate(0.1).contains(inner.bottomRight);

void main() {
  for (final (size, platform, scale) in [
    (const Size(320, 240), TargetPlatform.windows, 1.5),
    (const Size(320, 240), TargetPlatform.windows, 2.0),
    (const Size(320, 568), TargetPlatform.android, 2.0),
  ]) {
    testWidgets(
        '$platform $size at $scale: routed toolbar fits and remains tappable',
        (tester) async {
      final model = FakeModel(platform == TargetPlatform.windows ? 4 : 2,
          maxRooms: platform == TargetPlatform.windows ? 4 : 2);
      addTearDown(model.dispose);
      await _mount(tester,
          size: size,
          platform: platform,
          scale: scale,
          route: (_) => MultiLivePage(model: model));
      final appBar = find.byType(AppBar);
      final toolbar = tester.getRect(appBar);
      expect(tester.takeException(), isNull,
          reason:
              'Scaled title and controls must fit inside the routed toolbar');
      for (final action in [
        find.byType(BackButton),
        find.byKey(const ValueKey('layout-presets')),
        find.byKey(const ValueKey('audio-panel')),
        find.byTooltip('查看选中房间聊天'),
        find.byKey(const ValueKey('add-room')),
      ]) {
        expect(action.hitTestable(), findsOneWidget);
        expect(_contains(toolbar, tester.getRect(action)), isTrue);
      }
      final title = find.descendant(
        of: appBar,
        matching: find.textContaining('多开直播'),
      );
      expect(title, findsOneWidget);
      expect(_contains(toolbar, tester.getRect(title)), isTrue,
          reason:
              'Toolbar $toolbar, title ${tester.getRect(title)}, scale $scale');
    });
  }

  testWidgets('desktop picker paints eight complete, live-only avatar tiles',
      (tester) async {
    final follows = _Follows([
      _follow(0, status: 1),
      _follow(98, status: 0),
      _follow(99, site: 'unsupported'),
      for (var i = 1; i <= 1000; i++) _follow(i),
    ]);
    await _openPicker(tester, follows,
        size: const Size(1280, 800), platform: TargetPlatform.windows);
    final viewport = tester.getRect(find.byType(CustomScrollView));
    final tiles = <Rect>[];
    for (var i = 1; i <= 8; i++) {
      final tile = find.byKey(ValueKey('multi-live-follow-douyu-$i'));
      final avatar =
          find.byKey(ValueKey('multi-live-avatar-fallback-douyu-$i'));
      expect(tile.hitTestable(), findsOneWidget);
      tiles.add(tester.getRect(tile));
      expect(_contains(viewport, tiles.last), isTrue);
      expect(tester.getSize(avatar), const Size(40, 40));
      expect(_contains(tiles.last, tester.getRect(avatar)), isTrue);
    }
    expect(tiles[0].top, tiles[1].top);
    expect(tiles[2].top, greaterThan(tiles[0].bottom));
    expect(
        find.byKey(const ValueKey('multi-live-follow-douyu-0')), findsNothing);
    expect(find.byKey(const ValueKey('multi-live-follow-unsupported-99')),
        findsNothing);
    expect(find.byKey(const ValueKey('multi-live-follow-douyu-1000')),
        findsNothing);
    expect(find.byType(TextField).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    debugPrint(
        'Picker viewport $viewport, first tile ${tiles.first}, eighth tile ${tiles.last}');
  });

  testWidgets('a cancelled resolution cannot dismiss a reopened picker',
      (tester) async {
    const firstLink = 'https://live.bilibili.com/12';
    const secondLink = 'https://www.huya.com/456?share=copy';
    final pending = Completer<MultiLiveRoomSpec>();
    final results = <MultiLiveRoomSpec?>[];
    final calls = <String>[];
    final resolver =
        MultiLiveRoomLinkResolver(supportedSiteIds: Sites.allSites.keys);
    await _openPicker(tester, _Follows([_follow(1)]),
        size: const Size(1280, 800),
        platform: TargetPlatform.windows, resolveLink: (link) {
      calls.add(link);
      return link == firstLink ? pending.future : resolver.resolve(link);
    }, onPicked: results.add);
    final input = find.byKey(const ValueKey('multi-live-room-link'));
    await tester.enterText(input, firstLink);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(calls, [firstLink]);
    expect(tester.widget<TextField>(input).enabled, isFalse);
    expect(find.text('解析中…'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(results, [null]);
    await tester.tap(find.text('Choose'));
    await tester.pumpAndSettle();
    pending.complete(const MultiLiveRoomSpec(siteId: 'bilibili', roomId: '12'));
    await tester.pumpAndSettle();
    expect(results, [null]);
    expect(input.hitTestable(), findsOneWidget);

    await tester.enterText(input, secondLink);
    await tester.tap(find.text('添加直播间'));
    await tester.pumpAndSettle();
    expect(calls, [firstLink, secondLink]);
    expect(results, hasLength(2));
    expect(results.last?.roomKey, 'huya:456');
    expect(find.byType(MultiLiveRoomPicker), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone with many follows can reach link and cancel near the top',
      (tester) async {
    await _openPicker(tester, _Follows(List.generate(1000, _follow)),
        size: const Size(320, 568),
        platform: TargetPlatform.android,
        scale: 1.5);
    final link = find.byType(TextField);
    final cancel = find.text('取消');
    final scrollable = find.descendant(
        of: find.byType(CustomScrollView), matching: find.byType(Scrollable));
    final position = tester.state<ScrollableState>(scrollable).position;
    final extent = position.maxScrollExtent;
    for (var i = 0; i < 2 && link.hitTestable().evaluate().isEmpty; i++) {
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -320));
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);
    expect(link.hitTestable(), findsOneWidget,
        reason:
            'Link entry must be reachable without scrolling the 1000-room list. '
            'After two gestures: ${position.pixels}px / $extent px. '
            'Cancel visible: ${cancel.hitTestable().evaluate().isNotEmpty}');
    await tester.tap(link);
    tester.view.viewInsets = const FakeViewPadding(bottom: 210);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    expect(cancel.hitTestable(), findsOneWidget);
    await tester.tap(cancel);
    await tester.pumpAndSettle();
    expect(find.byType(MultiLiveRoomPicker), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets(
        'minimum desktop picker at $scale permits error correction and cancel',
        (tester) async {
      final results = <MultiLiveRoomSpec?>[];
      await _openPicker(tester, _Follows(List.generate(16, _follow)),
          size: const Size(280, 280),
          platform: TargetPlatform.windows,
          scale: scale,
          onPicked: results.add);
      final input = find.byType(TextField);
      final submit = find.text('添加直播间');
      final cancel = find.text('取消');
      final list = find.byType(CustomScrollView);
      final header = find.text('选择直播间');
      debugPrint('Minimum desktop at $scale: header ${tester.getRect(header)}, '
          'list ${tester.getRect(list)}, input ${tester.getRect(input)}, '
          'submit ${tester.getRect(submit)}, cancel ${tester.getRect(cancel)}');
      expect(tester.takeException(), isNull);
      expect(input.hitTestable(), findsOneWidget);
      expect(submit.hitTestable(), findsOneWidget);
      await tester.enterText(input, 'invalid');
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.widget<TextField>(input).decoration?.errorText, isNotNull);
      expect(results, isEmpty);
      expect(input.hitTestable(), findsOneWidget);
      expect(submit.hitTestable(), findsOneWidget);
      expect(cancel.hitTestable(), findsOneWidget);
      await tester.enterText(input, 'https://www.huya.com/456');
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(input).decoration?.errorText, isNull);
      await tester.tap(cancel);
      await tester.pumpAndSettle();
      expect(results, [null]);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('short landscape keyboard leaves link and actions usable',
      (tester) async {
    final results = <MultiLiveRoomSpec?>[];
    await _openPicker(tester, _Follows(List.generate(16, _follow)),
        size: const Size(568, 320),
        platform: TargetPlatform.android,
        onPicked: results.add);
    final input = find.byType(TextField);
    final submit = find.text('添加直播间');
    final cancel = find.text('取消');
    expect(input.hitTestable(), findsOneWidget);
    await tester.tap(input);
    tester.view.viewInsets = const FakeViewPadding(bottom: 180);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    final inputBounds = tester.getRect(input);
    final submitBounds = tester.getRect(submit);
    final cancelBounds = tester.getRect(cancel);
    debugPrint('Landscape keyboard: input $inputBounds, '
        'submit $submitBounds, cancel $cancelBounds');
    expect(tester.takeException(), isNull);
    const usableBounds = Rect.fromLTWH(0, 0, 568, 140);
    expect(_contains(usableBounds, inputBounds), isTrue);
    expect(_contains(usableBounds, submitBounds), isTrue);
    expect(_contains(usableBounds, cancelBounds), isTrue);
    await tester.enterText(input, 'invalid');
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(results, isEmpty);
    expect(tester.widget<TextField>(input).decoration?.errorText, isNotNull);
    await tester.tap(cancel);
    await tester.pumpAndSettle();
    expect(results, [null]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'rotation preserves the active editor for default Douyin submission',
      (tester) async {
    const draft = 'https://live.douyin.com/4161440';
    const complete = 'https://live.douyin.com/416144012050?share=copy';
    final results = <MultiLiveRoomSpec?>[];
    await _openPicker(tester, _Follows(List.generate(1000, _follow)),
        size: const Size(320, 568),
        platform: TargetPlatform.android,
        onPicked: results.add);
    final input = find.byType(TextField);
    await tester.enterText(input, draft);
    final original = tester.widget<TextField>(input);
    expect(original.focusNode!.hasFocus, isTrue);
    tester.view.viewInsets = const FakeViewPadding(bottom: 210);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(568, 320);
    tester.view.viewInsets = const FakeViewPadding(bottom: 180);
    await tester.pumpAndSettle();
    final rotated = tester.widget<TextField>(input);
    expect(rotated.controller, same(original.controller));
    expect(rotated.focusNode, same(original.focusNode));
    expect(rotated.controller!.text, draft);
    expect(rotated.focusNode!.hasFocus, isTrue);
    expect(tester.testTextInput.isRegistered, isTrue);
    expect(input.hitTestable(), findsOneWidget);
    expect(find.text('取消').hitTestable(), findsOneWidget);
    final scroll = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    expect(scroll.position.maxScrollExtent, lessThan(200),
        reason: 'Typing is independent of the 1000-follow browsing distance');
    tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: complete,
        selection: TextSelection.collapsed(offset: complete.length)));
    await tester.pump();
    expect(tester.widget<TextField>(input).controller!.text, complete);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(results, hasLength(1));
    expect(results.single?.roomKey, 'douyin:416144012050');
    expect(find.byType(MultiLiveRoomPicker), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
