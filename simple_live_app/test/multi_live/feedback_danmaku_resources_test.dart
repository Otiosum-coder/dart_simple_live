import 'dart:async';
import 'dart:ui' as ui;

import 'package:canvas_danmaku/danmaku_controller.dart';
import 'package:canvas_danmaku/danmaku_screen.dart';
import 'package:canvas_danmaku/models/danmaku_content_item.dart';
import 'package:canvas_danmaku/models/danmaku_item.dart';
import 'package:canvas_danmaku/models/danmaku_option.dart';
import 'package:canvas_danmaku/scroll_danmaku_painter.dart';
import 'package:canvas_danmaku/special_danmaku_painter.dart';
import 'package:canvas_danmaku/static_danmaku_painter.dart';
import 'package:canvas_danmaku/utils/utils.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

SpecialDanmakuContentItem _special() =>
    SpecialDanmakuContentItem('reusable special',
        duration: 60000,
        color: Colors.red,
        fontSize: 20,
        translateXTween: Tween<double>(begin: 0, end: 1),
        translateYTween: Tween<double>(begin: 0, end: 1));

List<T> _painters<T>(WidgetTester tester) => tester
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .map((widget) => widget.painter)
    .whereType<T>()
    .toList();

List<DanmakuItem> _items(WidgetTester tester) => [
      for (final p in _painters<ScrollDanmakuPainter>(tester))
        ...p.scrollDanmakuItems,
      for (final p in _painters<StaticDanmakuPainter>(tester))
        ...p.topDanmakuItems,
      for (final p in _painters<StaticDanmakuPainter>(tester))
        ...p.buttomDanmakuItems,
      for (final p in _painters<SpecialDanmakuPainter>(tester))
        ...p.specialDanmakuItems,
    ];

