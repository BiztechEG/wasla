import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasla/data/models.dart';
import 'package:wasla/ui/task_editor.dart';

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

  testWidgets('empty screens offer the next step', (tester) async {
    final api = FakeApi(signedInAs: 'me', name: 'Amr')
      ..memberships.add(
        FakeApi.membership('ws1', 'Engineering', WorkspaceRole.owner),
      )
      ..membersByWorkspace['ws1'] = [
        const Member(userId: 'me', fullName: 'Amr', role: WorkspaceRole.owner),
      ]
      ..projectsByWorkspace['ws1'] = [
        const Project(
          id: 'p1',
          workspaceId: 'ws1',
          name: 'Site',
          color: '#0F6E6A',
          status: ProjectStatus.active,
          memberCount: 1,
        ),
      ];
    await startApp(tester, api, prefs: {'locale': 'en'});

    // No chats: write the first message; nobody to write to: invite them.
    await tester.tap(find.byKey(const Key('firstMessage')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('inviteColleagues')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('inviteEmail')), findsOneWidget);
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    // No tasks: make one.
    await tester.tap(find.byTooltip('My tasks'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('emptyNewTask')));
    await tester.pumpAndSettle();
    expect(find.byType(TaskEditorScreen), findsOneWidget);
  });

  testWidgets('a member with nobody to write to is told whom to ask', (
    tester,
  ) async {
    final api = FakeApi(signedInAs: 'me', name: 'Amr')
      ..memberships.add(
        FakeApi.membership('ws1', 'Engineering', WorkspaceRole.member),
      )
      ..membersByWorkspace['ws1'] = [
        const Member(userId: 'me', fullName: 'Amr', role: WorkspaceRole.member),
      ];
    await startApp(tester, api, prefs: {'locale': 'en'});

    await tester.tap(find.byKey(const Key('firstMessage')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('inviteColleagues')), findsNothing);
    expect(
      find.text('Ask your workspace admin to invite your colleagues.'),
      findsOneWidget,
    );
  });

  testWidgets('my day gathers what needs me today', (tester) async {
    const site = Project(
      id: 'p1',
      workspaceId: 'ws1',
      name: 'Site',
      color: '#0F6E6A',
      status: ProjectStatus.active,
      memberCount: 2,
    );
    final api = FakeApi(signedInAs: 'me', name: 'Amr')
      ..memberships.add(
        FakeApi.membership('ws1', 'Engineering', WorkspaceRole.member),
      )
      ..projectsByWorkspace['ws1'] = [site];
    final now = DateTime.now();
    api
      ..addTask(
        projectId: 'p1',
        title: 'Late one',
        dueAt: now.subtract(const Duration(days: 1)),
      )
      ..addTask(
        projectId: 'p1',
        title: 'Today one',
        dueAt: DateTime(now.year, now.month, now.day, 23, 59),
      )
      ..addTask(
        projectId: 'p1',
        title: 'Not mine',
        assignees: ['u2'],
        dueAt: now.subtract(const Duration(days: 1)),
      );
    final chat = api.addProjectChat('ws1', site);
    api.receive(chat, 'u2', 'Mona', '@Amr look', mentions: ['me']);
    await startApp(tester, api, prefs: {'locale': 'en'});

    expect(find.byKey(const Key('myDay')), findsOneWidget);
    String count(String key) => tester
        .widgetList<Text>(
          find.descendant(
            of: find.byKey(Key(key)),
            matching: find.byType(Text),
          ),
        )
        .first
        .data!;
    expect(count('myDayLate'), '1');
    expect(count('myDayToday'), '1');
    expect(count('myDayMentions'), '1');
    expect(find.byKey(const Key('myDayAcks')), findsNothing);

    // Tasks open on the my-tasks tab.
    await tester.tap(find.byKey(const Key('myDayLate')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('myDay')), findsNothing);
    expect(find.text('Late one'), findsOneWidget);
  });

  testWidgets('a quiet day has no card', (tester) async {
    final api = FakeApi(signedInAs: 'me', name: 'Amr')
      ..memberships.add(
        FakeApi.membership('ws1', 'Engineering', WorkspaceRole.member),
      );
    await startApp(tester, api);
    expect(find.byKey(const Key('myDay')), findsNothing);
  });
}
