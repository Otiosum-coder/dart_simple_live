import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/services/background_playback_queue.dart';

void main() {
  group('BackgroundPlaybackQueue.nextIndex', () {
    test('下一台按列表循环前进', () {
      expect(
          BackgroundPlaybackQueue.nextIndex(
              length: 3, currentIndex: 0, step: 1),
          1);
      expect(
          BackgroundPlaybackQueue.nextIndex(
              length: 3, currentIndex: 1, step: 1),
          2);
      expect(
          BackgroundPlaybackQueue.nextIndex(
              length: 3, currentIndex: 2, step: 1),
          0);
    });

    test('上一台按列表循环后退', () {
      expect(
          BackgroundPlaybackQueue.nextIndex(
              length: 3, currentIndex: 0, step: -1),
          2);
      expect(
          BackgroundPlaybackQueue.nextIndex(
              length: 3, currentIndex: 2, step: -1),
          1);
    });

    test('当前房间不在列表时从头/尾进入', () {
      expect(
          BackgroundPlaybackQueue.nextIndex(
              length: 3, currentIndex: -1, step: 1),
          0);
      expect(
          BackgroundPlaybackQueue.nextIndex(
              length: 3, currentIndex: -1, step: -1),
          2);
    });

    test('只有当前一台或空列表时不切换', () {
      expect(
          BackgroundPlaybackQueue.nextIndex(
              length: 0, currentIndex: -1, step: 1),
          isNull);
      expect(
          BackgroundPlaybackQueue.nextIndex(
              length: 1, currentIndex: 0, step: 1),
          isNull);
      expect(
          BackgroundPlaybackQueue.nextIndex(
              length: 1, currentIndex: 0, step: -1),
          isNull);
    });

    test('非法步长返回 null', () {
      expect(
          BackgroundPlaybackQueue.nextIndex(
              length: 3, currentIndex: 0, step: 0),
          isNull);
      expect(
          BackgroundPlaybackQueue.nextIndex(
              length: 3, currentIndex: 0, step: 2),
          isNull);
    });
  });
}
