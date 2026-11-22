import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:uuid/uuid.dart';

class DBService extends GetxService {
  static DBService get instance => Get.find<DBService>();
  late Box<History> historyBox;
  late Box<FollowUser> followBox;
  late Box<FollowUserTag> tagBox;
  final Uuid uuid = const Uuid();

  Future init() async {
    historyBox = await Hive.openBox("History");
    followBox = await Hive.openBox("FollowUser");
    tagBox = await Hive.openBox("FollowUserTag");
  }

  // follow_user_tag 相关逻辑
  bool getFollowTagExist(String id) {
    return tagBox.values.any((tag) => tag.id == id);
  }

  // 删除标签
  Future deleteFollowTag(String id) async {
    final keys = tagBox.keys.where((key) => tagBox.get(key)?.id == id).toList();
    await tagBox.deleteAll(keys);
  }

  FollowUserTag? getFollowTag(String tag) {
    for (final item in getFollowTagList()) {
      if (item.tag == tag) return item;
    }
    return null;
  }

  // 判断标签名称是否重复
  bool getFollowTagExistByTag(String tag) {
    return tagBox.values.any((item) => item.tag == tag);
  }

  // 获取标签列表
  List<FollowUserTag> getFollowTagList() {
    // 兼容旧版按整数排序后又按 id 更新形成的重复记录。
    return {for (final tag in tagBox.values) tag.id: tag}.values.toList();
  }

  // 修改标签
  Future updateFollowTag(FollowUserTag followTag) async {
    final keys = tagBox.keys
        .where((key) => tagBox.get(key)?.id == followTag.id)
        .toList();
    await tagBox.put(keys.isEmpty ? followTag.id : keys.first, followTag);
    if (keys.length > 1) await tagBox.deleteAll(keys.skip(1));
  }

  // 添加标签
  Future<FollowUserTag> addFollowTag(String tag) async {
    // 导入和菜单共用同一标签，避免同名标签形成多份成员关系。
    if (getFollowTagExistByTag(tag)) {
      return getFollowTag(tag)!;
    }
    final String uniqueId = uuid.v4();
    final followUserTag = FollowUserTag(id: uniqueId, tag: tag, userId: []);
    await tagBox.put(uniqueId, followUserTag);
    return followUserTag;
  }

  // 调整标签顺序
  Future updateFollowTagOrder(List<FollowUserTag> userTagList) async {
    final tags = {for (final tag in userTagList) tag.id: tag}.values.toList();
    // Hive 按 key 排列；整数索引保留用户拖动后的顺序。
    final updatedMap = {for (var i = 0; i < tags.length; i++) i: tags[i]};
    await tagBox.clear();
    await tagBox.putAll(updatedMap);
  }

  bool getFollowExist(String id) {
    return followBox.containsKey(id);
  }

  List<FollowUser> getFollowList() {
    return followBox.values.toList();
  }

  Future addFollow(FollowUser follow) async {
    await followBox.put(follow.id, follow);
  }

  Future deleteFollow(String id) async {
    await followBox.delete(id);
  }

  History? getHistory(String id) {
    if (historyBox.containsKey(id)) {
      return historyBox.get(id);
    }
    return null;
  }

  Future addOrUpdateHistory(History history) async {
    await historyBox.put(history.id, history);
  }

  List<History> getHistores() {
    var his = historyBox.values.toList();
    his.sort((a, b) => b.updateTime.compareTo(a.updateTime));
    return his;
  }
}
