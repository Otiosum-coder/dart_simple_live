// ignore_for_file: invalid_use_of_protected_member

import 'dart:async';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';

/// 关注列表的平台筛选项
class FollowPlatformFilter {
  /// null = 全部平台
  final String? siteId;
  final String name;
  final String logo;
  final int count;
  final int liveCount;

  const FollowPlatformFilter({
    required this.siteId,
    required this.name,
    required this.logo,
    required this.count,
    required this.liveCount,
  });

  bool get isAll => siteId == null;
}

class FollowUserController extends BasePageController<FollowUser> {
  StreamSubscription<dynamic>? onUpdatedIndexedStream;
  StreamSubscription<dynamic>? onUpdatedListStream;

  /// 0:全部 1:直播中 2:未直播
  var filterMode = FollowUserTag(id: "0", tag: "全部", userId: []).obs;
  RxList<FollowUserTag> tagList = [
    FollowUserTag(id: "0", tag: "全部", userId: []),
    FollowUserTag(id: "1", tag: "直播中", userId: []),
    FollowUserTag(id: "2", tag: "未开播", userId: []),
  ].obs;

  // 用户自定义标签
  RxList<FollowUserTag> userTagList = <FollowUserTag>[].obs;

  /// 平台筛选（null = 全部平台）
  var platformFilter = Rxn<String>();

  /// 平台筛选项（含数量与在播数）
  RxList<FollowPlatformFilter> platformList = <FollowPlatformFilter>[].obs;

  /// 只有一个平台时不显示平台筛选行，避免占地方
  bool get showPlatformRow => platformList.where((e) => !e.isAll).length > 1;

  @override
  void onInit() {
    onUpdatedIndexedStream = EventBus.instance.listen(
      EventBus.kBottomNavigationBarClicked,
          (index) {
        if (index == 1) {
          scrollToTopOrRefresh();
        }
      },
    );
    onUpdatedListStream =
        FollowService.instance.updatedListStream.listen((event) {
      filterData();
    });
    super.onInit();
  }

  @override
  Future refreshData() async {
    await FollowService.instance.loadData();
    updateTagList();
    super.refreshData();
  }

  @override
  Future<List<FollowUser>> getData(int page, int pageSize) async {
    if (page > 1) {
      return Future.value([]);
    }
    return filteredList();
  }

  /// 根据当前关注列表生成平台筛选项
  void updatePlatformList() {
    var all = FollowService.instance.followList;
    var grouped = <String, List<FollowUser>>{};
    for (var e in all) {
      grouped.putIfAbsent(e.siteId, () => []).add(e);
    }
    var list = <FollowPlatformFilter>[
      FollowPlatformFilter(
        siteId: null,
        name: "全部",
        logo: "",
        count: all.length,
        liveCount: all.where((e) => e.liveStatus.value == 2).length,
      )
    ];
    for (var entry in grouped.entries) {
      var site = Sites.allSites[entry.key];
      list.add(FollowPlatformFilter(
        siteId: entry.key,
        name: site?.name ?? entry.key,
        logo: site?.logo ?? "",
        count: entry.value.length,
        liveCount: entry.value.where((e) => e.liveStatus.value == 2).length,
      ));
    }
    platformList.assignAll(list);
    // 选中的平台已经不存在了（取消关注完），回到全部
    var cur = platformFilter.value;
    if (cur != null && !grouped.containsKey(cur)) {
      platformFilter.value = null;
    }
  }

  void setPlatformFilter(String? siteId) {
    platformFilter.value = siteId;
    filterData();
  }

  /// 当前筛选（状态/标签 + 平台）后的列表
  List<FollowUser> filteredList() {
    Iterable<FollowUser> src;
    var tag = filterMode.value.tag;
    if (tag == "全部") {
      src = FollowService.instance.followList;
    } else if (tag == "直播中") {
      src = FollowService.instance.liveList;
    } else if (tag == "未开播") {
      src = FollowService.instance.notLiveList;
    } else {
      FollowService.instance.filterDataByTag(filterMode.value);
      src = FollowService.instance.curTagFollowList;
    }
    var siteId = platformFilter.value;
    return siteId == null
        ? src.toList()
        : src.where((e) => e.siteId == siteId).toList();
  }

