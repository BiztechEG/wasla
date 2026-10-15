import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasla/data/models.dart';

import 'fake_api.dart';
import 'harness.dart';

Future<void> openManage(WidgetTester tester) async {
  await tester.tap(find.byTooltip('More'));
  await tester.pumpAndSettle();
  final tile = find.byKey(const Key('manageWorkspaces'));
  await tester.scrollUntilVisible(tile, 200);
  await tester.ensureVisible(tile);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('manageWorkspaces')));
  await tester.pumpAndSettle();
}

Future<void> pick(WidgetTester tester, String workspace, String action) async {
  await tester.tap(find.text(workspace).first);
  await tester.pumpAndSettle();
  await tester.tap(find.text(action));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('an owner renames a workspace', (tester) async {
    final api = FakeApi(signedInAs: 'me', name: 'Amr')
      ..memberships.add(
        FakeApi.membership('ws1', 'Engineering', WorkspaceRole.owner),
      );
    await startApp(tester, api, prefs: {'locale': 'en'});
    await openManage(tester);

    await pick(tester, 'Engineering', 'Rename');
    await tester.enterText(find.byType(TextField), 'Field team');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(api.memberships.single.workspaceName, 'Field team');
    expect(find.text('Field team'), findsOneWidget);
  });

  testWidgets('a member can leave but not rename or delete', (tester) async {
    final api = FakeApi(signedInAs: 'me', name: 'Amr')
      ..memberships.addAll([
        FakeApi.membership('ws1', 'Engineering', WorkspaceRole.owner),
        FakeApi.membership('ws2', 'Sales', WorkspaceRole.member),
      ]);
    await startApp(tester, api, prefs: {'locale': 'en'});
    await openManage(tester);

    await tester.tap(find.text('Sales'));
    await tester.pumpAndSettle();
    expect(find.text('Rename'), findsNothing);
    expect(find.text('Delete workspace'), findsNothing);
    await tester.tap(find.text('Leave workspace'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Leave'));
    await tester.pumpAndSettle();

    expect(api.memberships.map((m) => m.workspaceId), ['ws1']);
    expect(find.text('Sales'), findsNothing);
  });

  testWidgets('deleting needs the name typed, and can be undone', (
    tester,
  ) async {
    final api = FakeApi(signedInAs: 'me', name: 'Amr')
      ..memberships.addAll([
        FakeApi.membership('ws1', 'Engineering', WorkspaceRole.owner),
        FakeApi.membership('ws2', 'Old site', WorkspaceRole.owner),
      ]);
    await startApp(tester, api, prefs: {'locale': 'en'});
    await openManage(tester);

    await pick(tester, 'Old site', 'Delete workspace');
    final button = find.byKey(const Key('deleteWorkspaceButton'));
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('deleteConfirmName')), 'Old');
    await tester.pump();
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    await tester.enterText(
      find.byKey(const Key('deleteConfirmName')),
      'Old site',
    );
    await tester.pump();
    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(api.memberships.map((m) => m.workspaceId), ['ws1']);
    expect(find.text('Deleted workspaces'), findsOneWidget);

    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();
    expect(api.memberships.map((m) => m.workspaceId), contains('ws2'));
    expect(find.text('Deleted workspaces'), findsNothing);
  });

  testWidgets('leaving the last workspace goes back to the start page', (
    tester,
  ) async {
    final api = FakeApi(signedInAs: 'me', name: 'Amr')
      ..memberships.add(
        FakeApi.membership('ws1', 'Engineering', WorkspaceRole.admin),
      );
    await startApp(tester, api, prefs: {'locale': 'en'});
    await openManage(tester);

    await pick(tester, 'Engineering', 'Leave workspace');
    await tester.tap(find.widgetWithText(TextButton, 'Leave'));
    await tester.pumpAndSettle();

    expect(find.text('Manage workspaces'), findsNothing);
    expect(find.byType(BackButton), findsNothing);
  });
}
