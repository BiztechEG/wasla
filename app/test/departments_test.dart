import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasla/data/models.dart';

import 'fake_api.dart';
import 'harness.dart';

const _north = Project(
  id: 'p1',
  workspaceId: 'ws1',
  name: 'Sales North',
  color: '#C2660A',
  status: ProjectStatus.active,
  memberCount: 2,
  departmentId: 'd1',
);
const _hiring = Project(
  id: 'p2',
  workspaceId: 'ws1',
  name: 'Hiring',
  color: '#0F6E6A',
  status: ProjectStatus.active,
  memberCount: 1,
);

FakeApi _company(WorkspaceRole role) => FakeApi(signedInAs: 'me', name: 'Amr')
  ..memberships.add(FakeApi.membership('ws1', 'Engineering', role))
  ..projectsByWorkspace['ws1'] = [_north, _hiring]
  ..membersByWorkspace['ws1'] = [
    Member(userId: 'me', fullName: 'Amr', role: role),
    const Member(userId: 'u2', fullName: 'Dina', role: WorkspaceRole.member),
  ];

Future<void> _openMore(WidgetTester tester) async {
  await tester.tap(find.byTooltip('More'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('an admin makes a department and names its manager', (
    tester,
  ) async {
    final api = _company(WorkspaceRole.owner);
    await startApp(tester, api, prefs: {'locale': 'en'});
    await _openMore(tester);
    final tile = find.byKey(const Key('departmentsTile'));
    await tester.scrollUntilVisible(tile, 200);
    // In the middle, clear of the floating bars.
    await Scrollable.ensureVisible(tester.element(tile), alignment: 0.5);
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.text('No departments yet'), findsOneWidget);

    await tester.tap(find.byKey(const Key('newDepartment')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('departmentName')), 'Sales');
    await tester.tap(find.byKey(const Key('manager-u2')));
    await tester.tap(find.byKey(const Key('deptProject-Sales North')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('saveDepartment')));
    await tester.tap(find.byKey(const Key('saveDepartment')));
    await tester.pumpAndSettle();

    final saved = api.departmentsByWorkspace['ws1']!.single;
    expect(saved.name, 'Sales');
    expect(saved.managerIds, ['u2']);
    expect(saved.projectIds, ['p1']);
    expect(find.text('1 project · Dina'), findsOneWidget);

    // And deletes it.
    await tester.tap(find.byKey(const Key('department-Sales')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('deleteDepartment')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
    expect(api.departmentsByWorkspace['ws1'], isEmpty);
  });

  testWidgets('a department manager follows and runs its projects', (
    tester,
  ) async {
    final api = _company(WorkspaceRole.member)
      ..managedDepartments['d1'] = 'Sales';
    // Amr is not on either project's team.
    for (final p in ['p1', 'p2']) {
      api.projectMembersById[p] = const [
        ProjectMember(userId: 'u2', fullName: 'Dina', role: ProjectRole.lead),
      ];
    }
    await startApp(tester, api, prefs: {'locale': 'en'});

    // The dashboard, without the admin tools.
    await _openMore(tester);
    expect(find.text('Department dashboard'), findsOneWidget);
    expect(find.byKey(const Key('departmentsTile')), findsNothing);

    // The department's project is theirs to run; another is not.
    await tester.tap(find.byTooltip('Projects'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sales North'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Follow-up'), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hiring'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Follow-up'), findsNothing);
  });

  testWidgets('a member who runs no department sees neither', (tester) async {
    final api = _company(WorkspaceRole.member);
    await startApp(tester, api, prefs: {'locale': 'en'});
    await _openMore(tester);
    expect(find.byKey(const Key('dashboardTile')), findsNothing);
    expect(find.byKey(const Key('departmentsTile')), findsNothing);
  });
}
