import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart' show Options, ResponseType;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:share_plus/share_plus.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/requests/http_client.dart' as app_http;
import 'package:simple_live_app/utils/bounded_chat_buffer.dart';
import 'package:simple_live_app/utils/danmaku_limit.dart';
import 'package:simple_live_app/services/background_playback.dart';
import 'package:simple_live_app/services/background_playback_queue.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/douyu_account_service.dart';
import 'package:simple_live_app/services/huya_account_service.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/modules/live_room/player/player_controller.dart';
import 'package:simple_live_app/modules/settings/danmu_settings_page.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/widgets/desktop_refresh_button.dart';
import 'package:simple_live_app/widgets/follow_user_item.dart';
import 'package:simple_live_app/widgets/follow_management_sheet.dart';
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

/// 一条已发出、等待「服务端回推 或 本地补发」的弹幕记录。
///
/// 用 token 追踪是否已上屏，替代旧的全局 _lastSentText/_lastSentEchoed 文字比较，
/// 这样即使别人发了相同文字也不会把「自己这条」的补发吞掉。
class _PendingSend {
  _PendingSend(this.text);
  final String text;

  /// 已经上屏（服务端回推 或 本地补发过一次）
  bool shown = false;
}

class LiveRoomController extends PlayerController with WidgetsBindingObserver {
  final Site pSite;
  final String pRoomId;
  late LiveDanmaku liveDanmaku;
  LiveRoomController({
    required this.pSite,
    required this.pRoomId,
    bool embedded = false,
  }) : super(embedded: embedded) {
    _senderActive = !embedded;
    rxSite = pSite.obs;
    rxRoomId = pRoomId.obs;
    liveDanmaku = site.liveSite.getDanmaku();
    if (embedded && liveDanmaku is LiveDanmakuSenderControl) {
      unawaited(
          (liveDanmaku as LiveDanmakuSenderControl).setSenderActive(false));
    }
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

  FollowUser? get followedUser =>
      FollowService.instance.getFollowUser('${site.id}_$roomId');
  bool get isFollowed => followedUser != null;
  bool get isSpecialFollow => followedUser?.isSpecial ?? false;
  var liveStatus = false.obs;
  RxList<LiveSuperChatMessage> superChats = RxList<LiveSuperChatMessage>();

  /// 画面内 SC 卡片显示时长（秒，固定）
  static const int overlaySuperChatSeconds = 10;

  /// 画面内 SC 展示列表（过期时间由数据层决定，UI 只渲染）
  RxList<OverlaySuperChat> overlaySuperChats = <OverlaySuperChat>[].obs;

  Timer? _overlayScTimer;

  /// 滚动控制
  final ScrollController scrollController = ScrollController();

  /// 聊天信息
  RxList<LiveMessage> messages = RxList<LiveMessage>();
  late final _chatBuffer = BoundedChatBuffer<LiveMessage>(messages);
  Worker? _autoScrollWorker;

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
    if (_roomClosing || isClosed) return;
    _autoScrollWorker = ever<bool>(disableAutoScroll, (paused) {
      if (!paused) {
        _chatBuffer.resume();
        _scheduleChatScroll();
      }
    });
    WidgetsBinding.instance.addObserver(this);
    if (FollowService.instance.followList.isEmpty) {
      FollowService.instance.loadData();
    }
    if (!embedded) initAutoExit();
    showDanmakuState.value = AppSettingsController.instance.danmuEnable.value;
    followed.value = DBService.instance.getFollowExist("${site.id}_$roomId");
    loadData();

    scrollController.addListener(scrollListener);

    // 后台播放：跟随播放状态同步前台服务，并把真实状态回写原生媒体控件。
    // 开始播放时 App 还在前台，满足 Android 12+ 「禁止从后台启动前台服务」的限制。
    // generation 守卫：房间关闭/重载后旧订阅自动失效，避免脏回调操作已释放的播放器。
    final bgGeneration = ++_bgSubscriptionGeneration;
    _bgPlayingSubscription = player.stream.playing.listen((playing) {
      if (bgGeneration != _bgSubscriptionGeneration) return;
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
        if (!embedded) {
          unawaited(syncBackgroundPlayback());
          unawaited(BackgroundPlayback.updateState('playing'));
        }
      } else if (!embedded) {
        // 暂停时保留通知（媒体控件仍可点播放），只回写状态，不销毁服务。
        unawaited(BackgroundPlayback.updateState('paused'));
      }
    });

