import 'dart:async';
import 'dart:io';

import 'package:wasla/data/api.dart';
import 'package:wasla/data/billing_models.dart';
import 'package:wasla/data/chat_models.dart';
import 'package:wasla/data/models.dart';
import 'package:wasla/data/picker.dart';
import 'package:wasla/data/search_models.dart';
import 'package:wasla/data/task_models.dart';

/// In-memory backend for widget tests. Only what the tests touch is real.
class FakeApi implements WaslaApi {
  FakeApi({String? signedInAs, this.name = ''}) : _user = signedInAs;

  final _auth = StreamController<String?>.broadcast();
  String? _user;
  String name;
  String email = 'amr@example.com';

  final memberships = <Membership>[];
  final invites = <MyInvite>[];
  final projectsByWorkspace = <String, List<Project>>{};
  final membersByWorkspace = <String, List<Member>>{};
  final sentCodes = <String>[];

  @override
  Stream<String?> userIdChanges() async* {
    yield _user;
    yield* _auth.stream;
  }

  @override
  Future<void> sendEmailCode(String email) async => sentCodes.add(email);

  @override
  Future<void> verifyEmailCode(String email, String code) async {
    this.email = email;
    _user = 'me';
    _auth.add(_user);
  }

  @override
  Future<void> signOut() async {
    _user = null;
    _auth.add(null);
  }

  @override
  Future<Profile> myProfile() async =>
      Profile(id: 'me', fullName: name, email: email);

  @override
  Future<void> updateProfile({
    String? fullName,
    String? locale,
    String? theme,
  }) async {
    if (fullName != null) name = fullName;
  }

  @override
  Future<List<Membership>> myWorkspaces() async => List.of(memberships);

  @override
  Future<List<MyInvite>> myInvites() async => List.of(invites);

  @override
  Future<String> acceptInvite(String token) async {
    final invite = invites.firstWhere((i) => i.token == token);
    invites.remove(invite);
    memberships.add(
      membership(invite.workspaceId, invite.workspaceName, invite.role),
    );
    return invite.workspaceId;
  }

  @override
  Future<void> declineInvite(String token) async =>
      invites.removeWhere((i) => i.token == token);

  @override
  Future<String> createCompanyWorkspace({
    required String companyName,
    required String countryCode,
    required String workspaceName,
  }) async {
    final id = 'ws${memberships.length + 1}';
    memberships.add(membership(id, workspaceName, WorkspaceRole.owner));
    return id;
  }

  @override
  Future<List<Project>> projects(String workspaceId) async =>
      List.of(projectsByWorkspace[workspaceId] ?? const []);

  /// Task counts by project id, as the server would count them.
  final progress = <String, ProjectProgress>{};

  @override
  Future<Map<String, ProjectProgress>> projectProgress(
    String workspaceId,
  ) async => Map.of(progress);

  @override
  Future<String> createProject(
    String workspaceId, {
    required String name,
    required String color,
  }) async {
    final list = projectsByWorkspace.putIfAbsent(workspaceId, () => []);
    final id = 'p${list.length + 1}';
    final project = Project(
      id: id,
      workspaceId: workspaceId,
      name: name,
      color: color,
      status: ProjectStatus.active,
      memberCount: 1,
    );
    list.add(project);
    addProjectChat(workspaceId, project);
    return id;
  }

  @override
  Future<List<Member>> members(String workspaceId) async =>
      List.of(membersByWorkspace[workspaceId] ?? const []);

  @override
  Future<List<SentInvite>> sentInvites(String workspaceId) async => const [];

  @override
  Future<List<JoinRequest>> joinRequests(String workspaceId) async => const [];

  @override
  Future<List<MyJoinRequest>> myJoinRequests() async => const [];

  /// Set per project in tests; otherwise just the signed-in user, as lead.
  final projectMembersById = <String, List<ProjectMember>>{};

  @override
  Future<List<ProjectMember>> projectMembers(String projectId) async => List.of(
    projectMembersById[projectId] ??
        [
          ProjectMember(
            userId: 'me',
            fullName: name,
            role: ProjectRole.lead,
            email: email,
          ),
        ],
  );

  static Membership membership(String id, String name, WorkspaceRole role) =>
      Membership(
        workspaceId: id,
        workspaceName: name,
        companyId: 'c1',
        companyName: 'Al Nour',
        isCompanyOwner: role == WorkspaceRole.owner,
        role: role,
        planName: 'Free',
        maxMembers: 10,
        discoverable: false,
      );

  // Not used by the tests yet.
  @override
  Future<String> createWorkspace({
    required String companyId,
    required String name,
  }) => throw UnimplementedError();
  @override
  Future<void> setDiscoverable(String workspaceId, bool discoverable) async {}

  final deleted = <DeletedWorkspace>[];

