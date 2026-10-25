import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:share_plus/share_plus.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/services/background_playback.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/douyu_account_service.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/modules/live_room/player/player_controller.dart';
import 'package:simple_live_app/modules/settings/danmu_settings_page.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/widgets/desktop_refresh_button.dart';
import 'package:simple_live_app/widgets/follow_user_item.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// 画面内 SC 卡片的展示状态
///
/// 关键：**显示到什么时候记在数据层**（[expireAt]），UI 只负责渲染 ——
/// 这样切全屏、转屏、布局重建都不会把 15 秒重新计时。
class OverlaySuperChat {
  final LiveSuperChatMessage message;
  final DateTime expireAt;
  OverlaySuperChat(this.message, this.expireAt);

  /// 剩余秒数（不会小于 0）
  int get remainSeconds {
    var s = expireAt.difference(DateTime.now()).inSeconds;
    return s < 0 ? 0 : s;
  }

  /// 剩余比例，用于进度条
  double get progress =>
      (remainSeconds / LiveRoomController.overlaySuperChatSeconds)
          .clamp(0.0, 1.0);
}

class LiveRoomController extends PlayerController with WidgetsBindingObserver {
  final Site pSite;
  final String pRoomId;
  late LiveDanmaku liveDanmaku;
  LiveRoomController({
    required this.pSite,
    required this.pRoomId,
  }) {
    rxSite = pSite.obs;
    rxRoomId = pRoomId.obs;
    liveDanmaku = site.liveSite.getDanmaku();
    canSendDanmaku.value = liveDanmaku.canSendDanmaku;
    // 抖音应该默认是竖屏的
    if (site.id == "douyin") {
      isVertical.value = true;
    }
  }

  late Rx<Site> rxSite;
  Site get site => rxSite.value;
  late Rx<String> rxRoomId;
  String get roomId => rxRoomId.value;

  Rx<LiveRoomDetail?> detail = Rx<LiveRoomDetail?>(null);
  var online = 0.obs;
  var followed = false.obs;
  var liveStatus = false.obs;
  RxList<LiveSuperChatMessage> superChats = RxList<LiveSuperChatMessage>();

  /// 画面内 SC 卡片显示时长（秒，固定）
  static const int overlaySuperChatSeconds = 15;

  /// 画面内 SC 最多同时显示几条
  static const int overlaySuperChatMaxCount = 4;

  /// 画面内 SC 展示列表（过期时间由数据层决定，UI 只渲染）
  RxList<OverlaySuperChat> overlaySuperChats = <OverlaySuperChat>[].obs;

  Timer? _overlayScTimer;

  /// 滚动控制
  final ScrollController scrollController = ScrollController();

  /// 聊天信息
  RxList<LiveMessage> messages = RxList<LiveMessage>();

  /// 是否「确认拿不到播放地址」（未开播 / 大航海等付费限定 / 取流失败）
  ///
  /// 只在取流流程结束后才置 true —— 用它控制兜底封面，
  /// 不能直接用 playUrls.isEmpty，否则每次进房加载时都会闪一下封面
  var playUrlEmpty = false.obs;

  /// 清晰度数据
  RxList<LivePlayQuality> qualites = RxList<LivePlayQuality>();

  /// 当前清晰度
  var currentQuality = -1;
  var currentQualityInfo = "".obs;

  /// 线路数据
  RxList<String> playUrls = RxList<String>();

  Map<String, String>? playHeaders;

  /// 当前线路
  var currentLineIndex = -1;
  var currentLineInfo = "".obs;

  /// 退出倒计时
  var countdown = 60.obs;

  Timer? autoExitTimer;

  /// 设置的自动关闭时间（分钟）
  var autoExitMinutes = 60.obs;

  ///是否延迟自动关闭
  var delayAutoExit = false.obs;

  /// 是否启用自动关闭
  var autoExitEnable = false.obs;

  /// 是否禁用自动滚动聊天栏
  /// - 当用户向上滚动聊天栏时，不再自动滚动
  var disableAutoScroll = false.obs;

  /// 是否处于后台
  var isBackground = false;

  /// 直播间加载失败
  var loadError = false.obs;
  Error? error;

  // 开播时长状态变量
  var liveDuration = "00:00:00".obs;
  Timer? _liveDurationTimer;

  @override
  void onInit() {
    WidgetsBinding.instance.addObserver(this);
    if (FollowService.instance.followList.isEmpty) {
      FollowService.instance.loadData();
    }
    initAutoExit();
    showDanmakuState.value = AppSettingsController.instance.danmuEnable.value;
    followed.value = DBService.instance.getFollowExist("${site.id}_$roomId");
    loadData();

    scrollController.addListener(scrollListener);

    // 后台播放：跟随播放状态启停前台服务。
    // 开始播放时 App 还在前台，满足 Android 12+ 「禁止从后台启动前台服务」的限制。
    _bgPlayingSubscription = player.stream.playing.listen((playing) {
      // 界面据此判断"确实在播"：避免切线路失败时误显示未开播卡片
      playerPlaying.value = playing;
      if (playing) {
        // 只有稳定播放超过 20 秒才重置断流退避计数：
        // 否则「播 1 秒就断」也会把计数清零 → 永远用最短延迟重连 → 高频重连被 CDN 限流
        if (_lastOpenTime != null &&
            DateTime.now().difference(_lastOpenTime!) >
                const Duration(seconds: 20)) {
          _streamEndReconnects = 0;
        }
        _reconnectToken += 1;
        syncBackgroundPlayback();
      } else {
        BackgroundPlayback.stop();
      }
    });

    super.onInit();
  }

  void scrollListener() {
    if (scrollController.position.userScrollDirection ==
        ScrollDirection.forward) {
      disableAutoScroll.value = true;
    }
  }

  /// 初始化自动关闭倒计时
  void initAutoExit() {
    if (AppSettingsController.instance.autoExitEnable.value) {
      autoExitEnable.value = true;
      autoExitMinutes.value =
          AppSettingsController.instance.autoExitDuration.value;
      setAutoExit();
    } else {
      autoExitMinutes.value =
          AppSettingsController.instance.roomAutoExitDuration.value;
    }
  }

