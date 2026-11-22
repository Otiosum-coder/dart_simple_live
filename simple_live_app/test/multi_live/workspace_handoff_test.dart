import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/modules/multi_live/session/multi_live_room_spec.dart';
import 'package:simple_live_app/routes/app_navigation.dart';
import 'package:simple_live_app/routes/route_path.dart';

import 'session_lifecycle_test.dart' show LifecycleRoom;

void main() {
  for (final navigateAway in [false, true]) {
    testWidgets(
        navigateAway
            ? 'leaving during standalone shutdown never opens a late workspace'
            : 'handoff opens workspace only after standalone native player closes',
        (tester) async {
      final room = LifecycleRoom()..onStart();
      var workspaceBuilds = 0;
      MultiLiveRoomSpec? seed;
      await tester.pumpWidget(GetMaterialApp(
        home: const Scaffold(body: Text('Home')),
        getPages: [
          GetPage(
              name: RoutePath.kLiveRoomDetail,
              page: () => Builder(
                  builder: (context) => Scaffold(
                          body: TextButton(
                        onPressed: () =>
                            unawaited(AppNavigator.toMultiLive(context, room)),
                        child: const Text('Switch'),
                      )))),
          GetPage(
              name: RoutePath.kMultiLive,
              page: () {
                workspaceBuilds++;
                seed = Get.arguments as MultiLiveRoomSpec;
                return const Scaffold(body: Text('Workspace'));
              }),
        ],
      ));
      unawaited(Get.toNamed<void>(RoutePath.kLiveRoomDetail));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Switch'));
      await tester.pump();
      expect(room.isClosed, isTrue);
      expect(workspaceBuilds, 0);
      if (navigateAway) {
        Get.back<void>();
        await tester.pumpAndSettle();
      }
      room.nativeClosed.complete();
      await tester.pumpAndSettle();
      if (navigateAway) {
        expect(workspaceBuilds, 0);
        expect(find.text('Home'), findsOneWidget);
      } else {
        expect(workspaceBuilds, 1);
        expect(seed?.roomId, 'fixture');
        expect(seed?.siteId, 'douyu');
        expect(find.text('Workspace'), findsOneWidget);
        Get.back<void>();
        await tester.pumpAndSettle();
        expect(find.text('Home'), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      Get.reset();
    });
  }
}