  @override
  Future<void> renameWorkspace(String workspaceId, String name) async {
    final i = memberships.indexWhere((m) => m.workspaceId == workspaceId);
    final m = memberships[i];
    memberships[i] = Membership(
      workspaceId: m.workspaceId,
      workspaceName: name,
      companyId: m.companyId,
      companyName: m.companyName,
      isCompanyOwner: m.isCompanyOwner,
      role: m.role,
      planName: m.planName,
      maxMembers: m.maxMembers,
      discoverable: m.discoverable,
    );
  }

  @override
  Future<void> leaveWorkspace(String workspaceId) async =>
      memberships.removeWhere((m) => m.workspaceId == workspaceId);

  @override
  Future<void> deleteWorkspace(String workspaceId, String confirmName) async {
    final m = memberships.firstWhere((m) => m.workspaceId == workspaceId);
    if (confirmName != m.workspaceName) throw StateError('name_mismatch');
    memberships.remove(m);
    final now = DateTime.now();
    deleted.add(
      DeletedWorkspace(
        id: m.workspaceId,
        name: m.workspaceName,
        companyName: m.companyName,
        deletedAt: now,
        purgeAt: now.add(const Duration(days: 30)),
      ),
    );
  }

  @override
  Future<List<DeletedWorkspace>> deletedWorkspaces() async => List.of(deleted);

  @override
  Future<void> restoreWorkspace(String workspaceId) async {
    final d = deleted.firstWhere((d) => d.id == workspaceId);
    deleted.remove(d);
    memberships.add(membership(d.id, d.name, WorkspaceRole.owner));
  }

  @override
  Future<List<WorkspaceHit>> searchWorkspaces(String query) async => const [];
  @override
  Future<void> requestToJoin(String workspaceId, {String? message}) async {}
  @override
  Future<void> cancelJoinRequest(String requestId) async {}
  @override
  Future<void> setMemberRole(
    String workspaceId,
    String userId,
    WorkspaceRole role,
  ) async {}
  @override
  Future<void> removeMember(String workspaceId, String userId) async {}
  @override
  Future<void> invite(
    String workspaceId, {
    required String email,
    required WorkspaceRole role,
    List<String> projectIds = const [],
  }) async {}
  @override
  Future<void> cancelInvite(String inviteId) async {}
  @override
  Future<void> decideJoinRequest(
    String requestId, {
    required bool accept,
  }) async {}
  @override
  Future<void> setProjectStatus(String projectId, ProjectStatus status) async {}
  @override
  Future<void> addProjectMember(String projectId, String userId) async {}
  @override
  Future<void> removeProjectMember(String projectId, String userId) async {}
  @override
  Future<void> setProjectRole(
    String projectId,
    String userId,
    ProjectRole role,
  ) async {}

  // Chats: conversations keep their kind and who/what they are about; the
  // last message and unread count are worked out from the messages.

  final chats = <String, Conversation>{};
  final chatWorkspace = <String, String>{};

  /// Newest first, per conversation.
  final chatMessages = <String, List<ChatMessage>>{};
  final reads = <String, Map<String, DateTime>>{};
  final announcementList = <Announcement>[];
  final readAnnouncements = <String>{};
  final projectFileList = <String, List<ProjectFile>>{};
  final _events = StreamController<ChatEvent>.broadcast();
  int _seq = 0;
  DateTime _clock = DateTime.utc(2026, 10, 8, 9);

  DateTime _tick() => _clock = _clock.add(const Duration(minutes: 1));

  /// A project's group chat, as the server creates with each project.
  String addProjectChat(String workspaceId, Project project) {
    final id = 'c-${project.id}';
    chats[id] = Conversation(
      id: id,
      kind: ConversationKind.project,
      projectId: project.id,
      projectName: project.name,
      projectColor: project.color,
    );
    chatWorkspace[id] = workspaceId;
    chatMessages[id] = [];
    return id;
  }

  /// A message from someone else arriving.
  void receive(
    String conversationId,
    String senderId,
    String senderName,
    String body, {
    String? projectId,
    List<String> mentions = const [],
  }) {
    chatMessages[conversationId]!.insert(
      0,
      ChatMessage(
        id: 'm${_seq++}',
        senderId: senderId,
        senderName: senderName,
        createdAt: _tick(),
        body: body,
        projectId: projectId ?? chats[conversationId]!.projectId,
        mentions: mentions,
      ),
    );
    _events.add(ChatEvent(conversationId: conversationId));
  }

