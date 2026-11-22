import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';

class _ControlledPageController extends BasePageController<int> {
  final List<Completer<List<int>>> pending = [];

  @override
  Future<List<int>> getData(int page, int pageSize) {
    final completer = Completer<List<int>>();
    pending.add(completer);
    return completer.future;
  }
}

void main() {
  setUp(Get.reset);

  test('第一页结果在加载期间外部填充列表后仍然替换而不是追加', () async {
    final controller = _ControlledPageController();

    final loading = controller.loadData();
    // 模拟 FollowService 在 getData 等待期间通过 updatedListStream 填充了列表。
    controller.list.assignAll([1, 2]);

    controller.pending.single.complete([1, 2]);
    await loading;

    expect(controller.list.toList(), [1, 2]);
    expect(controller.currentPage, 2);
    expect(controller.pageEmpty.value, isFalse);
  });

  test('后续页仍然追加到已有列表', () async {
    final controller = _ControlledPageController();

    final first = controller.loadData();
    controller.pending.single.complete([1, 2]);
    await first;
    expect(controller.list.toList(), [1, 2]);

    final second = controller.loadData();
    controller.pending.last.complete([3]);
    await second;

    expect(controller.list.toList(), [1, 2, 3]);
    expect(controller.currentPage, 3);
  });
}
