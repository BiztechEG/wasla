import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasla/data/chat_models.dart';
import 'package:wasla/data/models.dart';
import 'package:wasla/data/search_models.dart';
import 'package:wasla/data/task_models.dart';
import 'package:wasla/ui/chat_format.dart';
import 'package:wasla/ui/emoji.dart';
import 'package:wasla/ui/files_common.dart';
import 'package:wasla/ui/mentions.dart';
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

/// Opens the project's chat from its page.
Future<void> _openProjectChat(WidgetTester tester) async {
  await tester.tap(find.byTooltip('المشاريع'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('New Branch'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('المحادثة'));
  await tester.pumpAndSettle();
}

void main() {
  group('several files and the keyboard', keyboardTests);
  group('mentions, reactions and profiles', mentionTests);
  group('files, sharing, dates and reply chains', stage3Tests);
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

  testWidgets('swiping a message replies to it, and the quote leads back', (
    tester,
  ) async {
    final api = _company();
    final chat = api.addProjectChat('ws1', _branch);
    api.receive(chat, 'u2', 'Mona Adel', 'أول رسالة في المشروع');
    final first = api.chatMessages[chat]!.first;
    for (var i = 0; i < 120; i++) {
      api.receive(chat, 'u2', 'Mona Adel', 'متابعة رقم $i');
    }
    final last = api.chatMessages[chat]!.first;
    api.chatMessages[chat]!.insert(
      0,
      ChatMessage(
        id: 'r1',
        senderId: 'me',
        senderName: 'Amr',
        createdAt: last.createdAt.add(const Duration(minutes: 1)),
        body: 'ده لسه مطلوب؟',
        projectId: 'p1',
        replyTo: first.id,
        replySenderName: 'Mona Adel',
        replyBody: first.body,
      ),
    );
    await startApp(tester, api);
    await _openProjectChat(tester);

    // Swiping toward the middle (left, in Arabic) starts a reply.
    await tester.drag(find.text('متابعة رقم 119'), const Offset(-90, 0));
    await tester.pumpAndSettle();
    expect(find.text('رد على Mona Adel: متابعة رقم 119'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('messageField')), 'أيوه');
    await tester.pump();
    await tester.tap(find.byKey(const Key('sendButton')));
    await tester.pumpAndSettle();
    expect(api.chatMessages[chat]!.first.replyTo, last.id);

    // The quote of a message far back loads it and brings it on screen.
    final original = find.byWidgetPredicate(
      (w) =>
          w is Text &&
          (w.data ?? w.textSpan?.toPlainText()) == 'أول رسالة في المشروع' &&
          w.maxLines == null,
    );
    expect(original, findsNothing);
    await tester.tap(find.byKey(const Key('quote')).last);
    await tester.pumpAndSettle();
    expect(original.hitTestable(), findsOneWidget);
  });

  testWidgets('a right click opens the menu, and any part can be selected', (
    tester,
  ) async {
    final api = _company();
    final chat = api.addProjectChat('ws1', _branch);
    api.receive(chat, 'u2', 'Mona Adel', 'رقم الحساب EG3800190005');
    await startApp(tester, api);
    await _openProjectChat(tester);

    await tester.tap(
      find.text('رقم الحساب EG3800190005'),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('نسخ'), findsOneWidget);
    await tester.tap(find.text('تحديد النص'));
    await tester.pumpAndSettle();
    final selectable = tester.widget<SelectableText>(
      find.byKey(const Key('selectableMessage')),
    );
    expect(selectable.data, 'رقم الحساب EG3800190005');
  });

  testWidgets('a long paste goes as a file, or as several messages', (
    tester,
  ) async {
    final api = _company();
    final chat = api.addProjectChat('ws1', _branch);
    await startApp(tester, api);
    await _openProjectChat(tester);

    final long = List.filled(1100, 'word').join(' ');
    expect(long.length, greaterThan(maxMessageLength));
    await tester.enterText(find.byKey(const Key('messageField')), long);
    await tester.pump();
    expect(find.byKey(const Key('longText')), findsOneWidget);
    expect(find.text('5,499 حرف · سيُرسل كملف'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('messageField')), 'المحضر');
    await tester.pump();
    await tester.tap(find.byKey(const Key('sendButton')));
    await tester.pumpAndSettle();
    final sent = api.chatMessages[chat]!.first;
    expect(sent.body, 'المحضر');
    expect(sent.file!.name, 'نص طويل.txt');
    expect(sent.file!.size, long.length);

    // Changing to text sends it whole, over two messages.
    await tester.enterText(find.byKey(const Key('messageField')), long);
    await tester.pump();
    await tester.tap(find.byKey(const Key('longTextMode')));
    await tester.pump();
    expect(find.text('5,499 حرف · سيُرسل على 2 رسائل'), findsOneWidget);
    await tester.tap(find.byKey(const Key('sendButton')));
    await tester.pumpAndSettle();
    final parts = api.chatMessages[chat]!.take(2).toList().reversed;
    expect(parts.map((m) => m.body).join(' '), long);
    for (final m in parts) {
      expect(m.body!.length, lessThanOrEqualTo(maxMessageLength));
    }
  });

  testWidgets('a long message folds until "Read more"', (tester) async {
    final api = _company();
    final chat = api.addProjectChat('ws1', _branch);
    api.receive(
      chat,
      'u2',
      'Mona Adel',
      List.generate(30, (i) => 'سطر ${i + 1}').join('\n'),
    );
    await startApp(tester, api);
    await _openProjectChat(tester);

    expect(find.text('اقرأ المزيد'), findsOneWidget);
    await tester.tap(find.byKey(const Key('readMore')));
    await tester.pumpAndSettle();
    expect(find.text('عرض أقل'), findsOneWidget);
  });

  testWidgets('on a wide screen messages stay narrow; files can download', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = _company();
    final chat = api.addProjectChat('ws1', _branch);
    api.receive(chat, 'u2', 'Mona Adel', List.filled(80, 'كلام').join(' '));
    api.chatMessages[chat]!.insert(
      0,
      ChatMessage(
        id: 'f1',
        senderId: 'u2',
        senderName: 'Mona Adel',
        createdAt: api.chatMessages[chat]!.first.createdAt.add(
          const Duration(minutes: 1),
        ),
        projectId: 'p1',
        file: const ChatFile(
          id: 'file1',
          name: 'notes.txt',
          mime: 'text/plain',
          size: 2000,
          path: 'ws1/notes.txt',
        ),
      ),
    );
    await startApp(tester, api);
    await _openProjectChat(tester);

    final text = find.textContaining('كلام كلام');
    expect(tester.getSize(text).width, lessThanOrEqualTo(520));
    final download = find.byKey(const Key('bubbleDownload'));
    expect(download, findsOneWidget);
    expect(
      tester.getRect(download).right -
          tester.getRect(find.text('notes.txt')).left,
      lessThanOrEqualTo(320),
    );
  });

  test('a download link keeps the file name', () {
    expect(
      downloadLink('https://x.supabase.co/sign/files/a.txt?token=t', 'ملف.txt'),
      'https://x.supabase.co/sign/files/a.txt?token=t&download=%D9%85%D9%84%D9%81.txt',
    );
  });

  test('long text splits between words', () {
    final parts = splitLongText('aaa bbb ccc\nddd eee', 8);
    expect(parts, ['aaa bbb', 'ccc\nddd', 'eee']);
    for (final p in splitLongText(List.filled(50, 'كلمة').join(' '), 30)) {
      expect(p.runes.length, lessThanOrEqualTo(30));
    }
  });

  testWidgets('a project chat says where its details are', (tester) async {
    final api = _company();
    final chat = api.addProjectChat('ws1', _branch);
    api.receive(chat, 'u2', 'Mona Adel', 'صباح الخير');
    await startApp(tester, api);
    await tester.tap(find.text('Mona: صباح الخير'));
    await tester.pumpAndSettle();

    expect(find.text('3 أعضاء · اضغط للتفاصيل'), findsOneWidget);
    await tester.tap(find.byKey(const Key('chatDetails')));
    await tester.pumpAndSettle();
    expect(find.text('الحالة'), findsWidgets);
  });
}

FakeApi _team() {
  final api = _company();
  api.membersByWorkspace['ws1']!.add(
    const Member(
      userId: 'u3',
      fullName: 'Sara Ali',
      role: WorkspaceRole.member,
    ),
  );
  api.projectMembersById['p1'] = const [
    ProjectMember(userId: 'me', fullName: 'Amr', role: ProjectRole.lead),
    ProjectMember(
      userId: 'u2',
      fullName: 'Mona Adel',
      role: ProjectRole.member,
    ),
    ProjectMember(userId: 'u3', fullName: 'Sara Ali', role: ProjectRole.member),
  ];
  return api;
}

void mentionTests() {
  testWidgets('typing @ suggests people, and the message mentions them', (
    tester,
  ) async {
    final api = _team();
    final chat = api.addProjectChat('ws1', _branch);
    await startApp(tester, api);
    await _openProjectChat(tester);

    final field = find.byKey(const Key('messageField'));
    await tester.enterText(field, 'محتاجين @');
    await tester.pump();
    expect(find.byKey(const Key('mention-everyone')), findsOneWidget);
    expect(find.byKey(const Key('mention-u2')), findsOneWidget);
    expect(find.byKey(const Key('mention-me')), findsNothing);

    await tester.enterText(field, 'محتاجين @mo');
    await tester.pump();
    expect(find.byKey(const Key('mention-u3')), findsNothing);
    await tester.tap(find.byKey(const Key('mention-u2')));
    await tester.pump();
    expect(find.byKey(const Key('mentionSuggestions')), findsNothing);
    final text = tester.widget<TextField>(field).controller!.text;
    expect(text, 'محتاجين @Mona Adel ');

    await tester.enterText(field, '$textالصور');
    await tester.pump();
    await tester.tap(find.byKey(const Key('sendButton')));
    await tester.pumpAndSettle();
    expect(api.sentMentions.last, ['u2']);
    expect(api.chatMessages[chat]!.first.mentions, ['u2']);

    // "@الكل" is everyone in the project but oneself.
    await tester.enterText(field, '@ال');
    await tester.pump();
    await tester.tap(find.byKey(const Key('mention-everyone')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sendButton')));
    await tester.pumpAndSettle();
    expect(api.chatMessages[chat]!.first.body, '@الكل');
    expect(api.sentMentions.last, ['u2', 'u3']);
  });

  testWidgets(
    'a mention opens the person\'s card, and the chat list marks it',
    (tester) async {
      final api = _team();
      final chat = api.addProjectChat('ws1', _branch);
      api.receive(
        chat,
        'u3',
        'Sara Ali',
        '@Amr و @Mona Adel راجعوا الملف',
        mentions: ['me', 'u2'],
      );
      await startApp(tester, api);
      expect(find.byKey(const Key('mentionBadge')), findsOneWidget);

      await _openProjectChat(tester);
      // The names are tappable: Mona's opens her card.
      await tester.tapOnText(find.textRange.ofSubstring('@Mona Adel'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('profileCard')), findsOneWidget);
      expect(find.text('mona@example.com'), findsOneWidget);
      expect(find.text('New Branch'), findsWidgets);
    },
  );

  testWidgets('a name in the chat opens a card to message or give a task', (
    tester,
  ) async {
    final api = _team();
    final chat = api.addProjectChat('ws1', _branch);
    api.receive(chat, 'u2', 'Mona Adel', 'رفعت الميزانية');
    await startApp(tester, api);
    await _openProjectChat(tester);

    await tester.tap(find.byKey(const Key('senderName')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('profileCard')), findsOneWidget);
    expect(find.text('عضو'), findsWidgets);

    await tester.tap(find.byKey(const Key('profileMessage')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('profileCard')), findsNothing);
    expect(api.chats.containsKey('d-u2'), isTrue);

    // In the private chat, ⓘ is the same card; "Message" stays here.
    await tester.tap(find.byKey(const Key('chatDetails')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('profileCard')), findsOneWidget);
    await tester.tap(find.byKey(const Key('profileMessage')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('messageField')), findsOneWidget);

    await tester.tap(find.byKey(const Key('chatDetails')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('profileAssign')));
    await tester.pumpAndSettle();
    expect(find.text('Mona Adel'), findsWidgets);
  });

  testWidgets('people react to a message and see who did', (tester) async {
    final api = _team();
    final chat = api.addProjectChat('ws1', _branch);
    api.receive(chat, 'u2', 'Mona Adel', 'العميل وافق على التصميم');
    final m = api.chatMessages[chat]!.first;
    await startApp(tester, api);
    await _openProjectChat(tester);

    await tester.longPress(find.text('العميل وافق على التصميم'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('react-🎉')));
    await tester.pumpAndSettle();
    expect(api.chatMessages[chat]!.first.reactions, {
      '🎉': ['me'],
    });
    expect(find.byKey(const Key('reaction-🎉')), findsOneWidget);

    // Someone else adds the same one: the count goes up.
    api.react(m.id, '🎉', 'u3');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('🎉 2'), findsOneWidget);

    // A long press shows who.
    await tester.longPress(find.byKey(const Key('reaction-🎉')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const Key('whoReacted')),
        matching: find.text('Sara Ali'),
      ),
      findsOneWidget,
    );
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    // Tapping one's own takes it back.
    await tester.tap(find.byKey(const Key('reaction-🎉')));
    await tester.pumpAndSettle();
    expect(api.chatMessages[chat]!.first.reactions, {
      '🎉': ['u3'],
    });
    expect(find.text('🎉 2'), findsNothing);
  });

  testWidgets('the mouse reacts from the message, and emoji alone show big', (
    tester,
  ) async {
    final api = _team();
    final chat = api.addProjectChat('ws1', _branch);
    api.receive(chat, 'u2', 'Mona Adel', 'تمام كده');
    await startApp(tester, api);
    await _openProjectChat(tester);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('تمام كده')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('hoverReact')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('react-👍')));
    await tester.pumpAndSettle();
    expect(api.chatMessages[chat]!.first.reactions.keys, ['👍']);

    // The emoji button opens the picker in place of the keyboard.
    await tester.tap(find.byKey(const Key('emojiButton')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('emojiPanel')), findsOneWidget);
    await tester.tap(find.byKey(const Key('emojiButton')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('emojiPanel')), findsNothing);

    await tester.enterText(find.byKey(const Key('messageField')), '👏👏');
    await tester.pump();
    await tester.tap(find.byKey(const Key('sendButton')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('bigEmoji')), findsOneWidget);
  });

  test('which messages are emoji alone', () {
    expect(isBigEmoji('👍'), isTrue);
    expect(isBigEmoji('👏👏'), isTrue);
    expect(isBigEmoji('❤️ 🎉 ✅'), isTrue);
    expect(isBigEmoji('👨‍👩‍👧'), isTrue);
    expect(isBigEmoji('🇪🇬'), isTrue);
    expect(isBigEmoji('👍👍👍👍'), isFalse);
    expect(isBigEmoji('تمام 👍'), isFalse);
    expect(isBigEmoji('123'), isFalse);
    expect(isBigEmoji(''), isFalse);
  });

  test('mentions are found by name, and @all means everyone', () {
    const people = [
      MentionCandidate(id: null, name: 'الكل'),
      MentionCandidate(id: 'a', name: 'Ali'),
      MentionCandidate(id: 'b', name: 'Ali Hassan'),
    ];
    expect(mentionedIds('@Ali Hassan hi', people), ['b']);
    expect(mentionedIds('@Ali, hi', people), ['a']);
    expect(mentionedIds('mail ali@x.com', people), isEmpty);
    expect(mentionedIds('@all', people), ['a', 'b']);
    expect(matchMentions(people, 'has').map((c) => c.id), ['b']);
    expect(
      mentionQuery(
        const TextEditingValue(
          text: 'hi @Al',
          selection: TextSelection.collapsed(offset: 6),
        ),
      ),
      (start: 3, query: 'Al'),
    );
    expect(
      mentionQuery(
        const TextEditingValue(
          text: 'a@b',
          selection: TextSelection.collapsed(offset: 3),
        ),
      ),
      isNull,
    );
  });
}

