import 'dart:async';

import 'package:flutter/material.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/widgets/net_image.dart';
import 'package:simple_live_core/simple_live_core.dart';

class SuperChatCard extends StatefulWidget {
  final LiveSuperChatMessage message;
  final Function()? onExpire;
  final int? customCountdown;
  @visibleForTesting
  final DateTime Function()? now;
  const SuperChatCard(
    this.message, {
    required this.onExpire,
    this.customCountdown,
    this.now,
    Key? key,
  }) : super(key: key);

  @override
  State<SuperChatCard> createState() => _SuperChatCardState();
}

class _SuperChatCardState extends State<SuperChatCard>
    with WidgetsBindingObserver {
  Timer? timer;
  bool _expiryNotified = false;

  int countdown = 0;

  /// 倒计时结束（斗鱼的付费留言会保留在列表里，只把倒计时换成「已结束」）
  bool expired = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _resetCountdown();
  }

  @override
  void didUpdateWidget(covariant SuperChatCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.message, widget.message)) {
      _expiryNotified = false;
      _resetCountdown();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 后台挂起期间 Timer 可能停走，返回时按平台截止时间校准。
      setState(_resetCountdown);
    }
  }

  void _resetCountdown() {
    timer?.cancel();
    timer = null;
    final currentTime =
        (widget.now?.call() ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    var endTime = widget.message.endTime.millisecondsSinceEpoch ~/ 1000;

    // 不能为负数：进房时批量拉回的历史 SC，endTime 往往已经过去
    countdown = endTime - currentTime;
    expired = countdown <= 0;
    if (expired) {
      countdown = 0;
      _notifyExpiry();
      return;
    }

    timer = Timer.periodic(const Duration(seconds: 1), timerCallback);
  }

  void _notifyExpiry() {
    if (_expiryNotified) return;
    _expiryNotified = true;
    final message = widget.message;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && identical(widget.message, message)) {
        widget.onExpire?.call();
      }
    });
  }

  void timerCallback(Timer timer) {
    setState(() {
      countdown = (countdown - 1).clamp(0, 1 << 30);
      expired = countdown == 0;
    });
    if (expired) {
      timer.cancel();
      this.timer = null;
      _notifyExpiry();
    }
  }

  @override
  Widget build(BuildContext context) {
    // 双保险：任何情况下都不显示负数
    final displayCountdown =
        (widget.customCountdown ?? countdown).clamp(0, 1 << 30);
    return ClipRRect(
      borderRadius: AppStyle.radius8,
      child: Container(
        decoration: BoxDecoration(
          color: Utils.convertHexColor(widget.message.backgroundColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: AppStyle.edgeInsetsA8,
              child: Row(
                children: [
                  NetImage(
                    widget.message.face,
                    width: 48,
                    height: 48,
                    borderRadius: 36,
                  ),
                  AppStyle.hGap12,
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          widget.message.userName,
                          style: const TextStyle(
                            color: AppColors.black333,
                          ),
                        ),
                        Text(
                          widget.message.displayPrice,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    expired ? "已结束" : "$displayCountdown",
                    style: const TextStyle(
                      fontSize: 14,
                      color: Colors.grey,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              decoration: BoxDecoration(
                color:
                    Utils.convertHexColor(widget.message.backgroundBottomColor),
              ),
              padding: AppStyle.edgeInsetsA8,
              child: Text(
                widget.message.message,
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    timer?.cancel();
    super.dispose();
  }
}
