import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasla/data/models.dart';
import 'package:wasla/data/overview_models.dart';

import 'fake_api.dart';
import 'harness.dart';

Future<void> _openDashboard(WidgetTester tester) async {
  await tester.tap(find.byTooltip('More'));
  await tester.pumpAndSettle();
  final tile = find.byKey(const Key('dashboardTile'));
  await tester.scrollUntilVisible(tile, 200);
  await tester.pumpAndSettle();
  await tester.tap(tile);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('an owner sees every workspace in numbers', (tester) async {
    final api = FakeApi(signedInAs: 'me', name: 'Amr')
      ..memberships.add(
        FakeApi.membership('ws1', 'Engineering', WorkspaceRole.owner),
      )
      ..overviews.addAll([
        const WorkspaceOverview(
          workspaceId: 'ws1',
          workspaceName: 'Engineering',
          companyName: 'Al Nour',
          members: 12,
          open: 9,
          late: 2,
          review: 1,
          doneWeek: 5,
          doneWeekBefore: 7,
          messagesWeek: 140,
          activePeopleWeek: 10,
          attendance: AttendanceOverview(people: 12, present: 10, late: 3),
          projectList: [
            ProjectOverview(
              id: 'p1',
              name: 'Tower',
              color: '#C2660A',
              total: 10,
              open: 6,
              late: 2,
              done: 4,
            ),
          ],
        ),
        const WorkspaceOverview(
          workspaceId: 'ws2',
          workspaceName: 'Sales',
          companyName: 'Al Nour',
          members: 4,
          open: 1,
        ),
      ]);
    await startApp(tester, api, prefs: {'locale': 'en'});
    await _openDashboard(tester);

    expect(find.text('Management dashboard'), findsOneWidget);
    expect(find.text('All workspaces'), findsOneWidget);
    expect(find.text('16'), findsOneWidget); // people in both
    expect(find.text('Done this week: 5 · the week before: 7'), findsOneWidget);
    expect(
      find.text('Project chats this week: 140 messages from 10 people'),
      findsOneWidget,
    );
    expect(find.text('Attendance today: 10 of 12 · 3 late'), findsOneWidget);
    expect(find.text('Tower'), findsOneWidget);
    expect(find.text('4 of 10'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('No active projects'), 200);
    await tester.scrollUntilVisible(
      find.textContaining('private chats are never counted'),
      200,
    );
  });

  testWidgets('members do not get the dashboard', (tester) async {
    final api = FakeApi(signedInAs: 'me', name: 'Amr')
      ..memberships.add(
        FakeApi.membership('ws1', 'Engineering', WorkspaceRole.member),
      );
    await startApp(tester, api, prefs: {'locale': 'en'});
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dashboardTile')), findsNothing);
  });
}
