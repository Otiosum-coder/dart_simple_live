import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../widgets/multi_live_fullscreen_control.dart';

/// Injectable window boundary. No player, system volume or route operations.
abstract class MultiLiveWindowBackend implements Listenable {
  Future<bool> isFullScreen();
  Future<bool> isMaximized();
  Future<Rect> getBounds();
  Future<void> setFullScreen(bool value);
  Future<void> maximize();
  Future<void> unmaximize();
  Future<void> setBounds(Rect bounds);
  Future<void> close();
}

class MultiLiveWindowManagerBackend extends ChangeNotifier
    with WindowListener
    implements MultiLiveWindowBackend {
  MultiLiveWindowManagerBackend() {
    windowManager.addListener(this);
  }

  bool _closed = false;

  @override
  void onWindowEnterFullScreen() {
    if (!_closed) notifyListeners();
  }

  @override
  void onWindowLeaveFullScreen() {
    if (!_closed) notifyListeners();
  }

  @override
  Future<bool> isFullScreen() => windowManager.isFullScreen();
  @override
  Future<bool> isMaximized() => windowManager.isMaximized();
  @override
  Future<Rect> getBounds() => windowManager.getBounds();
  @override
  Future<void> setFullScreen(bool value) => windowManager.setFullScreen(value);
  @override
  Future<void> maximize() => windowManager.maximize();
  @override
  Future<void> unmaximize() => windowManager.unmaximize();
  @override
  Future<void> setBounds(Rect bounds) => windowManager.setBounds(bounds);

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    windowManager.removeListener(this);
    dispose();
  }
}

class _WindowState {
  const _WindowState(this.fullscreen, this.maximized, this.bounds);
  final bool fullscreen;
  final bool maximized;
  final Rect bounds;
}

/// Serializes native transitions and restores the window on route teardown.
class MultiLiveWindowFullscreenController extends ChangeNotifier
    implements MultiLiveFullscreenControl {
  MultiLiveWindowFullscreenController(
      {MultiLiveWindowBackend? backend, TargetPlatform? platform}) {
    final target = platform ?? defaultTargetPlatform;
    _supported = !kIsWeb &&
        (target == TargetPlatform.windows ||
            target == TargetPlatform.macOS ||
            target == TargetPlatform.linux);
    _backend = backend ?? (_supported ? MultiLiveWindowManagerBackend() : null);
    _backend?.addListener(_windowChanged);
  }

  late final MultiLiveWindowBackend? _backend;
  late bool _supported;
  bool _isFullscreen = false;
  bool _initialized = false;
  bool _touchedWindow = false;
  bool _closing = false;
  bool _closed = false;
  bool _disposed = false;
  _WindowState? _original;
  _WindowState? _beforeFullscreen;
  Future<void> _tail = Future<void>.value();
  Future<void>? _initialization;
  Future<void>? _closeFuture;

  @override
  bool get supported => _supported && !_closing;
  @override
  bool get isFullscreen => _isFullscreen;

  Future<void> initialize() => _initialization ??= _enqueue(_initialize);

  Future<void> _initialize() async {
    if (_initialized || !_supported) return;
    _original = await _readState();
    _initialized = true;
    _setFullscreenState(_original!.fullscreen);
  }

  Future<_WindowState> _readState() async {
    final backend = _backend!;
    final fullscreen = await backend.isFullScreen();
    final maximized = await backend.isMaximized();
    final bounds = await backend.getBounds();
    return _WindowState(fullscreen, maximized, bounds);
  }

  void _setFullscreenState(bool value) {
    if (_isFullscreen == value) return;
    _isFullscreen = value;
    if (!_closing && !_disposed) notifyListeners();
  }

  Future<void> _enqueue(Future<void> Function() action,
      {bool duringClose = false}) {
    final result = _tail.then((_) async {
      if (_closed || (_closing && !duringClose)) return;
      try {
        await action();
      } catch (error) {
        if (error is MissingPluginException || error is UnsupportedError) {
          _supported = false;
          if (!_closing && !_disposed) notifyListeners();
        }
        throw const MultiLiveFullscreenException('整窗全屏暂不可用，请稍后重试');
      }
    });
    // A failed command must not poison cleanup or the next native transition.
    _tail =
        result.then<void>((_) {}, onError: (Object error, StackTrace stack) {});
    return result;
  }

  @override
  Future<void> toggle() => _enqueue(() async {
        await _initialize();
        if (!_supported || _closing) return;
        final current = await _backend!.isFullScreen();
        await _setFullscreen(!current);
      });

  @override
  Future<void> exit() => _enqueue(() async {
        await _initialize();
        if (!_supported || _closing) return;
        await _setFullscreen(false);
      });

  Future<void> _setFullscreen(bool value) async {
    final current = await _readState();
    if (current.fullscreen == value) {
      _setFullscreenState(value);
      return;
    }
    if (_closing) return;
    if (value) _beforeFullscreen = current;
    _touchedWindow = true;
    await _backend!.setFullScreen(value);
    if (!value && _beforeFullscreen != null) {
      await _restoreWindow(_beforeFullscreen!);
      _beforeFullscreen = null;
    }
    _setFullscreenState(value);
  }

  Future<void> _restoreWindow(_WindowState state) async {
    final backend = _backend!;
    if (await backend.isFullScreen() != state.fullscreen) {
      await backend.setFullScreen(state.fullscreen);
    }
    if (!state.fullscreen) {
      final maximized = await backend.isMaximized();
      if (state.maximized) {
        if (!maximized) await backend.maximize();
      } else {
        if (maximized) await backend.unmaximize();
        if (await backend.getBounds() != state.bounds) {
          await backend.setBounds(state.bounds);
        }
      }
    }
    _setFullscreenState(state.fullscreen);
  }

  void _windowChanged() {
    if (_closing || !_supported) return;
    unawaited(_enqueue(() async {
      if (_initialized) {
        _setFullscreenState(await _backend!.isFullScreen());
      }
    }).catchError((Object error) {}));
  }

  @override
  Future<void> close() {
    if (_closeFuture != null) return _closeFuture!;
    _closing = true;
    _backend?.removeListener(_windowChanged);
    return _closeFuture = _enqueue(() async {
      try {
        if (_touchedWindow && _original != null) {
          await _restoreWindow(_original!);
        }
      } finally {
        _closed = true;
        await _backend?.close();
      }
    }, duringClose: true);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // Hosts should await close first; still clean up a prematurely disposed host.
    unawaited(close().catchError((Object error) {}));
    super.dispose();
  }
}
