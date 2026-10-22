import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasla/data/models.dart';

import 'fake_api.dart';
import 'harness.dart';

FakeApi _team() => FakeApi(signedInAs: 'me', name: 'Amr')
  ..memberships.add(
    FakeApi.membership('ws1', 'Engineering', WorkspaceRole.member),
  )
  ..membersByWorkspace['ws1'] = [
    const Member(userId: 'me', fullName: 'Amr', role: WorkspaceRole.member),
    const Member(
      userId: 'u2',
      fullName: 'Omar Said',
      role: WorkspaceRole.member,
    ),
  ];

void main() {
  testWidgets('one goes on leave from my account', (tester) async {
    final api = _team();
    await startApp(tester, api, prefs: {'locale': 'en'});
    await openMyAccount(tester);

    expect(find.text('Available'), findsOneWidget);
    await tester.tap(find.byKey(const Key('statusTile')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('status-leave')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('statusNote')),
      'Ask Rania for anything urgent',
    );
    await tester.tap(find.byKey(const Key('saveStatus')));
    await tester.pumpAndSettle();

    final mine = api.statuses['me']!;
    expect(mine.kind, StatusKind.leave);
    expect(mine.note, 'Ask Rania for anything urgent');
    expect(mine.until, isNull);
    expect(find.text('On leave'), findsOneWidget);

    // Back to available.
    await tester.tap(find.byKey(const Key('statusTile')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('status-available')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('saveStatus')));
    await tester.pumpAndSettle();
    expect(api.statuses, isEmpty);
    expect(find.text('Available'), findsOneWidget);
  });

  testWidgets('a meeting lasts an hour unless told otherwise', (tester) async {
    final api = _team();
    await startApp(tester, api, prefs: {'locale': 'en'});
    await openMyAccount(tester);
    await tester.tap(find.byKey(const Key('statusTile')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('status-meeting')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('saveStatus')));
    await tester.pumpAndSettle();

    final until = api.statuses['me']!.until!;
    expect(
      until.difference(DateTime.now()).inMinutes,
      inInclusiveRange(55, 60),
    );
  });

  testWidgets('writing to someone on leave shows their note', (tester) async {
    final api = _team()
      ..statuses['u2'] = UserStatus(
        kind: StatusKind.leave,
        note: 'Ask Rania for anything urgent',
        until: DateTime.now().add(const Duration(days: 5)),
      );
    await startApp(tester, api, prefs: {'locale': 'en'});

    await tester.tap(find.byTooltip('New message'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Omar Said'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('chatStatus')), findsOneWidget);
    expect(find.byKey(const Key('awayNote')), findsOneWidget);
    expect(find.text('Ask Rania for anything urgent'), findsOneWidget);
    expect(find.textContaining('Omar · On leave until'), findsOneWidget);

    // And on their card.
    await tester.tap(find.byKey(const Key('chatStatus')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('profileStatus')), findsOneWidget);
  });

  testWidgets('being busy shows in the chat, without a note', (tester) async {
    final api = _team()
      ..statuses['u2'] = const UserStatus(kind: StatusKind.busy);
    await startApp(tester, api, prefs: {'locale': 'en'});
    await tester.tap(find.byTooltip('New message'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Omar Said'));
    await tester.pumpAndSettle();

    expect(find.text('Busy'), findsOneWidget);
    expect(find.byKey(const Key('awayNote')), findsNothing);
  });
}
