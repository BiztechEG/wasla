import 'dart:async';

import 'package:wasla/data/api.dart';
import 'package:wasla/data/chat_models.dart';
import 'package:wasla/data/models.dart';

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

  @override
  Future<List<ProjectMember>> projectMembers(String projectId) async => [
    ProjectMember(
      userId: 'me',
      fullName: name,
      role: ProjectRole.lead,
      email: email,
    ),
  ];

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
  }) async {
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

  @override
  Future<List<String>> sharedProjects(String conversationId) async => [
    for (final p
        in projectsByWorkspace[chatWorkspace[conversationId]] ??
            const <Project>[])
      if (p.status == ProjectStatus.active) p.id,
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
        ),
  ];

  @override
  Future<List<UnreadAnnouncement>> unreadAnnouncements(
    String workspaceId,
  ) async => [
    for (final a in announcementList)
      if (a.authorId != 'me' && !readAnnouncements.contains(a.id))
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
        ),
  ];

  @override
  Future<void> postAnnouncement(
    String workspaceId, {
    String? projectId,
    required String body,
    bool pinned = false,
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
    ),
  );

  @override
  Future<void> markAnnouncementsRead(List<String> ids) async =>
      readAnnouncements.addAll(ids);

  @override
  Future<void> setAnnouncementPinned(String id, bool pinned) async {}

  @override
  Future<void> deleteAnnouncement(String id) async =>
      announcementList.removeWhere((a) => a.id == id);
}
