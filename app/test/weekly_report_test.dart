import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasla/data/models.dart';
import 'package:wasla/data/task_models.dart';
import 'package:wasla/ui/dashboard_screen.dart';

import 'fake_api.dart';
import 'harness.dart';

FakeApi _team(WorkspaceRole role) =>
    FakeApi(signedInAs: 'me', name: 'Amr')
      ..memberships.add(FakeApi.membership('ws1', 'Engineering', role));

void main() {
  testWidgets('the weekly report reads in one line and opens the dashboard', (
    tester,
  ) async {
    final api = _team(WorkspaceRole.owner)
      ..notificationList.add(
        AppNotification(
          id: 'n1',
          kind: NotificationKind.weeklyReport,
          workspaceId: 'ws1',
          workspaceName: 'Engineering',
          detail:
              '{"done": 12, "done_before": 8, "late": 2, "review": 1, '
              '"late_arrivals": 3}',
          createdAt: DateTime.now(),
        ),
      );
    await startApp(tester, api, prefs: {'locale': 'en'});
    await tester.tap(find.byTooltip('Notifications'));
    await tester.pumpAndSettle();

    const line =
        '12 tasks done (8 the week before) · 2 late · 1 in review · '
        '3 late arrivals';
    expect(find.text(line), findsOneWidget);
    await tester.tap(find.text(line));
    await tester.pumpAndSettle();
    expect(find.byType(DashboardScreen), findsOneWidget);
  });

  testWidgets('whoever runs a team turns the report off', (tester) async {
    final api = _team(WorkspaceRole.admin);
    await startApp(tester, api, prefs: {'locale': 'en'});
    await openMyAccount(tester);
    final toggle = find.byKey(const Key('weeklyReport'));
    await tester.scrollUntilVisible(toggle, 200);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(api.weekly, isFalse);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
  });

  testWidgets('a member has no report to turn off', (tester) async {
    final api = _team(WorkspaceRole.member);
    await startApp(tester, api, prefs: {'locale': 'en'});
    await openMyAccount(tester);
    // Down to the end, past where it would be.
    await tester.scrollUntilVisible(find.text('Sign out'), 200);
    expect(find.byKey(const Key('weeklyReport')), findsNothing);
  });
}
