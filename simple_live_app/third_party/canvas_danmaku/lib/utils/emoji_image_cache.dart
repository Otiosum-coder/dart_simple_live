import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// Owns decoded emoji images; active images may exceed the soft cache targets.
class EmojiImageCache {
  EmojiImageCache({
    this.maximumSize = 128,
    this.maximumBytes = 16 * 1024 * 1024,
    this.onChanged,
    ImageStream Function(String)? resolveImage,
  }) : _resolveImage = resolveImage ?? _defaultResolve {
    if (maximumSize < 0 || maximumBytes < 0) {
      throw ArgumentError('Emoji cache targets must not be negative');
    }
  }

  final int maximumSize;
  final int maximumBytes;
  final VoidCallback? onChanged;
  final ImageStream Function(String) _resolveImage;
  final _images = <String, ui.Image>{};
  final _pending = <String, _PendingEmojiImage>{};
  Set<String> _activeUrls = {};
  bool _disposed = false;
  int _estimatedBytes = 0;

  late final Map<String, ui.Image> images = UnmodifiableMapView(_images);
  int get estimatedBytes => _estimatedBytes;

  static ImageStream _defaultResolve(String url) {
    if (url.startsWith('asset://')) {
      return AssetImage(url.substring('asset://'.length))
          .resolve(ImageConfiguration.empty);
    }
    return NetworkImage(url).resolve(ImageConfiguration.empty);
  }

  /// Retain every on-screen emoji and reuse recently used off-screen images.
  void retainUrls(Iterable<String> urls) {
    if (_disposed) {
      return;
    }
    _activeUrls = urls.where((url) => url.isNotEmpty).toSet();
    for (final request in _pending.values.toList()) {
      if (!_activeUrls.contains(request.url)) {
        _finish(request);
      }
    }
    for (final url in _activeUrls) {
      final image = _images.remove(url);
      if (image != null) {
        _images[url] = image;
      }
    }
    _trimInactive();
    for (final url in _activeUrls) {
      if (!_images.containsKey(url) && !_pending.containsKey(url)) {
        _load(url);
      }
    }
  }

  void _load(String url) {
    final ImageStream stream;
    try {
      stream = _resolveImage(url);
    } catch (_) {
      return;
    }
    final request = _PendingEmojiImage(url, stream);
    request.listener = ImageStreamListener(
      (info, _) {
        var added = false;
        try {
          if (!_disposed &&
              identical(_pending[url], request) &&
              _activeUrls.contains(url)) {
            // ImageInfo belongs to this callback; keep our own native handle.
            final image = info.image.clone();
            _images[url] = image;
            _estimatedBytes += image.width * image.height * 4;
            added = true;
          }
        } finally {
          info.dispose();
          _finish(request);
        }
        if (added) {
          _trimInactive();
          onChanged?.call();
        }
      },
      onError: (_, __) => _finish(request),
    );
    // Register before listening: cached ImageStreams can complete synchronously.
    _pending[url] = request;
    try {
      stream.addListener(request.listener);
    } catch (_) {
      _finish(request);
    }
  }

  void _finish(_PendingEmojiImage request) {
    if (request.finished) {
      return;
    }
    request.finished = true;
    if (identical(_pending[request.url], request)) {
      _pending.remove(request.url);
    }
    request.stream.removeListener(request.listener);
  }

  void _trimInactive() {
    while (_images.length > maximumSize || _estimatedBytes > maximumBytes) {
      String? oldest;
      for (final url in _images.keys) {
        if (!_activeUrls.contains(url)) {
          oldest = url;
          break;
        }
      }
      if (oldest == null) {
        return;
      }
      final image = _images.remove(oldest)!;
      _estimatedBytes -= image.width * image.height * 4;
      image.dispose();
    }
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    for (final request in _pending.values.toList()) {
      _finish(request);
    }
    for (final image in _images.values) {
      image.dispose();
    }
    _images.clear();
    _activeUrls.clear();
    _estimatedBytes = 0;
  }
}

class _PendingEmojiImage {
  _PendingEmojiImage(this.url, this.stream);

  final String url;
  final ImageStream stream;
  late final ImageStreamListener listener;
  bool finished = false;
}
