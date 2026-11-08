import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/modules/mine/history/history_controller.dart';
import 'package:simple_live_app/routes/app_navigation.dart';
import 'package:simple_live_app/widgets/net_image.dart';
import 'package:simple_live_app/widgets/page_grid_view.dart';

class HistoryPage extends GetView<HistoryController> {
  const HistoryPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    var rowCount = MediaQuery.of(context).size.width ~/ 500;
    if (rowCount < 1) rowCount = 1;
    return Scaffold(
      appBar: AppBar(
        title: const Text("观看记录"),
        actions: [
          TextButton.icon(
            onPressed: controller.clean,
            icon: const Icon(Icons.delete_outline),
            label: const Text("清空"),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 平台筛选：全部 + 各平台（带条数），桌面和手机行为一致
          Padding(
            padding: const EdgeInsets.only(left: 14, right: 14, top: 14),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  buildSiteChip(
                    context,
                    siteId: "all",
                    name: "全部",
                    logo: "",
                  ),
                  ...Sites.supportSites.map(
                    (site) => buildSiteChip(
                      context,
                      siteId: site.id,
                      name: site.name,
                      logo: site.logo,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: PageGridView(
              crossAxisSpacing: 12,
              crossAxisCount: rowCount,
              pageController: controller,
              firstRefresh: true,
              padding: const EdgeInsets.only(top: 12, bottom: 12),
              itemBuilder: (_, i) {
                var item = controller.list[i];
                var site = Sites.allSites[item.siteId]!;
                return Dismissible(
                  key: ValueKey(item.id),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    color: Colors.red,
                    padding: AppStyle.edgeInsetsA12,
                    alignment: Alignment.centerRight,
                    child: const Icon(
                      Icons.delete,
                      color: Colors.white,
                    ),
                  ),
                  confirmDismiss: (direction) async {
                    return await Utils.showAlertDialog("确定要删除此记录吗?", title: "删除记录");
                  },
                  onDismissed: (_) {
                    controller.removeItem(item);
                  },
                  child: ListTile(
                    leading: NetImage(
                      item.face,
                      width: 48,
                      height: 48,
                      borderRadius: 24,
                    ),
                    title: Text(item.userName),
                    subtitle: Row(
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              Image.asset(
                                site.logo,
                                width: 20,
                              ),
                              AppStyle.hGap4,
                              Text(
                                site.name,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          Utils.parseTime(item.updateTime),
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ),
                    onTap: () {
                      AppNavigator.toLiveRoomDetail(
                        site: site,
                        roomId: item.roomId,
                      );
                    },
                    onLongPress: () async {
                      var result = await Utils.showAlertDialog(
                        "确定要删除此记录吗?",
                        title: "删除记录",
                      );
                      if (!result) {
                        return;
                      }
                      controller.removeItem(item);
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 平台筛选胶囊（样式与关注页保持一致）
  Widget buildSiteChip(
    BuildContext context, {
    required String siteId,
    required String name,
    required String logo,
  }) {
    var theme = Theme.of(context);
    return Obx(
      () {
        var selected = controller.siteFilter.value == siteId;
        var count = controller.counts[siteId] ?? 0;
        return InkWell(
          borderRadius: AppStyle.radius24,
          onTap: () {
            controller.setSiteFilter(siteId);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: AppStyle.radius24,
              border: Border.all(
                color: selected
                    ? theme.colorScheme.primary
                    : theme.dividerColor,
              ),
              color: selected
                  ? theme.colorScheme.primary.withValues(alpha: 0.15)
                  : Colors.transparent,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (logo.isNotEmpty) ...[
                  Image.asset(logo, width: 16),
                  AppStyle.hGap4,
                ],
                Text(
                  name,
                  style: TextStyle(
                    fontSize: 13,
                    color: selected ? theme.colorScheme.primary : null,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
                AppStyle.hGap4,
                Text(
                  count.toString(),
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