  @override
  Future<List<Conversation>> conversations(String workspaceId) async {
    final list = <Conversation>[];
    for (final c in chats.values) {
      if (chatWorkspace[c.id] != workspaceId) continue;
      // Like the server, a closed or archived project's chat leaves the list.
      final project = projectsByWorkspace[workspaceId]
          ?.where((p) => p.id == c.projectId)
          .firstOrNull;
      if (project != null && project.status != ProjectStatus.active) continue;
      final messages = chatMessages[c.id] ?? const <ChatMessage>[];
      if (!c.isProject && messages.isEmpty) continue;
      final last = messages.isEmpty ? null : messages.first;
      final myRead = reads[c.id]?['me'];
      list.add(
        Conversation(
          id: c.id,
          kind: c.kind,
          projectId: c.projectId,
          projectName: c.projectName,
          projectColor: c.projectColor,
          otherId: c.otherId,
          otherName: c.otherName,
          otherActive: c.otherActive,
          lastAt: last?.createdAt,
          lastSenderId: last?.senderId,
          lastSenderName: last?.senderName,
          lastBody: last?.body,
          lastFileName: last?.file?.name,
          lastDeleted: last?.deleted ?? false,
          unread: messages
              .where(
                (m) =>
                    m.senderId != 'me' &&
                    !m.deleted &&
                    (myRead == null || m.createdAt.isAfter(myRead)),
              )
              .length,
          unreadMentions: messages
              .where(
                (m) =>
                    m.mentions.contains('me') &&
                    !m.deleted &&
                    (myRead == null || m.createdAt.isAfter(myRead)),
              )
              .length,
          tagProjectIds: c.isProject
              ? [c.projectId!]
              : {
                  for (final m in messages)
                    if (m.projectId != null) m.projectId!,
                }.toList(),
        ),
      );
    }
    list.sort(
      (a, b) =>
          (b.lastAt ?? DateTime(2000)).compareTo(a.lastAt ?? DateTime(2000)),
    );
    return list;
  }

  @override
  Future<String?> projectConversation(String projectId) async {
    for (final c in chats.values) {
      if (c.projectId == projectId) return c.id;
    }
    return null;
  }

  @override
  Future<String> openDirect(String workspaceId, String userId) async {
    for (final c in chats.values) {
      if (chatWorkspace[c.id] == workspaceId && c.otherId == userId) {
        return c.id;
      }
    }
    final other = (membersByWorkspace[workspaceId] ?? const <Member>[])
        .firstWhere((m) => m.userId == userId);
    final id = 'd-$userId';
    chats[id] = Conversation(
      id: id,
      kind: ConversationKind.direct,
      otherId: userId,
      otherName: other.fullName,
    );
    chatWorkspace[id] = workspaceId;
    chatMessages[id] = [];
    return id;
  }

  @override
  Future<List<ChatMessage>> messages(
    String conversationId, {
    DateTime? before,
    DateTime? after,
    String? projectId,
    int limit = 50,
  }) async => (chatMessages[conversationId] ?? const <ChatMessage>[])
      .where(
        (m) =>
            (projectId == null || m.projectId == projectId) &&
            (before == null || m.createdAt.isBefore(before)) &&
            (after == null || m.createdAt.isAfter(after)),
      )
      .take(limit)
      .toList();

  @override
  Future<void> sendMessage(
    String workspaceId,
    String conversationId, {
    String? body,
    String? replyTo,
    String? projectId,
    Upload? file,
    List<String> mentions = const [],
  }) async {
    sentMentions.add(mentions);
    final list = chatMessages[conversationId]!;
    final quoted = replyTo == null
        ? null
        : list.firstWhere((m) => m.id == replyTo);
    final sent = ChatMessage(
      id: 'm${_seq++}',
      senderId: 'me',
      senderName: name,
      createdAt: _tick(),
      body: body,
      projectId: chats[conversationId]!.projectId ?? projectId,
      replyTo: replyTo,
      replySenderName: quoted?.senderName,
      replyBody: quoted?.body,
      mentions: mentions,
      file: file == null
          ? null
          : ChatFile(
              id: 'f${_seq++}',
              name: file.name,
              mime: file.mime,
              size: file.bytes.length,
              path: 'ws/me/${file.name}',
            ),
    );
    list.insert(0, sent);
    reads.putIfAbsent(conversationId, () => {})['me'] = sent.createdAt;
    _events.add(ChatEvent(conversationId: conversationId));
  }

  /// The mentions each sent message carried, in order.
  final sentMentions = <List<String>>[];

  @override
  Future<void> toggleReaction(String messageId, String emoji) async {
    for (final entry in chatMessages.entries) {
      final i = entry.value.indexWhere((m) => m.id == messageId);
      if (i < 0) continue;
      entry.value[i] = entry.value[i].withReaction(emoji, 'me');
      _events.add(ChatEvent(conversationId: entry.key));
    }
  }

  /// Someone else reacting.
  void react(String messageId, String emoji, String userId) {
    for (final entry in chatMessages.entries) {
      final i = entry.value.indexWhere((m) => m.id == messageId);
      if (i < 0) continue;
      entry.value[i] = entry.value[i].withReaction(emoji, userId);
      _events.add(ChatEvent(conversationId: entry.key));
    }
  }

  @override
  Future<void> markRead(String conversationId, DateTime until) async {
    final mine = reads.putIfAbsent(conversationId, () => {});
    final was = mine['me'];
    if (was == null || until.isAfter(was)) mine['me'] = until;
  }

  @override
  Future<void> deleteMessage(String messageId, {String? filePath}) async {
    for (final entry in chatMessages.entries) {
      final i = entry.value.indexWhere((m) => m.id == messageId);
      if (i < 0) continue;
      final m = entry.value[i];
      entry.value[i] = ChatMessage(
        id: m.id,
        senderId: m.senderId,
        senderName: m.senderName,
        createdAt: m.createdAt,
        projectId: m.projectId,
        deleted: true,
      );
      _events.add(ChatEvent(conversationId: entry.key));
    }
  }

