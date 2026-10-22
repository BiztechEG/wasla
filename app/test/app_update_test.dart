import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasla/data/models.dart';
import 'package:wasla/data/updates.dart';

import 'fake_api.dart';
import 'harness.dart';

/// The website has [release] (null: nothing newer).
class FakeUpdates implements UpdateChecker {
  FakeUpdates(this.release);

  final AppRelease? release;
  int checks = 0;

  @override
  Future<AppRelease?> newer() async {
    checks++;
    return release;
  }
}

FakeApi _team() => FakeApi(signedInAs: 'me', name: 'Amr')
  ..memberships.add(
    FakeApi.membership('ws1', 'Engineering', WorkspaceRole.member),
  );

const _release = AppRelease(
  version: '0.3.0',
  build: 420,
  bytes: 24 * 1024 * 1024,
  url: 'https://wasla.example/download/wasla.apk',
);

void main() {
  testWidgets('a newer app is offered on the chats until put off', (
    tester,
  ) async {
    final updates = FakeUpdates(_release);
    await startApp(tester, _team(), updates: updates);
    expect(find.text('نسخة جديدة من وصلة متاحة (0.3.0)'), findsOneWidget);
    expect(find.byKey(const Key('updateNow')), findsOneWidget);

    await tester.tap(find.text('لاحقاً'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('updateBanner')), findsNothing);

    // My account still has it, with its size.
    await openMyAccount(tester);
    final tile = find.byKey(const Key('updateTile'));
    await tester.scrollUntilVisible(tile, 200);
    expect(find.text('24 ميجا'), findsOneWidget);
    expect(updates.checks, 1);
  });

  testWidgets('put off, a version is not offered again on the chats', (
    tester,
  ) async {
    await startApp(
      tester,
      _team(),
      updates: FakeUpdates(_release),
      prefs: {'update_later_420': true},
    );
    expect(find.byKey(const Key('updateBanner')), findsNothing);
  });

  testWidgets('nothing newer, nothing shown', (tester) async {
    await startApp(tester, _team(), updates: FakeUpdates(null));
    expect(find.byKey(const Key('updateBanner')), findsNothing);
    await openMyAccount(tester);
    expect(find.byKey(const Key('updateTile')), findsNothing);
  });
}