    // 媒体通知/锁屏按钮命令 -> 驱动播放器，实现原生与 Dart 双向同步。
    _bgCommandsSubscription = BackgroundPlayback.commands.listen((command) {
      if (isClosed ||
          _roomClosing ||
          bgGeneration != _bgSubscriptionGeneration) {
        return;
      }
      switch (command) {
        case 'play':
          unawaited(player.play());
          break;
        case 'pause':
          unawaited(player.pause());
          break;
        case 'stop':
          unawaited(player.stop());
          break;
        case 'previous':
          unawaited(_switchBackgroundRoom(-1));
          break;
        case 'next':
          unawaited(_switchBackgroundRoom(1));
          break;
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
    if (embedded || _roomClosing) return;
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
  bool _chatScrollScheduled = false;

  void _scheduleChatScroll() {
    // Embedded chat uses its own reversed list. Hidden/paused chat needs no work.
    if (embedded ||
        _roomClosing ||
        isClosed ||
        disableAutoScroll.value ||
        !scrollController.hasClients ||
        _chatScrollScheduled) {
      return;
    }
    _chatScrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _chatScrollScheduled = false;
      if (_roomClosing || isClosed || disableAutoScroll.value) return;
      chatScrollToBottom();
    });
  }

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
    final generation = _roomLoadGeneration;
    liveDanmaku.onMessage = (msg) {
      if (!isClosed && generation == _roomLoadGeneration) onWSMessage(msg);
    };
    liveDanmaku.onClose = (msg) {
      if (!isClosed && generation == _roomLoadGeneration) onWSClose(msg);
    };
    liveDanmaku.onReady = () {
      if (!isClosed && generation == _roomLoadGeneration) onWSReady();
    };
  }

  /// 每次发送生成一条 pending 记录，按 token 追踪「是否已上屏」。
  /// 旧实现用全局 _lastSentText/_lastSentEchoed 做文字比较，会被别人同文误伤。
  int _sendTokenSeq = 0;
  final Map<int, _PendingSend> _pendingSends = {};

  /// 接收到WebSocket信息
  void onWSMessage(LiveMessage msg) {
    if (isClosed || _roomClosing) return;
    if (msg.type == LiveMessageType.chat) {
      // 屏蔽直播间专属图片表情弹幕（弹幕设置 → 屏蔽图片表情，默认关闭）
      if (msg.isRoomEmoji &&
          AppSettingsController.instance.danmuBlockRoomEmoji.value) {
        return;
      }
      // 只有「服务端把我自己发的这条推回来」才算已上屏；别人发相同文字绝不影响。
      if (msg.isSelf) {
        for (final p in _pendingSends.values) {
          if (p.text == msg.message) {
            if (p.shown) {
              // 已经上屏过（本地补发或前一次回推），迟到的重复回推直接丢掉，避免重复
              return;
            }
            p.shown = true;
            break;
          }
        }
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
            Log.d("弹幕屏蔽规则：正则格式错误");
          }
        } else {
          pattern = keyword;
        }
        if (pattern != null && msg.message.contains(pattern)) {
          return;
        }
      }

      _chatBuffer.add(msg, paused: disableAutoScroll.value);

      _scheduleChatScroll();
      if (!liveStatus.value || isBackground) {
        return;
      }

