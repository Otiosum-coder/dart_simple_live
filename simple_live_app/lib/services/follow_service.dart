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
import 'package:simple_live_app/models/live_start_tracker.dart';
import 'package:simple_live_app/services/live_notification_service.dart';
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
  Timer? _reminderTimer;
  final _reminderTracker = LiveStartTracker();
  final Map<String, Future<void>> _statusQueries = {};
  final Map<String, int> _statusRevisions = {};
  final Map<String, DateTime> _lastStatusChecks = {};
  Future<void>? _refreshFuture;
  bool _checkingReminders = false;
  int _reminderGeneration = 0;

  @override
  void onInit() {
    subscription = EventBus.instance.listen(Constant.kUpdateFollow, (p0) {
      loadData(updateStatus: false);
    });
    initTimer();
    unawaited(loadData(updateStatus: false));
    initReminderTimer();
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
    curTagFollowList
        .sort((a, b) => followList.indexOf(a).compareTo(followList.indexOf(b)));
  }

  FollowUser? getFollowUser(String id) {
    for (final item in followList) {
      if (item.id == id) return item;
    }
    return null;
  }

  Future<void> addFollow(FollowUser follow) async {
    final old = getFollowUser(follow.id);
    await DBService.instance.addFollow(follow);
    final index = followList.indexWhere((item) => item.id == follow.id);
    if (index < 0) {
      followList.add(follow);
    } else {
      followList[index] = follow;
    }
    if (old?.isSpecial != follow.isSpecial) _reminderTracker.forget(follow.id);
    filterData();
    if (follow.isSpecial && old == null) unawaited(updateLiveStatus(follow));
  }

  Future<void> setSpecialFollow(FollowUser follow, bool value) async {
    final current = getFollowUser(follow.id);
    if (current == null || current.isSpecial == value) return;
    final old = current.isSpecial;
    current.isSpecial = value;
    try {
      await DBService.instance.addFollow(current);
    } catch (_) {
      current.isSpecial = old;
      rethrow;
    }
    _reminderTracker.forget(current.id);
    filterData();
    // 刚设为特别关注时重新建基线，已在播的主播不会突然补发通知。
    if (value) unawaited(updateLiveStatus(current));
  }

  Future<void> removeFollow(FollowUser follow) async {
    await DBService.instance.deleteFollow(follow.id);
    _reminderTracker.forget(follow.id);
    _lastStatusChecks.remove(follow.id);
    followList.removeWhere((item) => item.id == follow.id);
    for (final tag in DBService.instance.getFollowTagList()) {
      if (tag.userId.contains(follow.id)) {
        tag.userId.removeWhere((id) => id == follow.id);
        await DBService.instance.updateFollowTag(tag);
      }
    }
    getAllTagList();
    filterData();
  }

  Future<void> setFollowTags(FollowUser follow, List<String> tagIds) async {
    final current = getFollowUser(follow.id);
    if (current == null) return;
    final selected = tagIds.toSet();
    final tags = DBService.instance.getFollowTagList();
    for (final tag in tags) {
      final contains = tag.userId.contains(current.id);
      if (selected.contains(tag.id) == contains) continue;
      tag.userId.removeWhere((id) => id == current.id);
      if (selected.contains(tag.id)) tag.userId.add(current.id);
      await DBService.instance.updateFollowTag(tag);
    }
    current.tag = tags
            .where((tag) => selected.contains(tag.id))
            .map((tag) => tag.tag)
            .firstOrNull ??
        '全部';
    await DBService.instance.addFollow(current);
    getAllTagList();
    filterData();
  }

  void initReminderTimer({bool resetBaseline = false}) {
    _reminderTimer?.cancel();
    if (resetBaseline) {
      _reminderGeneration++;
      _reminderTracker.clear();
      _lastStatusChecks.clear();
    }
    if (!AppSettingsController.instance.specialFollowNotifyEnable.value) return;
    _reminderTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      unawaited(checkSpecialFollows());
    });
    unawaited(checkSpecialFollows());
  }

  Future<void> checkSpecialFollows() async {
    if (_checkingReminders ||
        !AppSettingsController.instance.specialFollowNotifyEnable.value) {
      return;
    }
    _checkingReminders = true;
    try {
      final queue =
          Queue<FollowUser>.from(followList.where((item) => item.isSpecial));
      Future<void> worker() async {
        while (queue.isNotEmpty &&
            !isClosed &&
            AppSettingsController.instance.specialFollowNotifyEnable.value) {
          final item = queue.removeFirst();
          final last = _lastStatusChecks[item.id];
          if (last != null &&
              DateTime.now().difference(last) < const Duration(seconds: 45)) {
            continue;
          }
          await updateLiveStatus(item);
        }
      }

      await Future.wait(List.generate(4, (_) => worker()));
    } finally {
      _checkingReminders = false;
      if (!isClosed) filterData();
    }
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
    final old = {for (final item in followList) item.id: item};
    for (final item in list) {
      final previous = old[item.id];
      if (previous != null && !identical(previous, item)) {
        item.liveStatus.value = previous.liveStatus.value;
        item.liveStartTime = previous.liveStartTime;
        item.lastLiveTime = previous.lastLiveTime;
        item.roomNotFound = previous.roomNotFound;
      }
      if (previous?.isSpecial != item.isSpecial) {
        _reminderTracker.forget(item.id);
      }
    }
    final ids = list.map((item) => item.id).toSet();
    _lastStatusChecks.removeWhere((id, _) => !ids.contains(id));
    followList.assignAll(list);
    _reminderTracker.retain(
        list.where((item) => item.isSpecial).map((item) => item.id).toSet());
    filterData();
    if (updateStatus && list.isNotEmpty) await startUpdateStatus();
  }

  /// 获取最优并发数
  /// 根据 CPU 核心数和用户设置自动计算
  int getOptimalConcurrency() {
    var userSetting =
        AppSettingsController.instance.updateFollowThreadCount.value;

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

  Future<void> startUpdateStatus() {
    return _refreshFuture ??= _refreshAllStatuses().whenComplete(() {
      _refreshFuture = null;
    });
  }

  Future<void> _refreshAllStatuses() async {
    updatedCount = 0;
    updating.value = true;
    try {
      await prepareBiliFollowing();
      final queue =
          Queue<FollowUser>.from(interleaveByPlatform(followList.toList()));
      Future<void> worker() async {
        while (queue.isNotEmpty && !isClosed) {
          await updateLiveStatus(queue.removeFirst());
          updatedCount++;
        }
      }

      await Future.wait(
          List.generate(getOptimalConcurrency().clamp(1, 20), (_) => worker()));
      if (!isClosed) saveBiliFollowingCache();
    } finally {
      if (!isClosed) {
        updating.value = false;
        filterData();
      }
    }
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

  Future<void> updateLiveStatus(FollowUser item) {
    return _statusQueries[item.id] ??= _queryLiveStatus(item).whenComplete(() {
      _statusQueries.remove(item.id);
      _statusRevisions.remove(item.id);
    });
  }

  Future<void> _queryLiveStatus(FollowUser item) async {
    final revision = _statusRevisions[item.id] ?? 0;
    try {
      final site = Sites.allSites[item.siteId];
      if (site == null || !identical(getFollowUser(item.id), item)) return;
      final status = await site.liveSite
          .getRoomStatus(roomId: item.roomId)
          .timeout(const Duration(seconds: 25));
      if (isClosed ||
          !identical(getFollowUser(item.id), item) ||
          revision != (_statusRevisions[item.id] ?? 0) ||
          !status.querySucceeded) {
        return;
      }
      _applyLiveStatus(item, status);
    } catch (e) {
      // 保留上次可信状态：查询失败并不代表下播。
      Log.logPrint('关注状态查询失败 ${item.id}: $e');
    } finally {
      if (!isClosed && _refreshFuture == null && !_checkingReminders) {
        filterData();
      }
    }
  }

  bool _applyLiveStatus(FollowUser item, LiveRoomStatus status) {
    _lastStatusChecks[item.id] = DateTime.now();
    final newStatus = status.isLive ? 2 : 1;
    final changed = item.liveStatus.value != newStatus ||
        item.roomNotFound != status.roomNotFound ||
        item.liveStartTime != status.startTime ||
        item.lastLiveTime != status.lastLiveTime;
    item.roomNotFound = status.roomNotFound;
    item.liveStartTime = status.startTime;
    item.lastLiveTime = status.lastLiveTime;
    item.liveStatus.value = newStatus;

    final settings = AppSettingsController.instance;
    if (settings.specialFollowNotifyEnable.value &&
        item.isSpecial &&
        _reminderTracker.observe(item.id,
            isLive: status.isLive,
            startTime: status.startTime,
            querySucceeded: status.querySucceeded,
            roomNotFound: status.roomNotFound)) {
      final generation = _reminderGeneration;
      unawaited(LiveNotificationService.instance.showLiveStarted(
        siteId: item.siteId,
        roomId: item.roomId,
        userName: item.userName,
        canShow: () =>
            !isClosed &&
            generation == _reminderGeneration &&
            settings.specialFollowNotifyEnable.value &&
            getFollowUser(item.id)?.isSpecial == true,
      ));
    }
    return changed;
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
    // 进房拿到的新状态比正在等待的轮询结果更及时。
    if (_statusQueries.containsKey(item.id)) {
      _statusRevisions.update(item.id, (revision) => revision + 1,
          ifAbsent: () => 1);
    }
    if (_applyLiveStatus(
        item,
        LiveRoomStatus(
          roomId: detail.roomId,
          isLive: detail.status && !detail.isRecord,
          startTime: detail.status && !detail.isRecord ? detail.showTime : null,
          lastLiveTime:
              detail.status && !detail.isRecord ? null : detail.lastLiveTime,
          roomNotFound: detail.roomNotFound,
        ))) {
      filterData();
    }
  }

  void filterData() {
    followList.sort((a, b) {
      var status = b.liveStatus.value.compareTo(a.liveStatus.value);
      if (status != 0) {
        return status;
      }
      if (a.isSpecial != b.isSpecial) return a.isSpecial ? -1 : 1;
      // 同为未开播：最近播过的排前面（没有时间的排在最后）
      var ta = int.tryParse(a.lastLiveTime ?? "0") ?? 0;
      var tb = int.tryParse(b.lastLiveTime ?? "0") ?? 0;
      final lastLive = tb.compareTo(ta);
      return lastLive != 0 ? lastLive : b.addTime.compareTo(a.addTime);
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

  String generateJson() =>
      jsonEncode(followList.map((item) => item.toJson()).toList());

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
    _reminderTimer?.cancel();
    subscription?.cancel();
    unawaited(_updatedListController.close());
    super.onClose();
  }
}
