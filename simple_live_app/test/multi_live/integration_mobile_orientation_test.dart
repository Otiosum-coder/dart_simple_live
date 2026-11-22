import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'page_interaction_test.dart' show FakeModel, mount;

void main() {
  testWidgets('mobile split follows window orientation even with app chrome',
      (tester) async {
    final model = FakeModel(2, maxRooms: 2);
    await mount(tester, model, const Size(590, 600));
    final first = find.byKey(const ValueKey('tile:room0'));
    final second = find.byKey(const ValueKey('tile:room1'));
    // The toolbar and footer make the video area landscape, but the phone
    // window itself is portrait and must still stack its two streams.
    expect(tester.getTopLeft(second).dy,
        greaterThan(tester.getBottomLeft(first).dy),
        reason: '590×600 is portrait even when the video area is wider');

    tester.view.physicalSize = const Size(600, 590);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(second).dx,
        greaterThan(tester.getTopRight(first).dx));
    expect(model.created, {'room0': 1, 'room1': 1});
    expect(model.destroyed, isEmpty);
  });
}
