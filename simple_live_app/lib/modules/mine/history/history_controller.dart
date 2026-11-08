import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/services/db_service.dart';

class HistoryController extends BasePageController<History> {
  /// 平台筛选，all 表示全部
  var siteFilter = "all".obs;

  /// 各平台（含 all）的记录条数，用于胶囊上的数字
  var counts = <String, int>{}.obs;

  /// 最近一次从数据库读到的完整列表（筛选前），用来算条数
  List<History> _all = [];

  @override
  Future<List<History>> getData(int page, int pageSize) async {
    if (page > 1) {
      return [];
    }
    _all = DBService.instance.getHistores();
    _refreshCounts();
    return filterList();
  }

  List<History> filterList() {
    if (siteFilter.value == "all") {
      return _all;
    }
    return _all.where((e) => e.siteId == siteFilter.value).toList();
  }

  void _refreshCounts() {
    var result = <String, int>{"all": _all.length};
    for (var item in _all) {
      result[item.siteId] = (result[item.siteId] ?? 0) + 1;
    }
    counts.value = result;
  }

  void setSiteFilter(String siteId) {
    if (siteFilter.value == siteId) {
      return;
    }
    siteFilter.value = siteId;
    refreshData();
  }

  void clean() async {
    var result = await Utils.showAlertDialog("确定要清空观看记录吗?", title: "清空观看记录");
    if (!result) {
      return;
    }
    await DBService.instance.historyBox.clear();
    refreshData();
  }

  void removeItem(History item) async {
    await DBService.instance.historyBox.delete(item.id);
    refreshData();
  }
}