      // 表情弹幕：把富文本片段一起传下去，悬浮弹幕也能显示表情图（默认开启）
      final contentParts = msg.spans
          ?.map(
            (e) => e.isImage
                ? DanmakuContentPart.image(
                    e.imageUrl!.trim(),
                    scale: e.imageScale ?? 1,
                    ratio: e.imageRatio ?? 1,
                  )
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
      // 同一条付费留言可能被重复推送（进房全量 + 增量），按平台 id 去重
      final id = msg.data.id;
      if (id.isNotEmpty && superChats.any((e) => e.id == id)) {
        return;
      }
      superChats.add(msg.data);
      addOverlaySuperChat(msg.data);
    }
  }

  /// 全屏下的弹幕输入条是否显示（按回车或点控制条按钮唤起）
  var showDanmakuInput = false.obs;

  /// 进入/退出全屏（含系统 F11/ESC）时收起全屏输入框，避免输入框残留/焦点错乱
  @override
  void onFullScreenStateReset() {
    showDanmakuInput.value = false;
  }

  /// 正在输入弹幕（打字时控制条不要自动隐藏）
  bool danmakuTyping = false;

  /// 弹幕输入草稿：横竖屏切换/全屏进出时输入框会重建，靠它保留未发送内容
  var danmakuDraft = "".obs;

  /// 后台播放用的播放状态订阅
  StreamSubscription<bool>? _bgPlayingSubscription;

  /// 后台播放命令（媒体控件）订阅
  StreamSubscription<String>? _bgCommandsSubscription;

  /// 后台播放订阅/回写 generation：房间关闭或重载时自增，令旧回调失效
  int _bgSubscriptionGeneration = 0;

  /// 主播头像字节缓存（按 URL 去重，避免每次状态回写都重新拉图）
  Uint8List? _lastAvatarBytes;
  String? _lastAvatarUrl;

  /// 平台图标字节缓存（按平台 id 去重；资源来自 Site.logo）
  Uint8List? _lastPlatformIconBytes;
  String? _lastPlatformIconKey;

  /// 媒体控件上一台/下一台切换中，避免连点造成并发 resetRoom
  bool _backgroundRoomSwitching = false;

  /// 是否只播放声音
  bool _embeddedAudioOnly = false;
  bool get audioOnly => embedded
      ? _embeddedAudioOnly
      : AppSettingsController.instance.playerAudioOnly.value;
  bool _senderActive = true;
  int _senderLeaseGeneration = 0;
  Future<void> setSenderActive(bool active) async {
    _senderActive = active && !isClosed && !_roomClosing;
    _senderLeaseGeneration++;
    final sender = liveDanmaku;
    if (sender is LiveDanmakuSenderControl) {
      await (sender as LiveDanmakuSenderControl).setSenderActive(_senderActive);
    }
  }

  /// 按「允许后台播放」开关同步前台服务
  ///
  /// 关闭开关时立刻停服务（通知随之消失）；打开开关时如果正在播放就马上起服务。
  Future<void> syncBackgroundPlayback() async {
    if (isClosed || _roomClosing || embedded) return;
    if (!AppSettingsController.instance.playerBackgroundPlay.value) {
      await BackgroundPlayback.stop();
      return;
    }
    final room = detail.value;
    final user = room?.userName ?? "";
    final title = room?.title ?? "";
    final source = site.name;
    final startedAtMillis = (room?.status == true && room?.isRecord != true)
        ? (int.tryParse(room?.showTime ?? '') ?? 0) * 1000
        : 0;
    final avatarUrl = room?.userAvatar ?? "";
    Uint8List? avatarBytes;
    if (avatarUrl.isNotEmpty) {
      if (avatarUrl != _lastAvatarUrl) {
        _lastAvatarUrl = avatarUrl;
        _lastAvatarBytes = await _fetchImageBytes(avatarUrl);
        if (isClosed || _roomClosing) return;
      }
      avatarBytes = _lastAvatarBytes;
    }
    final platformIconBytes = await _loadPlatformIconBytes();
    if (isClosed || _roomClosing) return;
    await BackgroundPlayback.start(
      title.isEmpty ? "正在后台播放" : title,
      artist: user,
      source: source,
      startedAtMillis: startedAtMillis,
      avatarBytes: avatarBytes,
      platformIconBytes: platformIconBytes,
    );
    await BackgroundPlayback.updateMetadata(
      title: title,
      artist: user,
      source: source,
      startedAtMillis: startedAtMillis,
      avatarBytes: avatarBytes,
      platformIconBytes: platformIconBytes,
    );
  }

  /// 读取当前平台的图标字节，供原生合成通知艺术图（失败返回 null，仅用头像）。
  Future<Uint8List?> _loadPlatformIconBytes() async {
    final key = site.id;
    if (_lastPlatformIconKey == key) return _lastPlatformIconBytes;
    try {
      final data = await rootBundle.load(site.logo);
      _lastPlatformIconKey = key;
      _lastPlatformIconBytes = data.buffer.asUint8List();
      return _lastPlatformIconBytes;
    } catch (e) {
      Log.logPrint('读取平台图标失败：$e');
      return null;
    }
  }

  /// 媒体通知「上一台/下一台」：在关注列表中正在直播的房间之间循环切换。
  Future<void> _switchBackgroundRoom(int step) async {
    if (isClosed || _roomClosing || embedded || _backgroundRoomSwitching) {
      return;
    }
    _backgroundRoomSwitching = true;
    try {
      final candidates = <({Site site, String roomId})>[];
      final seen = <String>{};
      for (final follow in FollowService.instance.liveList) {
        if (follow.liveStatus.value != 2) continue;
        final targetSite = Sites.allSites[follow.siteId];
        if (targetSite == null) continue;
        final key = '${follow.siteId}_${follow.roomId}';
        if (!seen.add(key)) continue;
        candidates.add((site: targetSite, roomId: follow.roomId));
      }
      final currentIndex = candidates.indexWhere(
        (item) => item.site.id == site.id && item.roomId == roomId,
      );
      final next = BackgroundPlaybackQueue.nextIndex(
        length: candidates.length,
        currentIndex: currentIndex,
        step: step,
      );
      if (next == null) return;
      final target = candidates[next];
      await resetRoom(target.site, target.roomId);
    } catch (e) {
      Log.logPrint('切换后台播放房间失败：$e');
    } finally {
      _backgroundRoomSwitching = false;
    }
  }

  /// 拉取主播头像字节，供原生解码成通知大图标（失败返回 null，回退无图）
  Future<Uint8List?> _fetchImageBytes(String url) async {
    try {
      final response = await app_http.HttpClient.instance.dio.get<List<int>>(
        url,
        options: Options(responseType: ResponseType.bytes),
      );
      final data = response.data;
      if (data == null || data.isEmpty) return null;
      return Uint8List.fromList(data);
    } catch (e) {
      Log.logPrint('获取主播头像失败：$e');
      return null;
    }
  }

  /// 加大 mpv 缓冲与网络超时，减少「卡一下就切线路」
  Future<void> applyNetworkBuffering() async {
    if (isClosed || _roomClosing) return;
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
        if (isClosed || _roomClosing) return;
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
    if (isClosed || _roomClosing) return;
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

  /// 正在「静默抢回会话」自动重试（防止递归）
  bool _autoRecoveringSession = false;

  /// 正在发送的条数（并发上限 2，超出的静默忽略）
  int _sendingCount = 0;

  /// 斗鱼 dmjwt 快过期（或 [force] 时强制）先静默刷新登录态
  ///
  /// 成功返回 null；刷新失败会直接退出登录并返回提示文案。
  Future<String?> _refreshDouyuTokenIfNeeded({bool force = false}) async {
    if (site.id != Constant.kDouyu) {
      return null;
    }
    var service = DouyuAccountService.instance;
    if (!service.logined.value) {
      return null;
    }
    if (!force && !service.needRefreshToken) {
      return null;
    }
    Log.i("斗鱼 dmjwt 即将过期，静默刷新登录态");
    var ok = await service.refreshToken();
    if (ok) {
      var danmaku = liveDanmaku;
      if (danmaku is DouyuDanmaku) {
        danmaku.updateCookie(service.cookie);
      }
      return null;
    }
    Log.i("斗鱼 dmjwt 刷新失败，自动退出登录");
    service.logout();
    return "斗鱼登录已过期，请重新登录斗鱼";
  }

  /// 斗鱼「结果不确定」类错误：内容没被明确拒绝就按成功处理
  ///
  /// 356（服务端限流/对该条不置可否）和 8 秒没等到回执都属于这类，
  /// 官方客户端同样是发出去就不再管。
  bool _isSilentSuccess(String error) {
    if (site.id != Constant.kDouyu) {
      return false;
    }
    return error.contains("res=356") || error.contains("发送超时");
  }

  /// 发送弹幕：成功返回 null，失败返回可展示的原因
  Future<String?> sendDanmaku(String text) async {
    final senderGeneration = _senderLeaseGeneration;
    bool canContinue() =>
        !isClosed &&
        !_roomClosing &&
        _senderActive &&
        senderGeneration == _senderLeaseGeneration;
    if (!canContinue()) return "发送房间已切换或关闭";
    var message = text.trim();
    if (message.isEmpty) {
      return "弹幕内容不能为空";
    }
    // 兜底：超出平台字数上限就截断后发送，而不是整条被服务端拒绝
    var limit = danmakuMaxLength(site.id);
    var truncated = truncateDanmaku(message, limit);
    if (truncated != message) {
      Log.i("发送弹幕：超出上限（$limit 字），已截断");
      message = truncated;
    }
    if (!AppSettingsController.instance.playerSendDanmaku.value) {
      return "请先在「设置 - 播放设置」里打开「允许发送弹幕」";
    }
    if (!liveDanmaku.canSendDanmaku) {
      return "当前平台暂不支持发送弹幕";
    }
    var loginTip = _loginCheck();
    if (loginTip != null) {
      return loginTip;
    }
    var last = _lastSendTime;
    if (last != null && DateTime.now().difference(last).inSeconds < 2) {
      return "发送太快了，请稍后再试";
    }
    // 并发上限 2 条，再多就明确提示（绝不静默丢弃还当成功）
    if (_sendingCount >= 2) {
      Log.i("发送弹幕：已有 2 条在发送中，本次拒绝");
      return "发送太频繁，请稍候再试";
    }
    var tokenTip = await _refreshDouyuTokenIfNeeded();
    if (!canContinue()) return "发送房间已切换或关闭";
    if (tokenTip != null) {
      return tokenTip;
    }
    // 先建 pending 记录（广播可能比回执先到，靠它判断“这条是否已上屏”）
    final pending = _PendingSend(message);
    final token = ++_sendTokenSeq;
    _pendingSends[token] = pending;
    _sendingCount++;
    String? error;
    try {
      error = await liveDanmaku.sendDanmaku(message);
      if (error != null) {
        Log.i(
            "发送弹幕[${site.id}][sendId=$token]首次失败：${LogSanitizer.text(error)}");
      }
      // 被其它设备顶掉登录态时：不弹任何提示，直接静默重连抢回会话再发一次
      if (canContinue() &&
          error != null &&
          _isSessionLostError(error) &&
          !_autoRecoveringSession) {
        Log.i("发送失败（会话被接管），静默重新抢会话后自动重试");
        _autoRecoveringSession = true;
        try {
          await Future.delayed(const Duration(milliseconds: 300));
          if (!canContinue()) {
            _pendingSends.remove(token);
            return "发送房间已切换或关闭";
          }
          error = await liveDanmaku.sendDanmaku(message);
          Log.i("静默重试结果：${error == null ? "成功" : LogSanitizer.text(error)}");
        } finally {
          _autoRecoveringSession = false;
        }
        if (canContinue() && error != null && _isSessionLostError(error)) {
          // 还是不行：顺手强制刷新一次登录态（失败会自动退出登录），
          // 这样用户重新登录后下一条就能正常发
          var tip = await _refreshDouyuTokenIfNeeded(force: true);
          if (tip != null) {
            return tip;
          }
          // 刷新成功：用新 token 再发一次
          await Future.delayed(const Duration(milliseconds: 300));
          if (!canContinue()) {
            _pendingSends.remove(token);
            return "发送房间已切换或关闭";
          }
          error = await liveDanmaku.sendDanmaku(message);
          Log.i(
              "刷新登录态后重试结果：${error == null ? "成功" : LogSanitizer.text(error)}");
        }
      }
      // 虎牙：服务端回执 905（登录态失效）→ 翻转登录状态并给明确提示，
      // 避免「账号还显示登录中、实际发不出去」的错觉。
      if (error != null &&
          site.id == Constant.kHuya &&
          (error.contains("905") ||
              error.contains("biz exception") ||
              error.contains("登录已失效"))) {
        HuyaAccountService.instance.logined.value = false;
        error = "虎牙登录已失效，请重新登录";
      }
      // 斗鱼：356 / 超时属于「结果不确定」，按成功静默处理
      if (error != null && _isSilentSuccess(error)) {
        Log.i("发送结果不确定（${LogSanitizer.text(error)}），按成功静默处理");
        error = null;
      }
    } catch (e) {
      Log.i("发送弹幕[sendId=$token]异常：${LogSanitizer.text(e)}");
      error = "发送失败：$e";
    } finally {
      _sendingCount--;
    }
    if (!canContinue()) {
      _pendingSends.remove(token);
      return "发送房间已切换或关闭";
    }
    Log.i(
        "发送弹幕[${site.id}][sendId=$token]结果：${error == null ? "成功" : LogSanitizer.text(error)}");
    if (error == null) {
      _lastSendTime = DateTime.now();
      // 本地补发：1.2 秒内若没等到服务端把我这条推回来，就自己补一条上屏。
      // 按 token 判断、每条最多补一次，绝不受别人同文影响。
      Future.delayed(const Duration(milliseconds: 1200), () {
        if (!_pendingSends.containsKey(token)) {
          return;
        }
        if (!pending.shown) {
          Log.i("弹幕发送[sendId=$token] 服务端未回推，本地补发");
          onWSMessage(
            LiveMessage(
              type: LiveMessageType.chat,
              userName: _selfName(),
              message: message,
              color: LiveMessageColor.white,
              // 本地回显也要标成“自己发的”，否则滚动弹幕没有描边样式
              isSelf: true,
            ),
          );
          // onWSMessage 命中 pending 后会置 shown，这里兜底再置一次
          pending.shown = true;
        }
        // 再保留一段时间用于压掉迟到的服务端回推，然后回收
        Future.delayed(const Duration(seconds: 8), () {
          _pendingSends.remove(token);
        });
      });
    } else {
      // 发送失败：立即回收 pending，避免影响后续
      _pendingSends.remove(token);
    }
    return error;
  }

  /// 是否属于「登录态被顶/失效」类错误（这类才值得静默抢会话重试）
  bool _isSessionLostError(String error) {
    return error.contains("被接管") ||
        error.contains("已过期") ||
        error.contains("4205") ||
        error.contains("4206") ||
        error.contains("登录已在其它设备失效");
  }

  /// 自己发弹幕时用于本地回显的昵称
  String _selfName() {
    if (site.id == Constant.kHuya) {
      var nick = HuyaAccountService.instance.nickname;
      return nick.isNotEmpty ? nick : "我";
    }
    if (site.id == Constant.kDouyu) {
      return DouyuAccountService.instance.name.value;
    }
    if (site.id == Constant.kBiliBili) {
      return BiliBiliAccountService.instance.name.value;
    }
    return "我";
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
    if (site.id == Constant.kHuya &&
        !HuyaAccountService.instance.logined.value) {
      return "请先登录虎牙（发送弹幕需要登录态）";
    }
    return null;
  }

  /// 添加一条系统消息
  void addSysMsg(String msg) {
    _chatBuffer.add(
      LiveMessage(
        type: LiveMessageType.chat,
        userName: "LiveSysMessage",
        message: msg,
        color: LiveMessageColor.white,
      ),
      paused: disableAutoScroll.value,
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

  int _roomLoadGeneration = 0;

  /// 加载直播间信息
  Future<void> loadData() async {
    if (isClosed || _roomClosing) return;
    final generation = ++_roomLoadGeneration;
    final requestedSite = site;
    final requestedRoomId = roomId;
    try {
      if (!embedded) SmartDialog.showLoading(msg: "");
      loadError.value = false;
      error = null;
      update();
      addSysMsg("正在读取直播间信息");
      var sw = Stopwatch()..start();
      final room =
          await requestedSite.liveSite.getRoomDetail(roomId: requestedRoomId);
      if (isClosed || generation != _roomLoadGeneration) return;
      detail.value = room;
      Log.i("房间加载耗时[${site.id}] 详情=${sw.elapsedMilliseconds}ms");
      sw.reset();

      if (site.id == Constant.kDouyin) {
        // 兼容旧 RoomID，保留特别关注和标签后再切换为当前 WebRid。
        final newRoomId = detail.value!.roomId;
        if (newRoomId != roomId) {
          await migrateFollowUserId(roomId, newRoomId);
          if (isClosed || generation != _roomLoadGeneration) return;
          rxRoomId.value = newRoomId;
        }
      }

      // 迁移后把最新状态同步回当前关注项，避免两边数据不一致。
      FollowService.instance.syncRoomStatus(
        siteId: site.id,
        requestedRoomId: roomId,
        detail: detail.value!,
      );

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
      if (liveDanmaku is LiveDanmakuSenderControl) {
        await (liveDanmaku as LiveDanmakuSenderControl)
            .setSenderActive(_senderActive);
        if (isClosed || generation != _roomLoadGeneration) return;
      }
      liveDanmaku.start(detail.value?.danmakuData);
      Log.i("房间加载耗时[${site.id}] 弹幕连接=${sw.elapsedMilliseconds}ms");
      // 平台能力可能要到 start() 之后才明确，同步一次让输入框即时出现
      canSendDanmaku.value = liveDanmaku.canSendDanmaku;
      startLiveDurationTimer(); // 启动开播时长定时器
    } catch (e) {
      Log.logPrint(e);
      //SmartDialog.showToast(e.toString());
      if (isClosed || generation != _roomLoadGeneration) return;
      loadError.value = true;
      error = e is Error ? e : StateError(e.toString());
    } finally {
      if (!embedded && !isClosed && generation == _roomLoadGeneration) {
        SmartDialog.dismiss(status: SmartStatus.loading);
      }
    }
  }

  /// 初始化播放器
  void getPlayQualites() async {
    final generation = _roomLoadGeneration;
    final requestedSite = site;
    final requestedDetail = detail.value!;
    qualites.clear();
    currentQuality = -1;

    try {
      var playQualites =
          await requestedSite.liveSite.getPlayQualites(detail: requestedDetail);
      if (isClosed || generation != _roomLoadGeneration) return;

      if (playQualites.isEmpty) {
        SmartDialog.showToast("无法读取播放清晰度");
        return;
      }
      qualites.value = playQualites;
      var qualityLevel = await getQualityLevel();
      if (isClosed || generation != _roomLoadGeneration) return;
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
      if (isClosed || generation != _roomLoadGeneration) return;
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
    final generation = _roomLoadGeneration;
    final previousLines = playUrls.toList();
    try {
      var playUrl = await site.liveSite.getPlayUrls(
          detail: detail.value!, quality: qualites[currentQuality]);
      if (isClosed || generation != _roomLoadGeneration) return;
      if (playUrl.urls.isEmpty) {
        SmartDialog.showToast("无法读取播放地址");
        await replayWithPrevious(previousLines);
        return;
      }
      playUrls.value = playUrl.urls;
      playHeaders = playUrl.headers;
      audioLineIndex = playUrl.audioLineIndex;
    } catch (e) {
      if (isClosed || generation != _roomLoadGeneration) return;
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
    if (isClosed || _roomClosing) return;
    if (fromUser && audioLineIndex != null) {
      if (embedded) {
        _embeddedAudioOnly = index == audioLineIndex;
      } else {
        AppSettingsController.instance
            .setPlayerAudioOnly(index == audioLineIndex);
      }
    }
    currentLineIndex = index;
    //重置错误次数
    mediaErrorRetryCount = 0;
    setPlayer();
  }

  Future<void>? _playlistFuture;
  int _playlistRevision = 0;

  Future<void> initPlaylist() {
    if (isClosed || _roomClosing || playerClosing) return Future<void>.value();
    _playlistRevision++;
    return _playlistFuture ??= runPlayerOperation(() async {
      try {
        var revision = -1;
        while (!isClosed &&
            !_roomClosing &&
            !playerClosing &&
            revision != _playlistRevision) {
          revision = _playlistRevision;
          await _initPlaylist(revision);
        }
      } finally {
        _playlistFuture = null;
      }
    });
  }

  Future<void> _initPlaylist(int revision) async {
    if (isClosed || _roomClosing) return;
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
    final generation = _roomLoadGeneration;
    final mediaList = [Media(currentUrl, httpHeaders: playHeaders)];

    // 初始化播放器并设置 ao 参数
    await initializePlayer();
    bool isCurrent() =>
        !isClosed &&
        !_roomClosing &&
        !playerClosing &&
        generation == _roomLoadGeneration &&
        revision == _playlistRevision;
    if (!isCurrent()) return;

    // 加大 mpv 缓冲与网络超时：桌面端网络一抖就会卡顿 → 被判定线路失效 → 一直切线路，
    // 这里给足缓冲（在 open 之前设置才生效），不影响起播速度
    await applyNetworkBuffering();
    if (!isCurrent()) return;

    // 加超时：播放器异常/代理挂住时 open 可能一直不返回，导致界面卡死在"没有线路"
    var openWatch = Stopwatch()..start();
    firstFrameWatch = openWatch;
    Log.i("起播开始：${currentUrl.split("?").first}");
    final opening = runPlayerOperation(() => player.open(Playlist(mediaList)));
    try {
      await opening.timeout(const Duration(seconds: 12));
      Log.i("起播耗时：open=${openWatch.elapsedMilliseconds}ms");
    } catch (e) {
      if (isCurrent()) {
        Log.logPrint(e);
        SmartDialog.showToast("起播超时，正在重试");
      }
      // A timeout does not cancel a native call. Keep replacement and disposal
      // behind that call rather than opening the same player concurrently.
      await opening.catchError((Object _) {});
    }

    if (!isCurrent()) return;
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
    if (isClosed || _roomClosing) return;
    final generation = _roomLoadGeneration;
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
    if (isClosed || generation != _roomLoadGeneration) return;
    await refreshUrlAndReplay();

    // 看门狗：20 秒后仍未恢复播放，说明重连卡住/失败 → 换下一条线路或再试一次，
    // 避免停在"没有线路"的死状态。播放恢复/发起新重连时令牌变化，它自动失效。
    // 注意：要和重连互斥、熔断器保持一致，否则会和正在进行的重连打架。
    final token = ++_reconnectToken;
    Future.delayed(const Duration(seconds: 20), () {
      if (isClosed ||
          generation != _roomLoadGeneration ||
          token != _reconnectToken ||
          playerPlaying.value ||
          _replaying) {
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
    if (isClosed || _roomClosing) return;
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
    if (isClosed || _roomClosing) return;
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
      final generation = _roomLoadGeneration;
      await Future.delayed(Duration(seconds: (mediaErrorRetryCount + 1) * 2));
      if (isClosed || _roomClosing || generation != _roomLoadGeneration) return;
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
    // 不做条数裁剪：每条 SC 10 秒后自己过期，并发条数天然有上限；
    // 渲染层放不下时会从顶部渐隐，不会再被硬裁掉
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
    final generation = _roomLoadGeneration;
    try {
      var sc =
          await site.liveSite.getSuperChatMessage(roomId: detail.value!.roomId);
      if (isClosed || generation != _roomLoadGeneration) return;
      superChats.addAll(sc);
      // 进房时把「B站 上还在展示期」的 SC 也放进画面，
      // 时长取剩余时间与 15 秒的较小值（已到期的不加，避免负数）
      var now = DateTime.now().millisecondsSinceEpoch;
      for (var item in sc) {
        var remain = (item.endTime.millisecondsSinceEpoch - now) ~/ 1000;
        if (remain > 0) {
          addOverlaySuperChat(
            item,
            maxSeconds: remain < overlaySuperChatSeconds
                ? remain
                : overlaySuperChatSeconds,
          );
        }
      }
    } catch (e) {
      if (isClosed || generation != _roomLoadGeneration) return;
      Log.logPrint(e);
      addSysMsg("SC读取失败");
    }
  }

  /// 移除掉已到期的SC
  ///
  /// 斗鱼付费留言（高能弹幕）自带展示时长（`cet`/`etimeV2` → endTime），
  /// 到期就和 B 站 SC 一样从列表移除，不再额外保留固定 60 秒。
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

  /// 迁移旧房间号时先落盘新项与标签关系，再删除旧项。
  Future<void> migrateFollowUserId(
    String oldRoomId,
    String newRoomId,
  ) async {
    final service = FollowService.instance;
    final db = DBService.instance;
    final oldId = '${site.id}_$oldRoomId';
    final newId = '${site.id}_$newRoomId';
    final old = service.getFollowUser(oldId) ?? db.followBox.get(oldId);
    if (old == null) return;

    var target = service.getFollowUser(newId) ?? db.followBox.get(newId);
    if (target == null) {
      target = FollowUser(
        id: newId,
        roomId: newRoomId,
        siteId: old.siteId,
        userName: detail.value!.userName,
        face: detail.value!.userAvatar,
        addTime: old.addTime,
        tag: old.tag,
        isSpecial: old.isSpecial,
      );
      target.liveStatus.value = old.liveStatus.value;
      target.liveStartTime = old.liveStartTime;
      target.lastLiveTime = old.lastLiveTime;
      target.roomNotFound = old.roomNotFound;
      await service.addFollow(target);
    } else if (old.isSpecial && !target.isSpecial) {
      // 新 ID 已存在时仅合并星标，保留它的资料和关注时间。
      await service.setSpecialFollow(target, true);
    }

    for (final tag in db.getFollowTagList()) {
      if (!tag.userId.contains(oldId)) continue;
      final userIds =
          tag.userId.map((id) => id == oldId ? newId : id).toSet().toList();
      await db.updateFollowTag(tag.copyWith(userId: userIds));
    }
    service.getAllTagList();
    await service.removeFollow(old);
  }

  /// 直播间所有布局的关注按钮都打开共用管理菜单。
  Future<void> showFollowManagement() async {
    final room = detail.value;
    if (room == null) return;
    final item = followedUser ??
        FollowUser(
          id: '${site.id}_$roomId',
          roomId: roomId,
          siteId: site.id,
          userName: room.userName,
          face: room.userAvatar,
          addTime: DateTime.now(),
        );
    if (!isFollowed) {
      item.liveStatus.value = room.status && !room.isRecord ? 2 : 1;
      item.liveStartTime = room.status && !room.isRecord ? room.showTime : null;
      item.lastLiveTime = room.lastLiveTime;
    }
    await FollowManagementSheet.show(item);
    followed.value = isFollowed;
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
    if (embedded || _roomClosing) return;
    Utils.showBottomSheet(
      title: "弹幕设置",
      child: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          DanmuSettingsView(
            danmakuController: danmakuController,
            // 哔哩哔哩、斗鱼、虎牙都有图片表情弹幕，都需要这个开关
            showRoomEmojiBlock: site.id == Constant.kBiliBili ||
                site.id == Constant.kDouyu ||
                site.id == Constant.kHuya,
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
    if (embedded || _roomClosing) return;
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
    if (embedded || _roomClosing) return;
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
                      showManageAction: false,
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

  Future<void> resetRoom(Site site, String roomId) async {
    if (isClosed || _roomClosing) return;
    if (this.site == site && this.roomId == roomId) {
      return;
    }

    final generation = ++_roomLoadGeneration;
    rxSite.value = site;
    rxRoomId.value = roomId;
    detail.value = null;
    qualites.clear();
    playUrls.clear();
    currentQuality = -1;
    currentLineIndex = -1;
    currentQualityInfo.value = "";
    currentLineInfo.value = "";
    audioLineIndex = null;
    _reconnectToken++;
    _liveDurationTimer?.cancel();
    onFullScreenStateReset();

    // 清除全部消息
    liveDanmaku.stop();
    _chatBuffer.clear();
    _pendingSends.clear();
    superChats.clear();
    clearOverlaySuperChats();
    danmakuController?.clear();

    // 重新设置LiveDanmaku
    liveDanmaku = site.liveSite.getDanmaku();
    await setSenderActive(_senderActive);
    if (isClosed || generation != _roomLoadGeneration) return;
    canSendDanmaku.value = liveDanmaku.canSendDanmaku;

    // 停止播放
    await player.stop();

    // 刷新信息
    if (!isClosed && generation == _roomLoadGeneration) await loadData();
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

  bool _roomClosing = false;
  Future<void>? _roomCloseFuture;
  Future<void> closeRoom() {
    if (_roomCloseFuture != null) return _roomCloseFuture!;
    final completion = Completer<void>();
    _roomCloseFuture = completion.future;
    _roomClosing = true;
    _roomLoadGeneration++;
    _bgSubscriptionGeneration++;
    _senderLeaseGeneration++;
    _senderActive = false;
    _reconnectToken++;
    _autoScrollWorker?.dispose();
    _chatBuffer.clear();
    _pendingSends.clear();
    WidgetsBinding.instance.removeObserver(this);
    scrollController.removeListener(scrollListener);
    scrollController.dispose();
    autoExitTimer?.cancel();
    _liveDurationTimer?.cancel();
    clearOverlaySuperChats();
    if (!embedded) BackgroundPlayback.stop();
    final stopped = liveDanmaku.stop();
    if (!isClosed) onDelete();
    () async {
      try {
        await _bgPlayingSubscription?.cancel();
        await _bgCommandsSubscription?.cancel();
        await stopped;
      } finally {
        await closePlayer();
        danmakuController = null;
      }
    }()
        .then(completion.complete, onError: completion.completeError);
    return completion.future;
  }

  @override
  void onClose() {
    unawaited(closeRoom());
    super.onClose();
  }
}
