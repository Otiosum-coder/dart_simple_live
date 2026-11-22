import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/utils/bounded_chat_buffer.dart';

void main() {
  test('keeps only the newest 200 messages during a long session', () {
    final visible = <int>[].obs;
    final buffer = BoundedChatBuffer<int>(visible);
    for (var i = 0; i < 10000; i++) {
      buffer.add(i);
    }
    expect(visible, orderedEquals(List.generate(200, (i) => 9800 + i)));
    expect(buffer.pendingLength, 0);
  });

  test('reading snapshot stays stable and pending messages stay bounded', () {
    final visible = List.generate(200, (i) => i).obs;
    final buffer = BoundedChatBuffer<int>(visible);
    for (var i = 200; i < 10000; i++) {
      buffer.add(i, paused: true);
    }
    expect(visible, orderedEquals(List.generate(200, (i) => i)));
    expect(buffer.pendingLength, 200);
    buffer.resume();
    expect(visible, orderedEquals(List.generate(200, (i) => 9800 + i)));
    expect(buffer.pendingLength, 0);
  });

  test('resume merges a short backlog once in chronological order', () {
    final visible = <int>[1, 2, 3].obs;
    final buffer = BoundedChatBuffer<int>(visible, maximumSize: 4);
    buffer.add(4, paused: true);
    buffer.add(5, paused: true);
    buffer.resume();
    buffer.resume();
    expect(visible, orderedEquals([2, 3, 4, 5]));
    buffer.add(6);
    expect(visible, orderedEquals([3, 4, 5, 6]));
  });

  test('adding after pause flushes backlog even before a resume callback', () {
    final visible = <int>[1, 2, 3].obs;
    final buffer = BoundedChatBuffer<int>(visible, maximumSize: 3);
    buffer.add(4, paused: true);
    buffer.add(5);
    expect(visible, orderedEquals([3, 4, 5]));
    expect(buffer.pendingLength, 0);
  });

  test('clear removes pending messages across room switches', () {
    final visible = <int>[1].obs;
    final buffer = BoundedChatBuffer<int>(visible, maximumSize: 3);
    buffer.add(2, paused: true);
    buffer.clear();
    buffer.resume();
    buffer.add(3);
    expect(visible, orderedEquals([3]));
    expect(buffer.pendingLength, 0);
  });

  test('normalizes pre-existing overflow and rejects an invalid capacity', () {
    final visible = <int>[1, 2, 3, 4].obs;
    BoundedChatBuffer<int>(visible, maximumSize: 2);
    expect(visible, orderedEquals([3, 4]));
    expect(() => BoundedChatBuffer<int>(<int>[], maximumSize: 0),
        throwsArgumentError);
  });
}
