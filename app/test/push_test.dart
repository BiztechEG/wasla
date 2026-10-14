import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasla/app.dart';
import 'package:wasla/data/models.dart';
import 'package:wasla/push/push.dart';
import 'package:wasla/state/settings.dart';

import 'fake_api.dart';
import 'harness.dart';

/// A phone's notification service under the test's control.
class FakePush implements PushMessaging {
  FakePush({this.startedFrom});

  final Map<String, String>? startedFrom;
  final taps = StreamController<Map<String, String>>.broadcast();
  final refreshed = StreamController<String>.broadcast();

  @override
  Future<String?> token() async => 'phone-token-1';
  @override
  Stream<String> get tokenChanges => refreshed.stream;
  @override
  Future<Map<String, String>?> openedAtStart() async => startedFrom;
  @override
  Stream<Map<String, String>> get opened => taps.stream;
  @override
  String get platform => 'android';
}

const _branch = Project(
  id: 'p1',
  workspaceId: 'ws1',
  name: 'New Branch',
  color: '#C2660A',
  status: ProjectStatus.active,
  memberCount: 3,
);

FakeApi _company() => FakeApi(signedInAs: 'me', name: 'Amr')
  ..memberships.add(
    FakeApi.membership('ws1', 'Engineering', WorkspaceRole.owner),
  )
  ..projectsByWorkspace['ws1'] = [_branch];

void main() {
  testWidgets('the phone is registered in the app language until sign-out', (
    tester,
  ) async {
    final api = _company();
    final push = FakePush();
    await startApp(tester, api, push: push);
    expect(api.pushTokens, {'phone-token-1': 'ar'});

    final container = ProviderScope.containerOf(
      tester.element(find.byType(WaslaApp)),
    );
    await container
        .read(settingsProvider.notifier)
        .setLocale(const Locale('en'));
    await tester.pumpAndSettle();
    expect(api.pushTokens, {'phone-token-1': 'en'});

    push.refreshed.add('phone-token-2');
    await tester.pumpAndSettle();
    expect(api.pushTokens.keys, contains('phone-token-2'));

    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Sign out'), 200);
    await tester.ensureVisible(find.text('Sign out'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign out').last);
    await tester.pumpAndSettle();
    expect(api.pushTokens.keys, isNot(contains('phone-token-2')));
  });

  testWidgets('tapping a chat notification opens the chat', (tester) async {
    final api = _company();
    final chat = api.addProjectChat('ws1', _branch);
    api.receive(chat, 'u2', 'Mona Adel', 'التسليم يوم الخميس');
    final push = FakePush();
    await startApp(tester, api, push: push);

    push.taps.add({'type': 'chat', 'workspace': 'ws1', 'conversation': chat});
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('messageField')), findsOneWidget);
    expect(find.text('التسليم يوم الخميس'), findsOneWidget);
  });

  testWidgets('the notification the app was opened from is shown', (
    tester,
  ) async {
    final api = _company();
    final push = FakePush(
      startedFrom: {'type': 'announcement', 'workspace': 'ws1'},
    );
    await startApp(tester, api, push: push);
    expect(find.text('نشرات مساحة العمل'), findsOneWidget);
  });
}
