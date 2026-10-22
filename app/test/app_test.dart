import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wasla/data/models.dart';

import 'fake_api.dart';
import 'harness.dart';

void main() {
  testWidgets('new user signs in, names themselves and accepts an invite', (
    tester,
  ) async {
    final api = FakeApi()
      ..invites.add(
        const MyInvite(
          token: 't1',
          workspaceId: 'ws1',
          workspaceName: 'Engineering',
          role: WorkspaceRole.member,
          invitedByName: 'Mona',
        ),
      )
      ..projectsByWorkspace['ws1'] = [
        const Project(
          id: 'p1',
          workspaceId: 'ws1',
          name: 'New Branch',
          color: '#C2660A',
          status: ProjectStatus.active,
          memberCount: 3,
        ),
      ];
    await startApp(tester, api);

    // Arabic and right-to-left by default.
    expect(find.text('إرسال رمز الدخول'), findsOneWidget);
    expect(
      Directionality.of(tester.element(find.byKey(const Key('email')))),
      TextDirection.rtl,
    );

    await tester.enterText(find.byKey(const Key('email')), 'Amr@Example.com');
    await tester.tap(find.text('إرسال رمز الدخول'));
    await tester.pumpAndSettle();
    expect(api.sentCodes, ['amr@example.com']);

    await tester.enterText(find.byKey(const Key('code')), '123456');
    await tester.tap(find.text('دخول'));
    await tester.pumpAndSettle();

    expect(find.text('ما اسمك؟'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('fullName')), 'Amr');
    await tester.tap(find.text('متابعة'));
    await tester.pumpAndSettle();

    expect(find.text('دعوات لك'), findsOneWidget);
    expect(find.text('Engineering'), findsOneWidget);
    await tester.tap(find.text('قبول'));
    await tester.pumpAndSettle();

    // Lands on the chats of the workspace just joined.
    expect(find.text('Engineering'), findsOneWidget);
    expect(find.text('لا توجد محادثات بعد'), findsOneWidget);

    await tester.tap(find.byTooltip('المشاريع'));
    await tester.pumpAndSettle();
    expect(find.text('New Branch'), findsOneWidget);
    expect(find.text('3 أعضاء'), findsOneWidget);
    // Members cannot create projects.
    expect(find.byTooltip('مشروع جديد'), findsNothing);
  });

  testWidgets('back goes to the first tab, then asks before closing', (
    tester,
  ) async {
    final api = FakeApi(signedInAs: 'me', name: 'Amr')
      ..memberships.add(
        FakeApi.membership('ws1', 'Engineering', WorkspaceRole.owner),
      );
    await startApp(tester, api);

    await tester.tap(find.byTooltip('المشاريع'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('الخروج من وصلة؟'), findsNothing);
    expect(find.text('المحادثات'), findsNWidgets(2));

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('الخروج من وصلة؟'), findsOneWidget);
    await tester.tap(find.text('إلغاء'));
    await tester.pumpAndSettle();
    expect(find.text('الخروج من وصلة؟'), findsNothing);
    expect(find.text('المحادثات'), findsNWidgets(2));
  });

  testWidgets('owner creates a project', (tester) async {
    final api = FakeApi(signedInAs: 'me', name: 'Amr')
      ..memberships.add(
        FakeApi.membership('ws1', 'Engineering', WorkspaceRole.owner),
      );
    await startApp(tester, api);

    await tester.tap(find.byTooltip('المشاريع'));
    await tester.pumpAndSettle();
    expect(find.text('لا توجد مشاريع هنا'), findsOneWidget);
    await tester.tap(find.byTooltip('مشروع جديد'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('projectName')), 'Warehouse');
    await tester.tap(find.text('إنشاء'));
    await tester.pumpAndSettle();

    expect(find.text('Warehouse'), findsOneWidget);
    expect(api.projectsByWorkspace['ws1']!.single.name, 'Warehouse');

    // Its group chat is ready in the chats tab.
    await tester.tap(find.byTooltip('المحادثات'));
    await tester.pumpAndSettle();
    expect(find.text('لا توجد رسائل بعد'), findsOneWidget);
  });

  testWidgets('dark mode and English are remembered on the device', (
    tester,
  ) async {
    final api = FakeApi(signedInAs: 'me', name: 'Amr')
      ..memberships.add(
        FakeApi.membership('ws1', 'Engineering', WorkspaceRole.member),
      );
    await startApp(tester, api);

    await tester.tap(find.byTooltip('المزيد'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('داكن'), 200);
    await tester.ensureVisible(find.text('داكن'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('داكن'));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.text('داكن'))).brightness,
      Brightness.dark,
    );

    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();
    expect(find.text('Dark'), findsOneWidget);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('theme'), 'dark');
    expect(prefs.getString('locale'), 'en');
  });

  testWidgets('signing out returns to the sign-in screen', (tester) async {
    final api = FakeApi(signedInAs: 'me', name: 'Amr')
      ..memberships.add(
        FakeApi.membership('ws1', 'Engineering', WorkspaceRole.member),
      );
    await startApp(tester, api, prefs: {'locale': 'en'});

    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Sign out'), 200);
    await tester.ensureVisible(find.text('Sign out'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Sign out'));
    await tester.pumpAndSettle();

    expect(find.text('Send sign-in code'), findsOneWidget);
  });

  testWidgets('pulling to refresh lets someone in once a request is approved', (
    tester,
  ) async {
    final api = FakeApi(signedInAs: 'me', name: 'Amr');
    await startApp(tester, api);
    expect(find.text('ابدأ مع وصلة'), findsOneWidget);

    // An admin accepts the request somewhere else.
    api.memberships.add(
      FakeApi.membership('ws1', 'Engineering', WorkspaceRole.member),
    );
    await tester.fling(find.byType(ListView), const Offset(0, 400), 1000);
    await tester.pumpAndSettle();

    expect(find.text('Engineering'), findsOneWidget);
    expect(find.byTooltip('المشاريع'), findsWidgets);
  });

  testWidgets('screens on top close when the session ends', (tester) async {
    final api = FakeApi(signedInAs: 'me', name: 'Amr')
      ..memberships.add(
        FakeApi.membership('ws1', 'Engineering', WorkspaceRole.owner),
      );
    await startApp(tester, api);

    await tester.tap(find.byTooltip('المزيد'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('الأعضاء'));
    await tester.pumpAndSettle();
    expect(find.byType(BackButton), findsOneWidget);

    await api.signOut();
    await tester.pumpAndSettle();

    expect(find.text('إرسال رمز الدخول'), findsOneWidget);
    expect(find.byType(BackButton), findsNothing);
  });

  testWidgets('member actions fit on a small phone', (tester) async {
    smallPhone(tester);

    final api = FakeApi(signedInAs: 'me', name: 'Amr')
      ..memberships.add(
        FakeApi.membership('ws1', 'Engineering', WorkspaceRole.owner),
      )
      ..membersByWorkspace['ws1'] = [
        const Member(userId: 'me', fullName: 'Amr', role: WorkspaceRole.owner),
        const Member(
          userId: 'u2',
          fullName: 'Mona',
          role: WorkspaceRole.admin,
          email: 'mona@example.com',
        ),
      ];
    await startApp(tester, api);

    await tester.tap(find.byTooltip('المزيد'));
    await tester.pumpAndSettle();
    final members = find.text('الأعضاء');
    await tester.scrollUntilVisible(members, 100);
    await Scrollable.ensureVisible(tester.element(members), alignment: 0.5);
    await tester.pumpAndSettle();
    await tester.tap(members);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.text('إزالة من مساحة العمل'),
      100,
      scrollable: find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(Scrollable),
      ),
    );
    expect(find.text('إزالة من مساحة العمل'), findsOneWidget);
  });
}