  @override
  Future<List<ReadState>> readStates(String conversationId) async => [
    for (final e
        in (reads[conversationId] ?? const <String, DateTime>{}).entries)
      ReadState(userId: e.key, lastReadAt: e.value),
  ];

  @override
  Future<List<MessageHit>> searchMessages(
    String workspaceId,
    String query,
  ) async => [
    for (final e in chatMessages.entries)
      if (chatWorkspace[e.key] == workspaceId)
        for (final m in e.value)
          if (!m.deleted && (m.body ?? '').contains(query))
            MessageHit(
              messageId: m.id,
              chat: chats[e.key]!,
              createdAt: m.createdAt,
              senderName: m.senderName,
              body: m.body,
            ),
  ];

  /// What [searchWorkspace] returns, by query.
  final workspaceSearches = <String, WorkspaceSearch>{};

  @override
  Future<WorkspaceSearch> searchWorkspace(
    String workspaceId,
    String query,
  ) async => workspaceSearches[query] ?? const WorkspaceSearch();

  @override
  Future<List<String>> sharedProjects(String conversationId) async => [
    for (final p
        in projectsByWorkspace[chatWorkspace[conversationId]] ??
            const <Project>[])
      if (p.status == ProjectStatus.active) p.id,
  ];

  @override
  Future<List<String>> projectsWith(
    String workspaceId,
    String userId,
  ) async => [
    for (final p in projectsByWorkspace[workspaceId] ?? const <Project>[])
      if (p.status == ProjectStatus.active &&
          (projectMembersById[p.id]?.any((m) => m.userId == userId) ?? false))
        p.id,
  ];

  /// What the phone would hear after being offline.
  void reconnect() => _events.add(const ChatEvent.everything());

  @override
  Stream<ChatEvent> chatEvents(String workspaceId) => _events.stream;

  @override
  Future<List<ProjectFile>> projectFiles(String projectId) async =>
      List.of(projectFileList[projectId] ?? const []);

  @override
  Future<void> addProjectFile(
    String workspaceId,
    String projectId,
    Upload file,
  ) async {
    projectFileList
        .putIfAbsent(projectId, () => [])
        .insert(
          0,
          ProjectFile(
            file: ChatFile(
              id: 'f${_seq++}',
              name: file.name,
              mime: file.mime,
              size: file.bytes.length,
              path: 'ws/me/${file.name}',
            ),
            pinned: false,
            uploadedBy: 'me',
            uploaderName: name,
            createdAt: _tick(),
          ),
        );
  }

  @override
  Future<void> setFilePinned(String fileId, bool pinned) async {}

  @override
  Future<void> deleteFile(String fileId, {String? filePath}) async {
    for (final list in projectFileList.values) {
      list.removeWhere((f) => f.file.id == fileId);
    }
  }

  /// Tests have no network, so files show their placeholder.
  @override
  Future<String> fileUrl(String path) async => '';

  @override
  Future<List<Announcement>> announcements(
    String workspaceId, {
    String? projectId,
  }) async => [
    for (final a in announcementList)
      if (a.projectId == projectId)
        Announcement(
          id: a.id,
          projectId: a.projectId,
          body: a.body,
          pinned: a.pinned,
          authorId: a.authorId,
          authorName: a.authorName,
          createdAt: a.createdAt,
          readByMe: readAnnouncements.contains(a.id),
          readCount: a.readCount,
          audience: a.audience,
          needsAck: a.needsAck,
          ackedByMe: ackedAnnouncements.contains(a.id),
          ackCount: a.ackCount,
        ),
  ];

  @override
  Future<List<UnreadAnnouncement>> unreadAnnouncements(
    String workspaceId,
  ) async => [
    for (final a in announcementList)
      if (a.authorId != 'me' &&
          (a.needsAck
              ? !ackedAnnouncements.contains(a.id)
              : !readAnnouncements.contains(a.id)))
        UnreadAnnouncement(
          id: a.id,
          projectId: a.projectId,
          projectName: a.projectId == null
              ? null
              : projectsByWorkspace[workspaceId]
                    ?.firstWhere((p) => p.id == a.projectId)
                    .name,
          body: a.body,
          authorName: a.authorName,
          createdAt: a.createdAt,
          needsAck: a.needsAck,
        ),
  ];

  @override
  Future<void> postAnnouncement(
    String workspaceId, {
    String? projectId,
    required String body,
    bool pinned = false,
    bool needsAck = false,
  }) async => announcementList.insert(
    0,
    Announcement(
      id: 'a${_seq++}',
      projectId: projectId,
      body: body,
      pinned: pinned,
      authorId: 'me',
      authorName: name,
      createdAt: _tick(),
      audience: 3,
      needsAck: needsAck,
    ),
  );

  @override
  Future<void> markAnnouncementsRead(List<String> ids) async =>
      readAnnouncements.addAll(ids);

