import 'dart:async';

import 'package:simple_live_core/src/model/live_message.dart';

class LiveDanmaku {
  Function(LiveMessage msg)? onMessage;
  Function(String msg)? onClose;
  Function()? onReady;

  /// 心跳时间
  int heartbeatTime = 0;

  /// 发生心跳
  void heartbeat() {}

  /// 开始接收信息
  Future start(dynamic args) {
    return Future.value();
  }

  /// 停止接收信息
  Future stop() {
    return Future.value();
  }

  /// 是否支持发送弹幕（默认不支持，各平台按需覆写）
  bool get canSendDanmaku => false;

  /// 发送弹幕
  ///
  /// 成功返回 null；失败返回可以直接展示给用户的原因。
  Future<String?> sendDanmaku(String message) {
    return Future.value("当前平台暂不支持发送弹幕");
  }
}
