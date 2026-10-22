import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:wasla/data/chat_models.dart';
import 'package:wasla/data/models.dart';
import 'package:wasla/data/task_models.dart';
import 'package:wasla/ui/widgets.dart';

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
  await tester.tap(find.byTooltip('مهامي'));
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
    expect(_tabBadge(tester, LucideIcons.circleCheck), '1');

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

    await tester.tap(find.byTooltip('مهمة جديدة'));
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
    expect(find.byIcon(Icons.more_vert), findsNothing);

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
    expect(find.text('للمراجعة · Mona Adel'), findsOneWidget);

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
    await tester.tap(find.byKey(const Key('action-task')));
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

  testWidgets('a task whose file fails to upload is still made once', (
    tester,
  ) async {
    final api = _company()..failingUploads.add('plan.pdf');
    final plan = Upload(
      bytes: Uint8List(10),
      name: 'plan.pdf',
      mime: 'application/pdf',
    );
    await startApp(tester, api, picker: FakePicker(plan));
    await _openMyTasks(tester);
    await tester.tap(find.byTooltip('مهمة جديدة'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Send the plan');
    // Done typing, so the field stops keeping itself on screen.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.dragUntilVisible(
      find.text('إرفاق'),
      find.byType(ListView).last,
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('إرفاق'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ملف'));
    await tester.pumpAndSettle();
    expect(find.text('plan.pdf'), findsOneWidget);

    await tester.tap(find.text('إنشاء'));
    await tester.pumpAndSettle();
    final id = api.taskList.single.id;
    expect(api.taskCalls, ['create Send the plan', 'attach $id plan.pdf']);
    expect(
      find.text(
        'أُنشئت المهمة لكن تعذّر إرفاق بعض الملفات، يمكنك إرفاقها من شاشة المهمة',
      ),
      findsOneWidget,
    );
    // The task opens, so it isn't saved a second time.
    expect(_chip(tester, 'جديدة').selected, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('editing a task keeps what others changed meanwhile', (
    tester,
  ) async {
    final api = _member();
    final task = api.addTask(
      projectId: 'p1',
      title: 'Paint the hall',
      assignees: ['me', 'u2'],
    );
    await startApp(tester, api);
    await _openMyTasks(tester);
    await tester.tap(find.text('Paint the hall'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('تعديل المهمة'));
    await tester.pumpAndSettle();

    // Mona is on the task too; Amr doesn't lead the project, so he can't
    // change who it is for, and isn't told he makes tasks only for himself.
    expect(find.text('أنت، Mona Adel'), findsOneWidget);
    expect(
      find.text('في هذا المشروع يمكنك إنشاء مهام لنفسك فقط'),
      findsNothing,
    );

    // Meanwhile Mona makes it urgent from her phone.
    await api.updateTask(
      task.id,
      TaskDraft(
        workspaceId: 'ws1',
        projectId: 'p1',
        title: 'Paint the hall',
        priority: TaskPriority.urgent,
      ),
    );
    api.taskCalls.clear();

    await tester.enterText(find.byType(TextField).first, 'Paint the big hall');
    await tester.tap(find.text('حفظ'));
    await tester.pumpAndSettle();
    expect(api.taskCalls, ['update ${task.id}']);
    expect(api.lastDraft!.title, 'Paint the big hall');
    expect(api.lastDraft!.priority, TaskPriority.urgent);
    expect(api.taskById(task.id).assignees.map((a) => a.id), ['me', 'u2']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a deleted task\'s notification opens nothing', (tester) async {
    final api = _company();
    final task = api.addTask(
      projectId: 'p1',
      title: 'Old job',
      createdBy: 'u2',
    );
    api
      ..notify(NotificationKind.deleted, task, actor: 'Mona Adel')
      ..taskList.remove(task);
    await startApp(tester, api);
    await tester.tap(find.byTooltip('الإشعارات'));
    await tester.pumpAndSettle();
    expect(find.text('حُذفت المهمة · Mona Adel'), findsOneWidget);

    await tester.tap(find.text('Old job'));
    await tester.pumpAndSettle();
    expect(find.text('حُذفت المهمة · Mona Adel'), findsOneWidget);
    expect(api.notificationList.single.unread, isFalse);
    expect(tester.takeException(), isNull);
  });

  test('text limits count characters as the database does', () {
    const limit = RuneLimit(5);
    String type(String text) => limit
        .formatEditUpdate(
          TextEditingValue.empty,
          TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: text.length),
          ),
        )
        .text;
    expect(type('abcdef'), 'abcde');
    expect(type('👍👍👍👍👍👍'), '👍👍👍👍👍');
    // One family on screen, five code points: it doesn't fit after "ab".
    expect(type('ab👨‍👩‍👧'), 'ab');
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

  testWidgets('a task with a due time can repeat weekly', (tester) async {
    final api = _company();
    final task = api.addTask(
      projectId: 'p1',
      title: 'Weekly report',
      dueAt: _inDays(2),
    );
    await startApp(tester, api);
    await _openMyTasks(tester);
    await tester.tap(find.text('Weekly report'));
    await tester.pumpAndSettle();
    expect(find.text('التكرار'), findsNothing);
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('تعديل المهمة'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const Key('repeatTile')),
      100,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.byKey(const Key('repeatTile')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('أسبوعيًا'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('حفظ'));
    await tester.pumpAndSettle();
    expect(api.taskCalls.last, 'repeat ${task.id} weekly');
    expect(find.text('أسبوعيًا'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a project saves its tasks as a template and reuses it', (
    tester,
  ) async {
    final api = _company()
      ..projectsByWorkspace['ws1'] = [
        _branch,
        const Project(
          id: 'p2',
          workspaceId: 'ws1',
          name: 'Second Branch',
          color: '#2F5BD3',
          status: ProjectStatus.active,
          memberCount: 2,
        ),
      ];
    api
      ..addTask(projectId: 'p1', title: 'Rent the place', dueAt: _inDays(3))
      ..addTask(projectId: 'p1', title: 'Hire staff');
    await startApp(tester, api);
    await tester.tap(find.byTooltip('المشاريع'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New Branch'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('المهام').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('saveTemplate')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('templateName')), 'Branch');
    await tester.tap(find.text('حفظ'));
    await tester.pumpAndSettle();
    final saved = api.templates.single;
    expect(saved.name, 'Branch');
    expect(saved.items.map((i) => i.title).toSet(), {
      'Rent the place',
      'Hire staff',
    });
    expect(
      saved.items.firstWhere((i) => i.title == 'Rent the place').dueInDays,
      3,
    );

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Second Branch'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('المهام').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('fromTemplate')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Branch'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('إضافة'));
    await tester.pumpAndSettle();
    expect(api.appliedTemplates.single.$2, 'p2');
    expect(find.text('Rent the place'), findsOneWidget);
    expect(find.text('Hire staff'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