  final ackedAnnouncements = <String>{};

  /// What [announcementReaders] returns, by announcement.
  final readersByAnnouncement = <String, List<AnnouncementReader>>{};

  @override
  Future<void> acknowledgeAnnouncement(String id) async {
    readAnnouncements.add(id);
    ackedAnnouncements.add(id);
  }

  @override
  Future<List<AnnouncementReader>> announcementReaders(String id) async =>
      readersByAnnouncement[id] ?? const [];

  @override
  Future<void> setAnnouncementPinned(String id, bool pinned) async {}

  @override
  Future<void> deleteAnnouncement(String id) async =>
      announcementList.removeWhere((a) => a.id == id);

  // Tasks: the signed-in user is "me"; workspace owners and admins manage
  // every project, as do the leads in [projectMembersById].

  final taskList = <TaskItem>[];
  final taskDetails = <String, TaskDetail>{};
  final taskCalls = <String>[];

  /// What the last new or changed task was made from.
  TaskDraft? lastDraft;

  /// Names of attachments whose upload fails, as on a bad connection.
  final failingUploads = <String>{};
  final notificationList = <AppNotification>[];
  final _taskEvents = StreamController<void>.broadcast();
  final _noteEvents = StreamController<void>.broadcast();

  Project? _project(String projectId) {
    for (final list in projectsByWorkspace.values) {
      for (final p in list) {
        if (p.id == projectId) return p;
      }
    }
    return null;
  }

  bool _manages(String projectId) {
    final project = _project(projectId);
    if (project == null) return false;
    final role = memberships
        .where((m) => m.workspaceId == project.workspaceId)
        .firstOrNull
        ?.role;
    if (role?.canManage ?? false) return true;
    return projectMembersById[projectId]?.any(
          (m) => m.userId == 'me' && m.role == ProjectRole.lead,
        ) ??
        false;
  }

  String _personName(String id) {
    if (id == 'me') return name;
    for (final list in membersByWorkspace.values) {
      for (final m in list) {
        if (m.userId == id) return m.fullName;
      }
    }
    return id;
  }

  /// Adds a task as if someone made it on another phone.
  TaskItem addTask({
    required String projectId,
    required String title,
    String createdBy = 'me',
    List<String> assignees = const ['me'],
    TaskStatus status = TaskStatus.todo,
    TaskVisibility visibility = TaskVisibility.private,
    DateTime? dueAt,
    String? description,
  }) {
    final project = _project(projectId)!;
    final now = _tick();
    final task = TaskItem(
      id: 't${_seq++}',
      workspaceId: project.workspaceId,
      workspaceName:
          memberships
              .where((m) => m.workspaceId == project.workspaceId)
              .firstOrNull
              ?.workspaceName ??
          '',
      projectId: project.id,
      projectName: project.name,
      projectColor: project.color,
      title: title,
      status: status,
      visibility: visibility,
      dueAt: dueAt,
      createdBy: createdBy,
      creatorName: _personName(createdBy),
      assignees: [
        for (final a in assignees) TaskPerson(id: a, name: _personName(a)),
      ],
      createdAt: now,
      updatedAt: now,
      doneAt: status == TaskStatus.done ? now : null,
    );
    taskList.add(task);
    taskDetails[task.id] = TaskDetail(
      task: task,
      description: description,
      activity: [
        TaskActivity(
          id: 'a${_seq++}',
          kind: TaskEvent.created,
          actorId: createdBy,
          actorName: _personName(createdBy),
          createdAt: now,
        ),
      ],
    );
    _taskEvents.add(null);
    return task;
  }

  TaskItem taskById(String id) => taskList.firstWhere((t) => t.id == id);

  void _replace(TaskItem task) {
    final i = taskList.indexWhere((t) => t.id == task.id);
    taskList[i] = task;
    _taskEvents.add(null);
  }

  void _log(String taskId, TaskEvent kind, {String? value, String? body}) {
    final detail = taskDetails[taskId]!;
    taskDetails[taskId] = _detail(
      detail,
      activity: [
        ...detail.activity,
        TaskActivity(
          id: 'a${_seq++}',
          kind: kind,
          actorId: 'me',
          actorName: name,
          newValue: value,
          body: body,
          createdAt: _tick(),
        ),
      ],
    );
  }

  TaskDetail _detail(
    TaskDetail d, {
    String? description,
    String? holdReason,
    bool clearHold = false,
    List<TaskActivity>? activity,
    List<ProjectFile>? files,
    List<TaskReminder>? reminders,
    List<int>? remindBefore,
  }) => TaskDetail(
    task: d.task,
    description: description ?? d.description,
    holdReason: clearHold ? null : holdReason ?? d.holdReason,
    remindBefore: remindBefore ?? d.remindBefore,
    files: files ?? d.files,
    activity: activity ?? d.activity,
    reminders: reminders ?? d.reminders,
  );

