import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/modules/multi_live/multi_live_page.dart';

import 'page_interaction_test.dart' show FakeModel, Probe;

Future<void> _mount(WidgetTester tester, FakeModel model,
    {required Size size,
    double scale = 1,
    ThemeData? theme,
    TargetPlatform platform = TargetPlatform.windows}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
      theme: (theme ?? AppStyle.lightTheme).copyWith(platform: platform),
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!),
      home: Builder(
          builder: (context) => Scaffold(
              body: TextButton(
                  onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                          builder: (_) => MultiLivePage(model: model))),
                  child: const Text('Open'))))));
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

bool _contains(Rect outer, Rect inner) =>
    outer.inflate(.1).contains(inner.topLeft) &&
    outer.inflate(.1).contains(inner.bottomRight);

void _expectTitleFits(WidgetTester tester, String count,
    {double? desktopScale}) {
  final appBar = find.byType(AppBar);
  final bounds = tester.getRect(appBar);
  for (final label in ['多开直播', count]) {
    final text =
        find.descendant(of: appBar, matching: find.textContaining(label));
    expect(text, findsOneWidget);
    final rect = tester.getRect(text);
    expect(_contains(bounds, rect), isTrue,
        reason: '$label: $rect must fit within $bounds');
    if (desktopScale != null) {
      final paragraph = tester.renderObject<RenderParagraph>(text);
      expect(paragraph.didExceedMaxLines, isFalse,
          reason: '$label must be complete in $rect');
      for (final box in paragraph.getBoxesForSelection(TextSelection(
          baseOffset: 0, extentOffset: paragraph.text.toPlainText().length))) {
        final glyphBounds =
            box.toRect().shift(paragraph.localToGlobal(Offset.zero));
        expect(_contains(bounds, glyphBounds), isTrue,
            reason: '$label glyph $glyphBounds must fit within $bounds');
      }
      final widget = tester.widget<Text>(text);
      expect(widget.textScaler!.scale(16), closeTo(16 * desktopScale, .01),
          reason: 'Desktop title must honor the requested text scaling');
    }
  }
  for (final action in [
    find.byType(BackButton),
    find.byKey(const ValueKey('layout-presets')),
    find.byKey(const ValueKey('audio-panel')),
    find.byTooltip('查看选中房间聊天'),
    find.byKey(const ValueKey('add-room')),
  ]) {
    expect(action.hitTestable(), findsOneWidget);
    expect(_contains(bounds, tester.getRect(action)), isTrue);
  }
  expect(tester.takeException(), isNull);
}

void main() {
  for (final (themeName, theme) in [
    ('light', AppStyle.lightTheme),
    ('dark', AppStyle.darkTheme),
  ]) {
    for (final scale in [1.5, 2.0]) {
      testWidgets(
          'MV-REF-2 $themeName routed 320x240 at $scale preserves complete title',
          (tester) async {
        final model = FakeModel(4);
        addTearDown(model.dispose);
        await _mount(tester, model,
            size: const Size(320, 240), scale: scale, theme: theme);
        _expectTitleFits(tester, '4/4', desktopScale: scale);
        expect(find.byType(Probe), findsNWidgets(4));
        expect(model.created.values, everyElement(1));
        expect(model.destroyed, isEmpty);
        await tester.tap(find.byKey(const ValueKey('audio-panel')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('multi-live-audio-panel')),
            findsOneWidget);
        await tester.tap(find.byTooltip('关闭音量面板'));
        await tester.pumpAndSettle();
        _expectTitleFits(tester, '4/4', desktopScale: scale);
        expect(model.created.values, everyElement(1));
        expect(model.destroyed, isEmpty);
      });
    }
  }

  testWidgets(
      'normal desktop keeps 32px and updates count without recreating bodies',
      (tester) async {
    final model = FakeModel(4);
    addTearDown(model.dispose);
    await _mount(tester, model, size: const Size(1200, 800));
    expect(tester.getSize(find.byType(AppBar)).height, 32);
    _expectTitleFits(tester, '4/4', desktopScale: 1);
    tester.view.physicalSize = const Size(320, 240);
    await tester.pumpAndSettle();
    _expectTitleFits(tester, '4/4', desktopScale: 1);
    await model.closeRoom('room3');
    await tester.pumpAndSettle();
    _expectTitleFits(tester, '3/4', desktopScale: 1);
    expect(model.created, {'room0': 1, 'room1': 1, 'room2': 1, 'room3': 1});
    expect(model.destroyed, {'room3': 1});
    tester.view.physicalSize = const Size(1200, 800);
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(AppBar)).height, 32);
    _expectTitleFits(tester, '3/4', desktopScale: 1);
  });

  testWidgets('phone large text keeps 44px toolbar and 40px actions',
      (tester) async {
    final model = FakeModel(2, maxRooms: 2);
    addTearDown(model.dispose);
    await _mount(tester, model,
        size: const Size(320, 568), scale: 2, platform: TargetPlatform.android);
    expect(tester.getSize(find.byType(AppBar)).height, 44);
    _expectTitleFits(tester, '2/2');
    expect(find.bySemanticsLabel('多开直播 2/2'), findsOneWidget);
    for (final key in ['layout-presets', 'audio-panel', 'add-room']) {
      expect(tester.getSize(find.byKey(ValueKey(key))).height, 40);
    }
    expect(model.created, {'room0': 1, 'room1': 1});
    expect(model.destroyed, isEmpty);
  });
}
