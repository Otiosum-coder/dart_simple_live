import 'dart:ui' as ui;
import 'package:flutter/painting.dart' show TextPainter;
import '/models/danmaku_content_item.dart';

class DanmakuItem {
  /// 弹幕内容
  final DanmakuContentItem content;

  /// 弹幕创建时间
  final int creationTime;

  /// 弹幕宽度
  final double width;

  /// 弹幕高度
  final double height;

  /// 弹幕水平方向位置
  double xPosition;

  /// 弹幕竖直方向位置
  double yPosition;

  /// 上次绘制时间
  int? lastDrawTick;

  /// 弹幕布局缓存
  ui.Paragraph? paragraph;
  ui.Paragraph? strokeParagraph;

  /// Layout belongs to this active occurrence, never to reusable content.
  TextPainter? painterCache;

  void clearParagraphs() {
    paragraph?.dispose();
    strokeParagraph?.dispose();
    paragraph = null;
    strokeParagraph = null;
  }

  void dispose() {
    clearParagraphs();
    painterCache?.dispose();
    painterCache = null;
  }

  DanmakuItem({
    required this.content,
    required this.creationTime,
    required this.height,
    required this.width,
    this.xPosition = 0,
    this.yPosition = 0,
    this.paragraph,
    this.strokeParagraph,
    this.painterCache,
    this.lastDrawTick,
  });
}