  /// Adds a notification for the signed-in user, as the server would.
  void notify(
    NotificationKind kind,
    TaskItem task, {
    String? actor,
    String? detail,
  }) {
    notificationList.insert(
      0,
      AppNotification(
        id: 'n${_seq++}',
        kind: kind,
        taskId: task.id,
        taskTitle: task.title,
        projectName: task.projectName,
        projectColor: task.projectColor,
        workspaceId: task.workspaceId,
        workspaceName: task.workspaceName,
        actorName: actor,
        detail: detail,
        createdAt: _tick(),
      ),
    );
    _noteEvents.add(null);
  }

  @override
  Future<List<TaskItem>> myTasks() async => [
    for (final t in taskList)
      if (t.createdBy == 'me' || t.isAssignedTo('me')) t,
  ];

  @override
  Future<List<TaskItem>> projectTasks(String projectId) async => [
    for (final t in taskList)
      if (t.projectId == projectId &&
          (_manages(projectId) ||
              t.visibility == TaskVisibility.public ||
              t.createdBy == 'me' ||
              t.isAssignedTo('me')))
        t,
  ];

  @override
  Future<List<TaskItem>> managedTasks(String workspaceId) async => [
    for (final t in taskList)
      if (t.workspaceId == workspaceId && _manages(t.projectId)) t,
  ];

  @override
  Future<TaskDetail> task(String taskId) async {
    final task = taskById(taskId);
    final d = taskDetails[taskId]!;
    final editor = task.createdBy == 'me' || _manages(task.projectId);
    final assignee = task.isAssignedTo('me');
    final open = _project(task.projectId)?.status == ProjectStatus.active;
    return TaskDetail(
      task: task,
      description: d.description,
      holdReason: d.holdReason,
      remindBefore: d.remindBefore,
      projectOpen: open,
      isParty: editor || assignee,
      canEdit: editor,
      canClose: editor,
      canAssign: _manages(task.projectId),
      isAssignee: assignee,
      files: d.files,
      activity: [
        for (final a in d.activity)
          if (editor || assignee || a.kind != TaskEvent.comment) a,
      ],
      reminders: editor ? d.reminders : const [],
      repeat: taskRepeats[taskId],
    );
  }

  /// How each task repeats, by id.
  final taskRepeats = <String, TaskRepeat>{};
  final templates = <TaskTemplate>[];

  /// Each template applied: (template, project, start).
  final appliedTemplates = <(String, String, DateTime)>[];

  @override
  Future<void> setTaskRepeat(String taskId, TaskRepeat? repeat) async {
    taskCalls.add('repeat $taskId ${repeat?.name}');
    if (repeat == null) {
      taskRepeats.remove(taskId);
    } else {
      taskRepeats[taskId] = repeat;
    }
  }

  @override
  Future<List<TaskTemplate>> taskTemplates(String workspaceId) async => [
    ...templates,
  ];

  @override
  Future<void> saveTaskTemplate(
    String workspaceId,
    String name,
    List<TemplateItem> items,
  ) async => templates.add(
    TaskTemplate(id: 'tpl${_seq++}', name: name, items: items, canDelete: true),
  );

  @override
  Future<void> deleteTaskTemplate(String templateId) async =>
      templates.removeWhere((t) => t.id == templateId);

  @override
  Future<int> applyTaskTemplate(
    String templateId,
    String projectId, {
    List<String>? assigneeIds,
    required DateTime start,
  }) async {
    final template = templates.firstWhere((t) => t.id == templateId);
    appliedTemplates.add((templateId, projectId, start));
    for (final i in template.items) {
      addTask(
        projectId: projectId,
        title: i.title,
        assignees: assigneeIds ?? const ['me'],
        dueAt: i.dueInDays == null
            ? null
            : start.add(Duration(days: i.dueInDays!)),
      );
    }
    return template.items.length;
  }

  @override
  Future<String> createTask(TaskDraft draft) async {
    taskCalls.add('create ${draft.title}');
    lastDraft = draft;
    final task = addTask(
      projectId: draft.projectId,
      title: draft.title.trim(),
      assignees: draft.assigneeIds.isEmpty ? const ['me'] : draft.assigneeIds,
      visibility: draft.visibility,
      dueAt: draft.dueAt,
      description: draft.description,
    );
    taskDetails[task.id] = _detail(
      taskDetails[task.id]!,
      remindBefore: draft.remindBefore,
    );
    return task.id;
  }

  @override
  Future<void> updateTask(String taskId, TaskDraft draft) async {
    taskCalls.add('update $taskId');
    lastDraft = draft;
    final t = taskById(taskId);
    _replace(
      TaskItem(
        id: t.id,
        workspaceId: t.workspaceId,
        workspaceName: t.workspaceName,
        projectId: t.projectId,
        projectName: t.projectName,
        projectColor: t.projectColor,
        title: draft.title.trim(),
        status: t.status,
        priority: draft.priority,
        visibility: draft.visibility,
        dueAt: draft.dueAt,
        createdBy: t.createdBy,
        creatorName: t.creatorName,
        assignees: t.assignees,
        createdAt: t.createdAt,
        updatedAt: _tick(),
        doneAt: t.doneAt,
      ),
    );
    final d = taskDetails[taskId]!;
    taskDetails[taskId] = TaskDetail(
      task: d.task,
      description: draft.description,
      holdReason: d.holdReason,
      remindBefore: draft.remindBefore,
      files: d.files,
      activity: d.activity,
      reminders: d.reminders,
    );
    if (draft.dueAt != t.dueAt) {
      _log(taskId, TaskEvent.due, value: draft.dueAt?.toIso8601String());
    }
  }