/// A text exactly as shown, whether plain or with mentions drawn in it.
Finder _says(String text) => find.byWidgetPredicate(
  (w) => w is Text && (w.data ?? w.textSpan?.toPlainText()) == text,
);

Future<void> _openFilesTab(WidgetTester tester) async {
  await tester.tap(find.byTooltip('المشاريع'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('New Branch'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('الملفات'));
  await tester.pumpAndSettle();
}

void stage3Tests() {
  testWidgets('the files list says where each file came from and leads to '
      'its message', (tester) async {
    final api = _team();
    final chat = api.addProjectChat('ws1', _branch);
    const photo = ChatFile(
      id: 'f-photo',
      name: 'site.png',
      mime: 'image/png',
      size: 2048,
      path: 'ws1/u2/site.png',
    );
    api.receive(chat, 'u2', 'Mona Adel', 'Site photo', file: photo);
    final sent = api.chatMessages[chat]!.first;
    for (var i = 0; i < 70; i++) {
      api.receive(chat, 'u3', 'Sara Ali', 'later $i');
    }
    api.projectFileList['p1'] = [
      ProjectFile(
        file: const ChatFile(
          id: 'f-budget',
          name: 'budget.xlsx',
          mime: 'application/vnd.ms-excel',
          size: 4096,
          path: 'ws1/me/budget.xlsx',
        ),
        pinned: true,
        uploadedBy: 'me',
        uploaderName: 'Amr',
        createdAt: DateTime.utc(2026, 10, 8, 12),
      ),
      ProjectFile(
        file: photo,
        pinned: false,
        uploadedBy: 'u2',
        uploaderName: 'Mona Adel',
        createdAt: sent.createdAt,
        conversationId: chat,
        source: FileSource.project,
        messageId: sent.id,
      ),
      ProjectFile(
        file: const ChatFile(
          id: 'f-quote',
          name: 'quote.pdf',
          mime: 'application/pdf',
          size: 1024,
          path: 'ws1/u2/quote.pdf',
        ),
        pinned: false,
        uploadedBy: 'u2',
        uploaderName: 'Mona Adel',
        createdAt: DateTime.utc(2026, 9, 14, 10),
        conversationId: 'd-u2',
        privateChat: true,
        source: FileSource.direct,
        otherId: 'u2',
        otherName: 'Mona Adel',
      ),
    ];
    await startApp(tester, api);
    await _openFilesTab(tester);

    expect(find.text('ملفات New Branch'), findsOneWidget);
    expect(find.text('أكتوبر 2026'), findsOneWidget);
    expect(find.text('سبتمبر 2026'), findsOneWidget);
    expect(find.text('ملفان'), findsOneWidget);
    expect(find.textContaining('من الملفات ·'), findsOneWidget);
    expect(find.textContaining('محادثة المشروع ·'), findsOneWidget);
    expect(find.textContaining('خاصة بينك وبين'), findsOneWidget);
    expect(find.byKey(const Key('pinnedMark')), findsOneWidget);

    await tester.tap(find.byKey(const Key('fileFilter-media')));
    await tester.pumpAndSettle();
    expect(find.text('site.png'), findsOneWidget);
    expect(find.text('budget.xlsx'), findsNothing);
    await tester.tap(find.byKey(const Key('fileFilter-all')));
    await tester.enterText(find.byKey(const Key('fileSearch')), 'QUO');
    await tester.pumpAndSettle();
    expect(find.text('quote.pdf'), findsOneWidget);
    expect(find.text('site.png'), findsNothing);
    await tester.enterText(find.byKey(const Key('fileSearch')), '');
    await tester.pumpAndSettle();

    // A file from the Files tab, never sent in a chat, has no message.
    await tester.tap(find.byKey(const Key('fileMenu-f-budget')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pickedFile')), findsOneWidget);
    expect(find.text('New Branch · من الملفات'), findsOneWidget);
    expect(find.byKey(const Key('fileAction-goto')), findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('fileMenu')), findsNothing);

    // The photo opens the chat at its message, far back.
    await tester.tap(find.byKey(const Key('fileMenu-f-photo')));
    await tester.pumpAndSettle();
    expect(find.text('New Branch · محادثة المشروع'), findsOneWidget);
    await tester.tap(find.byKey(const Key('fileAction-goto')));
    await tester.pumpAndSettle();
    expect(_says('Site photo').hitTestable(), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a file added from the Files tab is sent in the chat too', (
    tester,
  ) async {
    final api = _team();
    final chat = api.addProjectChat('ws1', _branch);
    final picker = FakePicker(
      Upload(
        bytes: Uint8List.fromList([1, 2, 3]),
        name: 'plan.pdf',
        mime: 'application/pdf',
      ),
    );
    await startApp(tester, api, picker: picker);
    await _openFilesTab(tester);

    await tester.tap(find.byKey(const Key('addFile')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ملف'));
    await tester.pumpAndSettle();
    expect(find.text('plan.pdf'), findsOneWidget);
    expect(api.chatMessages[chat]!.first.fromFiles, isTrue);

    await tester.tap(
      find.byKey(Key('fileMenu-${api.projectFileList['p1']!.first.file.id}')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('fileAction-goto')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('fromFiles')), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('a message is shared out, unless the workspace turned it off', (
    tester,
  ) async {
    final api = _team();
    final chat = api.addProjectChat('ws1', _branch);
    api.receive(chat, 'u2', 'Mona Adel', 'The client approved the quote');
    final sharer = FakeSharer();
    await startApp(tester, api, sharer: sharer);
    await _openProjectChat(tester);

    await tester.longPress(_says('The client approved the quote'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moreActions')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('مشاركة'));
    await tester.tap(find.text('مشاركة'));
    await tester.pumpAndSettle();
    expect(sharer.shared, [('The client approved the quote', null)]);
  });

  testWidgets('a long press shows three quick actions, the rest on asking', (
    tester,
  ) async {
    final api = _team();
    final chat = api.addProjectChat('ws1', _branch);
    api.receive(chat, 'u2', 'Mona Adel', 'Quick or more');
    await startApp(tester, api);
    await _openProjectChat(tester);

    await tester.longPress(_says('Quick or more'));
    await tester.pumpAndSettle();
    for (final id in ['reply', 'copy', 'task']) {
      expect(find.byKey(Key('action-$id')), findsOneWidget);
    }
    expect(find.text('تحديد النص'), findsNothing);
    await tester.tap(find.byKey(const Key('moreActions')));
    await tester.pumpAndSettle();
    expect(find.text('تحديد النص'), findsOneWidget);
    await tester.tap(find.byKey(const Key('action-reply')));
    await tester.pumpAndSettle();
    expect(find.text('رد على Mona Adel: Quick or more'), findsOneWidget);
  });

  testWidgets('without a share sheet the text is copied instead', (
    tester,
  ) async {
    final api = _team();
    final chat = api.addProjectChat('ws1', _branch);
    api.receive(chat, 'u2', 'Mona Adel', 'Copy me');
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    await startApp(tester, api, sharer: FakeSharer(available: false));
    await _openProjectChat(tester);

    await tester.longPress(_says('Copy me'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moreActions')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('مشاركة'));
    await tester.tap(find.text('مشاركة'));
    await tester.pumpAndSettle();
    expect(find.text('المشاركة غير متاحة هنا، لذا نُسخ النص'), findsOneWidget);
    expect(copied, 'Copy me');
  });

  testWidgets('with sharing off there is no share button, and admins set it', (
    tester,
  ) async {
    final api = _team();
    api.memberships
      ..clear()
      ..add(
        FakeApi.membership(
          'ws1',
          'Engineering',
          WorkspaceRole.owner,
          allowSharing: false,
        ),
      );
    final chat = api.addProjectChat('ws1', _branch);
    api.receive(chat, 'u2', 'Mona Adel', 'Not for outside');
    await startApp(tester, api);
    await _openProjectChat(tester);

    await tester.longPress(_says('Not for outside'));
    await tester.pumpAndSettle();
    expect(find.text('مشاركة'), findsNothing);
    expect(find.text('نسخ'), findsOneWidget);
  });

  testWidgets('an admin turns sharing outside Wasla on and off', (
    tester,
  ) async {
    final api = _team();
    api.memberships
      ..clear()
      ..add(
        FakeApi.membership(
          'ws1',
          'Engineering',
          WorkspaceRole.owner,
          allowSharing: false,
        ),
      );
    await startApp(tester, api);
    await tester.tap(find.byTooltip('المزيد'));
    await tester.pumpAndSettle();
    final toggle = find.byKey(const Key('allowSharing'));
    await tester.scrollUntilVisible(
      toggle,
      100,
      scrollable: find.byType(Scrollable).first,
    );
    final tile = tester.widget<SwitchListTile>(toggle);
    expect(tile.value, isFalse);
    tile.onChanged!(true);
    await tester.pumpAndSettle();
    expect(api.sharingChanges, [('ws1', true)]);
  });

  testWidgets('the calendar opens a day at its first message, and Latest '
      'comes back', (tester) async {
    final api = _team();
    final chat = api.addProjectChat('ws1', _branch);
    api.receive(chat, 'u2', 'Mona Adel', 'Good morning, phase two starts');
    for (var i = 0; i < 5; i++) {
      api.receive(chat, 'u3', 'Sara Ali', 'day one $i');
    }
    api.skip(const Duration(days: 2));
    api.receive(chat, 'u2', 'Mona Adel', 'First on day three');
    for (var i = 0; i < 80; i++) {
      api.receive(chat, 'u3', 'Sara Ali', 'day three $i');
    }
    await startApp(tester, api);
    await tester.tap(find.textContaining('day three 79'));
    await tester.pumpAndSettle();
    expect(_says('day three 79'), findsOneWidget);

    Future<void> openOctober() async {
      await tester.tap(find.byKey(const Key('jumpToDate')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('dateSheet')), findsOneWidget);
      for (
        var i = 0;
        i < 36 && find.text('أكتوبر 2026').evaluate().isEmpty;
        i++
      ) {
        await tester.tap(find.byKey(const Key('prevMonth')));
        await tester.pump();
      }
    }

    await openOctober();
    await tester.tap(find.byKey(const Key('day-8')));
    await tester.pump();
    expect(find.text('اذهب لـ 8 أكتوبر'), findsOneWidget);
    await tester.tap(find.byKey(const Key('goToDay')));
    await tester.pumpAndSettle();
    expect(
      _says('Good morning, phase two starts').hitTestable(),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 3));

    // Far from the newest: "Latest" counts them and goes back.
    expect(find.byKey(const Key('jumpLatest')), findsOneWidget);
    expect(find.byKey(const Key('latestCount')), findsOneWidget);
    await tester.tap(find.byKey(const Key('jumpLatest')));
    await tester.pumpAndSettle();
    expect(_says('day three 79').hitTestable(), findsOneWidget);
    expect(find.byKey(const Key('jumpLatest')), findsNothing);

    // A day without messages opens the next day that has some.
    await openOctober();
    await tester.tap(find.byKey(const Key('day-9')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('goToDay')));
    await tester.pumpAndSettle();
    expect(_says('First on day three').hitTestable(), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('replies gather under the message and open as one chain', (
    tester,
  ) async {
    final api = _team();
    final chat = api.addProjectChat('ws1', _branch);
    api.receive(chat, 'u2', 'Mona Adel', 'Who takes the payment page?');
    final root = api.chatMessages[chat]!.first;
    api.receive(
      chat,
      'u3',
      'Sara Ali',
      'I can start tomorrow',
      replyTo: root.id,
    );
    final first = api.chatMessages[chat]!.first;
    api.receive(
      chat,
      'u2',
      'Mona Adel',
      'Great, I will review',
      replyTo: first.id,
    );
    await startApp(tester, api);
    await _openProjectChat(tester);

    expect(find.byKey(const Key('threadPill')), findsOneWidget);
    expect(find.text('ردّان'), findsOneWidget);
    await tester.tap(find.byKey(const Key('threadPill')));
    await tester.pumpAndSettle();

    expect(find.text('سلسلة الردود'), findsOneWidget);
    expect(find.byKey(const Key('replyThread')), findsOneWidget);
    expect(find.text('ردًا على Sara Ali'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('threadField')), 'On it');
    await tester.pump();
    await tester.tap(find.byKey(const Key('threadSend')));
    await tester.pumpAndSettle();
    expect(api.chatMessages[chat]!.first.replyTo, root.id);
    expect(api.chatMessages[chat]!.first.body, 'On it');
    expect(_says('On it'), findsOneWidget);

    // A reply tapped there is shown in the chat.
    await tester.tap(_says('I can start tomorrow'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('replyThread')), findsNothing);
    expect(find.text('3 ردود'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(tester.takeException(), isNull);
  });
}

void keyboardTests() {
  Upload file(String name) => Upload(
    bytes: Uint8List.fromList([1, 2, 3]),
    name: name,
    mime: mimeFor(name),
  );

  testWidgets('up to five files go at once, the text with the first', (
    tester,
  ) async {
    final api = _team();
    final chat = api.addProjectChat('ws1', _branch);
    final picker = FakePicker(file('a.pdf'))
      ..many = [for (var i = 1; i <= 7; i++) file('doc$i.pdf')];
    await startApp(tester, api, picker: picker);
    await _openProjectChat(tester);

    await tester.enterText(
      find.byKey(const Key('messageField')),
      'The drawings',
    );
    await tester.pump();
    await tester.tap(find.byTooltip('إرفاق'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ملف'));
    await tester.pumpAndSettle();
    expect(find.text('الحد 5 ملفات في المرة، اتاخد أول 5 بس'), findsOneWidget);

    final sent = api.chatMessages[chat]!.reversed.toList();
    expect(
      [for (final m in sent) m.file?.name],
      [for (var i = 1; i <= 5; i++) 'doc$i.pdf'],
    );
    expect(
      [for (final m in sent) m.body],
      ['The drawings', null, null, null, null],
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('files dragged from the computer onto a chat are sent', (
    tester,
  ) async {
    final api = _team();
    final chat = api.addProjectChat('ws1', _branch);
    final drops = FakeDrops();
    await startApp(tester, api, drops: drops);
    await _openProjectChat(tester);
    final middle = tester.getCenter(find.byKey(const Key('messageField')));

    drops.drag(middle);
    await tester.pumpAndSettle();
    expect(find.text('أفلت الملفات هنا لإرسالها'), findsOneWidget);
    drops.drag(null);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dropHint')), findsNothing);

    drops.drag(middle);
    await tester.pumpAndSettle();
    drops.drop(middle, [file('plan.pdf'), file('notes.txt')], tooLarge: 1);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dropHint')), findsNothing);
    expect(
      [for (final m in api.chatMessages[chat]!.reversed) m.file?.name],
      ['plan.pdf', 'notes.txt'],
    );
    expect(find.text('ملف واحد أكبر من 50 ميجا اتساب'), findsOneWidget);

    // Not while another screen is in front of the chat.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('إرفاق'));
    await tester.pumpAndSettle();
    drops.drop(middle, [file('later.pdf')]);
    await tester.pumpAndSettle();
    expect(api.chatMessages[chat], hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('with a keyboard, Enter sends and Shift+Enter makes a new line', (
    tester,
  ) async {
    final api = _team();
    final chat = api.addProjectChat('ws1', _branch);
    await startApp(tester, api);
    await _openProjectChat(tester);

    final field = find.byKey(const Key('messageField'));
    await tester.tap(field);
    await tester.enterText(field, 'First line');
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(api.chatMessages[chat], isEmpty);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(api.chatMessages[chat]!.single.body, 'First line');
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);

    // Enter while a mention is being typed picks the first name.
    await tester.enterText(field, 'شوف @mo');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(tester.widget<TextField>(field).controller!.text, 'شوف @Mona Adel ');
    expect(api.chatMessages[chat], hasLength(1));
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets(
    'replying or picking a mention puts the cursor in the message field',
    (tester) async {
      final api = _team();
      final chat = api.addProjectChat('ws1', _branch);
      api.receive(chat, 'u2', 'Mona Adel', 'Are the drawings ready?');
      await startApp(tester, api);
      await _openProjectChat(tester);
      final field = find.byKey(const Key('messageField'));
      bool focused() => tester.widget<TextField>(field).focusNode!.hasFocus;
      expect(focused(), isFalse);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(
        location: tester.getCenter(_says('Are the drawings ready?')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('hoverReply')),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(focused(), isTrue);

      await tester.enterText(field, 'أيوه @mo');
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('mention-u2')),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(focused(), isTrue);
      expect(
        tester.widget<TextField>(field).controller!.text,
        'أيوه @Mona Adel ',
      );
      await mouse.removePointer();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );
}