Future<List<DanmakuController>> _mount(WidgetTester tester,
    {int count = 4}) async {
  final controllers = <DanmakuController>[];
  await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Column(children: [
        for (var i = 0; i < count; i++)
          Expanded(
              child: DanmakuScreen(
                  option: DanmakuOption(), createdController: controllers.add)),
      ])));
  return controllers;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('four dense painters explicitly release every temporary Picture', () {
    final created = <ui.Picture>[];
    final oldCreate = ui.Picture.onCreate;
    ui.Picture.onCreate = (picture) {
      created.add(picture);
      oldCreate?.call(picture);
    };
    addTearDown(() => ui.Picture.onCreate = oldCreate);
    final scroll = List.generate(
        4,
        (_) => List.generate(
            20,
            (i) => DanmakuItem(
                content: DanmakuContentItem('dense $i'),
                creationTime: 0,
                width: 120,
                height: 20)));
    final specialContent = _special();
    final special = List.generate(
        4,
        (_) => List.generate(
            20,
            (i) => DanmakuItem(
                content: specialContent,
                creationTime: 0,
                width: 120,
                height: 20,
                painterCache: TextPainter(
                    text: const TextSpan(text: 'dense special'),
                    textDirection: TextDirection.ltr)
                  ..layout())));
    try {
      for (var frame = 0; frame < 200; frame++) {
        for (var room = 0; room < 4; room++) {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder);
          ScrollDanmakuPainter(
                  0, scroll[room], 10, 16, 4, null, true, 20, true, 0, const {})
              .paint(canvas, const Size(800, 600));
          SpecialDanmakuPainter(0, special[room], 16, 4, null, true, 0)
              .paint(canvas, const Size(800, 600));
          recorder.endRecording().dispose();
        }
      }
      expect(created.length, 2400);
      expect(created.every((picture) => picture.debugDisposed), isTrue);
    } finally {
      for (final item in [
        ...scroll.expand((r) => r),
        ...special.expand((r) => r)
      ]) {
        item.dispose();
        item.dispose(); // Repeated ownership cleanup must not release twice.
      }
    }
  });

  test('batch paint exceptions end and dispose the partial recordings', () {
    final created = <ui.Picture>[];
    final oldCreate = ui.Picture.onCreate;
    ui.Picture.onCreate = (picture) {
      created.add(picture);
      oldCreate?.call(picture);
    };
    addTearDown(() => ui.Picture.onCreate = oldCreate);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final special = List.generate(
        11,
        (_) => DanmakuItem(
            content: _special(), creationTime: 0, width: 120, height: 20));
    expect(
        () => SpecialDanmakuPainter(0, special, 16, 4, null, true, 0)
            .paint(canvas, const Size(800, 600)),
        throwsA(anything));
    final paragraph = Utils.generateParagraph(
        DanmakuContentItem('disposed fixture'), 120, 16, 4)
      ..dispose();
    final scroll = List.generate(
        11,
        (_) => DanmakuItem(
            content: DanmakuContentItem('broken'),
            creationTime: 0,
            width: 120,
            height: 20,
            paragraph: paragraph));
    expect(
        () => ScrollDanmakuPainter(
                0, scroll, 10, 16, 4, null, false, 20, true, 0, const {})
            .paint(canvas, const Size(800, 600)),
        throwsA(anything));
    recorder.endRecording().dispose();
    expect(created.length, 3);
    expect(created.every((picture) => picture.debugDisposed), isTrue);
  });

  test('5000 text measurements dispose their real TextPainter handles', () {
    final created = <TextPainter>[];
    final disposed = <TextPainter>[];
    void allocation(ObjectEvent event) {
      final object = event.object;
      if (object is! TextPainter) return;
      if (event is ObjectCreated) created.add(object);
      if (event is ObjectDisposed) disposed.add(object);
    }

    FlutterMemoryAllocations.instance.addListener(allocation);
    try {
      for (var i = 0; i < 5000; i++) {
        Utils.measureContent(DanmakuContentItem('measurement $i'), 16, 4);
      }
    } finally {
      FlutterMemoryAllocations.instance.removeListener(allocation);
    }
    expect(created.length, 5000);
    expect(disposed.length, created.length);
    expect(created.every((painter) => painter.debugDisposed), isTrue);
  });

  testWidgets(
      'four saturated screens release layouts on options, hide, clear and unmount',
      (tester) async {
    final controllers = await _mount(tester);
    for (final controller in controllers) {
      for (var i = 0; i < 2000; i++) {
        controller.addDanmaku(DanmakuContentItem('scroll $i'));
        controller.addDanmaku(
            DanmakuContentItem('top $i', type: DanmakuItemType.top));
        controller.addDanmaku(
            DanmakuContentItem('bottom $i', type: DanmakuItemType.bottom));
      }
    }
    await tester.pump();
    final active = _items(tester);
    expect(active, isNotEmpty);
    expect(active.length, lessThan(100));
    final oldParagraphs = [
      for (final item in active)
        ...[item.paragraph, item.strokeParagraph].whereType<ui.Paragraph>()
    ];
    for (final controller in controllers) {
      controller.updateOption(DanmakuOption(fontSize: 20, showStroke: false));
    }
    expect(oldParagraphs.every((paragraph) => paragraph.debugDisposed), isTrue);
    await tester.pump();
    final rebuilt = [
      for (final item in _items(tester))
        ...[item.paragraph, item.strokeParagraph].whereType<ui.Paragraph>()
    ];
    expect(rebuilt, isNotEmpty);
    controllers[0].updateOption(
        DanmakuOption(hideScroll: true, hideTop: true, hideBottom: true));
    controllers[1].clear();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(rebuilt.every((paragraph) => paragraph.debugDisposed), isTrue);
  });

  testWidgets('reused special content releases only its own active occurrence',
      (tester) async {
    final controllers = await _mount(tester, count: 2);
    final special = _special();
    controllers[0].addDanmaku(special);
    controllers[0].addDanmaku(special);
    controllers[1].addDanmaku(special);
    await tester.pump();
    final active = _items(tester);
    final painters = active.map((item) => item.painterCache!).toList();
    expect(painters.toSet(), hasLength(3));
    controllers[0].clear();
    expect(painters.take(2).every((painter) => painter.debugDisposed), isTrue);
    expect(painters.last.debugDisposed, isFalse);
    controllers[0].addDanmaku(special);
    await tester.pump();
    expect(tester.takeException(), isNull);
    controllers[1].updateOption(DanmakuOption(hideSpecial: true));
    expect(painters.last.debugDisposed, isTrue);
    final remaining = _items(tester)
        .map((item) => item.painterCache)
        .whereType<TextPainter>()
        .toList();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(remaining.every((painter) => painter.debugDisposed), isTrue);
  });

  testWidgets(
      'expiry uses current options and pause/resume keeps one cleanup timer',
      (tester) async {
    final timers = <Timer>[];
    await runZoned(() async {
      final controllers = await _mount(tester, count: 1);
      final controller = controllers.single;
      for (var i = 0; i < 100; i++) {
        controller.pause();
        controller.pause();
        controller.resume();
        controller.resume();
      }
      expect(timers.where((timer) => timer.isActive), hasLength(1));
      final top =
          _painters<StaticDanmakuPainter>(tester).single.topDanmakuItems;
      final content = DanmakuContentItem('expired', type: DanmakuItemType.top);
      final paragraph = Utils.generateParagraph(content, 120, 16, 4);
      top.add(DanmakuItem(
          content: content,
          creationTime: -2000,
          width: 120,
          height: 20,
          paragraph: paragraph));
      controller.updateOption(DanmakuOption(duration: 1));
      await tester.pump(const Duration(milliseconds: 110));
      expect(top, isEmpty);
      expect(paragraph.debugDisposed, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(timers.where((timer) => timer.isActive), isEmpty);
    }, zoneSpecification: ZoneSpecification(
        createPeriodicTimer: (self, parent, zone, duration, callback) {
      final timer = parent.createPeriodicTimer(zone, duration, callback);
      if (duration == const Duration(milliseconds: 100)) timers.add(timer);
      return timer;
    }));
  });
}