  @override
  Future<void> setTaskAssignees(String taskId, List<String> userIds) async {
    taskCalls.add('assign $taskId ${userIds.join(',')}');
    _replace(
      taskById(taskId).copyWith(
        assignees: [
          for (final u in userIds) TaskPerson(id: u, name: _personName(u)),
        ],
        updatedAt: _tick(),
      ),
    );
    _log(
      taskId,
      TaskEvent.assignees,
      value: userIds.map(_personName).join('، '),
    );
  }

  @override
  Future<void> setTaskStatus(
    String taskId,
    TaskStatus status, {
    String? reason,
  }) async {
    taskCalls.add('status $taskId ${status.wire}');
    final detail = await task(taskId);
    if (!detail.canMoveTo(status)) throw StateError('not_allowed');
    _replace(taskById(taskId).copyWith(status: status, updatedAt: _tick()));
    taskDetails[taskId] = _detail(
      taskDetails[taskId]!,
      holdReason: reason,
      clearHold: status != TaskStatus.onHold,
    );
    _log(taskId, TaskEvent.status, value: status.wire, body: reason);
  }

  @override
  Future<void> addTaskComment(String taskId, String body) async {
    taskCalls.add('comment $taskId $body');
    _log(taskId, TaskEvent.comment, body: body.trim());
    _taskEvents.add(null);
  }

  @override
  Future<void> addTaskAttachment(
    String workspaceId,
    String taskId,
    Upload file,
  ) async {
    taskCalls.add('attach $taskId ${file.name}');
    if (failingUploads.contains(file.name)) {
      throw const SocketException('Connection reset');
    }
    final d = taskDetails[taskId]!;
    taskDetails[taskId] = _detail(
      d,
      files: [
        ...d.files,
        ProjectFile(
          file: ChatFile(
            id: 'f${_seq++}',
            name: file.name,
            mime: file.mime,
            size: file.bytes.length,
            path: '$workspaceId/me/${file.name}',
          ),
          pinned: false,
          uploadedBy: 'me',
          uploaderName: name,
          createdAt: _tick(),
        ),
      ],
    );
    _log(taskId, TaskEvent.attachment, value: file.name);
    _taskEvents.add(null);
  }

  @override
  Future<void> nudgeTask(String taskId) async => taskCalls.add('nudge $taskId');

  @override
  Future<void> addTaskReminder(String taskId, DateTime at) async {
    taskCalls.add('remind $taskId');
    final d = taskDetails[taskId]!;
    taskDetails[taskId] = _detail(
      d,
      reminders: [
        ...d.reminders,
        TaskReminder(id: 'r${_seq++}', remindAt: at),
      ],
    );
  }

  @override
  Future<void> deleteTaskReminder(String reminderId) async {
    for (final entry in taskDetails.entries.toList()) {
      taskDetails[entry.key] = _detail(
        entry.value,
        reminders: [
          for (final r in entry.value.reminders)
            if (r.id != reminderId) r,
        ],
      );
    }
  }

  @override
  Future<void> deleteTask(String taskId) async {
    taskCalls.add('delete $taskId');
    taskList.removeWhere((t) => t.id == taskId);
    _taskEvents.add(null);
  }

  @override
  Stream<void> taskEvents(String workspaceId) => _taskEvents.stream;

  @override
  Future<List<AppNotification>> notifications() async =>
      List.of(notificationList);

  /// Phones registered for notifications: token to locale.
  final pushTokens = <String, String>{};

  @override
  Future<void> registerPushToken(
    String token,
    String platform,
    String locale,
  ) async => pushTokens[token] = locale;

  @override
  Future<void> unregisterPushToken(String token) async =>
      pushTokens.remove(token);

  @override
  Future<void> markNotificationsRead([List<String>? ids]) async {
    for (var i = 0; i < notificationList.length; i++) {
      final n = notificationList[i];
      if (ids != null && !ids.contains(n.id)) continue;
      notificationList[i] = AppNotification(
        id: n.id,
        kind: n.kind,
        taskId: n.taskId,
        taskTitle: n.taskTitle,
        projectName: n.projectName,
        projectColor: n.projectColor,
        workspaceId: n.workspaceId,
        workspaceName: n.workspaceName,
        actorName: n.actorName,
        detail: n.detail,
        createdAt: n.createdAt,
        readAt: n.readAt ?? _clock,
      );
    }
  }

  @override
  Stream<void> notificationEvents() => _noteEvents.stream;

  // Subscriptions: one company's page in [billingPages], kept up to date by
  // what the owner does; admin actions are recorded in [billingCalls].

