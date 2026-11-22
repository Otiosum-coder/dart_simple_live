import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/widgets/follow_user_item.dart';

class _StubFollowService extends FollowService {
  _StubFollowService(FollowUser item) {
    followList.add(item);
  }

  @override
  // 测试里不启动 FollowService 的定时器/Hive 初始化，只填充列表。
  // ignore: must_call_super
  void onInit() {}
}

void main() {
  late FollowUser item;
  late _StubFollowService service;

  setUp(() {
    Get.reset();
    item = FollowUser(
      id: '${Constant.kDouyu}1',
      roomId: '1',
      siteId: Constant.kDouyu,
      userName: '主播',
      face: '',
      addTime: DateTime(2026),
    )..liveStatus.value = 2;
    service = _StubFollowService(item);
    Get.put<FollowService>(service);
  });

  tearDown(Get.reset);

  Future<void> pumpItem(
    WidgetTester tester, {
    required bool showManage,
    VoidCallback? onLongPress,
  }) {
    return tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FollowUserItem(
          item: item,
          showManageAction: showManage,
          onLongPress: onLongPress,
        ),
      ),
    ));
  }

  testWidgets('直播间关注列表不显示关注管理菜单', (tester) async {
    await pumpItem(tester, showManage: false);
    expect(find.byTooltip('关注管理'), findsNothing);
    expect(find.byIcon(Icons.more_horiz), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('关注页仍保留关注管理菜单', (tester) async {
    await pumpItem(tester, showManage: true);
    expect(find.byTooltip('关注管理'), findsOneWidget);
    expect(find.byIcon(Icons.more_horiz), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('直播间的关注项隐藏菜单后仍可长按打开关注管理', (tester) async {
    var longPressed = false;
    await pumpItem(
      tester,
      showManage: false,
      onLongPress: () => longPressed = true,
    );
    await tester.longPress(find.byType(ListTile));
    expect(longPressed, isTrue);
    expect(tester.takeException(), isNull);
  });
}
