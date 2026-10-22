import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

const _site = Project(
  id: 'p2',
  workspaceId: 'ws1',
  name: 'Site Visit',
  color: '#2F5BD3',
  status: ProjectStatus.active,
  memberCount: 2,
);

FakeApi _company() => FakeApi(signedInAs: 'me', name: 'Amr')
  ..memberships.add(
    FakeApi.membership('ws1', 'Engineering', WorkspaceRole.owner),
  )
  ..projectsByWorkspace['ws1'] = [_branch, _site]
  ..membersByWorkspace['ws1'] = [
    const Member(userId: 'me', fullName: 'Amr', role: WorkspaceRole.owner),
    const Member(
      userId: 'u2',
      fullName: 'Mona Adel',
      role: WorkspaceRole.member,
    ),
  ];

Future<void> _openChat(WidgetTester tester, String project) async {
  await tester.tap(find.byTooltip('Projects'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(project));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Chat'));
  await tester.pumpAndSettle();
}

/// The messages the label screen lists, by their text.
Finder _listed(String text) => find.descendant(
  of: find.byWidgetPredicate(
    (w) => w is ListTile && '${w.key}'.contains('labelled-'),
  ),
  matching: find.text(text),
);

void main() {
  testWidgets('a message is filed under labels and found from any chat', (
    tester,
  ) async {
    final api = _company();
    final branch = api.addProjectChat('ws1', _branch);
    final site = api.addProjectChat('ws1', _site);
    api.receive(branch, 'u2', 'Mona Adel', 'Contract draft v2');
    api.receive(site, 'u2', 'Mona Adel', 'Contract signed');
    final signed = api.chatMessages[site]!.first.id;
    await api.labelMessage(signed, name: 'Contracts');
    await startApp(tester, api, prefs: {'locale': 'en'});
    await _openChat(tester, 'New Branch');
    expect(find.byKey(const Key('label-Contracts')), findsNothing);

    // An existing label is ticked, and a new one made by typing it.
    await tester.longPress(find.text('Contract draft v2'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('quickLabelMore')));
    await tester.pumpAndSettle();
    expect(find.text('Only you see your labels'), findsOneWidget);
    await tester.tap(find.byKey(const Key('pickLabel-Contracts')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('labelField')), ' Urgent ');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('newLabel')));
    await tester.pumpAndSettle();
    final draft = api.chatMessages[branch]!.first.id;
    expect(api.labelLinks.values.where((ids) => ids.contains(draft)).length, 2);
    expect(api.labels.values.map((l) => l.$2), contains('Urgent'));
    await tester.tap(find.byKey(const Key('labelsDone')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('label-Contracts')), findsOneWidget);
    expect(find.byKey(const Key('label-Urgent')), findsOneWidget);

    // Its label shows the messages from every chat...
    await tester.tap(find.byKey(const Key('label-Contracts')));
    await tester.pumpAndSettle();
    expect(_listed('Contract signed'), findsOneWidget);
    expect(_listed('Contract draft v2'), findsOneWidget);

    // ...or this chat's only, which is kept for next time.
    await tester.tap(find.text('This chat'));
    await tester.pumpAndSettle();
    expect(_listed('Contract signed'), findsNothing);
    expect(_listed('Contract draft v2'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('labels_this_chat'), isTrue);

    // A message in this chat is gone to in it.
    await tester.tap(_listed('Contract draft v2'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('labelScope')), findsNothing);
    expect(find.text('Contract draft v2'), findsOneWidget);

    await tester.tap(find.byKey(const Key('label-Contracts')));
    await tester.pumpAndSettle();
    expect(_listed('Contract signed'), findsNothing);

    // One in another chat opens that chat.
    await tester.tap(find.text('All chats'));
    await tester.pumpAndSettle();
    await tester.tap(_listed('Contract signed'));
    await tester.pumpAndSettle();
    expect(find.text('Site Visit'), findsWidgets);
    expect(find.byKey(const Key('label-Contracts')), findsOneWidget);
    expect(find.byKey(const Key('label-Urgent')), findsNothing);
  });

  testWidgets('a message comes off a label in the same sheet', (tester) async {
    final api = _company();
    final branch = api.addProjectChat('ws1', _branch);
    api.receive(branch, 'u2', 'Mona Adel', 'Keep this');
    await api.labelMessage(api.chatMessages[branch]!.first.id, name: 'Later');
    await startApp(tester, api, prefs: {'locale': 'en'});
    await _openChat(tester, 'New Branch');
    expect(find.byKey(const Key('label-Later')), findsOneWidget);

    await tester.longPress(find.text('Keep this'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('quickLabelMore')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pickLabel-Later')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('labelsDone')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('label-Later')), findsNothing);
    expect(api.labelLinks.values.single, isEmpty);
  });

  testWidgets('the labels used last are a tap away in the message menu', (
    tester,
  ) async {
    final api = _company();
    final branch = api.addProjectChat('ws1', _branch);
    api.receive(branch, 'u2', 'Mona Adel', 'Older');
    api.receive(branch, 'u2', 'Mona Adel', 'Quote 7');
    final older = api.chatMessages[branch]!.last.id;
    for (final name in ['Oldest', 'Money', 'Urgent', 'Site']) {
      await api.labelMessage(older, name: name);
    }
    await startApp(tester, api, prefs: {'locale': 'en'});
    await _openChat(tester, 'New Branch');

    // The three used last show above the reactions.
    await tester.longPress(find.text('Quote 7'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quickLabel-Site')), findsOneWidget);
    expect(find.byKey(const Key('quickLabel-Urgent')), findsOneWidget);
    expect(find.byKey(const Key('quickLabel-Money')), findsOneWidget);
    expect(find.byKey(const Key('quickLabel-Oldest')), findsNothing);
    expect(find.byTooltip('Another label'), findsOneWidget);
    await tester.tap(find.byKey(const Key('quickLabel-Money')));
    await tester.pumpAndSettle();
    final quote = api.chatMessages[branch]!.first.id;
    final money = api.labels.entries.firstWhere((e) => e.value.$2 == 'Money');
    expect(api.labelLinks[money.key], contains(quote));
    expect(find.byKey(const Key('label-Money')), findsNWidgets(2));

    // The message is ticked under it, and a tap takes it off.
    await tester.longPress(find.text('Quote 7'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quickLabel-Money')), findsOneWidget);
    await tester.tap(find.byKey(const Key('quickLabel-Money')));
    await tester.pumpAndSettle();
    expect(api.labelLinks[money.key], isNot(contains(quote)));
    expect(find.byKey(const Key('label-Money')), findsOneWidget);

    // A right click has them too.
    await tester.tap(find.text('Quote 7'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('quickLabel-Site')));
    await tester.pumpAndSettle();
    final site = api.labels.entries.firstWhere((e) => e.value.$2 == 'Site');
    expect(api.labelLinks[site.key], contains(quote));
  });

  testWidgets('with no labels yet, the menu offers to add one', (tester) async {
    final api = _company();
    final branch = api.addProjectChat('ws1', _branch);
    api.receive(branch, 'u2', 'Mona Adel', 'First');
    await startApp(tester, api, prefs: {'locale': 'en'});
    await _openChat(tester, 'New Branch');

    await tester.longPress(find.text('First'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Another label'), findsNothing);
    await tester.tap(find.text('Add to a label'));
    await tester.pumpAndSettle();
    expect(find.text('Only you see your labels'), findsOneWidget);
  });

  testWidgets('labels are listed under More, renamed and deleted', (
    tester,
  ) async {
    final api = _company();
    final branch = api.addProjectChat('ws1', _branch);
    api.receive(branch, 'u2', 'Mona Adel', 'Invoice 114');
    await startApp(tester, api, prefs: {'locale': 'en'});

    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    final tile = find.byKey(const Key('labelsTile'));
    await tester.scrollUntilVisible(tile, 200);
    await Scrollable.ensureVisible(tester.element(tile), alignment: 0.5);
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.text("You haven't labelled any messages yet"), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await api.labelMessage(api.chatMessages[branch]!.first.id, name: 'Money');
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.text('Money'), findsOneWidget);
    expect(find.text('1 message'), findsOneWidget);

    await tester.tap(find.text('Money'));
    await tester.pumpAndSettle();
    // Opened from outside a chat: every chat, with no choice to make.
    expect(find.byKey(const Key('labelScope')), findsNothing);
    expect(_listed('Invoice 114'), findsOneWidget);

    await tester.tap(find.byKey(const Key('labelMenu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Payments');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(api.labels.values.single.$2, 'Payments');
    expect(find.text('Payments'), findsOneWidget);

    await tester.tap(find.byKey(const Key('labelMenu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete label'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(api.labels, isEmpty);
    expect(find.text("You haven't labelled any messages yet"), findsOneWidget);
  });
}
