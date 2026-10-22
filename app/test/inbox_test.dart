import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasla/data/models.dart';
import 'package:wasla/data/task_models.dart';

import 'fake_api.dart';
import 'harness.dart';

const _invite = MyInvite(
  id: 'i1',
  token: 't1',
  workspaceId: 'ws2',
  workspaceName: 'Sales',
  role: WorkspaceRole.member,
  invitedByName: 'Mona',
);

final _asking = JoinRequest(
  id: 'r1',
  userId: 'u2',
  fullName: 'Sara',
  createdAt: DateTime.utc(2026, 10, 8),
  message: 'From the Cairo office',
);

FakeApi _engineering(WorkspaceRole role) =>
    FakeApi(signedInAs: 'me', name: 'Amr')
      ..memberships.add(FakeApi.membership('ws1', 'Engineering', role));

Future<void> _openBell(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Notifications'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('an invitation to another workspace shows on the home screen '
      'and is accepted from there', (tester) async {
    final api = _engineering(WorkspaceRole.member)..invites.add(_invite);
    await startApp(tester, api, prefs: {'locale': 'en'});

    expect(find.text('Mona invited you to Sales'), findsOneWidget);
    // The "more" tab counts it too.
    expect(find.text('1'), findsWidgets);

    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('inviteBanner')),
        matching: find.text('Accept'),
      ),
    );
    await tester.pumpAndSettle();

    expect(api.memberships.map((m) => m.workspaceName), contains('Sales'));
    expect(find.byKey(const Key('inviteBanner')), findsNothing);
    // Now in the workspace just joined.
    expect(find.text('Sales'), findsOneWidget);
  });

  testWidgets('"later" puts the banner away', (tester) async {
    final api = _engineering(WorkspaceRole.member)..invites.add(_invite);
    await startApp(tester, api, prefs: {'locale': 'en'});

    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('inviteBanner')), findsNothing);
    expect(api.invites, hasLength(1));
  });

  testWidgets('the workspace switcher offers invitations too', (tester) async {
    final api = _engineering(WorkspaceRole.member)..invites.add(_invite);
    await startApp(tester, api, prefs: {'locale': 'en'});

    await tester.tap(find.text('Engineering'));
    await tester.pumpAndSettle();
    expect(find.text('Invitations for you'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Accept').last);
    await tester.pumpAndSettle();
    expect(api.memberships.map((m) => m.workspaceName), contains('Sales'));
  });

  testWidgets('an admin answers a request to join right from the bell', (
    tester,
  ) async {
    final api = _engineering(WorkspaceRole.admin)
      ..joinRequestsByWorkspace['ws1'] = [_asking];
    await startApp(tester, api, prefs: {'locale': 'en'});
    api.notifyJoining(
      NotificationKind.joinRequest,
      workspaceId: 'ws1',
      workspaceName: 'Engineering',
      actor: 'Sara',
      detail: 'From the Cairo office',
      joinRequestId: 'r1',
      status: AnswerStatus.pending,
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('approvalsBanner')), findsOneWidget);
    expect(find.text('1 item is waiting for your approval'), findsOneWidget);

    await _openBell(tester);
    expect(find.text('Waiting for your answer'), findsOneWidget);
    expect(find.text('Sara asked to join'), findsOneWidget);
    expect(find.text('«From the Cairo office»'), findsOneWidget);

    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();

    expect(api.decided, [('r1', true)]);
    expect(find.text('Waiting for your answer'), findsNothing);
    // Still listed, now with how it ended.
    expect(find.text('Accepted'), findsOneWidget);
  });

  testWidgets('declining a request asks first', (tester) async {
    final api = _engineering(WorkspaceRole.owner)
      ..joinRequestsByWorkspace['ws1'] = [_asking];
    await startApp(tester, api, prefs: {'locale': 'en'});
    api.notifyJoining(
      NotificationKind.joinRequest,
      workspaceId: 'ws1',
      workspaceName: 'Engineering',
      actor: 'Sara',
      joinRequestId: 'r1',
      status: AnswerStatus.pending,
    );
    await tester.pumpAndSettle();
    await _openBell(tester);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Decline'));
    await tester.pumpAndSettle();
    expect(api.decided, isEmpty);
    await tester.tap(find.widgetWithText(TextButton, 'Decline'));
    await tester.pumpAndSettle();
    expect(api.decided, [('r1', false)]);
    expect(find.text('Declined'), findsOneWidget);
  });

  testWidgets('an invitation in the bell is accepted there', (tester) async {
    final api = _engineering(WorkspaceRole.member)..invites.add(_invite);
    await startApp(tester, api, prefs: {'locale': 'en'});
    api.notifyJoining(
      NotificationKind.invite,
      workspaceId: 'ws2',
      workspaceName: 'Sales',
      actor: 'Mona',
      detail: 'member',
      inviteId: 'i1',
      status: AnswerStatus.pending,
    );
    await tester.pumpAndSettle();
    await _openBell(tester);

    expect(find.text('Mona invited you to join as Member'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Accept').last);
    await tester.pumpAndSettle();

    expect(api.memberships.map((m) => m.workspaceName), contains('Sales'));
    // Back on the home screen, in the new workspace.
    expect(find.byTooltip('Notifications'), findsOneWidget);
  });

  testWidgets('someone waiting on a request moves in once accepted', (
    tester,
  ) async {
    final api = FakeApi(signedInAs: 'me', name: 'Amr')
      ..myRequests.add(
        const MyJoinRequest(id: 'r1', workspaceId: 'ws1', workspaceName: 'Ops'),
      );
    await startApp(tester, api, prefs: {'locale': 'en'});

    expect(find.text('Waiting for approval'), findsOneWidget);
    expect(
      find.text(
        "Waiting for an admin; we'll let you know as soon as they answer",
      ),
      findsOneWidget,
    );
    // The way to get invited is right there, with the email to send.
    expect(find.text('Join your team'), findsOneWidget);
    expect(find.text('amr@example.com'), findsOneWidget);

    api.admit('ws1', 'Ops');
    await tester.pumpAndSettle();

    expect(find.text('Join your team'), findsNothing);
    expect(find.text('Ops'), findsOneWidget);
    expect(find.byTooltip('Notifications'), findsOneWidget);
  });

  testWidgets('a new employee sends their email to the admin', (tester) async {
    final api = FakeApi(signedInAs: 'me', name: 'Amr');
    final sharer = FakeSharer();
    await startApp(tester, api, prefs: {'locale': 'en'}, sharer: sharer);

    await tester.tap(find.text('Send my email to the admin'));
    await tester.pumpAndSettle();
    expect(sharer.shared.single.$1, contains('amr@example.com'));
  });

  testWidgets('after inviting, the admin sends the invitation on', (
    tester,
  ) async {
    final api = _engineering(WorkspaceRole.owner);
    final sharer = FakeSharer();
    await startApp(tester, api, prefs: {'locale': 'en'}, sharer: sharer);

    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Invite people'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('inviteEmail')),
      'Hoda@Example.com',
    );
    await tester.tap(find.text('Create invitation'));
    await tester.pumpAndSettle();

    expect(api.invited, [('ws1', 'hoda@example.com')]);
    expect(find.text('Invitation ready'), findsOneWidget);
    await tester.tap(find.byKey(const Key('shareInvite')));
    await tester.pumpAndSettle();
    final text = sharer.shared.single.$1!;
    expect(text, contains('Engineering'));
    expect(text, contains('hoda@example.com'));

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Invitation ready'), findsNothing);
  });

  testWidgets('the bell explains itself when empty, and groups by day', (
    tester,
  ) async {
    final api = _engineering(WorkspaceRole.member);
    await startApp(tester, api, prefs: {'locale': 'en'});
    await _openBell(tester);
    expect(
      find.textContaining('invitations, requests to join'),
      findsOneWidget,
    );

    api.notifyJoining(
      NotificationKind.requestDeclined,
      workspaceId: 'ws1',
      workspaceName: 'Engineering',
      actor: 'Mona',
    );
    // Lists reload a moment after the last of a burst of changes.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text("Your request to join wasn't accepted"), findsOneWidget);
    // The fake clock is long past.
    expect(find.text('Earlier'), findsOneWidget);
  });
}
