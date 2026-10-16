import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/widgets/net_image.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'dart:ui' as ui;

class FollowUserItem extends StatelessWidget {
  final FollowUser item;
  final Function()? onRemove;
  final Function()? onTap;
  final Function()? onLongPress;
  final bool playing;
  const FollowUserItem({
    required this.item,
    this.onRemove,
    this.onTap,
    this.onLongPress,
    this.playing = false,
    Key? key,
  }) : super(key: key);

  /// 未开播卡片的整体不透明度
  ///
  /// 层级用透明度表达，而不是给某段文字上强调色 —— 否则整屏唯一的高饱和
  /// 文字会落在「上次开播多久」上，把注意力从正在直播的卡片抢走。
  /// 下限别低于 0.5，否则文字可读性会崩。
  static const double offlineOpacity = 0.65;

  @override
  Widget build(BuildContext context) {
    var site = Sites.allSites[item.siteId]!;
    var tile = ListTile(
      contentPadding: AppStyle.edgeInsetsL16.copyWith(right: 4),
      leading: NetImage(
        item.face,
        width: 48,
        height: 48,
        borderRadius: 24,
      ),
      title: Text.rich(
        TextSpan(
          text: item.userName,
          children: [
            WidgetSpan(
              alignment: ui.PlaceholderAlignment.middle,
              child: Obx(
                () => Offstage(
                  offstage: item.liveStatus.value == 0,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AppStyle.hGap12,
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: item.roomNotFound
                              ? Colors.orange
                              : item.liveStatus.value == 2
                                  ? Colors.green
                                  : Colors.grey,
                          borderRadius: AppStyle.radius12,
                        ),
                      ),
                      AppStyle.hGap4,
                      Text(
                        getStatus(item.liveStatus.value),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.normal,
                          color:
                              item.liveStatus.value == 2 ? null : Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      subtitle: Wrap(
        runSpacing: 1.0,
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
            overflow: TextOverflow.ellipsis,
          ),
          if (playing)
            Padding(
              padding: AppStyle.edgeInsetsL8,
              child: Text(
                "正在观看",
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            )
          else if (item.liveStatus.value == 2 && item.liveStartTime != null)
            Padding(
              padding: AppStyle.edgeInsetsL8,
              child: Text(
                '开播了${formatLiveDuration(item.liveStartTime)}',
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.grey,
                ),
              ),
            )
          // 未开播：只显示「上次开播 X 前」，具体时间只在直播间页面显示
          else if (item.liveStatus.value == 1 && item.lastLiveTime != null)
            Padding(
              padding: AppStyle.edgeInsetsL8,
              child: Text.rich(
                TextSpan(
                  children: [
                    const TextSpan(
                      text: '上次开播 ',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    TextSpan(
                      text: LiveDuration.agoText(item.lastLiveTime),
                      // 中性灰：强调色留给「状态/可点击」，不留给「过去多久」
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.grey,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
      trailing: playing
          ? const SizedBox(
              width: 64,
              child: Center(
                child: Icon(
                  Icons.play_arrow,
                ),
              ),
            )
          : (onRemove == null
              ? null
              : IconButton(
                  onPressed: () {
                    onRemove?.call();
                  },
                  icon: const Icon(Remix.dislike_line),
                )),
      onTap: onTap,
      onLongPress: onLongPress,
    );

    // 未开播（status==1）整行降权：扫视规则变成「亮的=在播、暗的=没播」。
    // status 0（读取中）不降权，避免启动时先暗后亮地闪一下；
    // 正在观看 / 房间失效的卡片也不降权，别把当前项压暗。
    return Obx(
      () => Opacity(
        opacity: (item.liveStatus.value == 1 &&
                !playing &&
                !item.roomNotFound)
            ? offlineOpacity
            : 1.0,
        child: tile,
      ),
    );
  }

  String getStatus(int status) {
    if (item.roomNotFound) {
      return "房间已失效";
    }
    if (status == 0) {
      return "读取中";
    } else if (status == 1) {
      return "未开播";
    } else {
      return "直播中";
    }
  }

  String formatLiveDuration(String? startTimeStampString) {
    if (startTimeStampString == null ||
        startTimeStampString.isEmpty ||
        startTimeStampString == "0") {
      return "";
    }
    try {
      int startTimeStamp = int.parse(startTimeStampString);
      int currentTimeStamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      int durationInSeconds = currentTimeStamp - startTimeStamp;

      int hours = durationInSeconds ~/ 3600;
      int minutes = (durationInSeconds % 3600) ~/ 60;

      String hourText = hours > 0 ? '$hours小时' : '';
      String minuteText = minutes > 0 ? '$minutes分钟' : '';

      if (hours == 0 && minutes == 0) {
        return "不足1分钟";
      }

      return '$hourText$minuteText';
    } catch (e) {
      Log.logPrint('格式化开播时长出错: $e');
      return "--小时--分钟";
    }
  }
}
