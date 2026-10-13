import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wasla/data/chat_models.dart';
import 'package:wasla/data/google.dart';
import 'package:wasla/data/models.dart';
import 'package:wasla/data/task_models.dart';
import 'package:wasla/state/google_providers.dart';
import 'package:wasla/state/settings.dart';

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

FakeApi _company() => FakeApi(signedInAs: 'me', name: 'Amr')
  ..memberships.add(
    FakeApi.membership('ws1', 'Engineering', WorkspaceRole.owner),
  )
  ..projectsByWorkspace['ws1'] = [_branch]
  ..membersByWorkspace['ws1'] = [
    const Member(userId: 'me', fullName: 'Amr', role: WorkspaceRole.owner),
  ];

DateTime _inDays(int days) => DateTime.now().add(Duration(days: days));

Future<void> _openTask(WidgetTester tester, String title) async {
  await tester.tap(find.text('مهامي'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(title));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a task goes to Google Calendar and can be taken out', (
    tester,
  ) async {
    final api = _company();
    api.addTask(projectId: 'p1', title: 'Visit the site', dueAt: _inDays(2));
    final google = FakeGoogle();
    await startApp(tester, api, google: google);
    await _openTask(tester, 'Visit the site');

    await tester.tap(find.byKey(const Key('addToCalendar')));
    await tester.pumpAndSettle();
    expect(google.events.values.single.title, 'Visit the site');
    expect(find.text('موجودة في تقويم Google بتاعك'), findsOneWidget);

    await tester.tap(find.byKey(const Key('removeFromCalendar')));
    await tester.pumpAndSettle();
    expect(google.events, isEmpty);
    expect(find.byKey(const Key('addToCalendar')), findsOneWidget);
  });

  testWidgets('saying no to Google adds nothing', (tester) async {
    final api = _company();
    api.addTask(projectId: 'p1', title: 'Visit the site', dueAt: _inDays(2));
    final google = FakeGoogle(allows: false);
    await startApp(tester, api, google: google);
    await _openTask(tester, 'Visit the site');

    await tester.tap(find.byKey(const Key('addToCalendar')));
    await tester.pumpAndSettle();
    expect(google.events, isEmpty);
    expect(find.text('مسمحتش لوصلة بالوصول لـ Google'), findsOneWidget);
  });

  testWidgets('without Google sign-in the calendar page opens instead', (
    tester,
  ) async {
    final api = _company();
    api.addTask(projectId: 'p1', title: 'Visit the site', dueAt: _inDays(2));
    final google = FakeGoogle(available: false);
    await startApp(tester, api, google: google);
    await _openTask(tester, 'Visit the site');

    expect(find.byKey(const Key('addToCalendar')), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('المزيد'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('calendarAuto')), findsNothing);
  });

  testWidgets('turning on the calendar adds every task with a due date', (
    tester,
  ) async {
    final api = _company();
    api.addTask(projectId: 'p1', title: 'Visit the site', dueAt: _inDays(2));
    api.addTask(projectId: 'p1', title: 'No date');
    final google = FakeGoogle();
    // Tall enough to show the whole tab.
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await startApp(tester, api, google: google);
    await tester.tap(find.text('المزيد'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('calendarAuto')));
    await tester.pumpAndSettle();
    expect(google.events.values.map((e) => e.title), ['Visit the site']);

    await tester.tap(find.byKey(const Key('googleDisconnect')));
    await tester.pumpAndSettle();
    expect(google.allowed, isEmpty);
    expect(
      tester
          .widget<SwitchListTile>(find.byKey(const Key('calendarAuto')))
          .value,
      isFalse,
    );
  });

  testWidgets('a file in a chat is saved to Google Drive', (tester) async {
    final api = _company();
    final chat = api.addProjectChat('ws1', _branch);
    api.chatMessages[chat]!.insert(
      0,
      ChatMessage(
        id: 'mf',
        senderId: 'me',
        senderName: 'Amr',
        createdAt: DateTime.now(),
        projectId: 'p1',
        file: const ChatFile(
          id: 'f1',
          name: 'plan.pdf',
          mime: 'application/pdf',
          size: 2048,
          path: 'ws1/plan.pdf',
        ),
      ),
    );
    final google = FakeGoogle();
    await startApp(tester, api, google: google);
    await tester.tap(find.text('المشاريع'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New Branch'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('المحادثة'));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('plan.pdf'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('احفظ في Google Drive'));
    await tester.pumpAndSettle();
    expect(google.drive, ['plan.pdf']);
    expect(find.text('اتحفظ في Google Drive بتاعك'), findsOneWidget);
  });

  test('calendar events follow their tasks', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final google = FakeGoogle()..allowed.add(calendarScope);
    final container = ProviderContainer(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        googleAccountProvider.overrideWithValue(google),
      ],
    );
    addTearDown(container.dispose);
    final calendar = container.read(calendarProvider.notifier);

    final api = _company();
    final task = api.addTask(
      projectId: 'p1',
      title: 'Visit the site',
      dueAt: _inDays(2),
    );
    await calendar.add(task);
    final id = container.read(calendarProvider).events[task.id]!.id;

    final moved = _copy(task, dueAt: _inDays(5));
    await calendar.sync([moved]);
    expect(google.events[id]!.end, moved.dueAt);

    // Kept on the phone across restarts.
    expect(prefs.getString('gcal.events'), contains(id));

    await calendar.sync([_copy(moved, status: TaskStatus.done)]);
    expect(google.events, isEmpty);
    expect(container.read(calendarProvider).events, isEmpty);

    // Without auto, a task never added stays out.
    await calendar.sync([task]);
    expect(google.events, isEmpty);
  });
}

TaskItem _copy(TaskItem t, {DateTime? dueAt, TaskStatus? status}) => TaskItem(
  id: t.id,
  workspaceId: t.workspaceId,
  workspaceName: t.workspaceName,
  projectId: t.projectId,
  projectName: t.projectName,
  projectColor: t.projectColor,
  title: t.title,
  status: status ?? t.status,
  createdBy: t.createdBy,
  creatorName: t.creatorName,
  createdAt: t.createdAt,
  updatedAt: t.updatedAt,
  dueAt: dueAt ?? t.dueAt,
  assignees: t.assignees,
);
