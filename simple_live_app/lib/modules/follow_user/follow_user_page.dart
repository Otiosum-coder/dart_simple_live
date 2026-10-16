import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/modules/follow_user/follow_user_controller.dart';
import 'package:simple_live_app/routes/app_navigation.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/widgets/filter_button.dart';
import 'package:simple_live_app/widgets/follow_user_item.dart';
import 'package:simple_live_app/widgets/page_grid_view.dart';

class FollowUserPage extends GetView<FollowUserController> {
  const FollowUserPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    var count = MediaQuery.of(context).size.width ~/ 500;
    if (count < 1) count = 1;
    return Scaffold(
      appBar: AppBar(
        // 只收窄标题栏本身，筛选区不动
        toolbarHeight: 44,
        title: const Text("关注用户"),
        actions: [
          PopupMenuButton(
            itemBuilder: (context) {
              return const [
                PopupMenuItem(
                  value: 0,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Remix.save_2_line),
                      AppStyle.hGap12,
                      Text("导出文件")
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 1,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Remix.folder_open_line),
                      AppStyle.hGap12,
                      Text("导入文件")
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 2,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Remix.text),
                      AppStyle.hGap12,
                      Text("导出文本"),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 3,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Remix.file_text_line),
                      AppStyle.hGap12,
                      Text("导入文本"),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 4,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Remix.price_tag_line),
                      AppStyle.hGap12,
                      Text("标签管理"),
                    ],
                  ),
                ),
              ];
            },
            onSelected: (value) {
              if (value == 0) {
                FollowService.instance.exportFile();
              } else if (value == 1) {
                FollowService.instance.inputFile();
              } else if (value == 2) {
                FollowService.instance.exportText();
              } else if (value == 3) {
                FollowService.instance.inputText();
              } else if (value == 4) {
                showTagsManager();
              }
            },
          ),
        ],
        leading: Obx(
          () => FollowService.instance.updating.value
              ? const IconButton(
                  onPressed: null,
                  icon: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                    ),
                  ),
                )
              : IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 40,
                    minHeight: 40,
                  ),
                  onPressed: () {
                    controller.refreshData();
                  },
                  icon: const Icon(Icons.refresh),
                ),
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 筛选区：平台行（多平台时才显示）+ 状态/标签行
          Padding(
            padding: const EdgeInsets.only(left: 14, right: 14, top: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Obx(
                  () => controller.showPlatformRow
                      ? SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: controller.platformList
                                .map((e) => buildPlatformChip(context, e))
                                .toList(),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                Obx(
                  () => controller.showPlatformRow
                      ? const SizedBox(height: 12)
                      : const SizedBox.shrink(),
                ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Obx(
                    () => Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: controller.tagList.map((option) {
                        return FilterButton(
                          text: option.tag,
                          selected: controller.filterMode.value == option,
                          onTap: () {
                            controller.setFilterMode(option);
                          },
                        );
                      }).toList(),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: PageGridView(
              crossAxisSpacing: 12,
              crossAxisCount: count,
              pageController: controller,
              firstRefresh: true,
              showPCRefreshButton: false,
              itemBuilder: (_, i) {
                var item = controller.list[i];
                var site = Sites.allSites[item.siteId]!;
                return FollowUserItem(
                  item: item,
                  onRemove: () {
                    controller.removeItem(item);
                  },
                  onTap: () {
                    AppNavigator.toLiveRoomDetail(
                        site: site, roomId: item.roomId);
                  },
                  onLongPress: () {
                    setFollowTagDialog(item);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 平台筛选胶囊
  Widget buildPlatformChip(BuildContext context, FollowPlatformFilter option) {
    var theme = Theme.of(context);
    return Obx(
      () {
        var selected = controller.platformFilter.value == option.siteId;
        return InkWell(
          borderRadius: AppStyle.radius24,
          onTap: () {
            controller.setPlatformFilter(option.siteId);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: AppStyle.radius24,
              border: Border.all(
                color:
                    selected ? theme.colorScheme.primary : theme.dividerColor,
              ),
              color: selected
                  ? theme.colorScheme.primary.withValues(alpha: 0.15)
                  : Colors.transparent,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (option.logo.isNotEmpty) ...[
                  Image.asset(option.logo, width: 16),
                  AppStyle.hGap4,
                ],
                Text(
                  option.name,
                  style: TextStyle(
                    fontSize: 13,
                    color: selected ? theme.colorScheme.primary : null,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
                AppStyle.hGap4,
                Text(
                  option.count.toString(),
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
                if (option.liveCount > 0) ...[
                  AppStyle.hGap4,
                  Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: Colors.green,
                      borderRadius: BorderRadius.all(Radius.circular(3)),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  /// 设置主播的标签（多选）
  ///
  /// 「全部」不是标签（它是「显示所有关注」的筛选），所以这里不出现；
  /// 一个都不勾 = 不属于任何自定义标签。
  void setFollowTagDialog(FollowUser item) {
    var customTags =
        controller.userTagList.where((e) => e.tag != "全部").toList();
    // 当前所属标签：以标签的 userId 成员关系为准（旧数据用 item.tag 兜底）
    var selected = <String>{};
    for (var tag in customTags) {
      if (tag.userId.contains(item.id)) {
        selected.add(tag.tag);
      }
    }
    if (selected.isEmpty && item.tag != "全部") {
      selected.add(item.tag);
    }
    Get.dialog(
      AlertDialog(
        contentPadding: const EdgeInsets.all(16.0),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12.0),
        ),
        content: SizedBox(
          width: 300,
          child: StatefulBuilder(
            builder: (context, setDialogState) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        '设置标签',
                        style: TextStyle(fontSize: 18),
                      ),
                      IconButton(
                        icon: const Icon(Icons.check),
                        onPressed: () {
                          controller.setItemTags(item, selected.toList());
                          Get.back();
                        },
                      ),
                    ],
                  ),
                  Text(
                    '当前：' +
                        (selected.isEmpty
                            ? '未设置标签'
                            : selected.join('、')),
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const Divider(),
                  if (customTags.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Text(
                        '还没有自定义标签，可在右上角「标签管理」里添加',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    )
                  else
                    SizedBox(
                      height: 260,
                      child: ListView.builder(
                        itemCount: customTags.length,
                        itemBuilder: (context, index) {
                          var tag = customTags[index];
                          return CheckboxListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(tag.tag),
                            value: selected.contains(tag.tag),
                            onChanged: (checked) {
                              setDialogState(() {
                                if (checked == true) {
                                  selected.add(tag.tag);
                                } else {
                                  selected.remove(tag.tag);
                                }
                              });
                            },
                          );
                        },
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  void showTagsManager() {
    Utils.showBottomSheet(
      title: '标签管理',
      child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppStyle.divider,
            ListTile(
              title: const Text("添加标签"),
              leading: const Icon(Icons.add),
              onTap: () {
                editTagDialog("添加标签");
              },
            ),
            AppStyle.divider,
            // 列表内容
            Expanded(
              child: Obx(
                () => ReorderableListView.builder(
                  itemCount: controller.userTagList.length,
                  itemBuilder: (context, index) {
                    // 偏移
                    FollowUserTag item = controller.userTagList[index];
                    return ListTile(
                      key: ValueKey(item.id),
                      title: GestureDetector(
                        child: Text(item.tag),
                        onLongPress: () {
                          {
                            editTagDialog("修改标签", followUserTag: item);
                          }
                        },
                      ),
                      leading: IconButton(
                        icon: const Icon(Icons.delete),
                        onPressed: () {
                          controller.removeTag(item);
                        },
                      ),
                    );
                  },
                  onReorder: (int oldIndex, int newIndex) {
                    controller.updateTagOrder(oldIndex, newIndex);
                  },
                ),
              ),
            ),
          ]),
    );
  }

  void editTagDialog(String title, {FollowUserTag? followUserTag}) {
    final TextEditingController tagEditController =
        TextEditingController(text: followUserTag?.tag);
    bool upMode = title == "添加标签" ? true : false;
    Get.dialog(
      AlertDialog(
        contentPadding: const EdgeInsets.all(16.0),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12.0),
        ),
        content: SingleChildScrollView(
          padding: EdgeInsets.only(
              bottom: MediaQuery.of(Get.context!).viewInsets.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                ),
              ),
              TextField(
                controller: tagEditController,
                minLines: 1,
                maxLines: 1,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  contentPadding: AppStyle.edgeInsetsA12,
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(
                      color: Colors.grey.withAlpha(51),
                    ),
                  ),
                ),
                onSubmitted: (tag) {
                  upMode
                      ? controller.addTag(tagEditController.text)
                      : controller.updateTagName(
                          followUserTag!, tagEditController.text);
                  Get.back();
                },
              ),
              Container(
                margin: AppStyle.edgeInsetsB4,
                width: double.infinity,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () {
                        Get.back();
                      },
                      child: const Text('否'),
                    ),
                    TextButton(
                      onPressed: () {
                        upMode
                            ? controller.addTag(tagEditController.text)
                            : controller.updateTagName(
                                followUserTag!, tagEditController.text);
                        Get.back();
                      },
                      child: const Text('是'),
                    ),
                  ],
                ),
              )
            ],
          ),
        ),
      ),
    );
  }
}
