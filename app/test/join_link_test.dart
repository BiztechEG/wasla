import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasla/data/models.dart';

import 'fake_api.dart';
import 'harness.dart';

const _ops = CodeWorkspace(
  workspaceId: 'ws9',
  workspaceName: 'Ops',
  companyName: 'Al Nour',
  autoJoin: false,
);

Future<void> _enterCode(WidgetTester tester, String code) async {
  await tester.tap(find.byKey(const Key('haveJoinCode')));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const Key('joinCode')), code);
  await tester.tap(find.text('Continue'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('an admin turns on the join link, shares it, renews it and '
      'turns it off', (tester) async {
    final api = FakeApi(signedInAs: 'me', name: 'Amr')
      ..memberships.add(
        FakeApi.membership('ws1', 'Engineering', WorkspaceRole.owner),
      );
    final sharer = FakeSharer();
    await startApp(tester, api, prefs: {'locale': 'en'}, sharer: sharer);

    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    final tile = find.byKey(const Key('joinLinkTile'));
    await tester.scrollUntilVisible(tile, 200);
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('joinLinkOn')));
    await tester.pumpAndSettle();

    final first = api.joinCodes['ws1']!;
    expect(find.text(first.shown), findsOneWidget);
    expect(first.autoJoin, isFalse);

    await tester.tap(find.byKey(const Key('shareJoinLink')));
    await tester.pumpAndSettle();
    expect(sharer.shared.single.$1, contains(first.shown));
    expect(sharer.shared.single.$1, contains('Engineering'));

    await tester.tap(find.byKey(const Key('joinLinkAuto')));
    await tester.pumpAndSettle();
    expect(api.joinCodes['ws1']!.autoJoin, isTrue);
    expect(api.joinCodes['ws1']!.code, first.code);

    await tester.tap(find.text('New code'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'New code'));
    await tester.pumpAndSettle();
    expect(api.joinCodes['ws1']!.code, isNot(first.code));
    expect(find.text(api.joinCodes['ws1']!.shown), findsOneWidget);

    await tester.tap(find.text('Turn off the join link'));
    await tester.pumpAndSettle();
    expect(api.joinCodes, isEmpty);
    expect(find.byKey(const Key('joinLinkOn')), findsOneWidget);
  });

  testWidgets('a new employee asks to join with a code', (tester) async {
    final api = FakeApi(signedInAs: 'me', name: 'Amr')
      ..codeWorkspaces['ABCDEFGH'] = _ops;
    await startApp(tester, api, prefs: {'locale': 'en'});

    await _enterCode(tester, 'zzzz-zzzz');
    expect(find.text('That code is wrong or no longer works.'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('joinCode')), 'abcd-efgh');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Ops'), findsOneWidget);
    expect(
      find.text('Your request goes to the admins to approve.'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('joinWithCode')));
    await tester.pumpAndSettle();

    expect(api.myRequests.single.workspaceName, 'Ops');
    expect(find.text('Waiting for approval'), findsOneWidget);
  });

  testWidgets('with auto-join the code lets one straight in', (tester) async {
    final api = FakeApi(signedInAs: 'me', name: 'Amr')
      ..codeWorkspaces['ABCDEFGH'] = const CodeWorkspace(
        workspaceId: 'ws9',
        workspaceName: 'Ops',
        companyName: 'Al Nour',
        autoJoin: true,
      );
    await startApp(tester, api, prefs: {'locale': 'en'});

    await _enterCode(tester, 'ABCDEFGH');
    expect(find.text("You'll join straight away as a member."), findsOneWidget);
    await tester.tap(find.text('Join now'));
    await tester.pumpAndSettle();

    expect(api.memberships.single.workspaceName, 'Ops');
    expect(find.byTooltip('Notifications'), findsOneWidget);
  });

  testWidgets('a join link opened before signing in is offered after', (
    tester,
  ) async {
    final api = FakeApi(signedInAs: 'me', name: 'Amr')
      ..codeWorkspaces['ABCDEFGH'] = _ops;
    await startApp(
      tester,
      api,
      prefs: {'locale': 'en', 'pending_join': 'ABCD-EFGH'},
    );

    expect(find.text('Ops'), findsOneWidget);
    expect(find.text('Ask to join'), findsOneWidget);
  });
}
