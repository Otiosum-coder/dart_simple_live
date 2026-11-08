import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '/models/danmaku_content_item.dart';

/// 系统 emoji 相对字号的倍数（emoji 字形约 1.1 倍字号，乘 0.9 与汉字齐平）
const double _kEmojiFontScale = 0.9;

class _EmojiRun {
  final String text;
  final bool isEmoji;
  const _EmojiRun(this.text, this.isEmoji);
}

/// 常见 emoji 码点判断（Dart 的 \p{Extended_Pictographic} 支持不稳定，用区间）
bool _isEmojiCodePoint(int code) {
  if (code == 0xFE0F || code == 0xFE0E || code == 0x200D) {
    return true;
  }
  if (code >= 0x1F000 && code <= 0x1FAFF) {
    return true;
  }
  if (code >= 0x2600 && code <= 0x27BF) {
    return true;
  }
  if (code >= 0x2B00 && code <= 0x2BFF) {
    return true;
  }
  if (code >= 0x2190 && code <= 0x21FF) {
    return true;
  }
  if (code >= 0x2900 && code <= 0x297F) {
    return true;
  }
  if (code >= 0x2300 && code <= 0x23FF) {
    return true;
  }
  if (code >= 0x25A0 && code <= 0x25FF) {
    return true;
  }
  const singles = {
    0x203C, 0x2049, 0x2122, 0x2139, 0x24C2, 0x3030, 0x303D, 0x3297, 0x3299,
    0x00A9, 0x00AE, 0x2934, 0x2935,
  };
  return singles.contains(code);
}

/// 把一段文字按「emoji / 普通文字」切成若干段
List<_EmojiRun> _splitEmojiRuns(String text) {
  final runs = <_EmojiRun>[];
  if (text.isEmpty) {
    return runs;
  }
  final buffer = StringBuffer();
  bool? bufferIsEmoji;
  void flush() {
    if (buffer.isEmpty) {
      return;
    }
    runs.add(_EmojiRun(buffer.toString(), bufferIsEmoji == true));
    buffer.clear();
  }

  for (final rune in text.runes) {
    final isEmoji = _isEmojiCodePoint(rune);
    if (bufferIsEmoji != null && bufferIsEmoji != isEmoji) {
      flush();
    }
    bufferIsEmoji = isEmoji;
    buffer.writeCharCode(rune);
  }
  flush();
  return runs;
}

class Utils {
  static final RegExp _emojiTokenPattern = RegExp(r'\[[^\[\]]{1,16}\]');

  static String normalizeImageUrl(String url) {
    final value = url.trim();
    if (value.startsWith("asset://")) {
      return value;
    }
    if (value.startsWith("//")) {
      return "https:$value";
    }
    return value;
  }

  static Size measureContent(
    DanmakuContentItem content,
    double fontSize,
    int fontWeight, [
    double emojiScale = 1.25,
    String? fontFamily,
  ]) {
    final parts = contentParts(content);
    final text = parts
        .where((part) => part.isText)
        .map((part) => part.text ?? "")
        .join();
    final textPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.values[fontWeight],
          fontFamily: fontFamily,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final imageSize = fontSize * emojiScale;
    var imageTotalWidth = 0.0;
    var imageMaxSize = 0.0;
    for (final part in parts) {
      if (part.isImage && (part.imageUrl ?? "").trim().isNotEmpty) {
        final size = imageSize * part.scale;
        // 表情宽度按素材真实宽高比算，宽扁的表情（如 2333）才不会被压窄
        imageTotalWidth += size * part.ratio;
        if (size > imageMaxSize) {
          imageMaxSize = size;
        }
      }
    }
    return Size(
      textPainter.width + imageTotalWidth,
      textPainter.height > imageMaxSize ? textPainter.height : imageMaxSize,
    );
  }

  static ui.Paragraph generateParagraph(
    DanmakuContentItem content,
    double danmakuWidth,
    double fontSize,
    int fontWeight, [
    double emojiScale = 1.25,
    String? fontFamily,
  ]) {
    final builder = ui.ParagraphBuilder(
      ui.ParagraphStyle(
        textAlign: TextAlign.left,
        fontSize: fontSize,
        fontWeight: FontWeight.values[fontWeight],
        fontFamily: fontFamily,
        textDirection: TextDirection.ltr,
      ),
    )..pushStyle(ui.TextStyle(color: content.color, fontFamily: fontFamily));
    _appendContent(builder, content, fontSize, emojiScale);
    return builder.build()
      ..layout(ui.ParagraphConstraints(width: danmakuWidth));
  }

