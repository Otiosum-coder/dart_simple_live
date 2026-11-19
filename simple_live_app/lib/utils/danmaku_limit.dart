import 'package:characters/characters.dart';
import 'package:simple_live_app/app/constant.dart';

/// 各平台弹幕字数上限（按「字符」计，emoji / 表情算 1 个）
///
/// 实测来源（2026-11，官方网页端输入框属性）：
/// - 哔哩哔哩：20（官网输入框 0/20）
/// - 斗鱼：50（www.douyu.com 输入框 maxlength=50）
/// - 虎牙：30（www.huya.com 全屏弹幕输入框 maxlength=30）
/// - 抖音：50（与官方客户端一致）
int danmakuMaxLength(String siteId) {
  switch (siteId) {
    case Constant.kBiliBili:
      return 20;
    case Constant.kDouyu:
      return 50;
    case Constant.kHuya:
      return 30;
    case Constant.kDouyin:
      return 50;
    default:
      return 50;
  }
}

/// 按平台上限截断，保证不会切坏 emoji / 组合字符
String truncateDanmaku(String text, int maxLength) {
  final chars = text.characters;
  if (chars.length <= maxLength) {
    return text;
  }
  return chars.take(maxLength).toString();
}
