import 'dart:io';
import 'dart:math' as math;

import 'package:floating/floating.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:lottie/lottie.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/live_room/player/player_controls.dart';
import 'package:simple_live_app/routes/app_navigation.dart';
import 'package:simple_live_app/services/background_playback.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/widgets/danmaku_input_bar.dart';
import 'package:simple_live_app/widgets/desktop_refresh_button.dart';
import 'package:simple_live_app/widgets/follow_user_item.dart';
import 'package:simple_live_app/widgets/keep_alive_wrapper.dart';
import 'package:simple_live_app/widgets/net_image.dart';
import 'package:simple_live_app/widgets/settings/settings_action.dart';
import 'package:simple_live_app/widgets/settings/settings_card.dart';
import 'package:simple_live_app/widgets/settings/settings_number.dart';
import 'package:simple_live_app/widgets/settings/settings_switch.dart';
import 'package:simple_live_app/widgets/superchat_card.dart';
import 'package:simple_live_core/simple_live_core.dart';

class LiveRoomPage extends GetView<LiveRoomController> {
  const LiveRoomPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final page = Obx(
      () {
        if (controller.loadError.value) {
          return Scaffold(
            appBar: AppBar(
              title: const Text("直播间加载失败"),
            ),
            body: Padding(
              padding: AppStyle.edgeInsetsA12,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  LottieBuilder.asset(
                    'assets/lotties/error.json',
                    height: 140,
                    repeat: false,
                  ),
                  const Text(
                    "直播间加载失败",
                    textAlign: TextAlign.center,
                  ),
                  AppStyle.vGap4,
                  Text(
                    controller.error?.toString() ?? "未知错误",
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  AppStyle.vGap4,
                  Text(
                    "${controller.rxSite.value.id} - ${controller.rxRoomId.value}",
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      TextButton.icon(
                        onPressed: controller.copyErrorDetail,
                        icon: const Icon(Remix.file_copy_line),
                        label: const Text("复制信息"),
                      ),
                      TextButton.icon(
                        onPressed: controller.refreshRoom,
                        icon: const Icon(Remix.refresh_line),
                        label: const Text("刷新"),
                      ),
                    ],
                  )
                ],
              ),
            ),
          );
        }
        if (controller.fullScreenState.value) {
          return PopScope(
            canPop: false,
            onPopInvokedWithResult: (e, r) {
              controller.exitFull();
            },
            child: Scaffold(
              body: buildMediaPlayer(context),
            ),
          );
        } else {
          return buildPageUI();
        }
      },
    );
    if (!Platform.isAndroid) {
      return page;
    }
    return PiPSwitcher(
      floating: controller.pip,
      childWhenDisabled: page,
      childWhenEnabled: buildMediaPlayer(context),
    );
  }

  Widget buildPageUI() {
    return OrientationBuilder(
      builder: (context, orientation) {
        return Scaffold(
          appBar: AppBar(
            title: Obx(
              () => Text(controller.detail.value?.title ?? "直播间"),
            ),
            actions: buildAppbarActions(context),
          ),
          body: orientation == Orientation.portrait
              ? buildPhoneUI(context)
              : buildTabletUI(context),
        );
      },
    );
  }

  Widget buildPhoneUI(BuildContext context) {
    return Column(
      children: [
        AspectRatio(
          aspectRatio: 16 / 9,
          child: buildMediaPlayer(context),
        ),
        buildUserProfile(context),
        buildMessageArea(),
        // 开启「发送弹幕」后进入新布局：底部功能行取消
        // （关注 → 主播名右侧；刷新/分享 → 右上角菜单）
        Obx(
          () => AppSettingsController.instance.playerSendDanmaku.value
              ? const SizedBox.shrink()
              : buildBottomActions(context),
        ),
      ],
    );
  }

  Widget buildTabletUI(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              Expanded(
                child: buildMediaPlayer(context),
              ),
              SizedBox(
                // 面板宽度自适应：桌面端仍是 300；移动端按屏宽比例算并限制在 200-300，
                // 否则手机横屏（逻辑宽约 700）时 300 会占掉 43%，SC 卡片看起来过长
                width: (MediaQuery.sizeOf(context).width * 0.36)
                    .clamp(200.0, 300.0),
                child: Column(
                  children: [
                    buildUserProfile(context),
                    buildMessageArea(),
                  ],
                ),
              ),
            ],
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            border: Border(
              top: BorderSide(
                color: Colors.grey.withAlpha(25),
              ),
            ),
          ),
          padding: AppStyle.edgeInsetsV4.copyWith(
            bottom: AppStyle.bottomBarHeight + 4,
          ),
          child: Row(
            children: [
              TextButton.icon(
                style: TextButton.styleFrom(
                  textStyle: const TextStyle(fontSize: 14),
                ),
                onPressed: controller.refreshRoom,
                icon: const Icon(Remix.refresh_line),
                label: const Text("刷新"),
              ),
              AppStyle.hGap4,
              Obx(
                () => controller.followed.value
                    ? TextButton.icon(
                        style: TextButton.styleFrom(
                          textStyle: const TextStyle(fontSize: 14),
                        ),
                        onPressed: controller.removeFollowUser,
                        icon: const Icon(Remix.heart_fill),
                        label: const Text("取消关注"),
                      )
                    : TextButton.icon(
                        style: TextButton.styleFrom(
                          textStyle: const TextStyle(fontSize: 14),
                        ),
                        onPressed: controller.followUser,
                        icon: const Icon(Remix.heart_line),
                        label: const Text("关注"),
                      ),
              ),
              const Expanded(child: Center()),
              TextButton.icon(
                style: TextButton.styleFrom(
                  textStyle: const TextStyle(fontSize: 14),
                ),
                onPressed: controller.share,
                icon: const Icon(Remix.share_line),
                label: const Text("分享"),
              ),
              TextButton.icon(
                style: TextButton.styleFrom(
                  textStyle: const TextStyle(fontSize: 14),
                ),
                onPressed: controller.copyUrl,
                icon: const Icon(Remix.file_copy_line),
                label: const Text("复制链接"),
              ),
              TextButton.icon(
                style: TextButton.styleFrom(
                  textStyle: const TextStyle(fontSize: 14),
                ),
                onPressed: controller.copyPlayUrl,
                icon: const Icon(Remix.file_copy_line),
                label: const Text("复制播放直链"),
              ),
              // 新布局：输入框放在底栏右侧（原三个按钮的位置）
              Obx(
                () => !AppSettingsController.instance.playerSendDanmaku.value
                    ? const SizedBox.shrink()
                    : SizedBox(
                        // 与上方聊天面板严格同宽
                        width: (MediaQuery.sizeOf(context).width * 0.36)
                            .clamp(200.0, 300.0),
                        child: Container(
                          decoration: BoxDecoration(
                            color: Theme.of(context).cardColor,
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          child: DanmakuInputBar(
                            controller: controller,
                            overlay: true,
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget buildMediaPlayer(BuildContext context) {
    var boxFit = BoxFit.contain;
    double? aspectRatio;
    if (AppSettingsController.instance.scaleMode.value == 0) {
      boxFit = BoxFit.contain;
    } else if (AppSettingsController.instance.scaleMode.value == 1) {
      boxFit = BoxFit.fill;
    } else if (AppSettingsController.instance.scaleMode.value == 2) {
      boxFit = BoxFit.cover;
    } else if (AppSettingsController.instance.scaleMode.value == 3) {
      boxFit = BoxFit.contain;
      aspectRatio = 16 / 9;
    } else if (AppSettingsController.instance.scaleMode.value == 4) {
      boxFit = BoxFit.contain;
      aspectRatio = 4 / 3;
    }
    return Stack(
      children: [
        Video(
          key: controller.globalPlayerKey,
          controller: controller.videoController,
          pauseUponEnteringBackgroundMode:
              AppSettingsController.instance.playerAutoPause.value,
          resumeUponEnteringForegroundMode:
              AppSettingsController.instance.playerAutoPause.value,
          controls: (state) {
            return playerControls(state, controller);
          },
          aspectRatio: aspectRatio,
          fit: boxFit,
          // 自己实现
          wakelock: false,
        ),
        // 拿不到播放地址时（未开播 / 大航海等付费限定房间）显示兜底封面，
        // 否则这里只剩一片黑，用户只看到几行文字
        Obx(
          () => Visibility(
            // 只在「取流流程结束且确实没地址」时显示，避免进房加载时闪一下
            visible: controller.playUrlEmpty.value &&
                controller.detail.value != null &&
                !controller.loadError.value,
            child: Image.asset(
              'assets/images/cover_fallback.png',
              fit: BoxFit.cover,
            ),
          ),
        ),
        // 下播/断开后先盖一层不透明底：否则会同时看到「冻结的最后一帧」和未开播卡片
        Obx(
          () => Visibility(
            // 必须加上「没在播放」：否则切线路失败被误判成未开播时，
            // 卡片会压在正常播放的画面上（用户看到的就是这个）
            visible: !controller.liveStatus.value &&
                !controller.playerPlaying.value &&
                controller.detail.value != null &&
                !controller.loadError.value,
            child: const ColoredBox(color: Colors.black),
          ),
        ),
        // 只有拿到详情后才显示未开播卡片；
        // 否则加载过程中会先闪一个「平台图标 + 暂无开播记录」的空壳
        Obx(
          () => Visibility(
            visible: !controller.liveStatus.value &&
                !controller.playerPlaying.value &&
                controller.detail.value != null &&
                !controller.loadError.value,
            child: buildOfflineInfo(context),
          ),
        ),
        // 「只播放声音」：盖住画面（视频解码已被 mpv 的 vid=no 关掉）
        Obx(
          () => Visibility(
            visible: AppSettingsController.instance.playerAudioOnly.value,
            child: buildAudioOnlyCover(context),
          ),
        ),
      ],
    );
  }

  /// 「只播放声音」时盖住画面，并给一个一键恢复
  Widget buildAudioOnlyCover(BuildContext context) {
    return Container(
      color: const Color(0xFF0E1013),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.headphones,
            size: 40,
            color: Color(0xFF6F767D),
          ),
          AppStyle.vGap12,
          const Text(
            "只播放声音",
            style: TextStyle(fontSize: 14, color: Color(0xFF9AA1A8)),
          ),
          AppStyle.vGap4,
          // 显示当前线路：有音频线路时这里就是「🎧 音频线路」，否则是「线路N」
          Obx(
            () => Text(
              controller.currentLineInfo.value,
              style: const TextStyle(fontSize: 12, color: Color(0xFF6F767D)),
            ),
          ),
          AppStyle.vGap12,
          TextButton(
            onPressed: () {
              AppSettingsController.instance.setPlayerAudioOnly(false);
              controller.applyAudioOnly();
            },
            child: const Text("恢复画面"),
          ),
        ],
      ),
    );
  }

  /// 未开播时的信息卡（横版 ≈1.5:1）
  ///
  /// - 不显示头像 / 昵称 / 平台 logo /「未开播」标识（状态由场景表达）
  /// - 卡片里不放操作按钮：刷新用底部操作栏，外链「查看主页」放在右上角「更多」菜单里
  /// - 时间用主题色，全局统一
  Widget buildOfflineInfo(BuildContext context) {
    var detail = controller.detail.value;
    var showTime = detail?.lastLiveTime ?? "";
    var hasTime = showTime.isNotEmpty && showTime != "0";
    // B站未登录时拿不到「上次直播」时间，改成登录引导
    var needBiliLogin = controller.site.id == Constant.kBiliBili &&
        !BiliBiliAccountService.instance.logined.value;
    var roomGone = detail?.roomNotFound == true;
    var colors = Theme.of(context).colorScheme;

    String label;
    String bigText;
    Color bigColor;
    String subText;
    if (hasTime) {
      label = "上次开播时间";
      bigText = LiveDuration.agoText(showTime);
      bigColor = colors.primary;
      // 底部显示完整日期时间（不做「今天/昨天」相对化）
      subText = LiveDuration.fullTimeText(showTime);
    } else if (needBiliLogin) {
      label = "上次开播时间";
      bigText = "登录后可见";
      bigColor = colors.primary;
      subText = "点击这里登录哔哩哔哩";
    } else if (roomGone) {
      label = "开播记录";
      bigText = "已失效";
      bigColor = const Color(0xFF6F767D);
      subText = "该直播间已失效或不存在";
    } else {
      label = "开播记录";
      bigText = "暂无";
      bigColor = const Color(0xFF6F767D);
      subText = "该主播还没有可查询的直播记录";
    }

    const double cardWidth = 340;
    Widget card = Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      decoration: BoxDecoration(
        color: const Color(0xFF111418),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF22262C)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Remix.time_line,
                size: 15,
                color: Color(0xFF9AA1A8),
              ),
              AppStyle.hGap4,
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12.5,
                  color: Color(0xFF8B9299),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            bigText,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 34,
              height: 1.15,
              fontWeight: FontWeight.w700,
              color: bigColor,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            subText,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12.5, color: Color(0xFF8B9299)),
          ),

        ],
      ),
    );

    // B站未登录：整张卡片可点，直接去登录（顺带解锁原画）
    if (!hasTime && needBiliLogin) {
      card = InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () async {
          await AppNavigator.toBiliBiliLogin();
          if (BiliBiliAccountService.instance.logined.value) {
            controller.loadData();
          }
        },
        child: card,
      );
    }

    return Center(
      child: Padding(
        padding: AppStyle.edgeInsetsA16,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 双重约束自适应：
            //   宽 ≤ 340，且不超过可用宽度的 82%；
            //   高 ≤ 可用高度的 72%（小窗口 / 手机横屏会自动缩小）
            var width = math.min(cardWidth, constraints.maxWidth * 0.82);
            var height = math.min(width / 1.6, constraints.maxHeight * 0.72);
            width = math.min(width, height * 1.6);
            return SizedBox(width: width, height: height, child: card);
          },
        ),
      ),
    );
  }

  Widget buildUserProfile(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        border: Border(
          top: BorderSide(
            color: Colors.grey.withAlpha(25),
          ),
          bottom: BorderSide(
            color: Colors.grey.withAlpha(25),
          ),
        ),
      ),
      padding: AppStyle.edgeInsetsA8.copyWith(
        left: 12,
        right: 12,
      ),
      child: Obx(
        () => Row(
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.withAlpha(50)),
                borderRadius: AppStyle.radius24,
              ),
              child: NetImage(
                controller.detail.value?.userAvatar ?? "",
                width: 48,
                height: 48,
                borderRadius: 24,
              ),
            ),
            AppStyle.hGap12,
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          controller.detail.value?.userName ?? "",
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  AppStyle.vGap4,
                  Row(
                    children: [
                      Image.asset(
                        controller.site.logo,
                        width: 20,
                      ),
                      AppStyle.hGap4,
                      Text(
                        controller.site.name,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            AppStyle.hGap12,
            // 右侧：热度 + （开启发送弹幕后）热度下方的矩形关注按钮
            Obx(
              () => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Remix.fire_fill,
                        size: 18,
                        color: Colors.orange,
                      ),
                      AppStyle.hGap4,
                      Text(
                        Utils.onlineToString(
                          controller.detail.value?.online ?? 0,
                        ),
                        style: const TextStyle(fontSize: 13),
                      ),
                    ],
                  ),
                  if (AppSettingsController
                      .instance.playerSendDanmaku.value) ...[
                    const SizedBox(height: 6),
                    InkWell(
                      borderRadius: AppStyle.radius8,
                      onTap: controller.followed.value
                          ? controller.removeFollowUser
                          : controller.followUser,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: AppStyle.radius8,
                          color: Colors.transparent,
                          border: Border.all(
                            color: controller.followed.value
                                ? Colors.grey.withAlpha(90)
                                : Theme.of(context).colorScheme.primary,
                          ),
                        ),
                        child: Text(
                          controller.followed.value ? "已关注" : "关注",
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: controller.followed.value
                                ? Colors.grey
                                : Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildBottomActions(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        border: Border(
          top: BorderSide(
            color: Colors.grey.withAlpha(25),
          ),
        ),
      ),
      padding: EdgeInsets.only(bottom: AppStyle.bottomBarHeight),
      child: Row(
        children: [
          Expanded(
            child: Obx(
              () => controller.followed.value
                  ? TextButton.icon(
                      style: TextButton.styleFrom(
                        textStyle: const TextStyle(fontSize: 14),
                      ),
                      onPressed: controller.removeFollowUser,
                      icon: const Icon(Remix.heart_fill),
                      label: const Text("取消关注"),
                    )
                  : TextButton.icon(
                      style: TextButton.styleFrom(
                        textStyle: const TextStyle(fontSize: 14),
                      ),
                      onPressed: controller.followUser,
                      icon: const Icon(Remix.heart_line),
                      label: const Text("关注"),
                    ),
            ),
          ),
          Expanded(
            child: TextButton.icon(
              style: TextButton.styleFrom(
                textStyle: const TextStyle(fontSize: 14),
              ),
              onPressed: controller.refreshRoom,
              icon: const Icon(Remix.refresh_line),
              label: const Text("刷新"),
            ),
          ),
          Expanded(
            child: TextButton.icon(
              style: TextButton.styleFrom(
                textStyle: const TextStyle(fontSize: 14),
              ),
              onPressed: controller.share,
              icon: const Icon(Remix.share_line),
              label: const Text("分享"),
            ),
          ),
        ],
      ),
    );
  }

  /// 弹幕输入框：设置开启 + 平台支持发送时才显示
  ///
  /// 只放在「聊天」页里（见 [buildChatTab]），切到 SC / 关注 / 设置 时不存在。
  /// 依赖 [LiveRoomController.canSendDanmaku]（Observable）而不是弹幕对象的
  /// 普通 getter，房间加载、切换后能力变化都能即时刷新。
  Widget buildDanmakuInput() {
    return Obx(
      () {
        var enabled = AppSettingsController.instance.playerSendDanmaku.value;
        if (!enabled) {
          return const SizedBox.shrink();
        }
        // 桌面/横屏：输入框在底栏右侧，聊天页不重复
        if (MediaQuery.of(Get.context!).orientation != Orientation.portrait) {
          return const SizedBox.shrink();
        }

        return DanmakuInputBar(controller: controller);
      },
    );
  }

  Widget buildMessageArea() {
    return Expanded(
      child: DefaultTabController(
        length: controller.site.id == Constant.kBiliBili ? 4 : 3,
        child: Column(
          children: [
            TabBar(
              indicatorSize: TabBarIndicatorSize.tab,
              labelPadding: EdgeInsets.zero,
              indicatorWeight: 1.0,
              tabs: [
                const Tab(
                  text: "聊天",
                ),
                if (controller.site.id == Constant.kBiliBili)
                  Tab(
                    child: Obx(
                      () => Text(
                        controller.superChats.isNotEmpty
                            ? "SC(${controller.superChats.length})"
                            : "SC",
                      ),
                    ),
                  ),
                const Tab(
                  text: "关注",
                ),
                const Tab(
                  text: "设置",
                ),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  buildChatTab(),
                  if (controller.site.id == Constant.kBiliBili)
                    buildSuperChats(),
                  buildFollowList(),
                  buildSettings(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 「聊天」页：消息列表 + 底部弹幕输入条
  ///
  /// 输入条属于聊天页本身，所以切到 SC / 关注 / 设置 时自然一起换掉。
  Widget buildChatTab() {
    return Column(
      children: [
        // 弹幕会话被其他设备接管（斗鱼单会话限制）时提示，并可跳转重新登录
        Obx(
          () => !controller.danmakuSessionLost.value
              ? const SizedBox.shrink()
              : Container(
                  width: double.infinity,
                  color: Colors.orange.withAlpha(38),
                  padding: const EdgeInsets.only(left: 12, right: 4, top: 2, bottom: 2),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.warning_amber_rounded,
                        size: 18,
                        color: Colors.orange,
                      ),
                      AppStyle.hGap8,
                      const Expanded(
                        child: Text(
                          "弹幕会话已被其他设备接管，当前只能观看",
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          Get.toNamed("/settings/account");
                        },
                        child: const Text(
                          "重新登录斗鱼",
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
        Expanded(
          child: Obx(
            () => Stack(
              children: [
                ListView.separated(
                  controller: controller.scrollController,
                  separatorBuilder: (_, i) => Obx(
                    () => SizedBox(
                      // *2与原来的EdgeInsets.symmetric(vertical: )做兼容
                      height:
                          AppSettingsController.instance.chatTextGap.value * 2,
                    ),
                  ),
                  padding: AppStyle.edgeInsetsA12,
                  itemCount: controller.messages.length,
                  itemBuilder: (_, i) {
                    var item = controller.messages[i];
                    return buildMessageItem(item);
                  },
                ),
                Visibility(
                  visible: controller.disableAutoScroll.value,
                  child: Positioned(
                    right: 12,
                    bottom: 12,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        controller.disableAutoScroll.value = false;
                        controller.chatScrollToBottom();
                      },
                      icon: const Icon(Icons.expand_more),
                      label: const Text("最新"),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        buildDanmakuInput(),
      ],
    );
  }

  /// 消息正文：有 spans 就按「文字 + 表情图」渲染，没有就退回纯文本
  ///
  /// 表情图用 NetImage 渲染，它同时支持网络图（B站表情）和 asset:// 本地图（抖音表情包）。
  List<InlineSpan> buildMessageSpans(LiveMessage message) {
    final textStyle = TextStyle(
      color: Get.isDarkMode ? Colors.white : AppColors.black333,
    );
    final spans = message.spans;
    if (spans == null || spans.isEmpty) {
      return [TextSpan(text: message.message, style: textStyle)];
    }
    var emojiSize =
        AppSettingsController.instance.chatTextSize.value * 1.45;
    return spans.map<InlineSpan>((span) {
      if (span.isImage) {
        return WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: NetImage(
              span.imageUrl!.trim(),
              width: emojiSize,
              height: emojiSize,
              fit: BoxFit.contain,
            ),
          ),
        );
      }
      return TextSpan(text: span.text ?? "", style: textStyle);
    }).toList();
  }

  Widget buildMessageItem(LiveMessage message) {
    if (message.userName == "LiveSysMessage") {
      return Obx(
        () => Text(
          message.message,
          style: TextStyle(
            color: Colors.grey,
            fontSize: AppSettingsController.instance.chatTextSize.value,
          ),
        ),
      );
    }

    return Obx(
      () => AppSettingsController.instance.chatBubbleStyle.value
          ? Row(
              mainAxisAlignment: MainAxisAlignment.start,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Flexible(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.blueGrey.withAlpha(25),
                      //borderRadius: AppStyle.radius8,
                      borderRadius: const BorderRadius.only(
                        topRight: Radius.circular(12),
                        bottomLeft: Radius.circular(12),
                        bottomRight: Radius.circular(12),
                      ),
                    ),
                    padding:
                        AppStyle.edgeInsetsA4.copyWith(left: 12, right: 12),
                    child: Text.rich(
                      TextSpan(
                        text: "${message.userName}：",
                        style: TextStyle(
                          color: Colors.grey,
                          fontSize:
                              AppSettingsController.instance.chatTextSize.value,
                        ),
                        children: buildMessageSpans(message),
                      ),
                    ),
                  ),
                ),
              ],
            )
          : Text.rich(
              TextSpan(
                text: "${message.userName}：",
                style: TextStyle(
                  color: Colors.grey,
                  fontSize: AppSettingsController.instance.chatTextSize.value,
                ),
                children: buildMessageSpans(message),
              ),
            ),
    );
  }

  Widget buildSuperChats() {
    return KeepAliveWrapper(
      child: Obx(
        () => ListView.separated(
          padding: AppStyle.edgeInsetsA12,
          itemCount: controller.superChats.length,
          separatorBuilder: (_, i) => AppStyle.vGap12,
          itemBuilder: (_, i) {
            var item = controller.superChats[i];
            return SuperChatCard(
              item,
              onExpire: () {
                controller.removeSuperChats();
              },
            );
          },
        ),
      ),
    );
  }

  Widget buildSettings() {
    return ListView(
      padding: AppStyle.edgeInsetsA12,
      children: [
        Obx(
          () => Visibility(
            visible: controller.autoExitEnable.value,
            child: ListTile(
              leading: const Icon(Icons.timer_outlined),
              visualDensity: VisualDensity.compact,
              title: Text("${parseDuration(controller.countdown.value)}后自动关闭"),
            ),
          ),
        ),
        Padding(
          padding: AppStyle.edgeInsetsA12,
          child: Text(
            "聊天区",
            style: Get.textTheme.titleSmall,
          ),
        ),
        SettingsCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Obx(
                () => SettingsNumber(
                  title: "文字大小",
                  value:
                      AppSettingsController.instance.chatTextSize.value.toInt(),
                  min: 8,
                  max: 36,
                  onChanged: (e) {
                    AppSettingsController.instance
                        .setChatTextSize(e.toDouble());
                  },
                ),
              ),
              AppStyle.divider,
              Obx(
                () => SettingsNumber(
                  title: "上下间隔",
                  value:
                      AppSettingsController.instance.chatTextGap.value.toInt(),
                  min: 0,
                  max: 12,
                  onChanged: (e) {
                    AppSettingsController.instance.setChatTextGap(e.toDouble());
                  },
                ),
              ),
              AppStyle.divider,
              Obx(
                () => SettingsSwitch(
                  title: "气泡样式",
                  value: AppSettingsController.instance.chatBubbleStyle.value,
                  onChanged: (e) {
                    AppSettingsController.instance.setChatBubbleStyle(e);
                  },
                ),
              ),
              AppStyle.divider,
              Obx(
                () => SettingsSwitch(
                  title: "播放器中显示SC",
                  value:
                      AppSettingsController.instance.playershowSuperChat.value,
                  onChanged: (e) {
                    AppSettingsController.instance.setPlayerShowSuperChat(e);
                  },
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: AppStyle.edgeInsetsA12,
          child: Text(
            "更多设置",
            style: Get.textTheme.titleSmall,
          ),
        ),
        SettingsCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SettingsAction(
                title: "关键词屏蔽",
                onTap: controller.showDanmuShield,
              ),
              AppStyle.divider,
              SettingsAction(
                title: "弹幕设置",
                onTap: controller.showDanmuSettingsSheet,
              ),
              AppStyle.divider,
              SettingsAction(
                title: "定时关闭",
                onTap: controller.showAutoExitSheet,
              ),
              AppStyle.divider,
              SettingsAction(
                title: "画面尺寸",
                onTap: controller.showPlayerSettingsSheet,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget buildFollowList() {
    return Obx(
      () => Stack(
        children: [
          RefreshIndicator(
            onRefresh: FollowService.instance.loadData,
            child: ListView.builder(
              itemCount: FollowService.instance.liveList.length,
              itemBuilder: (_, i) {
                var item = FollowService.instance.liveList[i];
                return Obx(
                  () => FollowUserItem(
                    item: item,
                    playing: controller.rxSite.value.id == item.siteId &&
                        controller.rxRoomId.value == item.roomId,
                    onTap: () {
                      controller.resetRoom(
                        Sites.allSites[item.siteId]!,
                        item.roomId,
                      );
                    },
                  ),
                );
              },
            ),
          ),
          if (Platform.isLinux || Platform.isWindows || Platform.isMacOS)
            Positioned(
              right: 12,
              bottom: 12,
              child: Obx(
                () => DesktopRefreshButton(
                  refreshing: FollowService.instance.updating.value,
                  onPressed: FollowService.instance.loadData,
                ),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> buildAppbarActions(BuildContext context) {
    return [
      IconButton(
        onPressed: () {
          showMore();
        },
        icon: const Icon(Icons.more_horiz),
      ),
    ];
  }

  /// 右上角「更多」菜单
  ///
  /// 只保留"唯一入口"的功能：截图在播放器控制条上、刷新在底部操作栏、
  /// 画面尺寸 / 定时关闭在直播间「设置」页签、复制链接在系统分享面板里都有，
  /// 这里不再重复放 —— 一级菜单过长时顶部会被顶出屏幕。
  void showMore() {
    // 给弹窗一个高度上限：内容再长也在屏幕内滚动，顶部不会跑出屏幕
    var maxHeight = MediaQuery.of(Get.context!).size.height * 0.85;
    showModalBottomSheet(
      context: Get.context!,
      constraints: BoxConstraints(maxWidth: 600, maxHeight: maxHeight),
      isScrollControlled: true,
      builder: (_) => Container(
        padding: EdgeInsets.only(
          bottom: AppStyle.bottomBarHeight,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          children: [
            // 新布局下底部功能行取消，刷新/分享收到这里（只在开启发送弹幕时出现）
            if (AppSettingsController.instance.playerSendDanmaku.value) ...[
              ListTile(
                leading: const Icon(Remix.refresh_line),
                title: const Text("刷新直播间"),
                onTap: () {
                  Get.back();
                  controller.refreshRoom();
                },
              ),
              ListTile(
                leading: const Icon(Remix.share_line),
                title: const Text("分享"),
                onTap: () {
                  Get.back();
                  controller.share();
                },
              ),
              const Divider(height: 1),
            ],
            // 后台播放：必须跑前台服务，代价是通知栏有一条低重要度通知
            Obx(
              () => SwitchListTile(
                secondary: const Icon(Icons.headphones),
                title: const Text("允许后台播放"),
                subtitle: const Text("退到后台继续播放（通知栏一条静音通知）"),
                value: AppSettingsController.instance.playerBackgroundPlay.value,
                onChanged: (e) {
                  AppSettingsController.instance.setPlayerBackgroundPlay(e);
                  if (e) {
                    BackgroundPlayback.ensureNotificationPermission();
                    if (controller.player.state.playing) {
                      controller.syncBackgroundPlayback();
                    }
                  } else {
                    BackgroundPlayback.stop();
                  }
                },
              ),
            ),
            // 只播放声音：关视频解码 + 最低清晰度
            Obx(
              () => SwitchListTile(
                secondary: const Icon(Icons.volume_up),
                title: const Text("只播放声音"),
                subtitle: const Text("关闭画面，按最低清晰度拉流"),
                value: AppSettingsController.instance.playerAudioOnly.value,
                onChanged: (e) {
                  AppSettingsController.instance.setPlayerAudioOnly(e);
                  controller.applyAudioOnly();
                },
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.play_circle_outline),
              trailing: const Icon(Icons.chevron_right),
              title: const Text("切换清晰度"),
              onTap: () {
                Get.back();
                controller.showQualitySheet();
              },
            ),
            ListTile(
              leading: const Icon(Icons.switch_video_outlined),
              title: const Text("切换线路"),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Get.back();
                controller.showPlayUrlsSheet();
              },
            ),
            Visibility(
              visible: Platform.isAndroid,
              child: ListTile(
                leading: const Icon(Icons.picture_in_picture),
                title: const Text("小窗播放"),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Get.back();
                  controller.enablePIP();
                },
              ),
            ),
            ListTile(
              leading: const Icon(Icons.share_sharp),
              title: const Text("分享直播间"),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Get.back();
                controller.share();
              },
            ),
            // 优先唤起平台 App，没装则自动转浏览器 —— 原先的「查看主页」已并入这里
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: const Text("APP中打开"),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Get.back();
                controller.openNaviteAPP();
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline_rounded),
              title: const Text("播放信息"),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Get.back();
                controller.showDebugInfo();
              },
            ),
          ],
        ),
      ),
    );
  }

  String parseDuration(int sec) {
    // 转为时分秒
    var h = sec ~/ 3600;
    var m = (sec % 3600) ~/ 60;
    var s = sec % 60;
    if (h > 0) {
      return "${h.toString().padLeft(2, '0')}小时${m.toString().padLeft(2, '0')}分钟${s.toString().padLeft(2, '0')}秒";
    }
    if (m > 0) {
      return "${m.toString().padLeft(2, '0')}分钟${s.toString().padLeft(2, '0')}秒";
    }
    return "${s.toString().padLeft(2, '0')}秒";
  }
}
