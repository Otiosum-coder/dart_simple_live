import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/modules/multi_live/integration/multi_live_fullscreen.dart';
import 'package:simple_live_app/modules/multi_live/multi_live_page.dart';

import 'fullscreen_controller_test.dart' show FullscreenWindowFake;
import 'page_interaction_test.dart' show FakeModel, Probe;

class _ComposerHost {
  final drafts = <String, String>{};
  final submitted = <String>[];
  final targets = <String>[];
  VoidCallback? close;
  BuildContext? promptContext;

  Widget build(BuildContext context, String roomId, FocusNode focus,
      bool Function() isCurrent, VoidCallback close) {
    this.close = close;
    promptContext = context;
    targets.add(roomId);
    return _Composer(host: this, roomId: roomId, focus: focus);
  }
}

/// Test-only host: production sending and IME policy are injected by the route.
class _Composer extends StatefulWidget {
  const _Composer(
      {required this.host, required this.roomId, required this.focus});
  final _ComposerHost host;
  final String roomId;
  final FocusNode focus;
  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  late final _input =
      TextEditingController(text: widget.host.drafts[widget.roomId] ?? '');
  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
        key: ValueKey('quick-input:${widget.roomId}'),
        controller: _input,
        focusNode: widget.focus,
        textInputAction: TextInputAction.send,
        decoration: const InputDecoration(hintText: '输入弹幕'),
        onChanged: (text) => widget.host.drafts[widget.roomId] = text,
        onSubmitted: (text) {
          if (_input.value.composing.isValid &&
              !_input.value.composing.isCollapsed) {
            return;
          }
          widget.host.submitted.add('${widget.roomId}:$text');
        },
      );
}

class _EditingModel extends FakeModel {
  _EditingModel() : super(2);
  final input = TextEditingController();
  int regularSubmits = 0;
  @override
  WidgetBuilder? get selectedRoomChatBuilder => (_) => TextField(
      key: const ValueKey('regular-chat-input'),
      controller: input,
      onSubmitted: (_) => regularSubmits++);
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }
}

class _Harness {
  final navigator = GlobalKey<NavigatorState>();
  final globalFocus = FocusNode();
  final globalEsc = <KeyEvent>[];
  final window = FullscreenWindowFake();
  late final fullscreen = MultiLiveWindowFullscreenController(
      backend: window, platform: TargetPlatform.windows);
  final composer = _ComposerHost();
  Route<void>? pageRoute;
}

Future<_Harness> _mount(WidgetTester tester, FakeModel model,
    {Size size = const Size(1200, 800),
    TargetPlatform platform = TargetPlatform.windows}) async {
  final harness = _Harness();
  await harness.fullscreen.initialize();
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  _cleanups.add(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await harness.fullscreen.close();
    harness.fullscreen.dispose();
    harness.globalFocus.dispose();
    model.dispose();
  });
  await tester.pumpWidget(MaterialApp(
      navigatorKey: harness.navigator,
      theme: AppStyle.lightTheme.copyWith(platform: platform),
      // This is the production main.dart shape: a global KeyboardListener
      // outside Navigator would otherwise exit fullscreen on every Escape.
      builder: (context, child) => KeyboardListener(
          focusNode: harness.globalFocus,
          onKeyEvent: (event) {
            if (event is KeyDownEvent &&
                event.logicalKey == LogicalKeyboardKey.escape) {
              harness.globalEsc.add(event);
              harness.window.externalFullscreen(false);
            }
          },
          child: child!),
      home: Scaffold(
          body: TextButton(
              onPressed: () {
                final route = MaterialPageRoute<void>(
                    builder: (_) => MultiLivePage(
                        model: model,
                        fullscreenControl: harness.fullscreen,
                        quickDanmakuBuilder: harness.composer.build));
                harness.pageRoute = route;
                harness.navigator.currentState!.push(route);
              },
              child: const Text('Open')))));
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
  return harness;
}

Future<void> _enter(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pumpAndSettle();
}

final _cleanups = <Future<void> Function()>[];

// Await window cleanup while the widget-test zone can still flush its microtasks.
void _pageTest(String name, WidgetTesterCallback callback) {
  testWidgets(name, (tester) async {
    try {
      await callback(tester);
    } finally {
      for (final cleanup in _cleanups.reversed) {
        await cleanup();
      }
      _cleanups.clear();
    }
  });
}

