import 'package:flutter/foundation.dart';

/// Capacity is a platform policy; resizing a desktop window never changes it.
@immutable
class MultiLiveDevicePolicy {
  const MultiLiveDevicePolicy(this.platform);

  final TargetPlatform platform;

  int get maxRooms => switch (platform) {
        TargetPlatform.windows ||
        TargetPlatform.macOS ||
        TargetPlatform.linux =>
          4,
        _ => 2,
      };
}
