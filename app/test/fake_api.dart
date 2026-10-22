import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart' show TimeOfDay;
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;
import 'package:wasla/data/api.dart';
import 'package:wasla/data/attendance_models.dart';
import 'package:wasla/data/billing_models.dart';
import 'package:wasla/data/chat_models.dart';
import 'package:wasla/data/location.dart';
import 'package:wasla/data/models.dart';
import 'package:wasla/data/overview_models.dart';
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

  /// People asking to join, by workspace, as its admins see them.
  final joinRequestsByWorkspace = <String, List<JoinRequest>>{};

  /// Answers given to join requests: the request and whether accepted.
  final decided = <(String, bool)>[];

  @override
  Future<List<JoinRequest>> joinRequests(String workspaceId) async =>
      List.of(joinRequestsByWorkspace[workspaceId] ?? const []);

  /// Requests the signed-in user sent and is waiting on.
  final myRequests = <MyJoinRequest>[];

  @override
  Future<List<MyJoinRequest>> myJoinRequests() async => List.of(myRequests);

  /// Invitations sent: workspace and email.
  final invited = <(String, String)>[];

  /// Muted chats and until when; quiet hours.
  final muted = <String, DateTime?>{};
  QuietHours? quiet;

  @override
  Future<void> muteConversation(
    String conversationId, {
    DateTime? until,
  }) async => muted[conversationId] = until;

  @override
  Future<void> unmuteConversation(String conversationId) async =>
      muted.remove(conversationId);

  @override
  Future<Map<String, DateTime?>> mutedConversations(String workspaceId) async =>
      Map.of(muted);

  @override
  Future<QuietHours?> quietHours() async => quiet;

  bool weekly = true;

  @override
  Future<bool> weeklyReport() async => weekly;

  @override
  Future<void> setWeeklyReport(bool on) async => weekly = on;

  @override
  Future<void> setQuietHours(
    TimeOfDay? from,
    TimeOfDay? to,
    int utcOffset,
  ) async => quiet = from == null || to == null
      ? null
      : QuietHours(from: from, to: to, utcOffset: utcOffset);

  /// Departments by workspace, and those the signed-in user manages.
  final departmentsByWorkspace = <String, List<Department>>{};
  final managedDepartments = <String, String>{};

  @override
  Future<List<Department>> departments(String workspaceId) async =>
      List.of(departmentsByWorkspace[workspaceId] ?? const []);

  @override
  Future<Map<String, String>> myDepartments(String workspaceId) async =>
      Map.of(managedDepartments);

  @override
  Future<void> saveDepartment(
    String workspaceId, {
    String? departmentId,
    required String name,
    required List<String> managerIds,
    required List<String> projectIds,
  }) async {
    final list = departmentsByWorkspace.putIfAbsent(workspaceId, () => []);
    final saved = Department(
      id: departmentId ?? 'd${_seq++}',
      name: name,
      managerIds: managerIds,
      projectIds: projectIds,
    );
    final i = list.indexWhere((d) => d.id == departmentId);
    if (i < 0) {
      list.add(saved);
    } else {
      list[i] = saved;
    }
  }

  @override
  Future<void> deleteDepartment(String departmentId) async {
    for (final list in departmentsByWorkspace.values) {
      list.removeWhere((d) => d.id == departmentId);
    }
  }

  /// Statuses by user id.
  final statuses = <String, UserStatus>{};

  @override
  Future<Map<String, UserStatus>> workspaceStatuses(String workspaceId) async =>
      Map.of(statuses);

  @override
  Future<void> setMyStatus(UserStatus? status) async =>
      status == null ? statuses.remove(_user) : statuses[_user!] = status;

  /// Whether owners see the first-steps checklist; off so that most tests
  /// start in a workspace that is already set up.
  bool newWorkspace = false;

  @override
  Future<SetupProgress?> workspaceSetup(String workspaceId) async {
    if (!newWorkspace) return null;
    final role = memberships
        .where((m) => m.workspaceId == workspaceId)
        .firstOrNull
        ?.role;
    if (role == null || !role.canManage) return null;
    return SetupProgress(
      project: (projectsByWorkspace[workspaceId] ?? const []).isNotEmpty,
      team:
          (membersByWorkspace[workspaceId] ?? const []).length > 1 ||
          invited.any((i) => i.$1 == workspaceId) ||
          joinCodes.containsKey(workspaceId),
      attendance: attendance?.enabled ?? false,
      announcement: announcementList.isNotEmpty,
    );
  }

  /// What the management dashboard shows.
  final overviews = <WorkspaceOverview>[];

  @override
  Future<List<WorkspaceOverview>> managementOverview() async =>
      List.of(overviews);

  /// Join codes by workspace, and the workspaces they lead to.
  final joinCodes = <String, JoinCode>{};
  final codeWorkspaces = <String, CodeWorkspace>{};

  @override
  Future<JoinCode?> joinCode(String workspaceId) async =>
      joinCodes[workspaceId];

  @override
  Future<JoinCode?> setJoinCode(
    String workspaceId, {
    required bool enabled,
    bool autoJoin = false,
    bool renew = false,
  }) async {
    if (!enabled) {
      joinCodes.remove(workspaceId);
      return null;
    }
    final old = joinCodes[workspaceId];
    return joinCodes[workspaceId] = JoinCode(
      code: old == null || renew ? 'ABCD${2345 + _seq++}' : old.code,
      autoJoin: autoJoin,
    );
  }

  @override
  Future<CodeWorkspace?> workspaceByCode(String code) async =>
      codeWorkspaces[code.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '')];

  @override
  Future<bool> joinWithCode(String code, {String? message}) async {
    final w = (await workspaceByCode(code))!;
    if (w.autoJoin) {
      memberships.add(
        membership(w.workspaceId, w.workspaceName, WorkspaceRole.member),
      );
      return true;
    }
    myRequests.add(
      MyJoinRequest(
        id: 'r${_seq++}',
        workspaceId: w.workspaceId,
        workspaceName: w.workspaceName,
      ),
    );
    return false;
  }

  /// An admin lets the signed-in user in, as the server would tell them.
  void admit(String workspaceId, String name) {
    myRequests.removeWhere((r) => r.workspaceId == workspaceId);
    memberships.add(membership(workspaceId, name, WorkspaceRole.member));
    notifyJoining(
      NotificationKind.requestAccepted,
      workspaceId: workspaceId,
      workspaceName: name,
      actor: 'Mona',
    );
  }

  /// Adds a notification about joining a workspace, as the server would.
  void notifyJoining(
    NotificationKind kind, {
    required String workspaceId,
    required String workspaceName,
    String? actor,
    String? detail,
    String? inviteId,
    String? joinRequestId,
    AnswerStatus? status,
  }) {
    notificationList.insert(
      0,
      AppNotification(
        id: 'n${_seq++}',
        kind: kind,
        workspaceId: workspaceId,
        workspaceName: workspaceName,
        actorName: actor,
        detail: detail,
        createdAt: _tick(),
        inviteId: inviteId,
        joinRequestId: joinRequestId,
        requestStatus: status,
      ),
    );
    _noteEvents.add(null);
  }

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

  static Membership membership(
    String id,
    String name,
    WorkspaceRole role, {
    bool allowSharing = true,
  }) => Membership(
    workspaceId: id,
    workspaceName: name,
    companyId: 'c1',
    companyName: 'Al Nour',
    isCompanyOwner: role == WorkspaceRole.owner,
    role: role,
    planName: 'Free',
    maxMembers: 10,
    discoverable: false,
    allowSharing: allowSharing,
  );

  // Not used by the tests yet.
  @override
  Future<String> createWorkspace({
    required String companyId,
    required String name,
  }) => throw UnimplementedError();
  @override
  Future<void> setDiscoverable(String workspaceId, bool discoverable) async {}

  /// Each change to a workspace's sharing setting.
  final sharingChanges = <(String, bool)>[];

  @override
  Future<void> setAllowSharing(String workspaceId, bool allow) async =>
      sharingChanges.add((workspaceId, allow));

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
  Future<void> cancelJoinRequest(String requestId) async =>
      myRequests.removeWhere((r) => r.id == requestId);
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
  }) async => invited.add((workspaceId, email));
  @override
  Future<void> cancelInvite(String inviteId) async {}
  @override
  Future<void> decideJoinRequest(
    String requestId, {
    required bool accept,
  }) async {
    decided.add((requestId, accept));
    for (final list in joinRequestsByWorkspace.values) {
      list.removeWhere((r) => r.id == requestId);
    }
    for (var i = 0; i < notificationList.length; i++) {
      final n = notificationList[i];
      if (n.joinRequestId != requestId) continue;
      notificationList[i] = AppNotification(
        id: n.id,
        kind: n.kind,
        workspaceId: n.workspaceId,
        workspaceName: n.workspaceName,
        actorName: n.actorName,
        detail: n.detail,
        createdAt: n.createdAt,
        readAt: _clock,
        joinRequestId: n.joinRequestId,
        requestStatus: accept ? AnswerStatus.accepted : AnswerStatus.rejected,
      );
    }
  }

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

  /// Moves the clock on, as if time passed between messages.
  void skip(Duration time) => _clock = _clock.add(time);

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
    String? replyTo,
    ChatFile? file,
  }) {
    final list = chatMessages[conversationId]!;
    final quoted = replyTo == null
        ? null
        : list.firstWhere((m) => m.id == replyTo);
    list.insert(
      0,
      ChatMessage(
        id: 'm${_seq++}',
        senderId: senderId,
        senderName: senderName,
        createdAt: _tick(),
        body: body,
        projectId: projectId ?? chats[conversationId]!.projectId,
        mentions: mentions,
        replyTo: replyTo,
        replySenderName: quoted?.senderName,
        replyBody: quoted?.body,
        file: file,
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
  }) async {
    final all = chatMessages[conversationId] ?? const <ChatMessage>[];
    return [
      for (final m in all.where(
        (m) =>
            (projectId == null || m.projectId == projectId) &&
            (before == null || m.createdAt.isBefore(before)) &&
            (after == null || m.createdAt.isAfter(after)),
      ))
        _withReplies(m, all),
    ].take(limit).toList();
  }

  /// Every reply under [root], replies to replies included, oldest first.
  List<ChatMessage> _repliesTo(ChatMessage root, List<ChatMessage> all) {
    final ids = {root.id};
    final found = <ChatMessage>[];
    for (final m in all.reversed) {
      if (m.replyTo != null && ids.contains(m.replyTo)) {
        ids.add(m.id);
        found.add(m);
      }
    }
    return found;
  }

  /// As the server counts a message's replies.
  ChatMessage _withReplies(ChatMessage m, List<ChatMessage> all) {
    if (m.replyTo != null) return m;
    final replies = _repliesTo(m, all).where((r) => !r.deleted).toList();
    final people = <String>[];
    for (final r in replies.reversed) {
      if (!people.contains(r.senderId)) people.add(r.senderId);
    }
    return m.copyWith(
      replyCount: replies.length,
      repliers: people.take(3).toList(),
    );
  }

  @override
  Future<List<ChatMessage>> replyChain(String messageId) async {
    for (final all in chatMessages.values) {
      final root = all.where((m) => m.id == messageId).firstOrNull;
      if (root != null) {
        return [_withReplies(root, all), ..._repliesTo(root, all)];
      }
    }
    return const [];
  }

  @override
  Future<Set<DateTime>> messageDays(
    String conversationId, {
    String? projectId,
  }) async => {
    for (final m in chatMessages[conversationId] ?? const <ChatMessage>[])
      if (!m.deleted && (projectId == null || m.projectId == projectId))
        DateTime(
          m.createdAt.toLocal().year,
          m.createdAt.toLocal().month,
          m.createdAt.toLocal().day,
        ),
  };

  @override
  Future<Uint8List> fileBytes(String path) async =>
      Uint8List.fromList([1, 2, 3]);

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

  /// Pinned message by chat; chats where the signed-in user may not pin.
  final pins = <String, String>{};
  final noPinning = <String>{};

  @override
  Future<void> createPoll(
    String conversationId, {
    required String question,
    required List<String> options,
    bool multiple = false,
    String? projectId,
  }) async {
    await sendMessage(
      chatWorkspace[conversationId] ?? '',
      conversationId,
      body: question,
      projectId: projectId,
    );
    final list = chatMessages[conversationId]!;
    list[0] = list[0].copyWith(
      poll: Poll(options: options, multiple: multiple),
    );
  }

  /// Applies [change] to the poll of [messageId] and tells its chat.
  void _poll(String messageId, Poll Function(Poll) change) {
    for (final entry in chatMessages.entries) {
      final i = entry.value.indexWhere((m) => m.id == messageId);
      if (i < 0) continue;
      final m = entry.value[i];
      entry.value[i] = m.copyWith(poll: change(m.poll!));
      _events.add(ChatEvent(conversationId: entry.key));
    }
  }

  @override
  Future<void> votePoll(String messageId, Set<int> options) async =>
      _poll(messageId, (p) => p.withVote('me', options));

  /// Someone else answering a poll.
  void vote(String messageId, String userId, Set<int> options) =>
      _poll(messageId, (p) => p.withVote(userId, options));

  @override
  Future<void> closePoll(String messageId) async =>
      _poll(messageId, (p) => p.closedCopy());

  @override
  Future<void> pinMessage(String messageId, {bool pin = true}) async {
    for (final entry in chatMessages.entries) {
      if (!entry.value.any((m) => m.id == messageId)) continue;
      if (pin) {
        pins[entry.key] = messageId;
      } else if (pins[entry.key] == messageId) {
        pins.remove(entry.key);
      }
      _events.add(ChatEvent(conversationId: entry.key));
    }
  }

  @override
  Future<ChatPin> chatPin(String conversationId) async {
    final id = pins[conversationId];
    final m = id == null
        ? null
        : chatMessages[conversationId]?.where((m) => m.id == id).firstOrNull;
    return ChatPin(
      canPin: !noPinning.contains(conversationId),
      message: m == null
          ? null
          : PinnedMessage(
              messageId: m.id,
              senderName: m.senderName,
              body: m.body,
              fileName: m.file?.name,
            ),
    );
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

  /// Labels by id: (workspace, name), and the messages under each.
  final labels = <String, (String, String)>{};
  final labelLinks = <String, List<String>>{};
  var _labelCount = 0;

  /// The chat a message is in.
  String? _chatOf(String messageId) => chatMessages.entries
      .where((e) => e.value.any((m) => m.id == messageId && !m.deleted))
      .firstOrNull
      ?.key;

  @override
  Future<List<MessageLabel>> myLabels(String workspaceId) async => [
    for (final e in labels.entries.toList().reversed)
      if (e.value.$1 == workspaceId)
        MessageLabel(
          id: e.key,
          name: e.value.$2,
          messages: (labelLinks[e.key] ?? const [])
              .where((id) => _chatOf(id) != null)
              .length,
        ),
  ];

  @override
  Future<Map<String, Set<String>>> chatLabels(String conversationId) async {
    final out = <String, Set<String>>{};
    for (final e in labelLinks.entries) {
      for (final id in e.value) {
        if (_chatOf(id) == conversationId) {
          out.putIfAbsent(id, () => {}).add(e.key);
        }
      }
    }
    return out;
  }

  @override
  Future<String> labelMessage(
    String messageId, {
    String? labelId,
    String? name,
  }) async {
    final chat = _chatOf(messageId)!;
    final ws = chatWorkspace[chat]!;
    var id = labelId;
    if (id == null) {
      final clean = name!.trim();
      id = labels.entries
          .where(
            (e) =>
                e.value.$1 == ws &&
                e.value.$2.toLowerCase() == clean.toLowerCase(),
          )
          .firstOrNull
          ?.key;
      if (id == null) {
        id = 'label${++_labelCount}';
        labels[id] = (ws, clean);
      }
    }
    final list = labelLinks.putIfAbsent(id, () => []);
    if (!list.contains(messageId)) list.add(messageId);
    // The most recently used comes first.
    labels[id] = labels.remove(id)!;
    return id;
  }

  @override
  Future<void> unlabelMessage(String messageId, String labelId) async =>
      labelLinks[labelId]?.remove(messageId);

  @override
  Future<void> renameLabel(String labelId, String name) async {
    final (ws, _) = labels[labelId]!;
    labels[labelId] = (ws, name.trim());
  }

  @override
  Future<void> deleteLabel(String labelId) async {
    labels.remove(labelId);
    labelLinks.remove(labelId);
  }

  @override
  Future<List<MessageHit>> labelled(
    String labelId, {
    String? conversationId,
  }) async {
    final hits = <MessageHit>[];
    for (final id in labelLinks[labelId] ?? const <String>[]) {
      final chat = _chatOf(id);
      if (chat == null || (conversationId != null && chat != conversationId)) {
        continue;
      }
      final m = chatMessages[chat]!.firstWhere((m) => m.id == id);
      hits.add(
        MessageHit(
          messageId: m.id,
          chat: chats[chat]!,
          createdAt: m.createdAt,
          senderName: m.senderName,
          body: m.body,
          fileName: m.file?.name,
        ),
      );
    }
    return hits..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

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
    final stored = ChatFile(
      id: 'f${_seq++}',
      name: file.name,
      mime: file.mime,
      size: file.bytes.length,
      path: 'ws/me/${file.name}',
    );
    // It is also sent in the project's chat, marked as from the Files tab.
    final chat = await projectConversation(projectId);
    String? messageId;
    if (chat != null) {
      final sent = ChatMessage(
        id: 'm${_seq++}',
        senderId: 'me',
        senderName: name,
        createdAt: _tick(),
        projectId: projectId,
        file: stored,
        fromFiles: true,
      );
      chatMessages[chat]!.insert(0, sent);
      messageId = sent.id;
      _events.add(ChatEvent(conversationId: chat));
    }
    projectFileList
        .putIfAbsent(projectId, () => [])
        .insert(
          0,
          ProjectFile(
            file: stored,
            pinned: false,
            uploadedBy: 'me',
            uploaderName: name,
            createdAt: _tick(),
            conversationId: chat,
            messageId: messageId,
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
          broadcastId: a.broadcastId,
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

  /// Announcements sent to several workspaces: their workspaces, and how
  /// each is doing.
  final broadcasts = <List<String>>[];
  final reach = <String, List<BroadcastReach>>{};

  @override
  Future<void> postBroadcast(
    List<String> workspaceIds, {
    required String body,
    bool pinned = false,
    bool needsAck = false,
  }) async {
    broadcasts.add(workspaceIds);
    announcementList.insert(
      0,
      Announcement(
        id: 'a${_seq++}',
        body: body,
        pinned: pinned,
        authorId: 'me',
        authorName: name,
        createdAt: _tick(),
        audience: 3,
        needsAck: needsAck,
        broadcastId: 'b${broadcasts.length}',
      ),
    );
  }

  @override
  Future<List<BroadcastReach>> broadcastReach(String broadcastId) async =>
      reach[broadcastId] ?? const [];

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

  /// The server's key for desktop notifications.
  String? webKey = 'BWebPushKey';

  @override
  Future<String?> webPushKey() async => webKey;

  @override
  Future<void> markNotificationsRead([List<String>? ids]) async {
    for (var i = 0; i < notificationList.length; i++) {
      final n = notificationList[i];
      if (ids != null && !ids.contains(n.id)) continue;
      notificationList[i] = n.read(_clock);
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
  Future<void> adminSetPlanWorkers(
    String planId, {
    int? freeWorkers,
    double extraUsd = 0,
  }) async => billingCalls.add('workers $planId $freeWorkers $extraUsd');

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

  // Attendance: one person (the signed-in user), kept in memory.

  AttendanceSetup? attendance;
  ShiftToday? shiftToday;
  final attendanceRecords = <AttendanceRecord>[];
  final attendanceCalls = <String>[];
  int _attSeq = 0;

  DateTime get _today {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  AttendanceRecord? get _todayRecord {
    for (final r in attendanceRecords) {
      if (r.day == _today) return r;
    }
    return null;
  }

  @override
  Future<AttendanceToday> attendanceToday(String workspaceId) async {
    final a = attendance;
    final admin = memberships
        .where((m) => m.workspaceId == workspaceId)
        .any((m) => m.role.canManage);
    if (a == null || !a.enabled) {
      return AttendanceToday(enabled: false, isAdmin: admin);
    }
    final recent = attendanceRecords
        .where((r) => !r.day.isBefore(_today.subtract(const Duration(days: 6))))
        .toList();
    return AttendanceToday(
      enabled: true,
      isAdmin: admin,
      isManager: attendanceManager ?? admin,
      today: _today,
      weekendDays: a.weekendDays,
      requireSelfie: a.requireSelfie,
      allowOutside: a.allowOutside,
      shift: shiftToday,
      sites: a.sites,
      record: _todayRecord,
      recent: recent,
      monthPresent: attendanceRecords.length,
      monthLate: attendanceRecords.where((r) => r.lateMinutes > 0).length,
      monthLateMinutes: attendanceRecords.fold(0, (s, r) => s + r.lateMinutes),
    );
  }

  @override
  Future<AttendanceRecord> checkIn(
    String workspaceId,
    LocationFix at, {
    Upload? photo,
    OutsideReason? reason,
    String? note,
  }) async {
    final a = attendance;
    if (a == null || !a.enabled) {
      throw const PostgrestException(message: 'attendance_off');
    }
    if (_todayRecord != null) {
      throw const PostgrestException(message: 'already_checked_in');
    }
    if (a.requireSelfie && photo == null) {
      throw const PostgrestException(message: 'selfie_required');
    }
    final place = PlaceCheck.of(at, sites: a.sites);
    if (!place.inside && reason == null) {
      throw const PostgrestException(message: 'attendance_reason_required');
    }
    final now = DateTime.now();
    final late =
        shiftToday == null ||
            now.isBefore(
              shiftToday!.startAt.add(Duration(minutes: shiftToday!.grace)),
            )
        ? 0
        : now.difference(shiftToday!.startAt).inMinutes;
    final r = AttendanceRecord(
      id: 'att${_attSeq++}',
      day: _today,
      inAt: now,
      lateMinutes: late,
      inSite: place.site?.name,
      inDistanceM: place.distanceM,
      outside: !place.inside,
      reason: place.inside ? null : reason,
      reasonNote: place.inside ? null : note,
      review: place.inside ? AttendanceReview.none : AttendanceReview.pending,
      inPhotoPath: photo == null ? null : 'ws/me/${photo.name}',
    );
    attendanceRecords.add(r);
    attendanceCalls.add(
      'in ${at.lat},${at.lng} ${reason?.name ?? '-'} ${photo?.name ?? '-'}',
    );
    return r;
  }

  @override
  Future<AttendanceRecord> checkOut(
    String workspaceId,
    LocationFix at, {
    Upload? photo,
  }) async {
    final open = _todayRecord;
    if (open == null || !open.open) {
      throw const PostgrestException(message: 'not_checked_in');
    }
    final r = AttendanceRecord(
      id: open.id,
      day: open.day,
      inAt: open.inAt,
      outAt: DateTime.now(),
      lateMinutes: open.lateMinutes,
      inSite: open.inSite,
      inDistanceM: open.inDistanceM,
      outside: open.outside,
      reason: open.reason,
      reasonNote: open.reasonNote,
      review: open.review,
    );
    attendanceRecords[attendanceRecords.indexOf(open)] = r;
    attendanceCalls.add('out ${at.lat},${at.lng}');
    return r;
  }

  @override
  Future<List<AttendanceRecord>> myAttendance(
    String workspaceId,
    DateTime from,
    DateTime to,
  ) async => [
    for (final r in attendanceRecords.reversed)
      if (!r.day.isBefore(from) && !r.day.isAfter(to)) r,
  ];

  @override
  Future<void> enableAttendance(String workspaceId, String shiftName) async {
    attendanceCalls.add('enable $shiftName');
    attendance = (attendance ?? const AttendanceSetup(enabled: true)).copyWith(
      enabled: true,
    );
    if (attendance!.shifts.isEmpty) {
      final shift = AttendanceShift(
        id: 'sh0',
        name: shiftName,
        start: const TimeOfDay(hour: 9, minute: 0),
        end: const TimeOfDay(hour: 17, minute: 0),
      );
      attendance = AttendanceSetup(
        enabled: true,
        weekendDays: attendance!.weekendDays,
        defaultShiftId: shift.id,
        shifts: [shift],
        sites: attendance!.sites,
      );
    }
  }

  @override
  Future<AttendanceSetup> attendanceSetup(String workspaceId) async =>
      attendance ?? const AttendanceSetup(enabled: false);

  @override
  Future<void> saveAttendanceSettings(
    String workspaceId,
    AttendanceSetup s,
  ) async {
    final days = s.weekendDays.toList()..sort();
    attendanceCalls.add(
      'settings ${s.enabled} ${days.join(',')} selfie=${s.requireSelfie} '
      'outside=${s.allowOutside} default=${s.defaultShiftId}',
    );
    attendance = AttendanceSetup(
      enabled: s.enabled,
      weekendDays: s.weekendDays,
      requireSelfie: s.requireSelfie,
      allowOutside: s.allowOutside,
      reminders: s.reminders,
      defaultShiftId: s.defaultShiftId,
      ramadanFrom: s.ramadanFrom,
      ramadanTo: s.ramadanTo,
      ramadanStart: s.ramadanStart,
      ramadanEnd: s.ramadanEnd,
      shifts: attendance?.shifts ?? const [],
      sites: attendance?.sites ?? const [],
    );
  }

  AttendanceSetup _withLists({
    List<AttendanceShift>? shifts,
    List<AttendanceSite>? sites,
  }) {
    final a = attendance ?? const AttendanceSetup(enabled: true);
    return AttendanceSetup(
      enabled: a.enabled,
      weekendDays: a.weekendDays,
      requireSelfie: a.requireSelfie,
      allowOutside: a.allowOutside,
      reminders: a.reminders,
      defaultShiftId: a.defaultShiftId,
      ramadanFrom: a.ramadanFrom,
      ramadanTo: a.ramadanTo,
      ramadanStart: a.ramadanStart,
      ramadanEnd: a.ramadanEnd,
      shifts: shifts ?? a.shifts,
      sites: sites ?? a.sites,
    );
  }

  @override
  Future<String> saveShift(
    String workspaceId, {
    String? id,
    required String name,
    required TimeOfDay start,
    required TimeOfDay end,
    required int graceMinutes,
  }) async {
    final shiftId = id ?? 'sh${_attSeq++}';
    final shift = AttendanceShift(
      id: shiftId,
      name: name,
      start: start,
      end: end,
      graceMinutes: graceMinutes,
    );
    final list = [...?attendance?.shifts]..removeWhere((s) => s.id == shiftId);
    attendance = _withLists(shifts: [...list, shift]);
    attendanceCalls.add(
      'shift $name ${clockParam(start)}-${clockParam(end)} $graceMinutes',
    );
    return shiftId;
  }

  @override
  Future<void> deleteShift(String workspaceId, String id) async {
    attendance = _withLists(
      shifts: [...?attendance?.shifts]..removeWhere((s) => s.id == id),
    );
    attendanceCalls.add('delete shift $id');
  }

  @override
  Future<String> saveSite(
    String workspaceId, {
    String? id,
    required String name,
    double? lat,
    double? lng,
    int radiusM = 150,
  }) async {
    final siteId = id ?? 'site${_attSeq++}';
    final site = AttendanceSite(
      id: siteId,
      name: name,
      lat: lat,
      lng: lng,
      radiusM: radiusM,
    );
    final list = [...?attendance?.sites]..removeWhere((s) => s.id == siteId);
    attendance = _withLists(sites: [...list, site]);
    attendanceCalls.add('site $name ${lat ?? '-'},${lng ?? '-'} $radiusM');
    return siteId;
  }

  @override
  Future<void> deleteSite(String workspaceId, String id) async {
    attendance = _withLists(
      sites: [...?attendance?.sites]..removeWhere((s) => s.id == id),
    );
    attendanceCalls.add('delete site $id');
  }

  // Attendance for managers: a team, today's records by person, requests.

  /// Null: managers are the workspace's owners and admins.
  bool? attendanceManager;
  final teamPeople = <TeamPerson>[];
  final teamRecords = <String, AttendanceRecord>{};
  final teamEdits = <String, List<AttendanceEdit>>{};
  final teamReviews = <(AttendanceRecord, String)>[];
  final teamFixes = <AttendanceFix>[];
  final myFixes = <AttendanceFix>[];
  var teamProjects = <AttendanceOption>[];
  int? workersFree;
  double extraWorkerUsd = 0;

  TeamPerson _withRecord(TeamPerson p) => TeamPerson(
    id: p.id,
    name: p.name,
    userId: p.userId,
    jobTitle: p.jobTitle,
    phone: p.phone,
    code: p.code,
    projectId: p.projectId,
    projectName: p.projectName,
    siteId: p.siteId,
    siteName: p.siteName,
    shiftId: p.shiftId,
    shift: p.shift,
    dayOff: p.dayOff,
    record: teamRecords[p.id],
  );

  @override
  Future<TeamBoard> teamAttendance(
    String workspaceId, {
    DateTime? day,
    String? projectId,
  }) async {
    final admin = memberships
        .where((m) => m.workspaceId == workspaceId)
        .any((m) => m.role.canManage);
    final d = day ?? _today;
    return TeamBoard(
      day: d,
      today: _today,
      isAdmin: admin,
      projects: teamProjects,
      sites: [
        for (final s in attendance?.sites ?? const <AttendanceSite>[])
          AttendanceOption(s.id, s.name),
      ],
      shifts: [
        for (final s in attendance?.shifts ?? const <AttendanceShift>[])
          AttendanceOption(s.id, s.name),
      ],
      workersUsed: teamPeople.where((p) => !p.hasApp).length,
      workersFree: workersFree,
      extraWorkerUsd: extraWorkerUsd,
      requests: teamReviews.length + teamFixes.length,
      people: [
        for (final p in teamPeople)
          if (projectId == null || p.projectId == projectId)
            d == _today ? _withRecord(p) : p,
      ],
    );
  }

  @override
  Future<AttendanceReport> attendanceReport(
    String workspaceId, {
    required DateTime from,
    required DateTime to,
    String? projectId,
    List<String>? personIds,
  }) async {
    String d(DateTime t) => '${t.month}/${t.day}';
    attendanceCalls.add(
      'report ${d(from)}-${d(to)} ${projectId ?? '-'} '
      '${personIds?.join(',') ?? '-'}',
    );
    final last = to.isAfter(_today) ? _today : to;
    return AttendanceReport(
      workspace: 'Acme',
      from: from,
      to: last,
      rows: [
        for (final p in teamPeople)
          if ((projectId == null || p.projectId == projectId) &&
              (personIds == null || personIds.contains(p.id)))
            for (
              var day = from;
              !day.isAfter(last);
              day = DateTime(day.year, day.month, day.day + 1)
            )
              ReportRow(
                personId: p.id,
                name: p.name,
                day: day,
                jobTitle: p.jobTitle,
                hasApp: p.hasApp,
                project: p.projectName,
                inAt: day == _today ? teamRecords[p.id]?.inAt : null,
                outAt: day == _today ? teamRecords[p.id]?.outAt : null,
                lateMinutes: day == _today
                    ? teamRecords[p.id]?.lateMinutes ?? 0
                    : 0,
                inBy: day == _today ? teamRecords[p.id]?.inByName : null,
              ),
      ],
    );
  }

  @override
  Future<PersonDay> personDay(String personId, DateTime day) async {
    final p = teamPeople.firstWhere((p) => p.id == personId);
    return PersonDay(
      person: day == _today ? _withRecord(p) : p,
      canEdit: true,
      edits: teamEdits[personId] ?? const [],
      fix: teamFixes.where((f) => f.personId == personId).firstOrNull,
    );
  }

  @override
  Future<void> reviewAttendance(String recordId, {required bool accept}) async {
    teamReviews.removeWhere((r) => r.$1.id == recordId);
    attendanceCalls.add('review $recordId $accept');
  }

  @override
  Future<String> saveWorker(
    String workspaceId, {
    String? id,
    required String name,
    String? jobTitle,
    String? phone,
    String? code,
    String? projectId,
    String? siteId,
    String? shiftId,
  }) async {
    final used = teamPeople.where((p) => !p.hasApp).length;
    if (id == null &&
        workersFree != null &&
        used >= workersFree! &&
        extraWorkerUsd == 0) {
      throw const PostgrestException(message: 'workers_limit');
    }
    final workerId = id ?? 'w${_attSeq++}';
    final worker = TeamPerson(
      id: workerId,
      name: name,
      jobTitle: jobTitle,
      phone: phone,
      code: code,
      projectId: projectId,
      projectName: teamProjects
          .where((p) => p.id == projectId)
          .firstOrNull
          ?.name,
      siteId: siteId,
      shiftId: shiftId,
      shift: shiftToday,
    );
    final i = teamPeople.indexWhere((p) => p.id == workerId);
    if (i < 0) {
      teamPeople.add(worker);
    } else {
      teamPeople[i] = worker;
    }
    attendanceCalls.add(
      'worker $name ${jobTitle ?? '-'} ${projectId ?? '-'} ${siteId ?? '-'}',
    );
    return workerId;
  }

  @override
  Future<void> removeWorker(String personId) async {
    teamPeople.removeWhere((p) => p.id == personId);
    attendanceCalls.add('remove worker $personId');
  }

  @override
  Future<void> assignAttendance(
    String personId, {
    String? siteId,
    String? shiftId,
  }) async => attendanceCalls.add('assign $personId $siteId $shiftId');

  @override
  Future<RollCallResult> rollCall(
    String workspaceId, {
    required bool checkIn,
    required Map<String, DateTime> times,
    LocationFix? at,
    Upload? photo,
  }) async {
    var done = 0;
    final skipped = <String>[];
    for (final e in times.entries) {
      final p = teamPeople.firstWhere((p) => p.id == e.key);
      final r = teamRecords[p.id];
      if (checkIn) {
        if (r != null) {
          skipped.add(p.id);
          continue;
        }
        final s = p.shift;
        final late =
            s != null &&
                e.value.isAfter(s.startAt.add(Duration(minutes: s.grace)))
            ? e.value.difference(s.startAt).inMinutes
            : 0;
        teamRecords[p.id] = AttendanceRecord(
          id: 'tr${_attSeq++}',
          personId: p.id,
          day: _today,
          inAt: e.value,
          lateMinutes: late,
          inByName: name,
        );
      } else {
        if (r == null || !r.open) {
          skipped.add(p.id);
          continue;
        }
        teamRecords[p.id] = AttendanceRecord(
          id: r.id,
          personId: p.id,
          day: r.day,
          inAt: r.inAt,
          outAt: e.value,
          lateMinutes: r.lateMinutes,
          inByName: r.inByName,
          outByName: name,
        );
      }
      done++;
    }
    String hm(DateTime t) =>
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    attendanceCalls.add(
      'roll ${checkIn ? 'in' : 'out'} '
      '${times.entries.map((e) => '${e.key}@${hm(e.value)}').join(',')}'
      '${photo == null ? '' : ' photo'}',
    );
    return RollCallResult(recorded: done, skipped: skipped);
  }

  @override
  Future<void> setAttendanceTimes(
    String recordId, {
    required DateTime inAt,
    DateTime? outAt,
    String? note,
  }) async {
    attendanceCalls.add(
      'times $recordId ${inAt.hour}:${inAt.minute} '
      '${outAt == null ? '-' : '${outAt.hour}:${outAt.minute}'} ${note ?? ''}',
    );
  }

  @override
  Future<void> deleteAttendanceRecord(String recordId, {String? note}) async {
    teamRecords.removeWhere((_, r) => r.id == recordId);
    attendanceCalls.add('delete record $recordId');
  }

  @override
  Future<void> requestAttendanceFix(
    String workspaceId,
    DateTime day, {
    DateTime? inAt,
    DateTime? outAt,
    required String note,
  }) async {
    if (myFixes.any((f) => f.day == day && f.status == FixStatus.pending)) {
      throw const PostgrestException(message: 'fix_pending');
    }
    myFixes.insert(
      0,
      AttendanceFix(
        id: 'fix${_attSeq++}',
        day: day,
        inAt: inAt,
        outAt: outAt,
        note: note,
      ),
    );
    String hm(DateTime? t) => t == null
        ? '-'
        : '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    attendanceCalls.add('fix ${day.day} ${hm(inAt)} ${hm(outAt)} $note');
  }

  @override
  Future<void> cancelAttendanceFix(String fixId) async {
    myFixes.removeWhere((f) => f.id == fixId);
    attendanceCalls.add('cancel fix $fixId');
  }

  @override
  Future<void> decideAttendanceFix(
    String fixId, {
    required bool accept,
    String? note,
  }) async {
    teamFixes.removeWhere((f) => f.id == fixId);
    attendanceCalls.add('decide $fixId $accept');
  }

  @override
  Future<List<AttendanceFix>> myAttendanceFixes(
    String workspaceId,
    DateTime from,
    DateTime to,
  ) async => [
    for (final f in myFixes)
      if (!f.day.isBefore(from) && !f.day.isAfter(to)) f,
  ];

  @override
  Future<AttendanceRequests> attendanceRequests(String workspaceId) async =>
      AttendanceRequests(reviews: [...teamReviews], fixes: [...teamFixes]);
}
