import 'dart:collection';

/// Keeps the visible reading position stable while bounding incoming chat.
class BoundedChatBuffer<T> {
  BoundedChatBuffer(this.messages, {this.maximumSize = 200}) {
    if (maximumSize < 1) {
      throw ArgumentError.value(maximumSize, 'maximumSize', 'Must be positive');
    }
    if (messages.length > maximumSize) {
      messages.removeRange(0, messages.length - maximumSize);
    }
  }

  final List<T> messages;
  final int maximumSize;
  final Queue<T> _pending = Queue<T>();

  int get pendingLength => _pending.length;

  void add(T message, {bool paused = false}) {
    if (paused) {
      if (_pending.length >= maximumSize) {
        _pending.removeFirst();
      }
      _pending.addLast(message);
      return;
    }
    resume();
    if (messages.length >= maximumSize) {
      messages.removeRange(0, messages.length - maximumSize + 1);
    }
    messages.add(message);
  }

  /// Merge only the newest messages once the user returns to the bottom.
  void resume() {
    if (_pending.isEmpty) {
      return;
    }
    final keepVisible = maximumSize - _pending.length;
    if (messages.length > keepVisible) {
      messages.removeRange(0, messages.length - keepVisible);
    }
    messages.addAll(_pending);
    _pending.clear();
  }

  void clear() {
    messages.clear();
    _pending.clear();
  }
}
