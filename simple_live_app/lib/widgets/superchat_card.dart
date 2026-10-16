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
  const SuperChatCard(
    this.message, {
    required this.onExpire,
    this.customCountdown,
    Key? key,
  }) : super(key: key);

  @override
  State<SuperChatCard> createState() => _SuperChatCardState();
}

class _SuperChatCardState extends State<SuperChatCard> {
  late Timer timer;

  int countdown = 0;

  @override
  void initState() {
    var currentTime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    var endTime = widget.message.endTime.millisecondsSinceEpoch ~/ 1000;

    // 不能为负数：进房时批量拉回的历史 SC，endTime 往往已经过去
    countdown = endTime - currentTime;
    if (countdown <= 0) {
      countdown = 0;
      // 首帧就请求移除，避免先渲染出 -2 这种数字
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onExpire?.call();
      });
    }

    timer = Timer.periodic(const Duration(seconds: 1), timerCallback);

    super.initState();
  }

  void timerCallback(e) {
    if (countdown <= 0) {
      widget.onExpire?.call();
      timer.cancel();
      return;
    }

    setState(() {
      countdown -= 1;
    });
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
                          "￥${widget.message.price}",
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    "$displayCountdown",
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
    timer.cancel();
    super.dispose();
  }
}
