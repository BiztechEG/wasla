import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasla/data/chat_models.dart';
import 'package:wasla/data/models.dart';

import 'fake_api.dart';
import 'harness.dart';

const _branch = Project(
  id: 'p1',
  workspaceId: 'ws1',
  name: 'New Branch',
  color: '#C2660A',
  status: ProjectStatus.active,
  memberCount: 3,
);

FakeApi _company({WorkspaceRole role = WorkspaceRole.owner}) =>
    FakeApi(signedInAs: 'me', name: 'Amr')
      ..memberships.add(FakeApi.membership('ws1', 'Engineering', role))
      ..projectsByWorkspace['ws1'] = [_branch]
      ..membersByWorkspace['ws1'] = [
        Member(userId: 'me', fullName: 'Amr', role: role),
        const Member(
          userId: 'u2',
          fullName: 'Mona Adel',
          role: WorkspaceRole.member,
          email: 'mona@example.com',
        ),
      ];

/// The chats tab's badge on the bottom bar.
String? _badge(WidgetTester tester) {
  final badges = tester.widgetList<Badge>(
    find.descendant(
      of: find.byType(NavigationBar),
      matching: find.byType(Badge),
    ),
  );
  final shown = badges.where((b) => b.isLabelVisible);
  if (shown.isEmpty) return null;
  return (shown.first.label! as Text).data;
}

void main() {
  testWidgets('a project message arrives live, is read, and gets an answer', (
    tester,
  ) async {
    final api = _company();
    final chat = api.addProjectChat('ws1', _branch);
    await startApp(tester, api);

    expect(find.text('لا توجد رسائل بعد'), findsOneWidget);
    expect(_badge(tester), isNull);

    // Someone writes while the list is open.
    api.receive(chat, 'u2', 'Mona Adel', 'التسليم يوم الخميس');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('Mona: التسليم يوم الخميس'), findsOneWidget);
    expect(_badge(tester), '1');

    await tester.tap(find.text('Mona: التسليم يوم الخميس'));
    await tester.pumpAndSettle();
    expect(find.text('التسليم يوم الخميس'), findsOneWidget);
    expect(find.text('Mona Adel'), findsOneWidget);
    expect(api.reads[chat]!['me'], isNotNull);

    await tester.enterText(find.byKey(const Key('messageField')), 'تمام');
    await tester.pump();
    await tester.tap(find.byKey(const Key('sendButton')));
    await tester.pumpAndSettle();
    expect(find.text('تمام'), findsOneWidget);
    expect(api.chatMessages[chat]!.first.body, 'تمام');

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('أنت: تمام'), findsOneWidget);
    expect(_badge(tester), isNull);
  });

  testWidgets('a private chat starts from "new message" and can be tagged', (
    tester,
  ) async {
    final api = _company(role: WorkspaceRole.member);
    api.addProjectChat('ws1', _branch);
    await startApp(tester, api);

    await tester.tap(find.text('رسالة جديدة'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mona Adel'));
    await tester.pumpAndSettle();

    // Files the message under a project they share.
    expect(find.text('بدون مشروع'), findsOneWidget);
    await tester.tap(find.text('بدون مشروع'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New Branch').last);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('messageField')),
      'ممكن ملف المقايسة؟',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('sendButton')));
    await tester.pumpAndSettle();
    expect(find.text('ممكن ملف المقايسة؟'), findsOneWidget);
    expect(api.chatMessages['d-u2']!.single.projectId, 'p1');

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Mona Adel'), findsOneWidget);

    // Filtering by the project keeps the private chat about it.
    await tester.tap(find.widgetWithText(ChoiceChip, 'New Branch'));
    await tester.pumpAndSettle();
    expect(find.text('Mona Adel'), findsOneWidget);
  });

  testWidgets('an announcement shows on top of the chats until it is read', (
    tester,
  ) async {
    final api = _company(role: WorkspaceRole.member)
      ..announcementList.add(
        Announcement(
          id: 'a1',
          projectId: null,
          body: 'الشركة إجازة يوم الأحد',
          pinned: false,
          authorId: 'u9',
          authorName: 'Hala',
          createdAt: DateTime.utc(2026, 10, 8, 8),
          audience: 5,
        ),
      );
    await startApp(tester, api);

    expect(find.text('الشركة إجازة يوم الأحد'), findsOneWidget);
    expect(_badge(tester), '1');

    await tester.tap(find.text('الشركة إجازة يوم الأحد'));
    await tester.pumpAndSettle();
    expect(find.text('نشرة لكل مساحة العمل'), findsOneWidget);
    expect(api.readAnnouncements, {'a1'});

    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(find.text('الشركة إجازة يوم الأحد'), findsNothing);
    expect(_badge(tester), isNull);
  });

  testWidgets('an admin posts a workspace announcement', (tester) async {
    final api = _company();
    await startApp(tester, api);

    await tester.tap(find.text('المزيد'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('نشرات مساحة العمل'));
    await tester.pumpAndSettle();
    expect(find.text('لا توجد نشرات'), findsOneWidget);

    await tester.tap(find.text('نشرة جديدة'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('announcementText')),
      'اجتماع عام الساعة 10',
    );
    await tester.pump();
    await tester.tap(find.text('نشر'));
    await tester.pumpAndSettle();

    expect(find.text('اجتماع عام الساعة 10'), findsOneWidget);
    expect(find.text('قرأها 0 من 3'), findsOneWidget);
    expect(api.announcementList.single.projectId, isNull);
  });

  testWidgets('a project has chat, files, announcements and members tabs', (
    tester,
  ) async {
    smallPhone(tester);
    final api = _company();
    final chat = api.addProjectChat('ws1', _branch);
    api.receive(chat, 'u2', 'Mona Adel', 'وصلت الخامات');
    await startApp(tester, api);

    await tester.tap(find.text('المشاريع'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New Branch'));
    await tester.pumpAndSettle();

    expect(find.text('وصلت الخامات'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('الملفات'));
    await tester.pumpAndSettle();
    expect(find.text('لا توجد ملفات بعد'), findsOneWidget);

    await tester.tap(find.text('النشرات'));
    await tester.pumpAndSettle();
    expect(find.text('لا توجد نشرات'), findsOneWidget);
    expect(find.text('نشرة جديدة'), findsOneWidget);

    await tester.tap(find.text('الأعضاء'));
    await tester.pumpAndSettle();
    expect(find.text('Amr (أنت)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a closed project keeps its chat read-only', (tester) async {
    final api = _company()
      ..projectsByWorkspace['ws1'] = [
        const Project(
          id: 'p1',
          workspaceId: 'ws1',
          name: 'Old Site',
          color: '#2F5BD3',
          status: ProjectStatus.closed,
          memberCount: 2,
        ),
      ];
    final chat = api.addProjectChat('ws1', api.projectsByWorkspace['ws1']![0]);
    api.receive(chat, 'u2', 'Mona Adel', 'تم التسليم');
    await startApp(tester, api);

    // It leaves the chats list and stays readable from the project.
    expect(find.text('Mona: تم التسليم'), findsNothing);
    await tester.tap(find.text('المشاريع'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('المغلقة'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Old Site'));
    await tester.pumpAndSettle();
    expect(find.text('تم التسليم'), findsOneWidget);
    expect(
      find.text('المشروع مغلق أو مؤرشف، ومحادثته للقراءة فقط'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('messageField')), findsNothing);
  });
}
