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
      final isLocalGameArtwork = DouyinGameArtwork.isLocalGameArtwork(pic);
      return NetImage(
        pic,
        fit: isLocalGameArtwork ? BoxFit.contain : BoxFit.cover,
        width: 40,
        height: 40,
        borderRadius: 8,
        // 按图床分站点给 Referer：给 B站图床发抖音的 Referer 会被拒（403）
        headers: _categoryImageHeaders(pic),
        failedWidget: buildCategoryIconBox(context, item),
      );
    }
    return buildCategoryIconBox(context, item);
  }

  /// 分类图请求头：不同图床要求不同的 Referer
  Map<String, String>? _categoryImageHeaders(String url) {
    if (url.contains("hdslb.com") || url.contains("biliimg.com")) {
      return {
        "Referer": "https://live.bilibili.com/",
        "User-Agent":
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
      };
    }
    if (url.contains("douyin") || url.contains("douyincdn")) {
      return {"Referer": "https://live.douyin.com/"};
    }
    return null;
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
        Icons.dashboard_customize_rounded,
        size: 22,
        color: color,
      ),
    );
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
