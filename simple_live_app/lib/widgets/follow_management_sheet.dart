import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/services/follow_service.dart';

enum _FollowManagementAction { follow, special, tags, remove }

/// 关注列表、直播间共用的关注管理入口。
class FollowManagementSheet {
  static Future<void> show(FollowUser item) async {
    final service = FollowService.instance;
    final action = await showModalBottomSheet<_FollowManagementAction>(
      context: Get.context!,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 600),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (context) => SafeArea(
        top: false,
        child: Obx(() {
          final current = service.getFollowUser(item.id);
          final special = current?.isSpecial ?? false;
          void select(_FollowManagementAction action) {
            Navigator.of(context).pop(action);
          }

          return SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ListTile(
                  title: Text(item.userName,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: IconButton(
                    tooltip: '关闭',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
                AppStyle.divider,
                if (current == null)
                  ListTile(
                    leading: const Icon(Icons.favorite_border),
                    title: const Text('关注'),
                    onTap: () => select(_FollowManagementAction.follow),
                  ),
                ListTile(
                  leading: Icon(special
                      ? Icons.star_outline_rounded
                      : Icons.star_rounded),
                  title: Text(special ? '取消特别关注' : '设为特别关注'),
                  subtitle: const Text('开播提醒可在「关注设置」中统一开启'),
                  onTap: () => select(_FollowManagementAction.special),
                ),
                if (current != null) ...[
                  ListTile(
                    leading: const Icon(Icons.sell_outlined),
                    title: const Text('设置标签'),
                    onTap: () => select(_FollowManagementAction.tags),
                  ),
                  ListTile(
                    leading: const Icon(Icons.heart_broken_outlined),
                    title: const Text('取消关注'),
                    onTap: () => select(_FollowManagementAction.remove),
                  ),
                ],
                AppStyle.vGap8,
              ],
            ),
          );
        }),
      ),
    );
    if (action == null) return;

    try {
      // 菜单打开期间关注状态也可能变化，操作时重新读取当前对象。
      final current = service.getFollowUser(item.id);
      switch (action) {
        case _FollowManagementAction.follow:
          if (current == null) {
            item.isSpecial = false;
            await service.addFollow(item);
          }
          break;
        case _FollowManagementAction.special:
          if (current == null) {
            item.isSpecial = true;
            await service.addFollow(item);
          } else {
            await service.setSpecialFollow(current, !current.isSpecial);
          }
          break;
        case _FollowManagementAction.tags:
          if (current != null) await showTagsDialog(current);
          break;
        case _FollowManagementAction.remove:
          if (current != null &&
              await Utils.showAlertDialog(
                '确定要取消关注${current.userName}吗？',
                title: '取消关注',
              )) {
            await service.removeFollow(current);
          }
          break;
      }
    } catch (error) {
      Log.logPrint('关注管理失败: $error');
      SmartDialog.showToast('操作失败，请重试');
    }
  }

  /// 保留原有多选标签面板，成员关系与提交值均使用标签 id。
  static Future<void> showTagsDialog(FollowUser item) async {
    final service = FollowService.instance;
    final tags = service.followTagList.where((tag) => tag.tag != '全部').toList();
    final selected = tags
        .where((tag) => tag.userId.contains(item.id))
        .map((tag) => tag.id)
        .toSet();
    // 兼容旧关注数据；有成员关系时以多选成员关系为准。
    if (selected.isEmpty && item.tag != '全部') {
      selected.addAll(
          tags.where((tag) => tag.tag == item.tag).map((tag) => tag.id));
    }

    final result = await Get.dialog<List<String>>(
      AlertDialog(
        contentPadding: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        scrollable: true,
        content: SizedBox(
          width: 300,
          child: StatefulBuilder(
            builder: (context, setDialogState) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('设置标签', style: TextStyle(fontSize: 18)),
                    IconButton(
                      tooltip: '保存',
                      icon: const Icon(Icons.check),
                      onPressed: () => Get.back(result: selected.toList()),
                    ),
                  ],
                ),
                Text(
                  '当前：${selected.isEmpty ? '未设置标签' : tags.where((tag) => selected.contains(tag.id)).map((tag) => tag.tag).join('、')}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const Divider(),
                if (tags.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      '还没有自定义标签，可在关注页右上角「标签管理」里添加',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  )
                else
                  SizedBox(
                    height: MediaQuery.sizeOf(context).height * 0.35,
                    child: ListView.builder(
                      itemCount: tags.length,
                      itemBuilder: (context, index) {
                        final tag = tags[index];
                        return CheckboxListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(tag.tag),
                          value: selected.contains(tag.id),
                          onChanged: (checked) {
                            setDialogState(() {
                              if (checked == true) {
                                selected.add(tag.id);
                              } else {
                                selected.remove(tag.id);
                              }
                            });
                          },
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    final current = service.getFollowUser(item.id);
    if (result != null && current != null) {
      await service.setFollowTags(current, result);
    }
  }
}
