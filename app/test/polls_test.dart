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
  memberCount: 2,
);

FakeApi _company() => FakeApi(signedInAs: 'me', name: 'Amr')
  ..memberships.add(
    FakeApi.membership('ws1', 'Engineering', WorkspaceRole.owner),
  )
  ..projectsByWorkspace['ws1'] = [_branch]
  ..membersByWorkspace['ws1'] = [
    const Member(userId: 'me', fullName: 'Amr', role: WorkspaceRole.owner),
    const Member(
      userId: 'u2',
      fullName: 'Mona Adel',
      role: WorkspaceRole.member,
    ),
  ];

Future<void> _openChat(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Projects'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('New Branch'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Chat'));
  await tester.pumpAndSettle();
}

int _votes(FakeApi api, String chat, int option) =>
    api.chatMessages[chat]!.first.poll!.votersOf(option).length;

void main() {
  testWidgets('a poll is asked, answered, changed and closed', (tester) async {
    final api = _company();
    final chat = api.addProjectChat('ws1', _branch);
    await startApp(tester, api, prefs: {'locale': 'en'});
    await _openChat(tester);

    await tester.tap(find.byTooltip('Attach'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('attachPoll')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('attachPoll')));
    await tester.pumpAndSettle();

    // A question and one option is not enough.
    await tester.enterText(find.byKey(const Key('pollQuestion')), 'Lunch?');
    await tester.enterText(find.byKey(const Key('pollOptionField-0')), 'Pizza');
    await tester.tap(find.byKey(const Key('sendPoll')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pollQuestion')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('pollOptionField-1')),
      'Koshary',
    );
    await tester.tap(find.byKey(const Key('pollAddOption')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('pollOptionField-2')),
      'Grills',
    );
    await tester.tap(find.byKey(const Key('sendPoll')));
    await tester.pumpAndSettle();

    final poll = api.chatMessages[chat]!.first;
    expect(poll.body, 'Lunch?');
    expect(poll.poll!.options, ['Pizza', 'Koshary', 'Grills']);
    expect(find.text('No votes yet'), findsOneWidget);

    // One answer at a time; a tap on it again takes it back.
    await tester.tap(find.byKey(const Key('pollOption-1')));
    await tester.pumpAndSettle();
    expect(_votes(api, chat, 1), 1);
    await tester.tap(find.byKey(const Key('pollOption-0')));
    await tester.pumpAndSettle();
    expect(_votes(api, chat, 0), 1);
    expect(_votes(api, chat, 1), 0);

    api.vote(poll.id, 'u2', {0});
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('2 people voted'), findsOneWidget);

    // Whoever asked closes it.
    await tester.longPress(find.text('Lunch?'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moreActions')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close voting'));
    await tester.pumpAndSettle();
    expect(find.text('Voting closed'), findsOneWidget);
    await tester.tap(find.byKey(const Key('pollOption-2')));
    await tester.pumpAndSettle();
    expect(_votes(api, chat, 2), 0);
  });

  testWidgets('a message is pinned on top of the chat and taken down', (
    tester,
  ) async {
    final api = _company();
    final chat = api.addProjectChat('ws1', _branch);
    api.receive(chat, 'u2', 'Mona Adel', 'The site address is 12 Nile St.');
    await startApp(tester, api, prefs: {'locale': 'en'});
    await _openChat(tester);
    expect(find.byKey(const Key('pinnedBar')), findsNothing);

    await tester.longPress(find.text('The site address is 12 Nile St.'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moreActions')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pin'));
    await tester.pumpAndSettle();
    expect(api.pins[chat], api.chatMessages[chat]!.first.id);
    expect(
      find.descendant(
        of: find.byKey(const Key('pinnedBar')),
        matching: find.text('Mona: The site address is 12 Nile St.'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('unpin')));
    await tester.pumpAndSettle();
    expect(api.pins, isEmpty);
    expect(find.byKey(const Key('pinnedBar')), findsNothing);
  });

  testWidgets('who may not pin sees the pin, without changing it', (
    tester,
  ) async {
    final api = _company();
    final chat = api.addProjectChat('ws1', _branch);
    api.receive(chat, 'u2', 'Mona Adel', 'Pinned for all');
    api
      ..pins[chat] = api.chatMessages[chat]!.first.id
      ..noPinning.add(chat);
    await startApp(tester, api, prefs: {'locale': 'en'});
    await _openChat(tester);

    expect(find.byKey(const Key('pinnedBar')), findsOneWidget);
    expect(find.byKey(const Key('unpin')), findsNothing);
    await tester.longPress(find.text('Pinned for all').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moreActions')));
    await tester.pumpAndSettle();
    expect(find.text('Unpin'), findsNothing);
    expect(find.text('Pin'), findsNothing);
  });
}
