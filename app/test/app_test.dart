import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wasla/app.dart';
import 'package:wasla/data/models.dart';
import 'package:wasla/state/providers.dart';
import 'package:wasla/state/settings.dart';

import 'fake_api.dart';

Future<SharedPreferences> _prefs([Map<String, Object> values = const {}]) {
  SharedPreferences.setMockInitialValues(values);
  return SharedPreferences.getInstance();
}

Future<void> _start(
  WidgetTester tester,
  FakeApi api, {
  Map<String, Object> prefs = const {},
}) async {
  final p = await _prefs(prefs);
  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: [
        prefsProvider.overrideWithValue(p),
        apiProvider.overrideWithValue(api),
      ],
      child: const WaslaApp(),
    ),
  );
  await tester.pumpAndSettle();
}

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
    await _start(tester, api);

    // Arabic and right-to-left by default.
    expect(find.text('أرسل رمز الدخول'), findsOneWidget);
    expect(
      Directionality.of(tester.element(find.byKey(const Key('email')))),
      TextDirection.rtl,
    );

    await tester.enterText(find.byKey(const Key('email')), 'Amr@Example.com');
    await tester.tap(find.text('أرسل رمز الدخول'));
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

    // Lands on the projects tab of the workspace just joined.
    expect(find.text('Engineering'), findsOneWidget);
    expect(find.text('New Branch'), findsOneWidget);
    expect(find.text('3 أعضاء'), findsOneWidget);
    // Members cannot create projects.
    expect(find.text('مشروع جديد'), findsNothing);
  });

  testWidgets('owner creates a project', (tester) async {
    final api = FakeApi(signedInAs: 'me', name: 'Amr')
      ..memberships.add(
        FakeApi.membership('ws1', 'Engineering', WorkspaceRole.owner),
      );
    await _start(tester, api);

    expect(find.text('لا توجد مشاريع هنا'), findsOneWidget);
    await tester.tap(find.text('مشروع جديد'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('projectName')), 'Warehouse');
    await tester.tap(find.text('إنشاء'));
    await tester.pumpAndSettle();

    expect(find.text('Warehouse'), findsOneWidget);
    expect(api.projectsByWorkspace['ws1']!.single.name, 'Warehouse');
  });

  testWidgets('dark mode and English are remembered on the device', (
    tester,
  ) async {
    final api = FakeApi(signedInAs: 'me', name: 'Amr')
      ..memberships.add(
        FakeApi.membership('ws1', 'Engineering', WorkspaceRole.member),
      );
    await _start(tester, api);

    await tester.tap(find.text('المزيد'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('غامق'), 200);
    await tester.tap(find.text('غامق'));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.text('غامق'))).brightness,
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
    await _start(tester, api, prefs: {'locale': 'en'});

    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Sign out'), 200);
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Sign out'));
    await tester.pumpAndSettle();

    expect(find.text('Send sign-in code'), findsOneWidget);
  });
}
