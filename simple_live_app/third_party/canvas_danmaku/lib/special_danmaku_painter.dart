import 'dart:math';
import 'dart:ui' as ui;

import 'package:canvas_danmaku/models/danmaku_content_item.dart';
import 'package:canvas_danmaku/models/danmaku_item.dart';
import 'package:flutter/material.dart';

class SpecialDanmakuPainter extends CustomPainter {
  final double progress;
  final List<DanmakuItem> specialDanmakuItems;
  final double fontSize;
  final int fontWeight;
  final String? fontFamily;
  final bool running;
  final int tick;
  final int batchThreshold;

  SpecialDanmakuPainter(
    this.progress,
    this.specialDanmakuItems,
    this.fontSize,
    this.fontWeight,
    this.fontFamily,
    this.running,
    this.tick, {
    this.batchThreshold = 10, // 默认值为10，可以自行调整
  });

  @override
  void paint(Canvas canvas, Size size) {
    var pictureCanvas = canvas;
    var batch = specialDanmakuItems.length > batchThreshold;
    late ui.PictureRecorder pictureRecorder;
    if (batch) {
      pictureRecorder = ui.PictureRecorder();
      pictureCanvas = Canvas(pictureRecorder);
    }
    try {
      for (final item in specialDanmakuItems) {
        final elapsed = tick - item.creationTime;
        final content = item.content as SpecialDanmakuContentItem;
        if (elapsed >= 0 && elapsed < content.duration) {
          _paintSpecialDanmaku(pictureCanvas, item, size, elapsed);
        }
      }
      if (batch) {
        final picture = pictureRecorder.endRecording();
        try {
          canvas.drawPicture(picture);
        } finally {
          picture.dispose();
        }
      }
    } finally {
      if (batch && pictureRecorder.isRecording) {
        pictureRecorder.endRecording().dispose();
      }
    }
  }

  void _paintSpecialDanmaku(
    Canvas canvas,
    DanmakuItem activeItem,
    Size size,
    int elapsed,
  ) {
    final item = activeItem.content as SpecialDanmakuContentItem;
    final painter = activeItem.painterCache!;
    // 透明度动画
    late final alpha =
        item.alphaTween?.transform(elapsed / item.duration) ?? item.color.a;
    final color = item.alphaTween == null
        ? item.color
        : item.color.withValues(alpha: alpha);
    final style = TextStyle(
      color: color,
      fontSize: item.fontSize,
      fontWeight: FontWeight.values[fontWeight],
      fontFamily: fontFamily,
      shadows: item.hasStroke
          ? [
              Shadow(
                  color: Colors.black.withValues(alpha: alpha), blurRadius: 2)
            ]
          : null,
    );
    if (painter.text?.style != style) {
      painter.text = TextSpan(text: item.text, style: style);
      painter.layout();
    }

    // 路径动画 TODO

    // else 位移动画
    late double dx, dy;
    if (elapsed > item.translationStartDelay) {
      late double translateProgress = item.easingType.transform(
        min(
          1.0,
          (elapsed - item.translationStartDelay) / item.translationDuration,
        ),
      );

      double getOffset(Tween<double> tween) => tween is ConstantTween
          ? tween.begin!
          : tween.transform(translateProgress);

      dx = getOffset(item.translateXTween) * size.width;
      dy = getOffset(item.translateYTween) * size.height;
    } else {
      dx = item.translateXTween.begin! * size.width;
      dy = item.translateYTween.begin! * size.height;
    }

    if (item.matrix != null) {
      canvas.save();
      canvas.translate(dx, dy);
      canvas.transform(item.matrix!.storage);
      painter.paint(canvas, Offset.zero);
      canvas.restore();
    } else {
      painter.paint(canvas, Offset(dx, dy));
    }
  }

  @override
  bool shouldRepaint(covariant SpecialDanmakuPainter oldDelegate) {
    return true;
  }
}
