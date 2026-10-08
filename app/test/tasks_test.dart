import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasla/data/models.dart';
import 'package:wasla/data/task_models.dart';

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
        ),
      ];

/// Amr is an ordinary member of the project; Mona leads it.
FakeApi _member() => _company(role: WorkspaceRole.member)
  ..projectMembersById['p1'] = const [
    ProjectMember(userId: 'me', fullName: 'Amr', role: ProjectRole.member),
    ProjectMember(userId: 'u2', fullName: 'Mona Adel', role: ProjectRole.lead),
  ];

DateTime _inDays(int days) => DateTime.now().add(Duration(days: days));

/// The badge on a bottom-bar tab, or null when hidden.
String? _tabBadge(WidgetTester tester, IconData icon) {
  final badge = tester.widget<Badge>(
    find.ancestor(of: find.byIcon(icon), matching: find.byType(Badge)).first,
  );
  return badge.isLabelVisible ? (badge.label! as Text).data : null;
}

Future<void> _openMyTasks(WidgetTester tester) async {
  await tester.tap(find.text('مهامي'));
  await tester.pumpAndSettle();
}

ChoiceChip _chip(WidgetTester tester, String label) =>
    tester.widget(find.widgetWithText(ChoiceChip, label));

void main() {
  testWidgets('my tasks are grouped by when they are due', (tester) async {
    final api = _company();
    api
      ..addTask(projectId: 'p1', title: 'Send the drawings', dueAt: _inDays(-1))
      ..addTask(projectId: 'p1', title: 'Order tiles', dueAt: _inDays(3))
      ..addTask(projectId: 'p1', title: 'Call the supplier')
      ..addTask(
        projectId: 'p1',
        title: 'Check the site',
        assignees: ['u2'],
        dueAt: _inDays(2),
      );
    await startApp(tester, api);

    // One late task of mine: the tab says so before it is opened.
    expect(_tabBadge(tester, Icons.task_alt_outlined), '1');

    await _openMyTasks(tester);
    expect(find.text('متأخرة · 1'), findsOneWidget);
    expect(find.text('خلال أسبوع · 1'), findsOneWidget);
    expect(find.text('بدون موعد · 1'), findsOneWidget);
    expect(find.text('Send the drawings'), findsOneWidget);
    // Given to someone else: only under "created by me".
    expect(find.text('Check the site'), findsNothing);

    await tester.tap(find.text('أنشأتها'));
    await tester.pumpAndSettle();
    expect(find.text('Check the site'), findsOneWidget);
    expect(find.textContaining('Mona Adel'), findsOneWidget);
    expect(find.text('Send the drawings'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a member creates a task, only for themselves', (tester) async {
    smallPhone(tester);
    final api = _member();
    await startApp(tester, api);
    await _openMyTasks(tester);
    expect(find.text('لا توجد مهام مسندة إليك'), findsOneWidget);

    await tester.tap(find.text('مهمة جديدة'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Measure the hall');
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New Branch').last);
    await tester.pumpAndSettle();
    expect(
      find.text('في هذا المشروع يمكنك إنشاء مهام لنفسك فقط'),
      findsOneWidget,
    );

    await tester.tap(find.text('إنشاء'));
    await tester.pumpAndSettle();
    expect(api.taskCalls, ['create Measure the hall']);
    expect(api.lastDraft!.assigneeIds, ['me']);

    // The new task opens.
    expect(find.text('Measure the hall'), findsOneWidget);
    expect(_chip(tester, 'جديدة').selected, isTrue);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Measure the hall'), findsOneWidget);
  });

  testWidgets('an assignee moves a task along but cannot close it', (
    tester,
  ) async {
    final api = _member();
    final task = api.addTask(
      projectId: 'p1',
      title: 'Paint the lobby',
      createdBy: 'u2',
    );
    await startApp(tester, api);
    await _openMyTasks(tester);
    await tester.tap(find.text('Paint the lobby'));
    await tester.pumpAndSettle();

    // Closing is for whoever gave the task.
    expect(_chip(tester, 'منتهية').onSelected, isNull);
    expect(find.byType(PopupMenuButton<Object?>), findsNothing);

    await tester.tap(find.text('قيد التنفيذ'));
    await tester.pumpAndSettle();
    expect(api.taskCalls, ['status ${task.id} in_progress']);
    expect(api.taskById(task.id).status, TaskStatus.inProgress);

    // On hold asks why.
    await tester.tap(find.text('متوقفة'));
    await tester.pumpAndSettle();
    expect(find.text('سبب التوقف'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'Waiting for paint');
    await tester.tap(find.text('حفظ'));
    await tester.pumpAndSettle();
    expect(api.taskCalls.last, 'status ${task.id} on_hold');
    expect(find.text('متوقفة: Waiting for paint'), findsOneWidget);

    // An update for the people on it.
    await tester.enterText(find.byType(TextField).last, 'Bought the paint');
    await tester.pump();
    await tester.tap(find.byTooltip('إرسال'));
    await tester.pumpAndSettle();
    expect(api.taskCalls.last, 'comment ${task.id} Bought the paint');
    expect(find.text('Bought the paint'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a lead follows up and nudges someone who is late', (
    tester,
  ) async {
    final api = _company();
    final late = api.addTask(
      projectId: 'p1',
      title: 'Submit the invoice',
      assignees: ['u2'],
      dueAt: _inDays(-2),
    );
    api
      ..addTask(
        projectId: 'p1',
        title: 'Approve the layout',
        assignees: ['u2'],
        status: TaskStatus.review,
      )
      ..addTask(projectId: 'p1', title: 'Book the hall', assignees: ['u2']);
    await startApp(tester, api);
    await _openMyTasks(tester);
    await tester.tap(find.byTooltip('المتابعة'));
    await tester.pumpAndSettle();

    expect(find.text('تحتاج تدخلك'), findsOneWidget);
    expect(find.text('متأخرة يومين · Mona Adel'), findsOneWidget);
    expect(find.text('تنتظر مراجعتك · Mona Adel'), findsOneWidget);

    await tester.tap(find.text('ذكّر'));
    await tester.pumpAndSettle();
    expect(api.taskCalls, ['nudge ${late.id}']);
    expect(find.text('تم إرسال التذكير'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a chat message becomes a task in its project', (tester) async {
    final api = _company();
    final chat = api.addProjectChat('ws1', _branch);
    api.receive(chat, 'u2', 'Mona Adel', 'Price the new client\nBy Sunday');
    await startApp(tester, api);

    await tester.tap(find.textContaining('Price the new client'));
    await tester.pumpAndSettle();
    await tester.longPress(find.textContaining('Price the new client').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('تحويل إلى مهمة'));
    await tester.pumpAndSettle();

    // The first line is the title; the project is the chat's.
    expect(find.text('Price the new client'), findsOneWidget);
    expect(find.text('اختر المشروع'), findsNothing);
    await tester.tap(find.text('إنشاء'));
    await tester.pumpAndSettle();

    final draft = api.lastDraft!;
    expect(draft.projectId, 'p1');
    expect(draft.title, 'Price the new client');
    expect(draft.description, 'Price the new client\nBy Sunday');
    expect(draft.sourceMessageId, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a notification opens its task and is marked read', (
    tester,
  ) async {
    final api = _company();
    final task = api.addTask(
      projectId: 'p1',
      title: 'Fix the door',
      createdBy: 'u2',
    );
    api.notify(NotificationKind.assigned, task, actor: 'Mona Adel');
    await startApp(tester, api);

    final bell = find.byTooltip('الإشعارات');
    Badge badge() => tester.widget<Badge>(
      find.descendant(of: bell, matching: find.byType(Badge)),
    );
    expect(badge().isLabelVisible, isTrue);

    await tester.tap(bell);
    await tester.pumpAndSettle();
    expect(find.text('مهمة جديدة لك من Mona Adel'), findsOneWidget);

    await tester.tap(find.text('Fix the door'));
    await tester.pumpAndSettle();
    expect(find.text('قيد التنفيذ'), findsOneWidget);
    expect(api.notificationList.single.unread, isFalse);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(badge().isLabelVisible, isFalse);
    expect(tester.takeException(), isNull);
  });

  test('due groups: late, today, this week, later, undated, done', () {
    final now = DateTime(2026, 10, 8, 12);
    TaskItem task(DateTime? due, {TaskStatus status = TaskStatus.todo}) =>
        TaskItem(
          id: 't',
          workspaceId: 'ws1',
          workspaceName: 'Engineering',
          projectId: 'p1',
          projectName: 'New Branch',
          projectColor: '#C2660A',
          title: 'x',
          status: status,
          createdBy: 'me',
          creatorName: 'Amr',
          createdAt: now,
          updatedAt: now,
          dueAt: due,
        );
    expect(dueGroup(task(DateTime(2026, 10, 8, 11)), now), DueGroup.late);
    expect(dueGroup(task(DateTime(2026, 10, 8, 17)), now), DueGroup.today);
    expect(dueGroup(task(DateTime(2026, 10, 14, 9)), now), DueGroup.week);
    expect(dueGroup(task(DateTime(2026, 10, 15, 9)), now), DueGroup.later);
    expect(dueGroup(task(null), now), DueGroup.noDate);
    expect(
      dueGroup(task(DateTime(2026, 10, 1), status: TaskStatus.done), now),
      DueGroup.done,
    );
  });
}
