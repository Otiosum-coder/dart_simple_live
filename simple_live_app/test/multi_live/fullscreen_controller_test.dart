import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/modules/multi_live/integration/multi_live_fullscreen.dart';
import 'package:simple_live_app/modules/multi_live/widgets/multi_live_fullscreen_control.dart';

class FullscreenWindowFake extends ChangeNotifier
    implements MultiLiveWindowBackend {
  FullscreenWindowFake({this.fullscreen = false, this.maximized = false});
  bool fullscreen;
  bool maximized;
  Rect bounds = const Rect.fromLTWH(80, 70, 1200, 800);
  final calls = <String>[];
  final transitions = <bool>[];
  final callbacks = <VoidCallback>[];
  Completer<void>? enterGate;
  final entered = Completer<void>();
  Object? queryError;
  Object? enterError;
  int nativeActive = 0;
  int nativePeak = 0;
  int closed = 0;

  @override
  void addListener(VoidCallback listener) {
    callbacks.add(listener);
    super.addListener(listener);
  }

  @override
  Future<bool> isFullScreen() async {
    calls.add('read-fullscreen');
    if (queryError != null) throw queryError!;
    return fullscreen;
  }

  @override
  Future<bool> isMaximized() async {
    calls.add('read-maximized');
    return maximized;
  }

  @override
  Future<Rect> getBounds() async {
    calls.add('read-bounds');
    return bounds;
  }

  @override
  Future<void> setFullScreen(bool value) async {
    calls.add('fullscreen:$value');
    transitions.add(value);
    nativeActive++;
    if (nativeActive > nativePeak) nativePeak = nativeActive;
    try {
      if (value) {
        if (!entered.isCompleted) entered.complete();
        await enterGate?.future;
        if (enterError != null) {
          final error = enterError!;
          enterError = null;
          throw error;
        }
      }
      fullscreen = value;
      maximized = false;
      bounds = value
          ? const Rect.fromLTWH(0, 0, 1920, 1080)
          : const Rect.fromLTWH(10, 10, 900, 700);
      notifyListeners();
    } finally {
      nativeActive--;
    }
  }

  @override
  Future<void> maximize() async {
    calls.add('maximize');
    maximized = true;
    bounds = const Rect.fromLTWH(0, 0, 1920, 1040);
  }

  @override
  Future<void> unmaximize() async {
    calls.add('unmaximize');
    maximized = false;
  }

  @override
  Future<void> setBounds(Rect value) async {
    calls.add('bounds:$value');
    bounds = value;
  }

  void externalFullscreen(bool value) {
    fullscreen = value;
    notifyListeners();
  }

  @override
  Future<void> close() async {
    closed++;
    calls.add('close');
    super.dispose();
  }
}

