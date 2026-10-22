import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasla/data/models.dart';

import 'fake_api.dart';
import 'harness.dart';

FakeApi _team() => FakeApi(signedInAs: 'me', name: 'Amr')
  ..memberships.add(
    FakeApi.membership('ws1', 'Engineering', WorkspaceRole.member),
  );

/// A laptop's browser window.
void _laptop(WidgetTester tester) {
  tester.view.physicalSize = const Size(1280, 860);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('in a wide browser the app is as wide as a phone, or full', (
    tester,
  ) async {
    _laptop(tester);
    // As wide as a phone to start with.
    await startApp(tester, _team(), web: true);
    final frame = tester.getRect(find.byKey(const Key('phoneView')));
    expect(frame.width, 420);
    expect(frame.center.dx, 640);
    // Inside, the app is laid out as on a phone, without its own button.
    expect(find.byKey(const Key('phoneViewButton')), findsNothing);
    expect(
      frame.contains(tester.getCenter(find.byKey(const Key('meButton')))),
      isTrue,
    );

    // Turned off beside the app; back on from the top bar or my account.
    await tester.tap(find.byKey(const Key('fullWidth')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('phoneView')), findsNothing);
    await tester.tap(find.byKey(const Key('phoneViewButton')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('phoneView')), findsOneWidget);
    await tester.tap(find.byKey(const Key('fullWidth')));
    await tester.pumpAndSettle();

    await openMyAccount(tester);
    final toggle = find.byKey(const Key('phoneViewSwitch'));
    await tester.scrollUntilVisible(toggle, 200);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('phoneView')), findsOneWidget);
    expect(find.text('عرض بحجم الموبايل'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('phones and narrow windows have no phone view', (tester) async {
    smallPhone(tester);
    await startApp(tester, _team(), web: true, prefs: {'phone_view': true});
    expect(find.byKey(const Key('phoneView')), findsNothing);
    expect(find.byKey(const Key('phoneViewButton')), findsNothing);

    // It can still be turned off there.
    await openMyAccount(tester);
    await tester.scrollUntilVisible(
      find.byKey(const Key('phoneViewSwitch')),
      200,
    );
    expect(find.byKey(const Key('phoneViewSwitch')), findsOneWidget);
  });

  testWidgets('the phone app has neither', (tester) async {
    _laptop(tester);
    await startApp(tester, _team(), prefs: {'phone_view': true});
    expect(find.byKey(const Key('phoneView')), findsNothing);
    expect(find.byKey(const Key('phoneViewButton')), findsNothing);
  });
}