  void setAutoExit() {
    if (!autoExitEnable.value) {
      autoExitTimer?.cancel();
      return;
    }
    autoExitTimer?.cancel();
    countdown.value = autoExitMinutes.value * 60;
    autoExitTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      countdown.value -= 1;
      if (countdown.value <= 0) {
        timer = Timer(const Duration(seconds: 10), () async {
          await WakelockPlus.disable();
          exit(0);
        });
        autoExitTimer?.cancel();
        var delay = await Utils.showAlertDialog("定时关闭已到时,是否延迟关闭?",
            title: "延迟关闭", confirm: "延迟", cancel: "关闭", selectable: true);
        if (delay) {
          timer.cancel();
          delayAutoExit.value = true;
          showAutoExitSheet();
          setAutoExit();
        } else {
          delayAutoExit.value = false;
          await WakelockPlus.disable();
          exit(0);
        }
      }
    });
  }
  // 弹窗逻辑

  void refreshRoom() {
    //messages.clear();
    superChats.clear();
    liveDanmaku.stop();

    loadData();
  }

  /// 聊天栏始终滚动到底部
  void chatScrollToBottom() {
    if (scrollController.hasClients) {
      // 如果手动上拉过，就不自动滚动到底部
      if (disableAutoScroll.value) {
        return;
      }
      scrollController.jumpTo(scrollController.position.maxScrollExtent);
    }
  }

  /// 初始化弹幕接收事件
  void initDanmau() {
    liveDanmaku.onMessage = onWSMessage;
    liveDanmaku.onClose = onWSClose;
    liveDanmaku.onReady = onWSReady;
  }

  /// 接收到WebSocket信息
  void onWSMessage(LiveMessage msg) {
    if (msg.type == LiveMessageType.chat) {
      if (messages.length > 200 && !disableAutoScroll.value) {
        messages.removeAt(0);
      }

      // 关键词屏蔽检查
      for (var keyword in AppSettingsController.instance.shieldList) {
        Pattern? pattern;
        if (Utils.isRegexFormat(keyword)) {
          String removedSlash = Utils.removeRegexFormat(keyword);
          try {
            pattern = RegExp(removedSlash);
          } catch (e) {
            // should avoid this during add keyword
            Log.d("关键词：$keyword 正则格式错误");
          }
        } else {
          pattern = keyword;
        }
        if (pattern != null && msg.message.contains(pattern)) {
          Log.d("关键词：$keyword\n已屏蔽消息内容：${msg.message}");
          return;
        }
      }

      messages.add(msg);

      WidgetsBinding.instance.addPostFrameCallback(
        (_) => chatScrollToBottom(),
      );
      if (!liveStatus.value || isBackground) {
        return;
      }

      // 表情弹幕：把富文本片段一起传下去，悬浮弹幕也能显示表情图（默认开启）
      final contentParts = msg.spans
          ?.map(
            (e) => e.isImage
                ? DanmakuContentPart.image(e.imageUrl!.trim())
                : DanmakuContentPart.text(e.text ?? ""),
          )
          .toList();
      addDanmaku([
        DanmakuContentItem(
          msg.message,
          color: Color.fromARGB(
            255,
            msg.color.r,
            msg.color.g,
            msg.color.b,
          ),
          // 自己发的弹幕：库会自动加描边 + 强制占一条轨道（保证看得见）
          selfSend: msg.isSelf,
          imageUrls: msg.imageUrls,
          parts: (contentParts == null || contentParts.isEmpty)
              ? null
              : contentParts,
        ),
      ]);
    } else if (msg.type == LiveMessageType.online) {
      online.value = msg.data;
    } else if (msg.type == LiveMessageType.superChat) {
      superChats.add(msg.data);
      addOverlaySuperChat(msg.data);
    }
  }

  /// 全屏下的弹幕输入条是否显示（按回车或点控制条按钮唤起）
  var showDanmakuInput = false.obs;

  /// 正在输入弹幕（打字时控制条不要自动隐藏）
  bool danmakuTyping = false;

  /// 弹幕输入草稿：横竖屏切换/全屏进出时输入框会重建，靠它保留未发送内容
  var danmakuDraft = "".obs;

  /// 后台播放用的播放状态订阅
  StreamSubscription<bool>? _bgPlayingSubscription;

  /// 是否只播放声音
  bool get audioOnly => AppSettingsController.instance.playerAudioOnly.value;

  /// 按「允许后台播放」开关同步前台服务
  ///
  /// 关闭开关时立刻停服务（通知随之消失）；打开开关时如果正在播放就马上起服务。
  void syncBackgroundPlayback() {
    if (!AppSettingsController.instance.playerBackgroundPlay.value) {
      BackgroundPlayback.stop();
      return;
    }
    var user = detail.value?.userName ?? "";
    var title = detail.value?.title ?? "";
    var text = user.isEmpty ? title : "$user · $title";
    BackgroundPlayback.start(text.isEmpty ? "正在后台播放" : text);
  }

  /// 加大 mpv 缓冲与网络超时，减少「卡一下就切线路」
  Future<void> applyNetworkBuffering() async {
    var platform = player.platform;
    if (platform is NativePlayer) {
      // 注意：不要设 cache / cache-secs —— Windows 版 mpv 会反复报
      // 「lavf: Failed to create file cache.」反而更不稳，实测去掉更好
      var options = {
        'demuxer-readahead-secs': '20',
        'demuxer-max-bytes': '64MiB',
        'demuxer-max-back-bytes': '32MiB',
        'network-timeout': '30',
      };
      for (var entry in options.entries) {
        try {
          // 加超时：mpv 处于异常状态时 setProperty 可能一直不返回
          await platform
              .setProperty(entry.key, entry.value)
              .timeout(const Duration(seconds: 2));
        } catch (e) {
          Log.logPrint('设置 mpv 参数 ${entry.key} 失败：$e');
        }
      }
    }
  }

  /// 「只播放声音」：用 mpv 的 vid 属性关掉/恢复视频解码
  ///
  /// 只关解码、不动音频管线，所以画面消失但声音不断；
  /// 直播流一般没有独立音轨，清晰度会在 getPlayQualites() 里降到最低。
  Future<void> applyAudioOnly() async {
    var platform = player.platform;
    if (platform is NativePlayer) {
      try {
        await platform.setProperty('vid', audioOnly ? 'no' : 'auto');
      } catch (e) {
        Log.logPrint('切换只播放声音失败：$e');
      }
    }
    // 音频线路联动：开启时真正切到音频线路，关闭时回到视频线路
    if (audioLineIndex != null) {
      if (audioOnly && currentLineIndex != audioLineIndex) {
        changePlayLine(audioLineIndex!);
      } else if (!audioOnly && currentLineIndex == audioLineIndex) {
        changePlayLine(0);
      }
    }
  }

  /// 当前房间是否支持发送弹幕（由平台的弹幕实现决定）
  ///
  /// 必须是 Observable：房间加载 / 切换后能力可能变化，
  /// 若直接读 [liveDanmaku].canSendDanmaku，UI 不会自动刷新，
  /// 就会出现「要进出一次全屏才显示输入框」的问题。
  var canSendDanmaku = false.obs;

  /// 上次发送弹幕的时间（本地节流，避免撞平台风控）
  DateTime? _lastSendTime;

  /// 弹幕会话被其他设备接管（斗鱼单会话限制）：显示状态条引导重新登录
  var danmakuSessionLost = false.obs;

  /// 斗鱼发送前提示：发送会接管账号的弹幕会话，可能断开其他设备的弹幕
  /// 返回 true = 继续发送；false = 用户取消
  Future<bool> _confirmDouyuSession() async {
    var noMore = false;
    var result = await SmartDialog.show<bool>(
      clickMaskDismiss: false,
      builder: (_) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text("发送弹幕会接管账号的弹幕会话"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "其他设备（浏览器 / 官方客户端）的弹幕连接会被断开，直到它们点「重试」。",
              ),
              AppStyle.vGap8,
              Row(
                children: [
                  Checkbox(
                    value: noMore,
                    onChanged: (v) {
                      setState(() => noMore = v ?? false);
                    },
                  ),
                  const Expanded(
                    child: Text("不再提示（可在「设置 - 播放设置」中恢复）"),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => SmartDialog.dismiss(result: false),
              child: const Text("取消"),
            ),
            TextButton(
              onPressed: () => SmartDialog.dismiss(result: true),
              child: const Text("继续发送"),
            ),
          ],
        ),
      ),
    );
    if (noMore) {
      AppSettingsController.instance.setDanmakuSendKickWarn(false);
    }
    return result ?? false;
  }

  /// 发送弹幕：成功返回 null，失败返回可展示的原因
  Future<String?> sendDanmaku(String text) async {
    var message = text.trim();
    if (message.isEmpty) {
      return "弹幕内容不能为空";
    }
    if (!AppSettingsController.instance.playerSendDanmaku.value) {
      return "请先在「设置 - 播放设置」里打开「允许发送弹幕」";
    }
    if (!liveDanmaku.canSendDanmaku) {
      return "当前平台暂不支持发送弹幕";
    }
    if (!liveStatus.value) {
      return "主播未开播，无法发送弹幕";
    }
    var loginTip = _loginCheck();
    if (loginTip != null) {
      return loginTip;
    }
    var last = _lastSendTime;
    if (last != null && DateTime.now().difference(last).inSeconds < 2) {
      return "发送太快了，请稍后再试";
    }
    // 斗鱼：发送会抢会话，先确认（用户可勾"不再提示"）
    if (site.id == Constant.kDouyu &&
        AppSettingsController.instance.danmakuSendKickWarn.value) {
      var go = await _confirmDouyuSession();
      if (!go) {
        // 空字符串 = 用户主动取消，输入框保留内容、不弹错误
        return "";
      }
    }
    var error = await liveDanmaku.sendDanmaku(message);
    if (error == null) {
      _lastSendTime = DateTime.now();
      danmakuSessionLost.value = false;
    } else if (error.contains("4206") ||
        error.contains("4205") ||
        error.contains("已过期") ||
        error.contains("被接管")) {
      danmakuSessionLost.value = true;
    }
    return error;
  }

  /// 未登录时返回提示，已登录返回 null
  String? _loginCheck() {
    if (site.id == Constant.kBiliBili &&
        !BiliBiliAccountService.instance.logined.value) {
      return "请先登录哔哩哔哩";
    }
    if (site.id == Constant.kDouyu &&
        !DouyuAccountService.instance.logined.value) {
      return "请先登录斗鱼";
    }
    return null;
  }

  /// 添加一条系统消息
  void addSysMsg(String msg) {
    messages.add(
      LiveMessage(
        type: LiveMessageType.chat,
        userName: "LiveSysMessage",
        message: msg,
        color: LiveMessageColor.white,
      ),
    );
  }

  /// 接收到WebSocket关闭信息
  void onWSClose(String msg) {
    addSysMsg(msg);
  }

  /// WebSocket准备就绪
  void onWSReady() {
    addSysMsg("弹幕服务器连接正常");
  }

  /// 加载直播间信息
  void loadData() async {
    try {
      SmartDialog.showLoading(msg: "");
      loadError.value = false;
      error = null;
      update();
      addSysMsg("正在读取直播间信息");
      detail.value = await site.liveSite.getRoomDetail(roomId: roomId);

      // 把最新状态同步回关注列表，避免两边数据不一致
      FollowService.instance.syncRoomStatus(
        siteId: site.id,
        requestedRoomId: roomId,
        detail: detail.value!,
      );

      if (site.id == Constant.kDouyin) {
        // 1.6.0之前收藏的WebRid
        // 1.6.0收藏的RoomID
        // 1.6.0之后改回WebRid
        if (detail.value!.roomId != roomId) {
          var oldId = roomId;
          rxRoomId.value = detail.value!.roomId;
          if (followed.value) {
            // 更新关注列表
            DBService.instance.deleteFollow("${site.id}_$oldId");
            DBService.instance.addFollow(
              FollowUser(
                id: "${site.id}_$roomId",
                roomId: roomId,
                siteId: site.id,
                userName: detail.value!.userName,
                face: detail.value!.userAvatar,
                addTime: DateTime.now(),
              ),
            );
          } else {
            followed.value =
                DBService.instance.getFollowExist("${site.id}_$roomId");
          }
        }
      }

      getSuperChatMessage();

      addHistory();
      // 确认房间关注状态
      followed.value = DBService.instance.getFollowExist("${site.id}_$roomId");
      online.value = detail.value!.online;
      liveStatus.value = detail.value!.status || detail.value!.isRecord;
      // 换房间/重新加载时先复位，避免上一个直播间的大航海封面残留
      playUrlEmpty.value = false;
      if (liveStatus.value) {
        getPlayQualites();
      }
      if (detail.value!.isRecord) {
        addSysMsg("当前主播未开播，正在轮播录像");
      }
      addSysMsg("开始连接弹幕服务器");
      initDanmau();
      liveDanmaku.start(detail.value?.danmakuData);
      // 平台能力可能要到 start() 之后才明确，同步一次让输入框即时出现
      canSendDanmaku.value = liveDanmaku.canSendDanmaku;
      startLiveDurationTimer(); // 启动开播时长定时器
    } catch (e) {
      Log.logPrint(e);
      //SmartDialog.showToast(e.toString());
      loadError.value = true;
      error = e as Error;
    } finally {
      SmartDialog.dismiss(status: SmartStatus.loading);
    }
  }

  /// 初始化播放器
  void getPlayQualites() async {
    qualites.clear();
    currentQuality = -1;

    try {
      var playQualites =
          await site.liveSite.getPlayQualites(detail: detail.value!);

      if (playQualites.isEmpty) {
        SmartDialog.showToast("无法读取播放清晰度");
        return;
      }
      qualites.value = playQualites;
      var qualityLevel = await getQualityLevel();
      if (audioOnly) {
        // 「只播放声音」：直接取最低清晰度，省电、省流量
        currentQuality = playQualites.length - 1;
      } else if (qualityLevel == 2) {
        //最高
        currentQuality = 0;
      } else if (qualityLevel == 0) {
        //最低
        currentQuality = playQualites.length - 1;
      } else {
        //中间值
        int middle = (playQualites.length / 2).floor();
        currentQuality = middle;
      }

      getPlayUrl();
    } catch (e) {
      // B站的大航海/付费限定在 getPlayQualites 里抛出（没有 playurl）
      playUrlEmpty.value = e is CoreError && e.statusCode == 403;
      Log.logPrint(e);
      SmartDialog.showToast(e is CoreError ? e.message : "无法读取播放清晰度");
    }
  }

  Future<int> getQualityLevel() async {
    var qualityLevel = AppSettingsController.instance.qualityLevel.value;
    try {
      var connectivityResult = await (Connectivity().checkConnectivity());
      if (connectivityResult.first == ConnectivityResult.mobile) {
        qualityLevel =
            AppSettingsController.instance.qualityLevelCellular.value;
      }
    } catch (e) {
      Log.logPrint(e);
    }
    return qualityLevel;
  }

  Future<void> getPlayUrl() async {
    if (detail.value == null || qualites.isEmpty || currentQuality < 0) {
      return;
    }
    playUrlEmpty.value = false;
    currentQualityInfo.value = qualites[currentQuality].quality;
    // 关键：先拿到结果再覆盖状态。
    // 以前是「先 playUrls.clear() + 清空线路名」，取流一旦失败就直接 return，
    // 界面会变成「没有线路」且播放彻底停住 —— 也就是用户看到的"突然没线路了"。
    final previousLines = playUrls.toList();
    try {
      var playUrl = await site.liveSite.getPlayUrls(
          detail: detail.value!, quality: qualites[currentQuality]);
      if (playUrl.urls.isEmpty) {
        SmartDialog.showToast("无法读取播放地址");
        await replayWithPrevious(previousLines);
        return;
      }
      playUrls.value = playUrl.urls;
      playHeaders = playUrl.headers;
      audioLineIndex = playUrl.audioLineIndex;
    } catch (e) {
      // 只有大航海/付费限定（403）才盖兜底封面
      playUrlEmpty.value = e is CoreError && e.statusCode == 403;
      Log.logPrint(e);
      SmartDialog.showToast(e is CoreError ? e.message : "无法读取播放地址");
      // 取流失败也不要让播放死掉：退回上一次拿到的地址继续播
      await replayWithPrevious(previousLines);
      return;
    }
    // 保留用户当前选择的线路；只有下标失效（首次加载 / 线路列表变了）时才自动选：
    // 「只播放声音」开启且平台有音频线路 → 优先音频线路
    if (currentLineIndex < 0 || currentLineIndex >= playUrls.length) {
      currentLineIndex =
          (audioOnly && audioLineIndex != null) ? audioLineIndex! : 0;
    }
    currentLineInfo.value = lineLabel(currentLineIndex);
    //重置错误次数
    mediaErrorRetryCount = 0;
    await initPlaylist();
  }

  /// 取流失败时的兜底：用上一次的地址继续播，避免播放直接死掉
  Future<void> replayWithPrevious(List<String> previousLines) async {
    if (playUrls.isEmpty && previousLines.isNotEmpty) {
      playUrls.value = previousLines;
    }
    if (playUrls.isEmpty) {
      currentLineInfo.value = "";
      return;
    }
    if (currentLineIndex < 0 || currentLineIndex >= playUrls.length) {
      currentLineIndex = 0;
    }
    currentLineInfo.value = lineLabel(currentLineIndex);
    await initPlaylist();
  }

  /// [fromUser] = 用户在界面上主动点的线路（内部自动跳线路时传 false）
  void changePlayLine(int index, {bool fromUser = false}) {
    // 模式跟着线路走：选音频线路 → 开「只播放声音」；选视频线路 → 关
    if (fromUser && audioLineIndex != null) {
      AppSettingsController.instance.setPlayerAudioOnly(index == audioLineIndex);
    }
    currentLineIndex = index;
    //重置错误次数
    mediaErrorRetryCount = 0;
    setPlayer();
  }

  Future<void> initPlaylist() async {
    currentLineInfo.value = lineLabel(currentLineIndex);
    errorMsg.value = "";

    // 只把「当前线路」放进播放列表。
    // 以前把全部线路塞进 Playlist，mpv 在流结束/出错时会自动播放下一条 ——
    // 表现就是「没人操作却一直在切线路」（日志里每隔几秒换一个 CDN）。
    if (playUrls.isEmpty ||
        currentLineIndex < 0 ||
        currentLineIndex >= playUrls.length) {
      return;
    }
    var currentUrl = playUrls[currentLineIndex];
    if (AppSettingsController.instance.playerForceHttps.value) {
      currentUrl = currentUrl.replaceAll("http://", "https://");
    }
    final mediaList = [Media(currentUrl, httpHeaders: playHeaders)];

    // 初始化播放器并设置 ao 参数
    await initializePlayer();

    // 加大 mpv 缓冲与网络超时：桌面端网络一抖就会卡顿 → 被判定线路失效 → 一直切线路，
    // 这里给足缓冲（在 open 之前设置才生效），不影响起播速度
    await applyNetworkBuffering();

    // 加超时：播放器异常/代理挂住时 open 可能一直不返回，导致界面卡死在"没有线路"
    try {
      await player
          .open(Playlist(mediaList))
          .timeout(const Duration(seconds: 12));
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("起播超时，正在重试");
    }

    // 每次重新拉流后都要重新应用「只播放声音」（切线路/清晰度会重置）
    await applyAudioOnly();
    _lastOpenTime = DateTime.now();
  }

  /// 用当前线路重新起播（播放列表里只有当前线路一条，所以直接重建播放列表）
  Future<void> setPlayer() async {
    await initPlaylist();
  }

  /// 直播流被正常断开后的重连计数（与 mediaError 的失败计数分开）
  int _streamEndReconnects = 0;

  /// 重连看门狗令牌：播放恢复或发起新重连时自增，让旧的看门狗失效
  int _reconnectToken = 0;

  /// 最近一次起播时间：用于判断"刚连上就被重置"（说明这条 CDN 不通，应立刻换线）
  DateTime? _lastOpenTime;

  /// 线路切换熔断记录：1 分钟内切换超过 6 次就停下来等网络恢复，
  /// 否则会出现「切线路→起播→立刻被重置→再切」的自激循环（实测每秒切好几次）
  final List<DateTime> _lineSwitchTimes = [];

  bool allowLineSwitch() {
    var now = DateTime.now();
    _lineSwitchTimes.removeWhere((t) => now.difference(t).inSeconds > 60);
    return _lineSwitchTimes.length < 6;
  }

  void recordLineSwitch() => _lineSwitchTimes.add(DateTime.now());

  /// 重连互斥：防止 mediaEnd / mediaError / 看门狗 并发重复打开播放器
  bool _replaying = false;

  @override
  void mediaEnd() async {
    super.mediaEnd();
    // 直播流被 CDN 正常断开（斗鱼大约每 300MB 断一次）或播放地址已过期。
    // 网页播放器每次都会重新向平台要一个「新地址」再连，这里照做：
    // 复用旧地址会因为 wsAuth 失效只拿到几十 KB，最后被误判成「线路坏了」而切线路。
    final delays = [0, 1, 2, 3, 5, 8, 15];
    var attempt = _streamEndReconnects;
    if (attempt >= delays.length) {
      attempt = delays.length - 1;
    }
    _streamEndReconnects += 1;
    Log.d("播放结束，${delays[attempt]}s 后重新取流并重连（第 $_streamEndReconnects 次）");
    await Future.delayed(Duration(seconds: delays[attempt]));
    await refreshUrlAndReplay();

    // 看门狗：20 秒后仍未恢复播放，说明重连卡住/失败 → 换下一条线路或再试一次，
    // 避免停在"没有线路"的死状态。播放恢复/发起新重连时令牌变化，它自动失效。
    // 注意：要和重连互斥、熔断器保持一致，否则会和正在进行的重连打架。
    final token = ++_reconnectToken;
    Future.delayed(const Duration(seconds: 20), () {
      if (token != _reconnectToken || playerPlaying.value || _replaying) {
        return;
      }
      if (!allowLineSwitch()) {
        Log.d("看门狗：1 分钟内切线路过多，暂停切换，20 秒后再试当前线路");
        Future.delayed(const Duration(seconds: 20), () => setPlayer());
        return;
      }
      Log.d("重连后 20 秒仍未播放，尝试切换线路");
      if (playUrls.length > 1 && currentLineIndex < playUrls.length - 1) {
        recordLineSwitch();
        changePlayLine(currentLineIndex + 1);
      } else {
        setPlayer();
      }
    });
  }

  /// 重新向平台请求播放地址，并用**当前线路**重连
  Future<void> refreshUrlAndReplay() async {
    // 互斥：避免多个失败回调并发取流/打开播放器，导致自己取消自己
    if (_replaying) {
      Log.d("上一次重连还没结束，跳过本次");
      return;
    }
    _replaying = true;
    try {
      if (detail.value == null || qualites.isEmpty || currentQuality < 0) {
        await setPlayer();
        return;
      }
      try {
        // getPlayUrl() 内部会重新请求取流接口并调用 initPlaylist()，
        // 同时保留当前线路（只有下标失效时才自动选）
        await getPlayUrl();
      } catch (e) {
        Log.logPrint(e);
        await setPlayer();
      }
    } finally {
      _replaying = false;
    }
  }

  /// 播放器当前是否真的在播放
  var playerPlaying = false.obs;

  /// 音频线路在 playUrls 里的下标（null = 当前平台没有音频线路）
  int? audioLineIndex;

  /// 线路名称：音频线路单独标注（带耳机）
  String lineLabel(int index) =>
      index == audioLineIndex ? "🎧 音频线路" : "线路${index + 1}";

  int mediaErrorRetryCount = 0;
  @override
  void mediaError(String error) async {
    super.mediaEnd();

    // 刚起播 3 秒内就被重置：大概率这条 CDN 在当前网络下不可用，
    // 不再对它重试（每秒一次的高频重连还会被 CDN 当成异常流量），直接换下一条线路
    final justOpened = _lastOpenTime != null &&
        DateTime.now().difference(_lastOpenTime!) < const Duration(seconds: 3);
    if (justOpened) {
      mediaErrorRetryCount = 0;
      if (!allowLineSwitch()) {
        // 熔断：短时间内已切太多次，停止切线路，等网络恢复后再试
        Log.d("1 分钟内切换线路过于频繁，暂停切换，10 秒后重试当前线路");
        errorMsg.value = "网络不稳定，正在等待恢复…";
        SmartDialog.showToast("网络不稳定，正在等待恢复");
        await Future.delayed(const Duration(seconds: 10));
        await setPlayer();
        return;
      }
      Log.d("起播后 3 秒内即被重置，直接切换线路");
      recordLineSwitch();
      if (playUrls.length - 1 <= currentLineIndex) {
        errorMsg.value = "播放失败";
        SmartDialog.showToast("播放失败:$error");
      } else {
        changePlayLine(currentLineIndex + 1);
      }
      return;
    }

    if (mediaErrorRetryCount < 4) {
      Log.d("播放失败，尝试第${mediaErrorRetryCount + 1}次刷新");
      // 重连间隔从 2 秒起（1 秒一次的高频重连容易被 CDN 限流）
      await Future.delayed(Duration(seconds: (mediaErrorRetryCount + 1) * 2));
      mediaErrorRetryCount += 1;
      // 重试时也重新取一次地址（旧 token 可能已失效）
      await refreshUrlAndReplay();
      return;
    }

    // 重试与新地址都失败：重置计数，作为最后手段切到下一条线路
    mediaErrorRetryCount = 0;
    if (playUrls.length - 1 <= currentLineIndex) {
      errorMsg.value = "播放失败";
      SmartDialog.showToast("播放失败:$error");
    } else {
      changePlayLine(currentLineIndex + 1);
    }
  }

  /// 添加一条画面内 SC（已到期的不会加入）
  void addOverlaySuperChat(LiveSuperChatMessage sc, {int? maxSeconds}) {
    if (overlaySuperChats.any((e) => e.message == sc)) {
      return;
    }
    var seconds = maxSeconds ?? overlaySuperChatSeconds;
    if (seconds <= 0) {
      return;
    }
    overlaySuperChats.add(
      OverlaySuperChat(sc, DateTime.now().add(Duration(seconds: seconds))),
    );
    // 超过上限：立刻移除最旧的一条（最上面那条被顶掉）
    while (overlaySuperChats.length > overlaySuperChatMaxCount) {
      overlaySuperChats.removeAt(0);
    }
    _startOverlayScTimer();
  }

  /// 统一的过期清理：整个页面只有一个 Timer，UI 不再各自计时
  void _startOverlayScTimer() {
    if (_overlayScTimer != null) {
      return;
    }
    _overlayScTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      var now = DateTime.now();
      overlaySuperChats.removeWhere((e) => !e.expireAt.isAfter(now));
      if (overlaySuperChats.isEmpty) {
        _overlayScTimer?.cancel();
        _overlayScTimer = null;
      }
    });
  }

  /// 清空画面内 SC
  void clearOverlaySuperChats() {
    _overlayScTimer?.cancel();
    _overlayScTimer = null;
    overlaySuperChats.clear();
  }

  /// 读取SC
  void getSuperChatMessage() async {
    try {
      var sc =
          await site.liveSite.getSuperChatMessage(roomId: detail.value!.roomId);
      superChats.addAll(sc);
      // 进房时把「B站 上还在展示期」的 SC 也放进画面，
      // 时长取剩余时间与 15 秒的较小值（已到期的不加，避免负数）
      var now = DateTime.now().millisecondsSinceEpoch;
      for (var item in sc) {
        var remain = (item.endTime.millisecondsSinceEpoch - now) ~/ 1000;
        if (remain > 0) {
          addOverlaySuperChat(
            item,
            maxSeconds:
                remain < overlaySuperChatSeconds ? remain : overlaySuperChatSeconds,
          );
        }
      }
    } catch (e) {
      Log.logPrint(e);
      addSysMsg("SC读取失败");
    }
  }

  /// 移除掉已到期的SC
  void removeSuperChats() async {
    var now = DateTime.now().millisecondsSinceEpoch;
    superChats.value = superChats
        .where((x) => x.endTime.millisecondsSinceEpoch > now)
        .toList();
  }

  /// 添加历史记录
  void addHistory() {
    if (detail.value == null) {
      return;
    }
    var id = "${site.id}_$roomId";
    var history = DBService.instance.getHistory(id);
    if (history != null) {
      history.updateTime = DateTime.now();
    }
    history ??= History(
      id: id,
      roomId: roomId,
      siteId: site.id,
      userName: detail.value?.userName ?? "",
      face: detail.value?.userAvatar ?? "",
      updateTime: DateTime.now(),
    );

    DBService.instance.addOrUpdateHistory(history);
  }

  /// 关注用户
  void followUser() {
    if (detail.value == null) {
      return;
    }
    var id = "${site.id}_$roomId";
    DBService.instance.addFollow(
      FollowUser(
        id: id,
        roomId: roomId,
        siteId: site.id,
        userName: detail.value?.userName ?? "",
        face: detail.value?.userAvatar ?? "",
        addTime: DateTime.now(),
      ),
    );
    followed.value = true;
    EventBus.instance.emit(Constant.kUpdateFollow, id);
  }

  /// 取消关注用户
  void removeFollowUser() async {
    if (detail.value == null) {
      return;
    }
    if (!await Utils.showAlertDialog("确定要取消关注该用户吗？", title: "取消关注")) {
      return;
    }

    var id = "${site.id}_$roomId";
    DBService.instance.deleteFollow(id);
    followed.value = false;
    EventBus.instance.emit(Constant.kUpdateFollow, id);
  }

  void share() {
    if (detail.value == null) {
      return;
    }
    SharePlus.instance.share(ShareParams(uri: Uri.parse(detail.value!.url)));
  }

  void copyUrl() {
    if (detail.value == null) {
      return;
    }
    Utils.copyToClipboard(detail.value!.url);
    SmartDialog.showToast("已复制直播间链接");
  }

  /// 复制新生成的直播流
  void copyPlayUrl() async {
    // 未开播不复制
    if (!liveStatus.value) {
      return;
    }
    var playUrl = await site.liveSite
        .getPlayUrls(detail: detail.value!, quality: qualites[currentQuality]);
    if (playUrl.urls.isEmpty) {
      SmartDialog.showToast("无法读取播放地址");
      return;
    }
    Utils.copyToClipboard(playUrl.urls.first);
    SmartDialog.showToast("已复制播放直链");
  }

  /// 底部打开播放器设置
  void showDanmuSettingsSheet() {
    Utils.showBottomSheet(
      title: "弹幕设置",
      child: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          DanmuSettingsView(
            danmakuController: danmakuController,
            onTapDanmuShield: () {
              Get.back();
              showDanmuShield();
            },
          ),
        ],
      ),
    );
  }

  void showVolumeSlider(BuildContext targetContext) {
    SmartDialog.showAttach(
      targetContext: targetContext,
      alignment: Alignment.topCenter,
      displayTime: const Duration(seconds: 3),
      maskColor: const Color(0x00000000),
      builder: (context) {
        return Container(
          decoration: BoxDecoration(
            borderRadius: AppStyle.radius12,
            color: Theme.of(context).cardColor,
          ),
          padding: AppStyle.edgeInsetsA4,
          child: Obx(
            () => SizedBox(
              width: 200,
              child: Slider(
                min: 0,
                max: 100,
                value: AppSettingsController.instance.playerVolume.value,
                onChanged: (newValue) {
                  player.setVolume(newValue);
                  AppSettingsController.instance.setPlayerVolume(newValue);
                },
              ),
            ),
          ),
        );
      },
    );
  }

  void showQualitySheet() {
    Utils.showBottomSheet(
      title: "切换清晰度",
      child: RadioGroup(
        groupValue: currentQuality,
        onChanged: (e) {
          Get.back();
          currentQuality = e ?? 0;
          getPlayUrl();
        },
        child: ListView.builder(
          itemCount: qualites.length,
          itemBuilder: (_, i) {
            var item = qualites[i];
            return RadioListTile(
              value: i,
              title: Text(item.quality),
            );
          },
        ),
      ),
    );
  }

  void showPlayUrlsSheet() {
    Utils.showBottomSheet(
      title: "切换线路",
      child: RadioGroup(
        groupValue: currentLineIndex,
        onChanged: (e) {
          Get.back();
          //currentLineIndex = i;
          //setPlayer();
          changePlayLine(e ?? 0, fromUser: true);
        },
        child: ListView.builder(
          itemCount: playUrls.length,
          itemBuilder: (_, i) {
            return RadioListTile(
              value: i,
              title: Text(lineLabel(i)),
              secondary: Text(
                i == audioLineIndex
                    ? "音频"
                    : (playUrls[i].contains(".flv") ? "FLV" : "HLS"),
              ),
            );
          },
        ),
      ),
    );
  }

  void showPlayerSettingsSheet() {
    Utils.showBottomSheet(
      title: "画面尺寸",
      child: Obx(
        () => RadioGroup(
          groupValue: AppSettingsController.instance.scaleMode.value,
          onChanged: (e) {
            AppSettingsController.instance.setScaleMode(e ?? 0);
            updateScaleMode();
          },
          child: ListView(
            padding: AppStyle.edgeInsetsV12,
            children: const [
              RadioListTile(
                value: 0,
                title: Text("适应"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 1,
                title: Text("拉伸"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 2,
                title: Text("铺满"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 3,
                title: Text("16:9"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 4,
                title: Text("4:3"),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void showDanmuShield() {
    TextEditingController keywordController = TextEditingController();

    void addKeyword() {
      if (keywordController.text.isEmpty) {
        SmartDialog.showToast("请输入关键词");
        return;
      }

      AppSettingsController.instance
          .addShieldList(keywordController.text.trim());
      keywordController.text = "";
    }

    Utils.showBottomSheet(
      title: "关键词屏蔽",
      child: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          TextField(
            controller: keywordController,
            decoration: InputDecoration(
              contentPadding: AppStyle.edgeInsetsH12,
              border: const OutlineInputBorder(),
              hintText: "请输入关键词",
              suffixIcon: TextButton.icon(
                onPressed: addKeyword,
                icon: const Icon(Icons.add),
                label: const Text("添加"),
              ),
            ),
            onSubmitted: (e) {
              addKeyword();
            },
          ),
          AppStyle.vGap12,
          Obx(
            () => Text(
              "已添加${AppSettingsController.instance.shieldList.length}个关键词（点击移除）",
              style: Get.textTheme.titleSmall,
            ),
          ),
          AppStyle.vGap12,
          Obx(
            () => Wrap(
              runSpacing: 12,
              spacing: 12,
              children: AppSettingsController.instance.shieldList
                  .map(
                    (item) => InkWell(
                      borderRadius: AppStyle.radius24,
                      onTap: () {
                        AppSettingsController.instance.removeShieldList(item);
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey),
                          borderRadius: AppStyle.radius24,
                        ),
                        padding: AppStyle.edgeInsetsH12.copyWith(
                          top: 4,
                          bottom: 4,
                        ),
                        child: Text(
                          item,
                          style: Get.textTheme.bodyMedium,
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }

  void showFollowUserSheet() {
    Utils.showBottomSheet(
      title: "关注列表",
      child: Obx(
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
                      playing: rxSite.value.id == item.siteId &&
                          rxRoomId.value == item.roomId,
                      onTap: () {
                        Get.back();
                        resetRoom(
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
      ),
    );
  }

  void showAutoExitSheet() {
    if (AppSettingsController.instance.autoExitEnable.value &&
        !delayAutoExit.value) {
      SmartDialog.showToast("已设置了全局定时关闭");
      return;
    }
    Utils.showBottomSheet(
      title: "定时关闭",
      child: ListView(
        children: [
          Obx(
            () => SwitchListTile(
              title: Text(
                "启用定时关闭",
                style: Get.textTheme.titleMedium,
              ),
              value: autoExitEnable.value,
              onChanged: (e) {
                autoExitEnable.value = e;

                setAutoExit();
                //controller.setAutoExitEnable(e);
              },
            ),
          ),
          Obx(
            () => ListTile(
              enabled: autoExitEnable.value,
              title: Text(
                "自动关闭时间：${autoExitMinutes.value ~/ 60}小时${autoExitMinutes.value % 60}分钟",
                style: Get.textTheme.titleMedium,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                var value = await showTimePicker(
                  context: Get.context!,
                  initialTime: TimeOfDay(
                    hour: autoExitMinutes.value ~/ 60,
                    minute: autoExitMinutes.value % 60,
                  ),
                  initialEntryMode: TimePickerEntryMode.inputOnly,
                  builder: (_, child) {
                    return MediaQuery(
                      data: Get.mediaQuery.copyWith(
                        alwaysUse24HourFormat: true,
                      ),
                      child: child!,
                    );
                  },
                );
                if (value == null || (value.hour == 0 && value.minute == 0)) {
                  return;
                }
                var duration =
                    Duration(hours: value.hour, minutes: value.minute);
                autoExitMinutes.value = duration.inMinutes;
                AppSettingsController.instance
                    .setRoomAutoExitDuration(autoExitMinutes.value);
                //setAutoExitDuration(duration.inMinutes);
                setAutoExit();
              },
            ),
          ),
        ],
      ),
    );
  }

  void openNaviteAPP() async {
    var naviteUrl = "";
    var webUrl = "";
    if (site.id == Constant.kBiliBili) {
      naviteUrl = "bilibili://live/${detail.value?.roomId}";
      webUrl = "https://live.bilibili.com/${detail.value?.roomId}";
    } else if (site.id == Constant.kDouyin) {
      var args = detail.value?.danmakuData as DouyinDanmakuArgs;
      naviteUrl = "snssdk1128://webcast_room?room_id=${args.roomId}";
      webUrl = "https://live.douyin.com/${args.webRid}";
    } else if (site.id == Constant.kHuya) {
      var args = detail.value?.danmakuData as HuyaDanmakuArgs;
      naviteUrl =
          "yykiwi://homepage/index.html?banneraction=https%3A%2F%2Fdiy-front.cdn.huya.com%2Fzt%2Ffrontpage%2Fcc%2Fupdate.html%3Fhyaction%3Dlive%26channelid%3D${args.subSid}%26subid%3D${args.subSid}%26liveuid%3D${args.subSid}%26screentype%3D1%26sourcetype%3D0%26fromapp%3Dhuya_wap%252Fclick%252Fopen_app_guide%26&fromapp=huya_wap/click/open_app_guide";
      webUrl = "https://www.huya.com/${detail.value?.roomId}";
    } else if (site.id == Constant.kDouyu) {
      naviteUrl =
          "douyulink://?type=90001&schemeUrl=douyuapp%3A%2F%2Froom%3FliveType%3D0%26rid%3D${detail.value?.roomId}";
      webUrl = "https://www.douyu.com/${detail.value?.roomId}";
    }
    try {
      await launchUrlString(naviteUrl, mode: LaunchMode.externalApplication);
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("无法打开APP，将使用浏览器打开");
      await launchUrlString(webUrl, mode: LaunchMode.externalApplication);
    }
  }

  void resetRoom(Site site, String roomId) async {
    if (this.site == site && this.roomId == roomId) {
      return;
    }

    rxSite.value = site;
    rxRoomId.value = roomId;

    // 清除全部消息
    liveDanmaku.stop();
    messages.clear();
    superChats.clear();
    clearOverlaySuperChats();
    danmakuController?.clear();

    // 重新设置LiveDanmaku
    liveDanmaku = site.liveSite.getDanmaku();
    canSendDanmaku.value = liveDanmaku.canSendDanmaku;

    // 停止播放
    await player.stop();

    // 刷新信息
    loadData();
  }

  void copyErrorDetail() {
    Utils.copyToClipboard('''直播平台：${rxSite.value.name}
房间号：${rxRoomId.value}
错误信息：
${error?.toString()}
----------------
${error?.stackTrace}''');
    SmartDialog.showToast("已复制错误信息");
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.paused) {
      Log.d("进入后台");
      //进入后台，关闭弹幕
      danmakuController?.clear();
      isBackground = true;
    } else
    //返回前台
    if (state == AppLifecycleState.resumed) {
      Log.d("返回前台");
      isBackground = false;
    }
  }

  // 用于启动开播时长计算和更新的函数
  void startLiveDurationTimer() {
    // 如果不是直播状态或者 showTime 为空，则不启动定时器
    if (!(detail.value?.status ?? false) || detail.value?.showTime == null) {
      liveDuration.value = "00:00:00"; // 未开播时显示 00:00:00
      _liveDurationTimer?.cancel();
      return;
    }

    try {
      int startTimeStamp = int.parse(detail.value!.showTime!);
      // 取消之前的定时器
      _liveDurationTimer?.cancel();
      // 创建新的定时器，每秒更新一次
      _liveDurationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        int currentTimeStamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        int durationInSeconds = currentTimeStamp - startTimeStamp;

        int hours = durationInSeconds ~/ 3600;
        int minutes = (durationInSeconds % 3600) ~/ 60;
        int seconds = durationInSeconds % 60;

        String formattedDuration =
            '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
        liveDuration.value = formattedDuration;
      });
    } catch (e) {
      liveDuration.value = "--:--:--"; // 错误时显示 --:--:--
    }
  }

  @override
  void onClose() {
    WidgetsBinding.instance.removeObserver(this);
    scrollController.removeListener(scrollListener);
    autoExitTimer?.cancel();

    // 离开直播间就不再需要后台播放服务（否则会留下一条常驻通知）
    _bgPlayingSubscription?.cancel();
    BackgroundPlayback.stop();

    liveDanmaku.stop();
    danmakuController = null;
    _liveDurationTimer?.cancel(); // 页面关闭时取消定时器
    super.onClose();
  }
}
