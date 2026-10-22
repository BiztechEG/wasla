import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasla/data/chat_models.dart';
import 'package:wasla/data/models.dart';

import 'fake_api.dart';
import 'harness.dart';

FakeApi _leader() =>
    FakeApi(signedInAs: 'me', name: 'Amr')
      ..memberships.addAll([
        FakeApi.membership('ws1', 'Branch A', WorkspaceRole.owner),
        FakeApi.membership('ws2', 'Branch B', WorkspaceRole.admin),
        FakeApi.membership('ws3', 'Branch C', WorkspaceRole.member),
      ]);

Future<void> _openAnnouncements(WidgetTester tester) async {
  await tester.tap(find.byTooltip('More'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Workspace announcements'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('one announcement goes to several workspaces and is followed', (
    tester,
  ) async {
    final api = _leader();
    await startApp(tester, api, prefs: {'locale': 'en'});
    await _openAnnouncements(tester);

    await tester.tap(find.text('New announcement'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('announcementText')),
      'Eid holiday starts Thursday',
    );
    await tester.pump();
    // Only the other workspaces one runs.
    expect(find.byKey(const Key('alsoTo-ws2')), findsOneWidget);
    expect(find.byKey(const Key('alsoTo-ws3')), findsNothing);
    expect(find.byKey(const Key('alsoTo-ws1')), findsNothing);
    await tester.tap(find.byKey(const Key('alsoTo-ws2')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Post'));
    await tester.pumpAndSettle();

    expect(api.broadcasts, [
      ['ws1', 'ws2'],
    ]);
    final posted = api.announcementList.single;
    api.reach[posted.broadcastId!] = const [
      BroadcastReach(
        workspaceId: 'ws1',
        workspaceName: 'Branch A',
        audience: 4,
        readCount: 3,
      ),
      BroadcastReach(
        workspaceId: 'ws2',
        workspaceName: 'Branch B',
        audience: 10,
        readCount: 2,
      ),
    ];
    await tester.tap(find.byKey(Key('reach-${posted.id}')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reachRow-ws1')), findsOneWidget);
    expect(find.text('75%'), findsOneWidget);
    expect(find.text('20%'), findsOneWidget);
  });

  testWidgets('without other workspaces it is a plain announcement', (
    tester,
  ) async {
    final api = FakeApi(signedInAs: 'me', name: 'Amr')
      ..memberships.add(
        FakeApi.membership('ws1', 'Branch A', WorkspaceRole.owner),
      );
    await startApp(tester, api, prefs: {'locale': 'en'});
    await _openAnnouncements(tester);
    await tester.tap(find.text('New announcement'));
    await tester.pumpAndSettle();
    expect(find.text('Also send to'), findsNothing);
    await tester.enterText(find.byKey(const Key('announcementText')), 'Hi');
    await tester.pump();
    await tester.tap(find.text('Post'));
    await tester.pumpAndSettle();
    expect(api.broadcasts, isEmpty);
    expect(api.announcementList.single.broadcastId, isNull);
  });
}