  void updateTagList() {
    updatePlatformList();
    userTagList.assignAll(FollowService.instance.followTagList);
    tagList.value = tagList.take(3).toList();
    for (var i in userTagList) {
      if (!tagList.contains(i)) {
        tagList.add(i);
      }
    }
  }

  void filterData() {
    updatePlatformList();
    list.assignAll(filteredList());
    // 列表数据变了就同步空态标记。
    // 导入关注文件、取消关注、切标签/平台都会走到这里，
    // 但并不经过 BasePageController.loadData()，标记不复位就会叠出空态。
    pageEmpty.value = list.isEmpty;
  }

  void setFilterMode(FollowUserTag tag) {
    filterMode.value = tag;
    filterData();
  }

  void removeItem(FollowUser item) async {
    var result =
    await Utils.showAlertDialog("确定要取消关注${item.userName}吗?", title: "取消关注");
    if (!result) {
      return;
    }
    // 取消关注：从所有自定义标签里移除该 id
    for (var tag in tagList) {
      if (tag.tag == "全部") {
        continue;
      }
      if (tag.userId.remove(item.id)) {
        updateTag(tag);
      }
    }
    await DBService.instance.followBox.delete(item.id);
    refreshData();
  }

  void updateItem(FollowUser item){
    FollowService.instance.addFollow(item);
  }
  /// 保存主播的标签（多选）
  ///
  /// [selected] 是标签名列表，空表示不属于任何自定义标签。
  /// 成员关系以各标签的 userId 为准；FollowUser.tag 只保留第一个标签，
  /// 用于兼容导出/导入和旧数据。
  void setItemTags(FollowUser item, List<String> selected) {
    for (var tag in tagList) {
      if (tag.tag == "全部") {
        continue;
      }
      var want = selected.contains(tag.tag);
      var had = tag.userId.contains(item.id);
      if (want && !had) {
        tag.userId.add(item.id);
      } else if (!want && had) {
        tag.userId.remove(item.id);
      }
      if (want != had) {
        updateTag(tag);
      }
    }
    item.tag = selected.isEmpty ? "全部" : selected.first;
    updateItem(item);
    filterData();
  }

  Future<void> removeTag(FollowUserTag tag) async {
    // 将tag下的所有follow设置为全部
    for(var i in tag.userId){
      var follow = DBService.instance.followBox.get(i);
      if(follow != null){
        follow.tag = "全部";
        updateItem(follow);
      }
    }
    await FollowService.instance.delFollowUserTag(tag);
    updateTagList();
    Log.i('删除tag${tag.tag}');
  }

  void addTag(String tag) async {
    FollowService.instance
        .addFollowUserTag(tag)
        .then((value) => updateTagList());
  }

  void updateTag(FollowUserTag followUserTag) {
    if(followUserTag.tag == '全部'){
      return;
    }
    FollowService.instance.updateFollowUserTag(followUserTag);
  }

  void updateTagName(FollowUserTag followUserTag, String newTagName) {
    // 未操作
    if (followUserTag.tag == newTagName) {
      return;
    }
    // 避免重名
    if (tagList.any((item) => item.tag == newTagName)) {
      SmartDialog.showToast("标签名重复，修改失败");
      return;
    }
    final FollowUserTag newTag = followUserTag.copyWith(tag: newTagName);
    updateTag(newTag);
    // update item's tag when update tagName
    for(var i in newTag.userId){
      var follow = DBService.instance.followBox.get(i);
      if(follow != null){
        follow.tag = newTagName;
        updateItem(follow);
      }
    }
    SmartDialog.showToast("标签名修改成功");
    updateTagList();
  }

  // 调整标签顺序
  void updateTagOrder(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex -= 1; // 处理索引调整
    final item = userTagList.removeAt(oldIndex);
    userTagList.insert(newIndex, item);
    tagList.value = tagList.take(3).toList();
    tagList.addAll(userTagList);
    DBService.instance.updateFollowTagOrder(userTagList);
  }

  @override
  void onClose() {
    onUpdatedIndexedStream?.cancel();
    super.onClose();
  }
}
