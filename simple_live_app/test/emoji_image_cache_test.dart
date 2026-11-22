import 'dart:ui' as ui;

import 'package:canvas_danmaku/utils/emoji_image_cache.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

Future<ui.Image> _image([int size = 4]) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    ui.Paint()..color = const ui.Color(0xFFFF0000),
  );
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(size, size);
  } finally {
    picture.dispose();
  }
}

// Delivers callback-owned ImageInfo handles, including explicitly late frames.
class _Source extends ImageStreamCompleter {
  _Source({this.synchronousFrame}) {
    stream.setCompleter(this);
  }

  final stream = ImageStream();
  final listeners = <ImageStreamListener>{};
  ImageStreamListener? lastListener;
  ImageInfo? synchronousFrame;

  @override
  void addListener(ImageStreamListener listener) {
    listeners.add(listener);
    lastListener = listener;
    final frame = synchronousFrame;
    synchronousFrame = null;
    if (frame != null) {
      listener.onImage(frame, true);
    }
  }

  @override
  void removeListener(ImageStreamListener listener) {
    listeners.remove(listener);
  }

  void emit(ui.Image image) {
    final info = ImageInfo(image: image);
    try {
      for (final listener in listeners.toList()) {
        listener.onImage(info.clone(), false);
      }
    } finally {
      info.dispose();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('evicts the least recently used inactive image and disposes its handle',
      () async {
    final sources = <String, _Source>{};
    final cache = EmojiImageCache(
      maximumSize: 2,
      resolveImage: (url) => sources.putIfAbsent(url, _Source.new).stream,
    );
    addTearDown(cache.dispose);
    cache.retainUrls(['a']);
    sources['a']!.emit(await _image());
    final a = cache.images['a']!;
    cache.retainUrls(['b']);
    sources['b']!.emit(await _image());
    final b = cache.images['b']!;
    cache.retainUrls(['a']);
    cache.retainUrls(['c']);
    sources['c']!.emit(await _image());
    expect(cache.images.keys, unorderedEquals(['a', 'c']));
    expect(a.debugDisposed, isFalse);
    expect(b.debugDisposed, isTrue);
    expect(cache.estimatedBytes, 128);
  });

  test('protects all active images above target and shrinks after they leave',
      () async {
    final sources = <String, _Source>{};
    final cache = EmojiImageCache(
      maximumSize: 1,
      maximumBytes: 64,
      resolveImage: (url) => sources.putIfAbsent(url, _Source.new).stream,
    );
    addTearDown(cache.dispose);
    cache.retainUrls(['a', 'b']);
    sources['a']!.emit(await _image());
    sources['b']!.emit(await _image());
    final a = cache.images['a']!;
    final b = cache.images['b']!;
    expect(cache.images.length, 2);
    expect(a.debugDisposed, isFalse);
    expect(b.debugDisposed, isFalse);
    cache.retainUrls(['a']);
    expect(cache.images.keys, ['a']);
    expect(b.debugDisposed, isTrue);
    expect(cache.estimatedBytes, 64);
  });

  test('decoded byte target evicts inactive images even below count target',
      () async {
    final sources = <String, _Source>{};
    final cache = EmojiImageCache(
      maximumSize: 100,
      maximumBytes: 64,
      resolveImage: (url) => sources.putIfAbsent(url, _Source.new).stream,
    );
    addTearDown(cache.dispose);
    cache.retainUrls(['a']);
    sources['a']!.emit(await _image());
    final a = cache.images['a']!;
    cache.retainUrls(['b']);
    sources['b']!.emit(await _image(8));
    final b = cache.images['b']!;
    expect(a.debugDisposed, isTrue);
    expect(cache.estimatedBytes, 256);
    cache.retainUrls([]);
    expect(b.debugDisposed, isTrue);
    expect(cache.images, isEmpty);
    expect(cache.estimatedBytes, 0);
  });

  test('deduplicates pending URLs and detaches obsolete image listeners', () {
    final sources = <String, _Source>{};
    var resolutions = 0;
    final cache = EmojiImageCache(resolveImage: (url) {
      resolutions++;
      return sources.putIfAbsent(url, _Source.new).stream;
    });
    addTearDown(cache.dispose);
    cache.retainUrls(['a', 'a']);
    cache.retainUrls(['a']);
    expect(resolutions, 1);
    expect(sources['a']!.listeners.length, 1);
    cache.retainUrls([]);
    expect(sources['a']!.listeners, isEmpty);
  });

  test('synchronous first frame is cloned and its callback handle is disposed',
      () async {
    final first = await _image();
    final source = _Source(synchronousFrame: ImageInfo(image: first));
    var changes = 0;
    final cache = EmojiImageCache(
      resolveImage: (_) => source.stream,
      onChanged: () => changes++,
    );
    cache.retainUrls(['a']);
    final cached = cache.images['a']!;
    expect(first.debugDisposed, isTrue);
    expect(cached.debugDisposed, isFalse);
    expect(source.listeners, isEmpty);
    expect(changes, 1);
    cache.dispose();
    cache.dispose();
    expect(cached.debugDisposed, isTrue);
    expect(cache.images, isEmpty);
  });

  test('late delivery after disposal is released without a change callback',
      () async {
    final source = _Source();
    var changes = 0;
    final cache = EmojiImageCache(
      resolveImage: (_) => source.stream,
      onChanged: () => changes++,
    );
    cache.retainUrls(['a']);
    final lateListener = source.lastListener!;
    cache.dispose();
    final lateImage = await _image();
    lateListener.onImage(ImageInfo(image: lateImage), false);
    expect(lateImage.debugDisposed, isTrue);
    expect(source.listeners, isEmpty);
    expect(cache.images, isEmpty);
    expect(changes, 0);
  });

  test('failed requests detach and can be retried', () async {
    final source = _Source();
    var resolutions = 0;
    final cache = EmojiImageCache(resolveImage: (_) {
      resolutions++;
      return source.stream;
    });
    addTearDown(cache.dispose);
    cache.retainUrls(['a']);
    source.lastListener!.onError!(
        StateError('load failed'), StackTrace.current);
    expect(source.listeners, isEmpty);
    cache.retainUrls(['a']);
    source.emit(await _image());
    expect(resolutions, 2);
    expect(cache.images.keys, ['a']);
  });
}
