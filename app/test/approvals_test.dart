import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasla/data/attendance_models.dart';
import 'package:wasla/data/models.dart';
import 'package:wasla/data/task_models.dart';

import 'attendance_team_test.dart' show teamApi;
import 'fake_api.dart';
import 'harness.dart';

const _tower = Project(
  id: 'p1',
  workspaceId: 'ws1',
  name: 'Tower',
  color: '#C2660A',
  status: ProjectStatus.active,
  memberCount: 3,
);

void main() {
  testWidgets('a manager answers everything waiting from one place', (
    tester,
  ) async {
    final api = teamApi()
      ..projectsByWorkspace['ws1'] = [_tower]
      ..joinRequestsByWorkspace['ws1'] = [
        JoinRequest(
          id: 'r1',
          userId: 'u9',
          fullName: 'Sara',
          createdAt: DateTime.utc(2026, 10, 8),
        ),
      ];
    api.addTask(
      projectId: 'p1',
      title: 'Pour the slab',
      assignees: const ['u2'],
      status: TaskStatus.review,
    );
    final now = DateTime.now();
    api.teamFixes.add(
      AttendanceFix(
        id: 'f1',
        personId: 'sami',
        name: 'Sami',
        day: DateTime(now.year, now.month, now.day - 1),
        note: 'Forgot my phone',
      ),
    );
    await startApp(tester, api, prefs: {'locale': 'en'});

    expect(find.text('3 items are waiting for your approval'), findsOneWidget);
    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();

    expect(find.text('Waiting for your approval'), findsOneWidget);
    expect(find.text('Sara'), findsOneWidget);
    expect(find.textContaining('Forgot my phone'), findsOneWidget);
    expect(find.text('Tasks to review'), findsOneWidget);
    expect(find.text('Pour the slab'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Accept').first);
    await tester.pumpAndSettle();
    expect(api.decided, [('r1', true)]);
    expect(find.text('Sara'), findsNothing);

    await tester.tap(find.text('Pour the slab'));
    await tester.pumpAndSettle();
    expect(find.text('Pour the slab'), findsWidgets);
  });

  testWidgets('a member sees only their own tasks to review', (tester) async {
    final api = FakeApi(signedInAs: 'me', name: 'Amr')
      ..memberships.add(
        FakeApi.membership('ws1', 'Engineering', WorkspaceRole.member),
      )
      ..projectsByWorkspace['ws1'] = [_tower];
    api.addTask(
      projectId: 'p1',
      title: 'Mine to close',
      assignees: const ['u2'],
      status: TaskStatus.review,
    );
    api.addTask(
      projectId: 'p1',
      title: 'Not mine',
      createdBy: 'u3',
      assignees: const ['me'],
      status: TaskStatus.review,
    );
    await startApp(tester, api, prefs: {'locale': 'en'});

    expect(find.text('1 item is waiting for your approval'), findsOneWidget);
    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();
    expect(find.text('Mine to close'), findsOneWidget);
    expect(find.text('Not mine'), findsNothing);
  });

  testWidgets('nothing waiting, no banner and a clear empty page', (
    tester,
  ) async {
    final api = FakeApi(signedInAs: 'me', name: 'Amr')
      ..memberships.add(
        FakeApi.membership('ws1', 'Engineering', WorkspaceRole.admin),
      );
    await startApp(tester, api, prefs: {'locale': 'en'});
    expect(find.byKey(const Key('approvalsBanner')), findsNothing);

    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('approvalsTile')));
    await tester.pumpAndSettle();
    expect(find.text('Nothing waiting'), findsOneWidget);
  });
}
