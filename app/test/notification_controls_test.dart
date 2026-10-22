import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasla/data/models.dart';

import 'fake_api.dart';
import 'harness.dart';

const _branch = Project(
  id: 'p1',
  workspaceId: 'ws1',
  name: 'New Branch',
  color: '#C2660A',
  status: ProjectStatus.active,
  memberCount: 3,
);

FakeApi _company() => FakeApi(signedInAs: 'me', name: 'Amr')
  ..memberships.add(
    FakeApi.membership('ws1', 'Engineering', WorkspaceRole.member),
  );

void main() {
  testWidgets('a chat is muted for a week, marked in the list, then unmuted', (
    tester,
  ) async {
    final api = _company();
    final chat = api.addProjectChat('ws1', _branch);
    api.receive(chat, 'u2', 'Mona Adel', 'Morning');
    await startApp(tester, api, prefs: {'locale': 'en'});

    await tester.tap(find.text('New Branch').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('muteChat')));
    await tester.pumpAndSettle();
    expect(
      find.text(
        "Messages here won't reach your phone, unless someone "
        'mentions you.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('For a week'));
    await tester.pumpAndSettle();

    final until = api.muted[chat]!;
    expect(until.difference(DateTime.now()).inDays, 6);
    expect(find.byTooltip('Unmute'), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('mutedMark')), findsOneWidget);

    await tester.tap(find.text('New Branch').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('muteChat')));
    await tester.pumpAndSettle();
    expect(api.muted, isEmpty);
  });

  testWidgets('quiet hours are set from my account', (tester) async {
    final api = _company();
    await startApp(tester, api, prefs: {'locale': 'en'});
    await openMyAccount(tester);

    expect(find.text('My account'), findsOneWidget);
    await tester.tap(find.byKey(const Key('quietHours')));
    await tester.pumpAndSettle();

    expect(api.quiet!.from, const TimeOfDay(hour: 22, minute: 0));
    expect(api.quiet!.to, const TimeOfDay(hour: 7, minute: 0));
    expect(api.quiet!.utcOffset, DateTime.now().timeZoneOffset.inMinutes);
    expect(find.byKey(const Key('quietFrom')), findsOneWidget);

    await tester.tap(find.byKey(const Key('quietHours')));
    await tester.pumpAndSettle();
    expect(api.quiet, isNull);
  });

  testWidgets('the chats tab stays simple in a new workspace', (tester) async {
    final api = FakeApi(signedInAs: 'me', name: 'Amr')
      ..memberships.add(
        FakeApi.membership('ws1', 'Engineering', WorkspaceRole.owner),
      );
    await startApp(tester, api, prefs: {'locale': 'en'});

    // No filters with nothing to filter, and the first step offered.
    expect(find.text('Unread'), findsNothing);
    await tester.tap(find.byKey(const Key('firstProject')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('projectName')), findsOneWidget);
  });

  testWidgets('a new workspace owner is walked through the first steps', (
    tester,
  ) async {
    final api = FakeApi(signedInAs: 'me', name: 'Amr')
      ..newWorkspace = true
      ..memberships.add(
        FakeApi.membership('ws1', 'Engineering', WorkspaceRole.owner),
      );
    await startApp(tester, api, prefs: {'locale': 'en'});

    // Only the next step shows, and the empty chats don't repeat it.
    expect(find.text('0 of 4'), findsOneWidget);
    expect(find.byKey(const Key('setup-project')), findsOneWidget);
    expect(find.byKey(const Key('setup-team')), findsNothing);
    expect(find.byKey(const Key('firstProject')), findsNothing);

    await tester.tap(find.byKey(const Key('setup-project')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('projectName')), 'Site');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(find.text('1 of 4'), findsOneWidget);
    expect(find.byKey(const Key('setup-team')), findsOneWidget);

    // All of them, the done one ticked.
    await tester.tap(find.byKey(const Key('allSetupSteps')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('setup-attendance')), findsOneWidget);
    expect(
      tester.widget<ListTile>(find.byKey(const Key('setup-project'))).enabled,
      isFalse,
    );

    // Hidden, it stays hidden.
    await tester.tap(find.byKey(const Key('hideSetup')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('setupChecklist')), findsNothing);
  });

  testWidgets('members have no first steps to take', (tester) async {
    final api = FakeApi(signedInAs: 'me', name: 'Amr')
      ..newWorkspace = true
      ..memberships.add(
        FakeApi.membership('ws1', 'Engineering', WorkspaceRole.member),
      );
    await startApp(tester, api);
    expect(find.byKey(const Key('setupChecklist')), findsNothing);
  });
}
