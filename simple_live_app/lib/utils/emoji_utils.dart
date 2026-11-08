/// 系统 emoji（不是图片表情）的识别与排版约定。
///
/// 弹幕里的「表情」有两种完全不同的东西：
/// 1. 平台图片表情（B站 2333、[doge]、抖音表情包）—— 有图片 URL，走 [WidgetSpan] / 占位符绘制；
/// 2. 系统 emoji（😱 🐶 这类）—— Unicode 字符，没有 URL，由字体渲染。
///
/// 后者字形会占满 em 框甚至外扩，跟汉字并排时视觉偏大，
/// 所以单独降一档字号：[kEmojiFontScale]。
library;

/// 系统 emoji 相对字号的倍数。
///
/// 大多数 emoji 字体（Segoe UI Emoji、ColorOS 字体）的字形视觉尺寸约为
/// 字号的 1.1 倍，乘 0.9 后与汉字基本齐平。
const double kEmojiFontScale = 0.9;

/// 判断一个码点是不是 emoji（覆盖常见 emoji 区段）
///
/// Dart 的 RegExp 对 \p{Extended_Pictographic} 支持不稳定，这里用码点区间判断。
bool isEmojiCodePoint(int code) {
  // U+FE0F 变体选择符、U+200D 零宽连接符：必须留在 emoji 片段里
  if (code == 0xFE0F || code == 0xFE0E || code == 0x200D) {
    return true;
  }
  // 键帽：# * 0-9 本身不是 emoji，不做处理，交给普通文字
  if (code >= 0x1F000 && code <= 0x1FAFF) {
    return true; // 表情、旗帜、肤色、符号（含 1F1E6-1F1FF 区域旗帜）
  }
  if (code >= 0x2600 && code <= 0x27BF) {
    return true; // 杂项符号 + 装饰符号（☀✅✈❤ …）
  }
  if (code >= 0x2B00 && code <= 0x2BFF) {
    return true; // ⬛⭐ 等
  }
  if (code >= 0x2190 && code <= 0x21FF) {
    return true; // 箭头（↔️↩️ 等）
  }
  if (code >= 0x2900 && code <= 0x297F) {
    return true; // 补充箭头
  }
  if (code >= 0x2300 && code <= 0x23FF) {
    return true; // ⌚⏰⏳ 等
  }
  if (code >= 0x25A0 && code <= 0x25FF) {
    return true; // ▪️▶️ 等
  }
  const singles = {
    0x203C, 0x2049, 0x2122, 0x2139, 0x24C2, 0x3030, 0x303D, 0x3297, 0x3299,
    0x00A9, 0x00AE, 0x2934, 0x2935,
  };
  return singles.contains(code);
}
