import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasla/data/models.dart';
import 'package:wasla/push/push.dart';
import 'package:wasla/push/web_push.dart';

import 'fake_api.dart';
import 'harness.dart';

/// A browser whose notification prompt answers [answer].
class FakeBrowser implements PushMessaging, BrowserNotifications {
  FakeBrowser({this.permission = NotifyPermission.ask, this.answer});

  @override
  NotifyPermission permission;
  final NotifyPermission? answer;
  int asked = 0;

  @override
  Future<NotifyPermission> ask() async {
    asked++;
    if (answer != null) permission = answer!;
    return permission;
  }

  @override
  Future<String?> token() async =>
      permission == NotifyPermission.granted ? 'browser-subscription' : null;
  @override
  Stream<String> get tokenChanges => const Stream.empty();
  @override
  Future<Map<String, String>?> openedAtStart() async => null;
  @override
  Stream<Map<String, String>> get opened => const Stream.empty();
  @override
  String get platform => 'web';
}

FakeApi _team() => FakeApi(signedInAs: 'me', name: 'Amr')
  ..memberships.add(
    FakeApi.membership('ws1', 'Engineering', WorkspaceRole.member),
  );

void main() {
  testWidgets('the chats offer desktop notifications; a click turns them on', (
    tester,
  ) async {
    final api = _team();
    final browser = FakeBrowser(answer: NotifyPermission.granted);
    await startApp(tester, api, push: browser);
    expect(api.pushTokens, isEmpty, reason: 'not before the person agrees');

    expect(
      find.text('فعّل إشعارات سطح المكتب لتصلك الرسائل والصفحة مغلقة'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('bannerTurnOn')));
    await tester.pumpAndSettle();
    expect(browser.asked, 1);
    expect(api.pushTokens, {'browser-subscription': 'ar'});
    expect(find.byKey(const Key('desktopNotificationsBanner')), findsNothing);

    await openMyAccount(tester);
    expect(find.text('مفعّلة في هذا المتصفح'), findsOneWidget);
  });

  testWidgets('put off, the offer stays away; My account still has it', (
    tester,
  ) async {
    final api = _team();
    final browser = FakeBrowser(answer: NotifyPermission.denied);
    await startApp(tester, api, push: browser);
    await tester.tap(find.text('لاحقاً'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('desktopNotificationsBanner')), findsNothing);
    expect(browser.asked, 0);

    await openMyAccount(tester);
    await tester.tap(find.byKey(const Key('turnOnDesktopNotifications')));
    await tester.pumpAndSettle();
    expect(find.textContaining('المتصفح يمنعها'), findsOneWidget);
    expect(api.pushTokens, isEmpty);
  });

  testWidgets('a browser already allowed is registered at start', (
    tester,
  ) async {
    final api = _team();
    await startApp(
      tester,
      api,
      push: FakeBrowser(permission: NotifyPermission.granted),
    );
    expect(api.pushTokens, {'browser-subscription': 'ar'});
    expect(find.byKey(const Key('desktopNotificationsBanner')), findsNothing);
  });

  testWidgets('phones show neither', (tester) async {
    await startApp(tester, _team());
    expect(find.byKey(const Key('desktopNotificationsBanner')), findsNothing);
    await openMyAccount(tester);
    expect(find.byKey(const Key('desktopNotifications')), findsNothing);
  });
}