MultiLiveWindowFullscreenController _control(FullscreenWindowFake window,
        {TargetPlatform platform = TargetPlatform.windows}) =>
    MultiLiveWindowFullscreenController(backend: window, platform: platform);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('initialize is shared and makes no window mutation', () async {
    final window = FullscreenWindowFake();
    final control = _control(window);
    final first = control.initialize();
    expect(identical(first, control.initialize()), isTrue);
    await first;
    expect(control.supported, isTrue);
    expect(control.isFullscreen, isFalse);
    expect(window.calls, ['read-fullscreen', 'read-maximized', 'read-bounds']);
    await control.close();
    control.dispose();
    expect(window.closed, 1);
    expect(window.transitions, isEmpty);
  });

  test('rapid toggles serialize across an unfinished native enter', () async {
    final window = FullscreenWindowFake()..enterGate = Completer<void>();
    final original = window.bounds;
    final control = _control(window);
    final enter = control.toggle();
    await window.entered.future;
    final leave = control.toggle();
    expect(window.transitions, [true]);
    window.enterGate!.complete();
    await Future.wait([enter, leave]);
    expect(window.transitions, [true, false]);
    expect(window.nativePeak, 1);
    expect(window.fullscreen, isFalse);
    expect(window.bounds, original);
    expect(control.isFullscreen, isFalse);
    await control.exit();
    expect(window.transitions, [true, false]);
    await control.close();
    control.dispose();
  });

  test('exit restores pre-fullscreen bounds; close restores route-entry bounds',
      () async {
    final window = FullscreenWindowFake();
    final original = window.bounds;
    final control = _control(window);
    await control.initialize();
    const resized = Rect.fromLTWH(120, 40, 1000, 700);
    window.bounds = resized;
    await control.toggle();
    expect(window.fullscreen, isTrue);
    await control.exit();
    expect(window.bounds, resized);
    await control.close();
    expect(window.bounds, original);
    expect(window.fullscreen, isFalse);
    control.dispose();
  });

  test('maximized route returns to a maximized window on exit and close',
      () async {
    final window = FullscreenWindowFake(maximized: true)
      ..bounds = const Rect.fromLTWH(0, 0, 1920, 1040);
    final control = _control(window);
    await control.toggle();
    await control.exit();
    expect(window.maximized, isTrue);
    expect(window.calls.where((call) => call == 'maximize').length, 1);
    expect(window.calls.where((call) => call.startsWith('bounds:')), isEmpty);
    await control.toggle();
    await control.close();
    expect(window.fullscreen, isFalse);
    expect(window.maximized, isTrue);
    expect(window.closed, 1);
    control.dispose();
  });

  test('a page entered while already fullscreen restores that state on close',
      () async {
    final window = FullscreenWindowFake(fullscreen: true);
    final control = _control(window);
    await control.initialize();
    expect(control.isFullscreen, isTrue);
    await control.toggle();
    expect(control.isFullscreen, isFalse);
    await control.close();
    expect(window.fullscreen, isTrue);
    expect(window.transitions, [false, true]);
    control.dispose();
  });

  test('close waits for an in-flight enter and cancels queued and late toggles',
      () async {
    final window = FullscreenWindowFake()..enterGate = Completer<void>();
    final original = window.bounds;
    final control = _control(window);
    var notifications = 0;
    control.addListener(() => notifications++);
    final entering = control.toggle();
    await window.entered.future;
    final queued = control.toggle();
    final closing = control.close();
    final countAtClose = notifications;
    expect(identical(closing, control.close()), isTrue);
    final late = control.toggle();
    window.enterGate!.complete();
    await Future.wait([entering, queued, closing, late]);
    expect(window.transitions, [true, false]);
    expect(window.bounds, original);
    expect(window.closed, 1);
    expect(window.nativePeak, 1);
    expect(notifications, countAtClose);
    expect(control.supported, isFalse);
    final calls = window.calls.length;
    for (final callback in window.callbacks) {
      callback();
    }
    await control.exit();
    expect(window.calls.length, calls);
    control.dispose();
  });

  test('close before initialization starts cannot mutate a late window',
      () async {
    final window = FullscreenWindowFake();
    final control = _control(window);
    final initialize = control.initialize();
    final closing = control.close();
    await Future.wait([initialize, closing]);
    expect(window.calls, ['close']);
    expect(window.closed, 1);
    control.dispose();
  });

  test('native fullscreen notifications update the button state', () async {
    final window = FullscreenWindowFake();
    final control = _control(window);
    await control.initialize();
    var changes = 0;
    control.addListener(() => changes++);
    window.externalFullscreen(true);
    await Future<void>.delayed(Duration.zero);
    expect(control.isFullscreen, isTrue);
    window.externalFullscreen(false);
    await Future<void>.delayed(Duration.zero);
    expect(control.isFullscreen, isFalse);
    expect(changes, 2);
    await control.close();
    control.dispose();
  });

  test('mobile never queries or changes native window state', () async {
    final window = FullscreenWindowFake();
    final control = _control(window, platform: TargetPlatform.android);
    await control.initialize();
    await control.toggle();
    await control.exit();
    expect(control.supported, isFalse);
    expect(window.calls, isEmpty);
    await control.close();
    expect(window.calls, ['close']);
    control.dispose();
  });

  test('missing plugin disables fullscreen and returns a clear failure',
      () async {
    final window = FullscreenWindowFake()
      ..queryError = MissingPluginException('native details');
    final control = _control(window);
    await expectLater(
        control.initialize(), throwsA(isA<MultiLiveFullscreenException>()));
    expect(control.supported, isFalse);
    await control.toggle();
    await control.close();
    expect(window.transitions, isEmpty);
    control.dispose();
  });

  test('a failed transition does not poison the queue or cleanup', () async {
    final window = FullscreenWindowFake()
      ..enterError = PlatformException(code: 'unavailable', message: 'details');
    final original = window.bounds;
    final control = _control(window);
    await expectLater(
        control.toggle(), throwsA(isA<MultiLiveFullscreenException>()));
    expect(control.supported, isTrue);
    expect(window.fullscreen, isFalse);
    await control.toggle();
    expect(window.fullscreen, isTrue);
    await control.close();
    expect(window.fullscreen, isFalse);
    expect(window.bounds, original);
    expect(window.closed, 1);
    control.dispose();
  });
}
