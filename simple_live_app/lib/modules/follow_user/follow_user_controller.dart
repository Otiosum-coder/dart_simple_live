// ignore_for_file: invalid_use_of_protected_member

import 'dart:async';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
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

enum FollowFilterType { all, special, live, offline, tag }

/// 固定筛选与用户标签使用不同身份，不依赖显示名称区分。
class FollowFilterOption {
  final FollowFilterType type;
  final FollowUserTag? userTag;

  const FollowFilterOption(this.type, {this.userTag});

  String get key => type == FollowFilterType.tag
      ? 'tag:${userTag!.id}'
      : 'filter:${type.name}';

  String get label => switch (type) {
        FollowFilterType.all => '全部',
        FollowFilterType.special => '特别关注',
        FollowFilterType.live => '直播中',
        FollowFilterType.offline => '未开播',
        FollowFilterType.tag => userTag!.tag,
      };
}

class FollowUserController extends BasePageController<FollowUser> {
  StreamSubscription<dynamic>? onUpdatedIndexedStream;
  StreamSubscription<dynamic>? onUpdatedListStream;

  static const _fixedFilters = [
    FollowFilterOption(FollowFilterType.all),
    FollowFilterOption(FollowFilterType.special),
    FollowFilterOption(FollowFilterType.live),
    FollowFilterOption(FollowFilterType.offline),
  ];

  var filterMode = _fixedFilters.first.obs;
  RxList<FollowFilterOption> tagList = _fixedFilters.toList().obs;
  Worker? _followTagsWorker;

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
    _followTagsWorker = ever<List<FollowUserTag>>(
      FollowService.instance.followTagList,
      (_) => filterData(),
    );
    updateTagList();
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
    // 顺序跟设置里的「平台排序」一致；不在排序里的平台（以后新增的）排到最后
    var siteOrder = AppSettingsController.instance.siteSort;
    var keys = grouped.keys.toList()
      ..sort((a, b) {
        var ia = siteOrder.indexOf(a);
        var ib = siteOrder.indexOf(b);
        if (ia < 0) ia = siteOrder.length;
        if (ib < 0) ib = siteOrder.length;
        return ia.compareTo(ib);
      });
    for (var key in keys) {
      var entry = grouped[key]!;
      var site = Sites.allSites[key];
      list.add(FollowPlatformFilter(
        siteId: key,
        name: site?.name ?? key,
        logo: site?.logo ?? "",
        count: entry.length,
        liveCount: entry.where((e) => e.liveStatus.value == 2).length,
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
    final service = FollowService.instance;
    final filter = filterMode.value;
    final Iterable<FollowUser> src = switch (filter.type) {
      FollowFilterType.all => service.followList,
      FollowFilterType.special => service.followList.where((item) => item.isSpecial),
      FollowFilterType.live => service.liveList,
      FollowFilterType.offline => service.notLiveList,
      FollowFilterType.tag => service.followList
          .where((item) => filter.userTag!.userId.contains(item.id)),
    };
    var siteId = platformFilter.value;
    return siteId == null
        ? src.toList()
        : src.where((e) => e.siteId == siteId).toList();
  }

  void updateTagList() {
    updatePlatformList();
    userTagList.assignAll(FollowService.instance.followTagList);
    final selectedKey = filterMode.value.key;
    tagList.assignAll([
      ..._fixedFilters,
      for (final tag in userTagList)
        FollowFilterOption(FollowFilterType.tag, userTag: tag),
    ]);
    // 标签被删除或导入替换后回到全部；重命名时保留同一标签。
    filterMode.value = tagList.firstWhere(
      (option) => option.key == selectedKey,
      orElse: () => _fixedFilters.first,
    );
  }

  void filterData() {
    updateTagList();
    list.assignAll(filteredList());
    // 列表数据变了就同步空态标记。
    // 导入关注文件、取消关注、切标签/平台都会走到这里，
    // 但并不经过 BasePageController.loadData()，标记不复位就会叠出空态。
    pageEmpty.value = list.isEmpty;
  }

  void setFilterMode(FollowFilterOption tag) {
    filterMode.value = tag;
    filterData();
  }

  void updateItem(FollowUser item){
    FollowService.instance.addFollow(item);
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
    if (userTagList.any((item) => item.tag == newTagName)) {
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
  void updateTagOrder(int oldIndex, int newIndex) async {
    if (newIndex > oldIndex) newIndex -= 1; // 处理索引调整
    final item = userTagList.removeAt(oldIndex);
    userTagList.insert(newIndex, item);
    await DBService.instance.updateFollowTagOrder(userTagList.toList());
    FollowService.instance.getAllTagList();
  }

  @override
  void onClose() {
    onUpdatedIndexedStream?.cancel();
    onUpdatedListStream?.cancel();
    _followTagsWorker?.dispose();
    super.onClose();
  }
}
