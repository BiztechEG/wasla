import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasla/data/chat_models.dart';
import 'package:wasla/data/models.dart';
import 'package:wasla/data/search_models.dart';
import 'package:wasla/data/task_models.dart';
import 'package:wasla/ui/files_common.dart';
import 'package:wasla/ui/modern.dart';

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
      of: find.byType(FloatingNavBar),
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

    await tester.tap(find.byTooltip('رسالة جديدة'));
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
    await tester.tap(find.byTooltip('New Branch'));
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

    await tester.tap(find.byTooltip('المزيد'));
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

  testWidgets('a project has status, chat, files, tasks and announcements', (
    tester,
  ) async {
    smallPhone(tester);
    final api = _company();
    final chat = api.addProjectChat('ws1', _branch);
    api.receive(chat, 'u2', 'Mona Adel', 'وصلت الخامات');
    await startApp(tester, api);

    await tester.tap(find.byTooltip('المشاريع'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New Branch'));
    await tester.pumpAndSettle();

    // It opens on how the project is going.
    expect(find.text('لا توجد مهام عامة مفتوحة'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('المحادثة'));
    await tester.pumpAndSettle();
    expect(find.text('وصلت الخامات'), findsOneWidget);

    await tester.tap(find.text('الملفات'));
    await tester.pumpAndSettle();
    expect(find.text('لا توجد ملفات بعد'), findsOneWidget);

    await tester.tap(find.text('المهام'));
    await tester.pumpAndSettle();
    expect(find.text('لا توجد مهام في هذا المشروع'), findsOneWidget);

    await tester.ensureVisible(find.text('النشرات'));
    await tester.tap(find.text('النشرات'));
    await tester.pumpAndSettle();
    expect(find.text('لا توجد نشرات'), findsOneWidget);
    expect(find.text('نشرة جديدة'), findsOneWidget);

    await tester.tap(find.byTooltip('أعضاء المشروع'));
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
    await tester.tap(find.byTooltip('المشاريع'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('المغلقة'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Old Site'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('المحادثة'));
    await tester.pumpAndSettle();
    expect(find.text('تم التسليم'), findsOneWidget);
    expect(
      find.text('المشروع مغلق أو مؤرشف، ومحادثته للقراءة فقط'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('messageField')), findsNothing);
  });

  testWidgets('photos and videos sit in a bounded frame and open full size', (
    tester,
  ) async {
    final api = _company();
    final chat = api.addProjectChat('ws1', _branch);
    ChatMessage media(String id, String name, String mime) => ChatMessage(
      id: id,
      senderId: 'u2',
      senderName: 'Mona Adel',
      createdAt: DateTime.now(),
      projectId: 'p1',
      file: ChatFile(
        id: 'f$id',
        name: name,
        mime: mime,
        size: 4000000,
        path: 'ws1/$name',
      ),
    );
    api.chatMessages[chat]!.insertAll(0, [
      media('v1', 'site.mp4', 'video/mp4'),
      media('i1', 'plan.jpg', 'image/jpeg'),
    ]);
    await startApp(tester, api);
    await tester.tap(find.byTooltip('المشاريع'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New Branch'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('المحادثة'));
    await tester.pumpAndSettle();

    final frames = find.byType(ChatMedia);
    expect(frames, findsNWidgets(2));
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    for (final frame in tester.widgetList<ChatMedia>(frames)) {
      expect(frame.width, lessThanOrEqualTo(260));
    }
    for (var i = 0; i < 2; i++) {
      final size = tester.getSize(frames.at(i));
      expect(size.height, lessThanOrEqualTo(size.width * 4 / 3 + 0.5));
      expect(size.width, lessThan(screen.width * 0.78));
    }

    await tester.tap(frames.at(1));
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewerScreen), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    await tester.tap(frames.at(0));
    await tester.pumpAndSettle();
    expect(find.byType(VideoViewerScreen), findsOneWidget);
  });

  testWidgets('one search finds people, projects, tasks, files and more', (
    tester,
  ) async {
    final api = _company();
    final chat = api.addProjectChat('ws1', _branch);
    api.receive(chat, 'u2', 'Mona Adel', 'مخطط الفرع جاهز');
    api.workspaceSearches['الفرع'] = WorkspaceSearch(
      tasks: const [
        TaskHit(
          id: 't1',
          title: 'مراجعة مخطط الفرع',
          status: TaskStatus.inProgress,
          projectName: 'New Branch',
        ),
      ],
      files: [
        FileHit(
          file: const ChatFile(
            id: 'f1',
            name: 'الفرع.pdf',
            mime: 'application/pdf',
            size: 1000,
            path: 'ws1/me/a.pdf',
          ),
          createdAt: DateTime.now(),
          projectId: 'p1',
          projectName: 'New Branch',
        ),
      ],
      announcements: [
        AnnouncementHit(
          id: 'a1',
          body: 'افتتاح الفرع الخميس',
          createdAt: DateTime.now(),
          authorName: 'Amr',
        ),
      ],
    );
    await startApp(tester, api);

    await tester.enterText(find.byKey(const Key('chatSearch')), 'الفرع');
    await tester.pumpAndSettle();
    for (final text in [
      'المهام',
      'مراجعة مخطط الفرع',
      'الملفات',
      'الفرع.pdf',
      'مخطط الفرع جاهز',
      'افتتاح الفرع الخميس',
    ]) {
      await tester.scrollUntilVisible(
        find.text(text),
        100,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text(text), findsOneWidget, reason: text);
    }

    await tester.enterText(find.byKey(const Key('chatSearch')), 'new');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('New Branch'), findsWidgets);
  });

  Future<void> openBranchChat(WidgetTester tester) async {
    await tester.tap(find.byTooltip('المشاريع'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New Branch'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('المحادثة'));
    await tester.pumpAndSettle();
  }

  Future<TestGesture> pressMic(WidgetTester tester) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('micButton'))),
    );
    await tester.pump();
    await tester.pump();
    return gesture;
  }

  Future<void> holdFor(WidgetTester tester, Duration length) async {
    await tester.runAsync(() => Future.delayed(length));
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('holding the mic records and letting go sends', (tester) async {
    final api = _company();
    final chat = api.addProjectChat('ws1', _branch);
    final recorder = FakeRecorder();
    await startApp(tester, api, recorder: recorder);
    await openBranchChat(tester);

    // A tap only explains how.
    var gesture = await pressMic(tester);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(recorder.cancelled, 1);
    expect(api.chatMessages[chat], isEmpty);
    expect(find.text('اضغط مطولًا على المايك للتسجيل'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 5));

    gesture = await pressMic(tester);
    expect(find.text('اسحب للإلغاء'), findsOneWidget);
    expect(find.byKey(const Key('lockHint')), findsOneWidget);
    await holdFor(tester, const Duration(seconds: 2));
    await gesture.up();
    await tester.pumpAndSettle();
    final sent = api.chatMessages[chat]!.first.file!;
    expect(sent.mime, 'audio/mp4');
    expect(sent.name, matches(RegExp(r'^voice_[2-9]s\.m4a$')));
    expect(find.byType(VoicePlayer), findsOneWidget);
    expect(find.textContaining('0:0'), findsOneWidget);
    expect(find.text('اسحب للإلغاء'), findsNothing);

    // Typing turns the microphone back into send.
    await tester.enterText(find.byKey(const Key('messageField')), 'تمام');
    await tester.pump();
    expect(find.byKey(const Key('micButton')), findsNothing);
    expect(find.byKey(const Key('sendButton')), findsOneWidget);
  });

  testWidgets('sliding up locks the recording, sliding aside cancels it', (
    tester,
  ) async {
    final api = _company();
    final chat = api.addProjectChat('ws1', _branch);
    final recorder = FakeRecorder();
    await startApp(tester, api, recorder: recorder);
    await openBranchChat(tester);

    // Aside (towards the text, right in Arabic) drops it.
    var gesture = await pressMic(tester);
    await holdFor(tester, const Duration(seconds: 2));
    // Halfway does nothing yet.
    final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    final cancelAt = math.max(150.0, width * 0.45);
    await gesture.moveBy(Offset(cancelAt / 2, 0));
    await tester.pump();
    expect(find.text('اسحب للإلغاء'), findsOneWidget);
    for (var i = 0; i < 4; i++) {
      await gesture.moveBy(Offset(cancelAt / 6, 0));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(recorder.cancelled, 1);
    expect(api.chatMessages[chat], isEmpty);
    expect(find.byKey(const Key('micButton')), findsOneWidget);

    // Up keeps it going without the finger.
    gesture = await pressMic(tester);
    await gesture.moveBy(const Offset(0, -65));
    await tester.pump();
    expect(find.byKey(const Key('lockHint')), findsOneWidget);
    for (var i = 0; i < 4; i++) {
      await gesture.moveBy(const Offset(0, -20));
      await tester.pump();
    }
    await gesture.up();
    await tester.pump();
    expect(find.text('جارٍ التسجيل'), findsOneWidget);
    await holdFor(tester, const Duration(seconds: 2));
    await tester.tap(find.byKey(const Key('sendVoice')));
    await tester.pumpAndSettle();
    expect(
      api.chatMessages[chat]!.first.file!.name,
      matches(RegExp(r'^voice_[2-9]s\.m4a$')),
    );

    // Locked, it can still be thrown away.
    gesture = await pressMic(tester);
    await gesture.moveBy(const Offset(0, -140));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    await tester.tap(find.byKey(const Key('cancelRecording')));
    await tester.pumpAndSettle();
    expect(recorder.cancelled, 2);
    expect(api.chatMessages[chat], hasLength(1));
  });

  testWidgets('without the microphone, recording explains why', (tester) async {
    final api = _company();
    api.addProjectChat('ws1', _branch);
    await startApp(tester, api, recorder: FakeRecorder(allowed: false));
    await openBranchChat(tester);
    final gesture = await pressMic(tester);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.textContaining('الميكروفون'), findsOneWidget);
    expect(find.byKey(const Key('sendVoice')), findsNothing);
  });

  testWidgets('an announcement that asks stays until it is confirmed', (
    tester,
  ) async {
    final api = _company(role: WorkspaceRole.member)
      ..announcementList.add(
        Announcement(
          id: 'a1',
          body: 'تعليمات السلامة الجديدة',
          authorId: 'u9',
          authorName: 'Hala',
          createdAt: DateTime.utc(2026, 10, 8, 8),
          audience: 5,
          needsAck: true,
        ),
      );
    await startApp(tester, api);

    await tester.tap(find.text('تعليمات السلامة الجديدة'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    // Opened, but not confirmed: still on top.
    expect(find.text('تعليمات السلامة الجديدة'), findsOneWidget);

    await tester.tap(find.text('تعليمات السلامة الجديدة'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ackButton')));
    await tester.pumpAndSettle();
    expect(api.ackedAnnouncements, {'a1'});
    expect(find.text('تعليمات السلامة الجديدة'), findsNothing);
  });

  testWidgets('an admin asks for confirmation and sees who read', (
    tester,
  ) async {
    final api = _company();
    await startApp(tester, api);
    await tester.tap(find.byTooltip('المزيد'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('نشرات مساحة العمل'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('نشرة جديدة'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('announcementText')),
      'تحديث اللائحة',
    );
    await tester.tap(find.byKey(const Key('askAck')));
    await tester.pump();
    await tester.tap(find.text('نشر'));
    await tester.pumpAndSettle();
    final posted = api.announcementList.single;
    expect(posted.needsAck, isTrue);
    expect(find.text('قرأها 0 من 3 · أكّد 0'), findsOneWidget);

    api.readersByAnnouncement[posted.id] = [
      AnnouncementReader(
        userId: 'u2',
        name: 'Mona Adel',
        readAt: DateTime.now(),
        acknowledgedAt: DateTime.now(),
      ),
      AnnouncementReader(userId: 'u3', name: 'Karim', readAt: DateTime.now()),
      const AnnouncementReader(userId: 'u4', name: 'Sara'),
    ];
    await tester.tap(find.byKey(Key('readers-${posted.id}')));
    await tester.pumpAndSettle();
    expect(find.text('أكدوا الاطلاع (1)'), findsOneWidget);
    expect(find.text('قرأوها ولم يؤكدوا (1)'), findsOneWidget);
    expect(find.text('لم يفتحوها بعد (1)'), findsOneWidget);
    expect(find.text('Sara'), findsOneWidget);
  });
}
