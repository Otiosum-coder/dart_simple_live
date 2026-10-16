import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class FollowService extends GetxService {
  StreamSubscription<dynamic>? subscription;
  static FollowService get instance => Get.find<FollowService>();

  final StreamController _updatedListController = StreamController.broadcast();
  Stream get updatedListStream => _updatedListController.stream;

  /// 关注用户列表
  RxList<FollowUser> followList = RxList<FollowUser>();

  /// 直播中的用户列表
  RxList<FollowUser> liveList = RxList<FollowUser>();

  /// 未直播的用户列表
  RxList<FollowUser> notLiveList = RxList<FollowUser>();

  /// 用户自定义的tag
  RxList<FollowUserTag> followTagList = RxList<FollowUserTag>();

  /// 当前tag的用户列表
  RxList<FollowUser> curTagFollowList = RxList<FollowUser>();

  /// 已经更新状态的数量
  var updatedCount = 0;

  /// 是否正在更新
  var updating = false.obs;

  Timer? updateTimer;

  @override
  void onInit() {
    subscription = EventBus.instance.listen(Constant.kUpdateFollow, (p0) {
      loadData(updateStatus: false);
    });
    initTimer();
    super.onInit();
  }

  // 添加标签
  Future<void> addFollowUserTag(String tag) async {
    // 判断待添加tag是否已存在，存在则return
    if (followTagList.any((item) => item.tag == tag)) {
      SmartDialog.showToast("标签名重复，修改失败");
      return;
    }
    FollowUserTag item = await DBService.instance.addFollowTag(tag);
    followTagList.add(item);
  }

  // 删除标签
  Future<void> delFollowUserTag(FollowUserTag tag) async {
    followTagList.remove(tag);
    await DBService.instance.deleteFollowTag(tag.id);
  }

  // 获取用户自定义标签列表
  void getAllTagList() {
    var list = DBService.instance.getFollowTagList();
    followTagList.assignAll(list);
  }

  // 修改标签
  void updateFollowUserTag(FollowUserTag tag) {
    DBService.instance.updateFollowTag(tag);
    // 查找并修改
    var index = followTagList.indexWhere((oTag) => oTag.id == tag.id);
    followTagList[index] = tag;
  }

  // 根据标签筛选数据
  void filterDataByTag(FollowUserTag tag) {
    curTagFollowList.clear();
    // 用一个新的列表来存储需要删除的 userId
    List<String> toRemove = [];
    for (var id in tag.userId) {
      if (followList.any((x) => x.id == id)) {
        // 找到对应的 followUser 添加到 curTagFollowList
        curTagFollowList.add(followList.firstWhere((x) => x.id == id));
      } else {
        // 标记要删除的 id
        toRemove.add(id);
      }
    }
    // 双向确认用户取消关注后标签内是否还有该用户
    // 在遍历结束后统一移除不在 followList 中的 id
    tag.userId.removeWhere((id) => toRemove.contains(id));
    // 更新数据库
    if (toRemove.isNotEmpty) {
      DBService.instance.updateFollowTag(tag);
    }
    // 标签内排序
    curTagFollowList.sort(
      (a, b) => b.liveStatus.value.compareTo(a.liveStatus.value),
    );
  }

  // 添加关注
  Future<void> addFollow(FollowUser follow) async {
    await DBService.instance.addFollow(follow);
  }

  void initTimer() {
    if (AppSettingsController.instance.autoUpdateFollowEnable.value) {
      updateTimer?.cancel();
      updateTimer = Timer.periodic(
        Duration(
            minutes:
                AppSettingsController.instance.autoUpdateFollowDuration.value),
        (timer) {
          Log.logPrint("Update Follow Timer");
          loadData();
        },
      );
    } else {
      updateTimer?.cancel();
    }
  }

  Future<void> loadData({bool updateStatus = true}) async {
    var list = DBService.instance.getFollowList();
    getAllTagList();
    if (list.isEmpty) {
      updating.value = false;
      followList.assignAll(list);
      return;
    }
    followList.assignAll(list);
    if (updateStatus) {
      startUpdateStatus();
    }
  }

  /// 获取最优并发数
  /// 根据 CPU 核心数和用户设置自动计算
  int getOptimalConcurrency() {
    var userSetting = AppSettingsController.instance.updateFollowThreadCount.value;

    // 如果用户设置为 0，则自动根据 CPU 核心数计算
    if (userSetting == 0) {
      var cpuCount = Platform.numberOfProcessors;
      // 网络 I/O 密集型任务，并发数可以是 CPU 核心数的 2-3 倍
      var optimal = (cpuCount * 2.5).round();
      // 限制在合理范围内（最少 4，最多 20）
      return optimal.clamp(4, 20);
    }

    return userSetting;
  }

  /// 按平台交错排列，避免单一平台阻塞
  List<FollowUser> interleaveByPlatform(List<FollowUser> list) {
    // 按平台分组
    var grouped = <String, Queue<FollowUser>>{};
    for (var item in list) {
      grouped.putIfAbsent(item.siteId, () => Queue<FollowUser>()).add(item);
    }

    // 交错处理
    var result = <FollowUser>[];
    while (grouped.values.any((queue) => queue.isNotEmpty)) {
      for (var queue in grouped.values) {
        if (queue.isNotEmpty) {
          result.add(queue.removeFirst());
        }
      }
    }

    return result;
  }

  void startUpdateStatus() async {
    updatedCount = 0;
    updating.value = true;

    var concurrency = getOptimalConcurrency();

    Log.logPrint("开始更新关注状态，并发数: $concurrency，总数: ${followList.length}");

    // B站：登录后先用「关注列表」批量接口按需预取（目标驱动），
    // 这样未开播的房间也能拿到上次直播时间，且不用逐个房间查
    await prepareBiliFollowing();

    // 按平台交错排列，避免单一平台阻塞
    var interleavedList = interleaveByPlatform(followList);

    // 创建任务队列
    var taskQueue = Queue<FollowUser>.from(interleavedList);

    // 工作函数 - 持续从队列中取任务执行
    Future<void> worker(int workerId) async {
      while (taskQueue.isNotEmpty) {
        var item = taskQueue.removeFirst();
        await updateLiveStatus(item);
      }
    }

    // 启动固定数量的并发 worker
    var workers = <Future>[];
    for (var i = 0; i < concurrency; i++) {
      workers.add(worker(i));
    }

    await Future.wait(workers);

    // 刷新结束后再存一次：此时后台的深层补齐可能已经完成
    saveBiliFollowingCache();

    Log.logPrint("关注状态更新完成");
  }

  bool _biliCacheLoaded = false;

  /// B站关注列表批量预取（目标驱动 + 持久化 + 渐进补齐）
  Future<void> prepareBiliFollowing() async {
    try {
      // 确保站点已注入登录 Cookie（BiliBiliAccountService 是异步加载的，
      // 刷新可能早于它完成，这里主动同步一次）
      if (BiliBiliAccountService.instance.logined.value) {
        BiliBiliAccountService.instance.setSite();
      }
      var live = Sites.allSites[Constant.kBiliBili]?.liveSite;
      if (live is! BiliBiliSite || live.cookie.isEmpty) {
        Log.logPrint("B站未登录，跳过关注列表批量预取");
        return;
      }
      // 冷启动先恢复上次的缓存，界面立刻有数据
      if (!_biliCacheLoaded) {
        _biliCacheLoaded = true;
        var saved = LocalStorageService.instance
            .getValue(LocalStorageService.kBiliFollowingCache, "");
        if (saved.isNotEmpty) {
          live.importFollowingCacheJson(saved);
        }
      }
      var roomIds = followList
          .where((e) => e.siteId == Constant.kBiliBili)
          .map((e) => e.roomId)
          .toList();
      if (roomIds.isEmpty) {
        return;
      }
      await live.primeFollowingStatus(roomIds);
      saveBiliFollowingCache();
    } catch (e) {
      Log.logPrint(e);
    }
  }

  /// 持久化 B站关注列表缓存（冷启动即可显示上次直播时间）
  void saveBiliFollowingCache() {
    try {
      var live = Sites.allSites[Constant.kBiliBili]?.liveSite;
      if (live is! BiliBiliSite || live.cookie.isEmpty) {
        return;
      }
      LocalStorageService.instance.setValue(
        LocalStorageService.kBiliFollowingCache,
        live.exportFollowingCacheJson(),
      );
    } catch (e) {
      Log.logPrint(e);
    }
  }

  Future updateLiveStatus(FollowUser item) async {
    try {
      var site = Sites.allSites[item.siteId]!;
      // 一次拿全：是否直播 + 本场开播时间 / 上次直播时间
      var status = await site.liveSite.getRoomStatus(roomId: item.roomId);
      item.liveStatus.value = status.isLive ? 2 : 1;
      item.roomNotFound = status.roomNotFound;
      if (status.isLive) {
        item.liveStartTime = status.startTime;
        item.lastLiveTime = null;
      } else {
        item.liveStartTime = null;
        item.lastLiveTime = status.lastLiveTime;
      }
    } catch (e) {
      Log.logPrint(e);
      item.liveStatus.value = 0;
      item.liveStartTime = null;
      item.lastLiveTime = null;
      item.roomNotFound = false;
    } finally {
      updatedCount++;
      if (updatedCount >= followList.length) {
        filterData();
        updating.value = false;
      }
    }
  }

  /// 进入直播间后把最新状态同步回关注列表
  ///
  /// 关注列表可能还没刷新到（例如 B站 排名较后的主播没命中批量缓存），
  /// 但进房间时已经拿到了准确数据，这里同步过去避免「外面未开播、进去却有数据」。
  void syncRoomStatus({
    required String siteId,
    required String requestedRoomId,
    required LiveRoomDetail detail,
  }) {
    FollowUser? item;
    for (var e in followList) {
      if (e.siteId == siteId &&
          (e.roomId == detail.roomId || e.roomId == requestedRoomId)) {
        item = e;
        break;
      }
    }
    if (item == null) {
      return;
    }
    var status = detail.status ? 2 : 1;
    var startTime = detail.status ? detail.showTime : null;
    var lastLiveTime = detail.status ? null : detail.lastLiveTime;
    if (item.liveStatus.value == status &&
        item.liveStartTime == startTime &&
        item.lastLiveTime == lastLiveTime) {
      return;
    }
    item.liveStatus.value = status;
    item.liveStartTime = startTime;
    item.lastLiveTime = lastLiveTime;
    item.roomNotFound = detail.roomNotFound;
    Log.logPrint("已同步直播间状态到关注列表：$siteId/$requestedRoomId");
    filterData();
  }

  void filterData() {
    followList.sort((a, b) {
      var status = b.liveStatus.value.compareTo(a.liveStatus.value);
      if (status != 0) {
        return status;
      }
      // 同为未开播：最近播过的排前面（没有时间的排在最后）
      var ta = int.tryParse(a.lastLiveTime ?? "0") ?? 0;
      var tb = int.tryParse(b.lastLiveTime ?? "0") ?? 0;
      return tb.compareTo(ta);
    });
    liveList.assignAll(followList.where((x) => x.liveStatus.value == 2));
    notLiveList.assignAll(followList.where((x) => x.liveStatus.value == 1));
    _updatedListController.add(0);
  }

  void exportFile() async {
    if (followList.isEmpty) {
      SmartDialog.showToast("列表为空");
      return;
    }

    try {
      var status = await Utils.checkStorgePermission();
      if (!status) {
        SmartDialog.showToast("无权限");
        return;
      }

      var dir = "";
      if (Platform.isIOS) {
        dir = (await getApplicationDocumentsDirectory()).path;
      } else {
        dir = await FilePicker.platform.getDirectoryPath() ?? "";
      }

      if (dir.isEmpty) {
        return;
      }
      var jsonFile = File(
          '$dir/SimpleLive_${DateTime.now().millisecondsSinceEpoch ~/ 1000}.json');
      var jsonText = generateJson();
      await jsonFile.writeAsString(jsonText);
      SmartDialog.showToast("已导出关注列表");
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("导出失败：$e");
    }
  }

  void inputFile() async {
    try {
      var status = await Utils.checkStorgePermission();
      if (!status) {
        SmartDialog.showToast("无权限");
        return;
      }
      var file = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (file == null) {
        return;
      }
      var jsonFile = File(file.files.single.path!);
      await inputJson(await jsonFile.readAsString());
      SmartDialog.showToast("导入成功");
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("导入失败:$e");
    } finally {
      loadData();
    }
  }

  void exportText() {
    if (followList.isEmpty) {
      SmartDialog.showToast("列表为空");
      return;
    }
    var content = generateJson();
    Get.dialog(
      AlertDialog(
        title: const Text("导出为文本"),
        content: TextField(
          controller: TextEditingController(text: content),
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
          ),
          minLines: 5,
          maxLines: 8,
        ),
        actions: [
          TextButton(
            onPressed: () {
              Get.back();
            },
            child: const Text("关闭"),
          ),
          TextButton(
            onPressed: () {
              Utils.copyToClipboard(content);
              Get.back();
            },
            child: const Text("复制"),
          ),
        ],
      ),
    );
  }

  void inputText() async {
    final TextEditingController textController = TextEditingController();
    await Get.dialog(
      AlertDialog(
        title: const Text("从文本导入"),
        content: TextField(
          controller: textController,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: "请输入内容",
          ),
          minLines: 5,
          maxLines: 8,
        ),
        actions: [
          TextButton(
            onPressed: () {
              Get.back();
            },
            child: const Text("关闭"),
          ),
          TextButton(
            onPressed: () async {
              var content = await Utils.getClipboard();
              if (content != null) {
                textController.text = content;
              }
            },
            child: const Text("粘贴"),
          ),
          TextButton(
            onPressed: () async {
              if (textController.text.isEmpty) {
                SmartDialog.showToast("内容为空");
                return;
              }
              try {
                await inputJson(textController.text);
                SmartDialog.showToast("导入成功");
                Get.back();
                loadData();
              } catch (e) {
                SmartDialog.showToast("导入失败，请检查内容是否正确");
              }
            },
            child: const Text("导入"),
          ),
        ],
      ),
    );
  }

  String generateJson() {
    var data = followList
        .map(
          (item) => {
            "siteId": item.siteId,
            "id": item.id,
            "roomId": item.roomId,
            "userName": item.userName,
            "face": item.face,
            "addTime": item.addTime.toString(),
            "tag": item.tag
          },
        )
        .toList();
    return jsonEncode(data);
  }

  Future inputJson(String content) async {
    var data = jsonDecode(content);

    for (var item in data) {
      var follow = FollowUser.fromJson(item);
      // 导入关注列表同时导入标签列表 此方法可优化为所有导入逻辑
      if (follow.tag != "全部") {
        // logic: 尝试添加，存在则返回已存在的对象
        var tag = await DBService.instance.addFollowTag(follow.tag);
        // 更新tag
        tag.userId.addIf(!tag.userId.contains(follow.id), follow.id);
        await DBService.instance.updateFollowTag(tag);
      }
      await DBService.instance.addFollow(follow);
    }
  }

  @override
  void onClose() {
    updateTimer?.cancel();
    subscription?.cancel();
    super.onClose();
  }
}
