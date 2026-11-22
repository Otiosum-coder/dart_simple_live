import 'package:flutter/foundation.dart';

/// The workspace owns fullscreen; embedded room players never change it.
/// The route owns this control and awaits [close] before disposing it.
abstract class MultiLiveFullscreenControl implements Listenable {
  bool get supported;
  bool get isFullscreen;
  Future<void> toggle();
  Future<void> exit();
  Future<void> close();
}

class MultiLiveFullscreenException implements Exception {
  const MultiLiveFullscreenException(this.message);
  final String message;
  @override
  String toString() => message;
}