void main() {
  _pageTest('Escape closes prompt, restores pane, then exits whole workspace',
      (tester) async {
    final model = FakeModel(4);
    final harness = await _mount(tester, model);
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pumpAndSettle();
    expect(harness.window.fullscreen, isTrue);
    model.maximizeRoom('room0');
    await tester.pumpAndSettle();
    await _enter(tester);
    final field = find.byKey(const ValueKey('quick-input:room0'));
    expect(field, findsOneWidget);
    expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
    await tester.enterText(field, '保留这个草稿');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('quick-danmaku-prompt')), findsNothing);
    expect(harness.composer.drafts['room0'], '保留这个草稿');
    expect(model.maximizedRoomId, 'room0');
    expect(harness.window.fullscreen, isTrue);
    expect(harness.globalEsc, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(model.maximizedRoomId, isNull);
    expect(harness.window.fullscreen, isTrue);
    expect(harness.globalEsc, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(harness.window.fullscreen, isFalse);
    expect(harness.window.transitions, [true, false]);
    expect(harness.globalEsc, isEmpty);
    expect(model.created.values, everyElement(1));
    expect(model.destroyed, isEmpty);
    expect(find.byType(Probe), findsNWidgets(4));
    await _enter(tester);
    expect(tester.widget<TextField>(field).controller!.text, '保留这个草稿');
    expect(harness.composer.submitted, isEmpty);
    expect(tester.takeException(), isNull);
  });

  _pageTest('Enter delegates editing and candidate confirmation to the host',
      (tester) async {
    final model = FakeModel(2);
    final harness = await _mount(tester, model);
    await _enter(tester);
    final field = find.byKey(const ValueKey('quick-input:room0'));
    await tester.enterText(field, '一次提交');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();
    expect(harness.composer.submitted, ['room0:一次提交']);
    expect(find.byKey(const ValueKey('quick-danmaku-prompt')), findsOneWidget);
    tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: '候选文字',
        selection: TextSelection.collapsed(offset: 4),
        composing: TextRange(start: 0, end: 4)));
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();
    expect(harness.composer.submitted, ['room0:一次提交']);
    expect(find.byKey(const ValueKey('quick-danmaku-prompt')), findsOneWidget);
    expect(harness.composer.targets.toSet(), {'room0'});
    expect(model.created.values, everyElement(1));
  });

  _pageTest('ordinary chat editor and active modals keep their Enter behavior',
      (tester) async {
    final model = _EditingModel();
    final harness = await _mount(tester, model);
    final regular = find.byKey(const ValueKey('regular-chat-input'));
    await tester.tap(regular);
    tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: '输入法候选',
        selection: TextSelection.collapsed(offset: 5),
        composing: TextRange(start: 0, end: 5)));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('quick-danmaku-prompt')), findsNothing);
    expect(harness.composer.targets, isEmpty);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('layout-presets')));
    await tester.pumpAndSettle();
    await _enter(tester);
    expect(find.byKey(const ValueKey('quick-danmaku-prompt')), findsNothing);
    harness.navigator.currentState!.pop();
    await tester.pumpAndSettle();
    final pageContext = tester.element(find.byType(MultiLivePage));
    var modalSubmits = 0;
    showDialog<void>(
        context: pageContext,
        builder: (_) => AlertDialog(
            content: TextField(
                key: const ValueKey('link-like-input'),
                autofocus: true,
                onSubmitted: (_) => modalSubmits++)));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('link-like-input')), 'https://room.example');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(modalSubmits, 1);
    expect(harness.composer.targets, isEmpty);
    expect(find.byKey(const ValueKey('quick-danmaku-prompt')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  _pageTest(
      'selection and close remove the fixed-target prompt and keep drafts',
      (tester) async {
    final model = FakeModel(2);
    final harness = await _mount(tester, model);
    await _enter(tester);
    await tester.enterText(
        find.byKey(const ValueKey('quick-input:room0')), '房间零草稿');
    model.selectRoom('room1');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('quick-danmaku-prompt')), findsNothing);
    expect(harness.composer.drafts['room0'], '房间零草稿');
    await _enter(tester);
    expect(find.byKey(const ValueKey('quick-input:room1')), findsOneWidget);
    expect(find.text('发送弹幕 · 房间 1'), findsOneWidget);
    await tester.enterText(
        find.byKey(const ValueKey('quick-input:room1')), '房间一草稿');
    await model.closeRoom('room1');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('quick-danmaku-prompt')), findsNothing);
    expect(harness.composer.drafts['room1'], '房间一草稿');
    expect(harness.composer.submitted, isEmpty);
    expect(model.created['room0'], 1);
    expect(model.destroyed, {'room1': 1});
    expect(tester.takeException(), isNull);
  });

  _pageTest('closing our prompt beneath another modal leaves its focus intact',
      (tester) async {
    final model = FakeModel(2);
    final harness = await _mount(tester, model);
    await _enter(tester);
    final close = harness.composer.close!;
    showDialog<void>(
        context: harness.composer.promptContext!,
        builder: (_) => const AlertDialog(
            content: TextField(
                key: ValueKey('above-prompt-input'), autofocus: true)));
    await tester.pumpAndSettle();
    final topInput = find.byKey(const ValueKey('above-prompt-input'));
    await tester.enterText(topInput, '上层输入');
    close();
    close();
    model.selectRoom('room1');
    await tester.pumpAndSettle();
    expect(topInput, findsOneWidget);
    expect(
        tester.widget<TextField>(topInput).controller?.text ??
            tester
                .widget<EditableText>(find.byType(EditableText))
                .controller
                .text,
        '上层输入');
    expect(
        tester
            .widget<EditableText>(find.byType(EditableText))
            .focusNode
            .hasFocus,
        isTrue);
    expect(
        find.byKey(const ValueKey('quick-danmaku-prompt'), skipOffstage: false),
        findsNothing);
    expect(harness.globalEsc, isEmpty);
    expect(tester.takeException(), isNull);
  });

  _pageTest('removing the page with a prompt open closes only the owned prompt',
      (tester) async {
    final model = FakeModel(2);
    final harness = await _mount(tester, model);
    await _enter(tester);
    await tester.enterText(
        find.byKey(const ValueKey('quick-input:room0')), '离开仍保留');
    final close = harness.composer.close!;
    harness.navigator.currentState!.removeRoute(harness.pageRoute!);
    await tester.pumpAndSettle();
    close();
    await tester.pumpAndSettle();
    expect(find.byType(MultiLivePage), findsNothing);
    expect(find.byKey(const ValueKey('quick-danmaku-prompt')), findsNothing);
    expect(find.text('Open'), findsOneWidget);
    expect(harness.composer.drafts['room0'], '离开仍保留');
    // Page does not dispose a control owned by the route.
    expect(harness.window.closed, 0);
    expect(tester.takeException(), isNull);
  });

  // The user removed the title pencil; Enter remains the quick entry after
  // dismissing the narrow chat sheet. The bottom composer is route-owned.
  _pageTest('narrow chat sheet omits pencil and restores keyboard entry',
      (tester) async {
    final harness =
        await _mount(tester, FakeModel(4), size: const Size(480, 320));
    await tester.tap(find.byKey(const ValueKey('chat-panel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('quick-danmaku-entry')), findsNothing);
    await _enter(tester);
    expect(find.byKey(const ValueKey('quick-input:room0')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await _enter(tester);
    expect(find.byKey(const ValueKey('quick-input:room0')), findsOneWidget);
    expect(harness.composer.targets.toSet(), {'room0'});
    expect(tester.takeException(), isNull);
  });

  _pageTest('mobile keeps touch targets and does not intercept hardware Enter',
      (tester) async {
    final model = FakeModel(2, maxRooms: 2);
    final harness = await _mount(tester, model,
        size: const Size(320, 568), platform: TargetPlatform.android);
    expect(find.byKey(const ValueKey('workspace-fullscreen')), findsNothing);
    expect(tester.getSize(find.byType(AppBar)).height, 44);
    for (final key in [
      'layout-presets',
      'audio-panel',
      'chat-panel',
      'add-room'
    ]) {
      expect(tester.getSize(find.byKey(ValueKey(key))).height, 40);
    }
    await _enter(tester);
    expect(harness.composer.targets, isEmpty);
    expect(harness.window.transitions, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