  bool platformAdmin = false;
  final billingPages = <String, BillingOverview>{};
  final billingCalls = <String>[];
  AdminOverview adminFigures = const AdminOverview();
  final adminRequestList = <AdminRequest>[];
  final adminCompanyList = <AdminCompany>[];
  final adminInvoiceList = <Invoice>[];
  final adminPlanList = <PlanOption>[];
  final adminRateList = <CountryRate>[];
  PaymentInfo adminPayment = const PaymentInfo();

  @override
  Future<bool> isPlatformAdmin() async => platformAdmin;

  /// The uploaded logo's name, standing in for its address.
  String? logo;

  @override
  Future<String?> logoUrl() async => logo;

  @override
  Future<void> setLogo(Upload? file) async {
    if (!platformAdmin) throw Exception('not_allowed');
    if (file != null && logoExtension(file.mime) == null) {
      throw const UnsupportedLogo();
    }
    logo = file?.name;
  }

  @override
  Future<BillingOverview> billing(String companyId) async =>
      billingPages[companyId]!;

  void _setRequest(String workspaceId, PlanRequest? request) {
    for (final entry in billingPages.entries) {
      final b = entry.value;
      if (!b.workspaces.any((w) => w.id == workspaceId)) continue;
      billingPages[entry.key] = BillingOverview(
        company: b.company,
        plans: b.plans,
        invoices: b.invoices,
        payment: b.payment,
        workspaces: [
          for (final w in b.workspaces)
            w.id != workspaceId
                ? w
                : WorkspaceBilling(
                    id: w.id,
                    name: w.name,
                    planId: w.planId,
                    planName: w.planName,
                    maxMembers: w.maxMembers,
                    storageGb: w.storageGb,
                    paidUntil: w.paidUntil,
                    members: w.members,
                    storageBytes: w.storageBytes,
                    request: request,
                  ),
        ],
      );
    }
  }

  @override
  Future<void> requestPlan(
    String workspaceId,
    String planId, {
    required int months,
    String? note,
  }) async {
    billingCalls.add('request $workspaceId $planId $months ${note ?? '-'}');
    _setRequest(
      workspaceId,
      PlanRequest(
        id: 'r-$workspaceId',
        planId: planId,
        months: months,
        status: RequestStatus.pending,
        createdAt: DateTime.now(),
      ),
    );
  }

  @override
  Future<void> cancelPlanRequest(String requestId) async {
    billingCalls.add('cancel $requestId');
    _setRequest(requestId.substring(2), null);
  }

  @override
  Future<AdminOverview> adminOverview() async => adminFigures;

  @override
  Future<List<AdminCompany>> adminCompanies({String? search}) async => [
    for (final c in adminCompanyList)
      if (search == null ||
          c.name.toLowerCase().contains(search.toLowerCase()) ||
          c.ownerEmail.contains(search))
        c,
  ];

  @override
  Future<List<AdminRequest>> adminRequests() async => List.of(adminRequestList);

  @override
  Future<List<Invoice>> adminInvoices({InvoiceStatus? status}) async => [
    for (final i in adminInvoiceList)
      if (status == null || i.status == status) i,
  ];

  @override
  Future<List<PlanOption>> adminPlans() async => List.of(adminPlanList);

  @override
  Future<List<CountryRate>> adminRates() async => List.of(adminRateList);

  @override
  Future<PaymentInfo> adminPaymentInfo() async => adminPayment;

  @override
  Future<void> adminSetRate(String countryCode, double rate) async =>
      billingCalls.add('rate $countryCode $rate');

  @override
  Future<void> adminUpdatePlan(PlanOption plan) async => billingCalls.add(
    'plan ${plan.id} ${plan.name} ${plan.maxMembers} ${plan.storageGb} '
    '${plan.priceUsd} ${plan.offered}',
  );

  @override
  Future<void> adminUpdatePaymentInfo(PaymentInfo info) async {
    billingCalls.add(
      'payment ${info.instructions} ${info.phone} ${info.email}',
    );
    adminPayment = info;
  }

  @override
  Future<String> adminCreateInvoice(
    String companyId,
    List<InvoiceItem> items, {
    required int months,
    double discountPct = 0,
    String? note,
    int dueDays = 14,
  }) async {
    final lines = [
      for (final i in items)
        '${i.workspaceId}:${i.planId}:${i.priceUsd ?? '-'}',
    ];
    billingCalls.add(
      'invoice $companyId ${lines.join(',')} $months $discountPct $dueDays',
    );
    return 'inv-new';
  }

  @override
  Future<void> adminMarkInvoicePaid(
    String invoiceId, {
    String? reference,
  }) async => billingCalls.add('paid $invoiceId ${reference ?? '-'}');

  @override
  Future<void> adminVoidInvoice(String invoiceId) async =>
      billingCalls.add('void $invoiceId');

  @override
  Future<void> adminSetWorkspacePlan(
    String workspaceId,
    String planId, {
    DateTime? until,
  }) async =>
      billingCalls.add('set $workspaceId $planId ${until ?? 'forever'}');
}
