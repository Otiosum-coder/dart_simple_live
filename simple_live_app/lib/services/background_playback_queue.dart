/// 后台媒体控件「上一台 / 下一台」的纯索引计算。
///
/// 真正的候选列表由 [LiveRoomController] 从关注列表的 liveList 构建，
/// 这里只负责边界处理，方便单元测试覆盖。
class BackgroundPlaybackQueue {
  BackgroundPlaybackQueue._();

  /// 返回从 [currentIndex] 前进 [step]（-1 上一台 / 1 下一台）后的索引。
  ///
  /// - [length] <= 0 时没有可切换目标，返回 null；
  /// - [length] == 1 且就是当前房间时，返回 null（不重复切到同一个）；
  /// - [currentIndex] 不在列表里（-1）时，上一台取最后一个，下一台取第一个；
  /// - 到头后循环。
  static int? nextIndex({
    required int length,
    required int currentIndex,
    required int step,
  }) {
    if (length <= 0 || (step != -1 && step != 1)) {
      return null;
    }
    if (currentIndex < 0) {
      return step > 0 ? 0 : length - 1;
    }
    final index = (currentIndex + step + length) % length;
    return index == currentIndex ? null : index;
  }
}
