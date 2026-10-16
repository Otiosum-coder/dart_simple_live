import 'package:flutter/material.dart';
import 'package:flutter_easyrefresh/easy_refresh.dart';

import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/modules/category/category_list_controller.dart';
import 'package:simple_live_app/routes/app_navigation.dart';
import 'package:simple_live_app/widgets/keep_alive_wrapper.dart';
import 'package:simple_live_app/widgets/net_image.dart';
import 'package:simple_live_app/widgets/shadow_card.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:sticky_headers/sticky_headers.dart';

class CategoryListView extends StatelessWidget {
  final String tag;
  const CategoryListView(this.tag, {Key? key}) : super(key: key);
  CategoryListController get controller =>
      Get.find<CategoryListController>(tag: tag);
  @override
  Widget build(BuildContext context) {
    return KeepAliveWrapper(
      child: Obx(
        () => EasyRefresh(
          firstRefresh: true,
          controller: controller.easyRefreshController,
          onRefresh: controller.refreshData,
          header: MaterialHeader(
            completeDuration: const Duration(milliseconds: 400),
          ),
          child: ListView.builder(
            padding: AppStyle.edgeInsetsA12,
            itemCount: controller.list.length,
            controller: controller.scrollController,
            itemBuilder: (_, i) {
              var item = controller.list[i];
              return Column(
                children: [
                  StickyHeader(
                    header: Container(
                      padding: AppStyle.edgeInsetsV8.copyWith(left: 4),
                      color: Theme.of(context).scaffoldBackgroundColor,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        item.name,
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                    ),
                    content: Obx(
                      () => GridView.count(
                        shrinkWrap: true,
                        padding: AppStyle.edgeInsetsV8,
                        physics: const NeverScrollableScrollPhysics(),
                        crossAxisCount: MediaQuery.of(context).size.width ~/ 80,
                        crossAxisSpacing: 8,
                        mainAxisSpacing: 8,
                        children: item.showAll.value
                            ? (item.children
                                .map(
                                  (e) => buildSubCategory(context, e),
                                )
                                .toList())
                            : (item.take15
                                .map(
                                  (e) => buildSubCategory(context, e),
                                )
                                .toList()
                              ..add(buildShowMore(item))),
                      ),
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

  Widget buildSubCategory(BuildContext context, LiveSubCategory item) {
    return ShadowCard(
      onTap: () {
        AppNavigator.toCategoryDetail(site: controller.site, category: item);
      },
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          buildSubCategoryIcon(context, item),
          AppStyle.vGap4,
          Text(
            item.name,
            maxLines: 1,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }

  /// 子分类图标：有封面图就用封面，没有就用按名称映射的语义图标兜底
  ///
  /// 抖音的分类接口（解析 live.douyin.com 首页）不返回封面，pic 恒为空字符串，
  /// 只显示文字会显得很空；这里按分类名映射一个图标，其它平台缺封面时同样受益。
  Widget buildSubCategoryIcon(BuildContext context, LiveSubCategory item) {
    var pic = (item.pic ?? "").trim();
    if (pic.isNotEmpty) {
      return NetImage(
        pic,
        width: 40,
        height: 40,
        borderRadius: 8,
        // 抖音分类图的域名常需要 Referer；失败了也不要留破图，回落到语义图标
        headers: const {"Referer": "https://live.douyin.com/"},
        failedWidget: buildCategoryIconBox(context, item),
      );
    }
    return buildCategoryIconBox(context, item);
  }

  /// 语义图标兜底（分类图缺失或加载失败时用）
  Widget buildCategoryIconBox(BuildContext context, LiveSubCategory item) {
    var color = Theme.of(context).colorScheme.primary;
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withAlpha(40)),
        color: color.withAlpha(18),
      ),
      child: Icon(
        categoryIconByName(item.name),
        size: 22,
        color: color,
      ),
    );
  }

  /// 分类名 → 图标（按关键词匹配，匹配不到给一个通用图标）
  IconData categoryIconByName(String name) {
    if (name.contains("游戏") ||
        name.contains("电竞") ||
        name.contains("手游") ||
        name.contains("赛事")) {
      return Icons.sports_esports_rounded;
    }
    if (name.contains("唱") || name.contains("音乐") || name.contains("电台")) {
      return Icons.music_note_rounded;
    }
    if (name.contains("舞") || name.contains("才艺") || name.contains("颜值")) {
      return Icons.auto_awesome_rounded;
    }
    if (name.contains("聊天") || name.contains("交友") || name.contains("情感")) {
      return Icons.forum_rounded;
    }
    if (name.contains("美食") || name.contains("吃")) {
      return Icons.restaurant_rounded;
    }
    if (name.contains("户外") || name.contains("旅行") || name.contains("风景")) {
      return Icons.landscape_rounded;
    }
    if (name.contains("知识") || name.contains("教育") || name.contains("课堂")) {
      return Icons.school_rounded;
    }
    if (name.contains("体育") || name.contains("运动") || name.contains("健身")) {
      return Icons.sports_basketball_rounded;
    }
    if (name.contains("购物") || name.contains("带货") || name.contains("电商")) {
      return Icons.shopping_bag_rounded;
    }
    if (name.contains("二") && name.contains("次")) {
      return Icons.animation_rounded;
    }
    if (name.contains("汽车") || name.contains("车")) {
      return Icons.directions_car_rounded;
    }
    if (name.contains("科技") || name.contains("数码") || name.contains("电脑")) {
      return Icons.memory_rounded;
    }
    if (name.contains("生活") || name.contains("日常")) {
      return Icons.weekend_rounded;
    }
    if (name.contains("娱乐") || name.contains("综艺")) {
      return Icons.celebration_rounded;
    }
    if (name.contains("亲子") || name.contains("萌娃") || name.contains("育儿")) {
      return Icons.child_care_rounded;
    }
    if (name.contains("热门") || name.contains("推荐")) {
      return Icons.local_fire_department_rounded;
    }
    return Icons.live_tv_rounded;
  }

  Widget buildShowMore(AppLiveCategory item) {
    return ShadowCard(
      onTap: () {
        item.showAll.value = true;
      },
      child: const Center(
        child: Text(
          "显示全部",
          maxLines: 1,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12),
        ),
      ),
    );
  }
}