  static ui.Paragraph generateStrokeParagraph(
    DanmakuContentItem content,
    double danmakuWidth,
    double fontSize,
    int fontWeight, [
    double emojiScale = 1.25,
    String? fontFamily,
  ]) {
    final Paint strokePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.black;

    final ui.ParagraphBuilder strokeBuilder = ui.ParagraphBuilder(
      ui.ParagraphStyle(
        textAlign: TextAlign.left,
        fontSize: fontSize,
        fontWeight: FontWeight.values[fontWeight],
        fontFamily: fontFamily,
        textDirection: TextDirection.ltr,
      ),
    )..pushStyle(ui.TextStyle(foreground: strokePaint, fontFamily: fontFamily));
    _appendContent(strokeBuilder, content, fontSize, emojiScale);

    return strokeBuilder.build()
      ..layout(ui.ParagraphConstraints(width: danmakuWidth));
  }

  static void drawEmojiImages(
    Canvas canvas,
    ui.Paragraph paragraph,
    DanmakuContentItem content,
    Offset offset,
    Map<String, ui.Image> imageCache,
  ) {
    final imageUrls = imageUrlsForContent(content);
    if (imageUrls.isEmpty) {
      return;
    }
    final boxes = paragraph.getBoxesForPlaceholders();
    final paint = Paint()..filterQuality = FilterQuality.medium;
    for (var i = 0; i < imageUrls.length && i < boxes.length; i++) {
      final image = imageCache[imageUrls[i]];
      if (image == null) {
        continue;
      }
      final box = boxes[i];
      final dst = Rect.fromLTRB(
        offset.dx + box.left,
        offset.dy + box.top,
        offset.dx + box.right,
        offset.dy + box.bottom,
      );
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        dst,
        paint,
      );
    }
  }

  static List<DanmakuContentPart> contentParts(DanmakuContentItem content) {
    final parts = content.parts ?? const <DanmakuContentPart>[];
    if (parts.isNotEmpty) {
      return parts;
    }
    final imageUrls = (content.imageUrls ?? const <String>[])
        .where((url) => url.trim().isNotEmpty)
        .toList();
    if (imageUrls.isEmpty) {
      return [
        if (content.text.isNotEmpty) DanmakuContentPart.text(content.text),
      ];
    }

    final result = <DanmakuContentPart>[];
    var start = 0;
    var imageIndex = 0;
    for (final match in _emojiTokenPattern.allMatches(content.text)) {
      if (imageIndex >= imageUrls.length) {
        break;
      }
      if (match.start > start) {
        result.add(
          DanmakuContentPart.text(content.text.substring(start, match.start)),
        );
      }
      result.add(DanmakuContentPart.image(imageUrls[imageIndex]));
      imageIndex += 1;
      start = match.end;
    }
    if (start < content.text.length) {
      result.add(DanmakuContentPart.text(content.text.substring(start)));
    }
    for (; imageIndex < imageUrls.length; imageIndex += 1) {
      result.add(DanmakuContentPart.image(imageUrls[imageIndex]));
    }
    return result;
  }

  static List<String> imageUrlsForContent(DanmakuContentItem content) {
    return contentParts(content)
        .where((part) => part.isImage)
        .map((part) => normalizeImageUrl(part.imageUrl ?? ""))
        .where((url) => url.isNotEmpty)
        .toList();
  }

  static void _appendContent(
    ui.ParagraphBuilder builder,
    DanmakuContentItem content,
    double fontSize,
    double emojiScale,
  ) {
    final imageSize = fontSize * emojiScale;
    for (final part in contentParts(content)) {
      if (part.isText) {
        // 文字里混的系统 emoji 单独降一档字号（它不是图片，走字体渲染）
        for (final run in _splitEmojiRuns(part.text ?? "")) {
          if (run.isEmoji) {
            builder.pushStyle(ui.TextStyle(fontSize: fontSize * _kEmojiFontScale));
            builder.addText(run.text);
            builder.pop();
          } else {
            builder.addText(run.text);
          }
        }
      } else if (part.isImage && (part.imageUrl ?? "").trim().isNotEmpty) {
        final size = imageSize * part.scale;
        builder.addPlaceholder(
          size * part.ratio,
          size,
          ui.PlaceholderAlignment.middle,
        );
      }
    }
  }
}
