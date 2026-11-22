/// Optional sender lease. Releasing it must preserve the receive connection.
abstract class LiveDanmakuSenderControl {
  Future<void> setSenderActive(bool active);
}
