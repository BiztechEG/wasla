import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart' show TimeOfDay;
import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'attendance_models.dart';
import 'billing_models.dart';
import 'chat_models.dart';
import 'models.dart';
import 'overview_models.dart';
import 'picker.dart';
import 'search_models.dart';
import 'task_models.dart';

/// Everything the app asks of the backend. Screens only talk to this, so
/// tests can swap in a fake and a self-hosted server only needs a new
/// implementation if it stops speaking the Supabase protocol.
abstract class WaslaApi {
  /// The signed-in user's id, then every change to it (null when signed out).
  Stream<String?> userIdChanges();

  Future<void> sendEmailCode(String email);
  Future<void> verifyEmailCode(String email, String code);
  Future<void> signOut();

  Future<Profile> myProfile();
  Future<void> updateProfile({String? fullName, String? locale, String? theme});

  Future<List<Membership>> myWorkspaces();
  Future<List<MyInvite>> myInvites();
  Future<String> acceptInvite(String token);
  Future<void> declineInvite(String token);

  Future<String> createCompanyWorkspace({
    required String companyName,
    required String countryCode,
    required String workspaceName,
  });
  Future<String> createWorkspace({
    required String companyId,
    required String name,
  });
  Future<void> setDiscoverable(String workspaceId, bool discoverable);

  /// Whether people may share messages and files to other apps.
  Future<void> setAllowSharing(String workspaceId, bool allow);
  Future<void> renameWorkspace(String workspaceId, String name);
  Future<void> leaveWorkspace(String workspaceId);

  /// Needs the workspace's name typed back as [confirmName].
  Future<void> deleteWorkspace(String workspaceId, String confirmName);
  Future<List<DeletedWorkspace>> deletedWorkspaces();
  Future<void> restoreWorkspace(String workspaceId);

  Future<List<WorkspaceHit>> searchWorkspaces(String query);
  Future<void> requestToJoin(String workspaceId, {String? message});
  Future<List<MyJoinRequest>> myJoinRequests();
  Future<void> cancelJoinRequest(String requestId);

  Future<List<Member>> members(String workspaceId);
  Future<void> setMemberRole(
    String workspaceId,
    String userId,
    WorkspaceRole role,
  );
  Future<void> removeMember(String workspaceId, String userId);

  Future<void> invite(
    String workspaceId, {
    required String email,
    required WorkspaceRole role,
    List<String> projectIds = const [],
  });
  Future<List<SentInvite>> sentInvites(String workspaceId);
  Future<void> cancelInvite(String inviteId);

  Future<List<JoinRequest>> joinRequests(String workspaceId);
  Future<void> decideJoinRequest(String requestId, {required bool accept});

  /// The workspace's join code, for its admins; null while it is off.
  Future<JoinCode?> joinCode(String workspaceId);

  /// Turns the join code on (a new one with [renew]) or off.
  Future<JoinCode?> setJoinCode(
    String workspaceId, {
    required bool enabled,
    bool autoJoin = false,
    bool renew = false,
  });

  /// How each workspace one runs is doing (a company owner: all of the
  /// company's), in numbers only.
  Future<List<WorkspaceOverview>> managementOverview();

  /// Where a join code leads; null when it leads nowhere.
  Future<CodeWorkspace?> workspaceByCode(String code);

  /// Joins with a code; false when it sent a request to join instead.
  Future<bool> joinWithCode(String code, {String? message});

  Future<List<Project>> projects(String workspaceId);

  /// Task counts per project id, for projects with tasks one may see.
  Future<Map<String, ProjectProgress>> projectProgress(String workspaceId);
  Future<String> createProject(
    String workspaceId, {
    required String name,
    required String color,
  });
  Future<void> setProjectStatus(String projectId, ProjectStatus status);
  Future<List<ProjectMember>> projectMembers(String projectId);
  Future<void> addProjectMember(String projectId, String userId);
  Future<void> removeProjectMember(String projectId, String userId);
  Future<void> setProjectRole(
    String projectId,
    String userId,
    ProjectRole role,
  );

  // Chats

  Future<List<Conversation>> conversations(String workspaceId);

  /// The private chat with [userId], created on first use.
  Future<String> openDirect(String workspaceId, String userId);

  /// Keeps a chat's messages off one's phone until [until] (null: until
  /// unmuted). Mentions still come through.
  Future<void> muteConversation(String conversationId, {DateTime? until});
  Future<void> unmuteConversation(String conversationId);

  /// Chats one has muted in a workspace, and until when (null: for good).
  Future<Map<String, DateTime?>> mutedConversations(String workspaceId);

  /// Hours when nothing reaches one's phone; null when off.
  Future<QuietHours?> quietHours();

  /// Whether one gets the weekly report (for whoever runs a team).
  Future<bool> weeklyReport();
  Future<void> setWeeklyReport(bool on);

  /// A workspace's departments, for its owners and admins.
  Future<List<Department>> departments(String workspaceId);

  /// The departments one manages in a workspace, by id.
  Future<Map<String, String>> myDepartments(String workspaceId);

  /// Makes ([departmentId] null) or changes a department.
  Future<void> saveDepartment(
    String workspaceId, {
    String? departmentId,
    required String name,
    required List<String> managerIds,
    required List<String> projectIds,
  });
  Future<void> deleteDepartment(String departmentId);

  /// The statuses of a workspace's members, by user id; those available
  /// are left out.
  Future<Map<String, UserStatus>> workspaceStatuses(String workspaceId);

  /// Sets one's status, or with null clears it.
  Future<void> setMyStatus(UserStatus? status);

  /// A new workspace's first steps, for its owners and admins; null for
  /// anyone else.
  Future<SetupProgress?> workspaceSetup(String workspaceId);

  /// Sets quiet hours, or turns them off with nulls.
  Future<void> setQuietHours(TimeOfDay? from, TimeOfDay? to, int utcOffset);

  /// A project's group chat, or null for someone who cannot see it.
  Future<String?> projectConversation(String projectId);

  /// Newest first. [before] pages back; [after] fetches what is new.
  Future<List<ChatMessage>> messages(
    String conversationId, {
    DateTime? before,
    DateTime? after,
    String? projectId,
    int limit = 50,
  });
  Future<void> sendMessage(
    String workspaceId,
    String conversationId, {
    String? body,
    String? replyTo,
    String? projectId,
    Upload? file,
    List<String> mentions = const [],
  });
  Future<void> markRead(String conversationId, DateTime until);

  /// Adds the signed-in user's [emoji] reaction, or takes it back.
  Future<void> toggleReaction(String messageId, String emoji);

  /// A message and every reply under it, oldest first.
  Future<List<ChatMessage>> replyChain(String messageId);

  /// Asks the chat [question] with [options]; [multiple]: more than one may
  /// be picked.
  Future<void> createPoll(
    String conversationId, {
    required String question,
    required List<String> options,
    bool multiple = false,
    String? projectId,
  });

  /// One's answer to a poll; none takes it back.
  Future<void> votePoll(String messageId, Set<int> options);
  Future<void> closePoll(String messageId);

  /// Pins a message on top of its chat, or with [pin] false takes it down.
  Future<void> pinMessage(String messageId, {bool pin = true});
  Future<ChatPin> chatPin(String conversationId);

  /// The days, in the device's time zone, that a chat has messages on.
  Future<Set<DateTime>> messageDays(String conversationId, {String? projectId});

  /// [filePath]: the message's file, when the signed-in user sent it, so the
  /// stored copy is removed too.
  Future<void> deleteMessage(String messageId, {String? filePath});
  Future<List<ReadState>> readStates(String conversationId);
  Future<List<MessageHit>> searchMessages(String workspaceId, String query);

  /// Files, tasks and announcements matching [query] that one can see.
  Future<WorkspaceSearch> searchWorkspace(String workspaceId, String query);

  /// Projects a private chat's messages can be tagged with: active ones both
  /// people are in.
  Future<List<String>> sharedProjects(String conversationId);

  /// Active projects that both the signed-in user and [userId] are part of.
  Future<List<String>> projectsWith(String workspaceId, String userId);

  /// Fires whenever a message arrives, changes or is read in [workspaceId],
  /// and with [ChatEvent.everything] when changes may have been missed.
  Stream<ChatEvent> chatEvents(String workspaceId);

  // Files

  Future<List<ProjectFile>> projectFiles(String projectId);
  Future<void> addProjectFile(
    String workspaceId,
    String projectId,
    Upload file,
  );
  Future<void> setFilePinned(String fileId, bool pinned);

  /// [filePath]: given when the signed-in user added the file, so the stored
  /// copy is removed too.
  Future<void> deleteFile(String fileId, {String? filePath});

  /// A short-lived link for viewing or downloading a stored file.
  Future<String> fileUrl(String path);

  /// A stored file's contents, to share it as a file.
  Future<Uint8List> fileBytes(String path);

  // Announcements

  Future<List<Announcement>> announcements(
    String workspaceId, {
    String? projectId,
  });
  Future<List<UnreadAnnouncement>> unreadAnnouncements(String workspaceId);
  Future<void> postAnnouncement(
    String workspaceId, {
    String? projectId,
    required String body,
    bool pinned = false,
    bool needsAck = false,
  });
  Future<void> markAnnouncementsRead(List<String> ids);

  /// "I've read it", for an announcement that asks.
  Future<void> acknowledgeAnnouncement(String id);

  /// Who an announcement is for and whether they read and confirmed it; for
  /// its author and those who may post such announcements.
  Future<List<AnnouncementReader>> announcementReaders(String id);
  Future<void> setAnnouncementPinned(String id, bool pinned);
  Future<void> deleteAnnouncement(String id);

  /// The same workspace-wide announcement to each of [workspaceIds].
  Future<void> postBroadcast(
    List<String> workspaceIds, {
    required String body,
    bool pinned = false,
    bool needsAck = false,
  });

  /// How an announcement sent to several workspaces is doing in each one
  /// runs.
  Future<List<BroadcastReach>> broadcastReach(String broadcastId);

  // Tasks

  /// Tasks one created or is assigned, across every workspace.
  Future<List<TaskItem>> myTasks();
  Future<List<TaskItem>> projectTasks(String projectId);

  /// Tasks in the projects one leads (all projects for an admin).
  Future<List<TaskItem>> managedTasks(String workspaceId);
  Future<TaskDetail> task(String taskId);

  /// Creates the task and returns its id.
  Future<String> createTask(TaskDraft draft);
  Future<void> updateTask(String taskId, TaskDraft draft);
  Future<void> setTaskAssignees(String taskId, List<String> userIds);

  /// Null stops it repeating. Repeating needs a due time.
  Future<void> setTaskRepeat(String taskId, TaskRepeat? repeat);

  Future<List<TaskTemplate>> taskTemplates(String workspaceId);
  Future<void> saveTaskTemplate(
    String workspaceId,
    String name,
    List<TemplateItem> items,
  );
  Future<void> deleteTaskTemplate(String templateId);

  /// Adds a template's tasks to a project, due their days after [start].
  /// Returns how many were added.
  Future<int> applyTaskTemplate(
    String templateId,
    String projectId, {
    List<String>? assigneeIds,
    required DateTime start,
  });
  Future<void> setTaskStatus(
    String taskId,
    TaskStatus status, {
    String? reason,
  });
  Future<void> addTaskComment(String taskId, String body);
  Future<void> addTaskAttachment(
    String workspaceId,
    String taskId,
    Upload file,
  );

  /// Reminds the assignees now.
  Future<void> nudgeTask(String taskId);
  Future<void> addTaskReminder(String taskId, DateTime at);
  Future<void> deleteTaskReminder(String reminderId);
  Future<void> deleteTask(String taskId);

  /// Fires when a task one sees in [workspaceId] changes, and when changes
  /// may have been missed.
  Stream<void> taskEvents(String workspaceId);

  // Notifications

  Future<List<AppNotification>> notifications();

  /// Marks [ids] read, or every notification when null.
  Future<void> markNotificationsRead([List<String>? ids]);

  /// Tells the server this phone gets the signed-in person's notifications,
  /// written in [locale].
  Future<void> registerPushToken(String token, String platform, String locale);

  /// This phone stops getting the signed-in person's notifications.
  Future<void> unregisterPushToken(String token);

  /// The key browsers subscribe to desktop notifications with; null until
  /// the server has one.
  Future<String?> webPushKey();

  /// Fires when a notification arrives for the signed-in user, and when
  /// some may have been missed.
  Stream<void> notificationEvents();

  /// Wasla's logo set from the admin dashboard, or null for the built-in one.
  Future<String?> logoUrl();

  /// Uploads [file] as the logo, or puts back the built-in one when null.
  /// Platform admins only.
  Future<void> setLogo(Upload? file);

  // Subscriptions: company owners see and ask; platform admins invoice.

  /// Whether the signed-in user runs the platform.
  Future<bool> isPlatformAdmin();

  /// A company's plans, workspaces and invoices, for its owner or a platform
  /// admin.
  Future<BillingOverview> billing(String companyId);
  Future<void> requestPlan(
    String workspaceId,
    String planId, {
    required int months,
    String? note,
  });
  Future<void> cancelPlanRequest(String requestId);

  Future<AdminOverview> adminOverview();
  Future<List<AdminCompany>> adminCompanies({String? search});

  /// Plan requests waiting for an invoice, oldest first.
  Future<List<AdminRequest>> adminRequests();
  Future<List<Invoice>> adminInvoices({InvoiceStatus? status});
  Future<List<PlanOption>> adminPlans();
  Future<List<CountryRate>> adminRates();
  Future<PaymentInfo> adminPaymentInfo();
  Future<void> adminSetRate(String countryCode, double rate);

  /// Saves [plan]'s name, limits, price and whether companies can ask for it.
  Future<void> adminUpdatePlan(PlanOption plan);

  /// Free workers without the app on a plan (null = twice its seats), and
  /// the monthly price of each one past that (0 = no more).
  Future<void> adminSetPlanWorkers(
    String planId, {
    int? freeWorkers,
    double extraUsd = 0,
  });
  Future<void> adminUpdatePaymentInfo(PaymentInfo info);

  /// Issues an invoice and returns its id.
  Future<String> adminCreateInvoice(
    String companyId,
    List<InvoiceItem> items, {
    required int months,
    double discountPct = 0,
    String? note,
    int dueDays = 14,
  });
  Future<void> adminMarkInvoicePaid(String invoiceId, {String? reference});
  Future<void> adminVoidInvoice(String invoiceId);

  /// Puts a workspace on a plan by hand; without [until] it never runs out.
  Future<void> adminSetWorkspacePlan(
    String workspaceId,
    String planId, {
    DateTime? until,
  });

  // Attendance

  Future<AttendanceToday> attendanceToday(String workspaceId);

  /// [photo] is a selfie; [reason] is needed away from one's branch.
  Future<AttendanceRecord> checkIn(
    String workspaceId,
    LocationFix at, {
    Upload? photo,
    OutsideReason? reason,
    String? note,
  });
  Future<AttendanceRecord> checkOut(
    String workspaceId,
    LocationFix at, {
    Upload? photo,
  });

  /// The signed-in user's days from [from] to [to], newest first.
  Future<List<AttendanceRecord>> myAttendance(
    String workspaceId,
    DateTime from,
    DateTime to,
  );

  /// Turns attendance on; the first time also adds a 9-to-5 shift called
  /// [shiftName].
  Future<void> enableAttendance(String workspaceId, String shiftName);
  Future<AttendanceSetup> attendanceSetup(String workspaceId);
  Future<void> saveAttendanceSettings(String workspaceId, AttendanceSetup s);

  /// Adds a shift when [id] is null. Returns its id.
  Future<String> saveShift(
    String workspaceId, {
    String? id,
    required String name,
    required TimeOfDay start,
    required TimeOfDay end,
    required int graceMinutes,
  });
  Future<void> deleteShift(String workspaceId, String id);

  /// Adds a branch when [id] is null; no point makes a field branch.
  Future<String> saveSite(
    String workspaceId, {
    String? id,
    required String name,
    double? lat,
    double? lng,
    int radiusM = 150,
  });
  Future<void> deleteSite(String workspaceId, String id);

  // Attendance for managers

  /// Everyone the signed-in manager looks after, on [day] (today when
  /// null), optionally only [projectId]'s people.
  Future<TeamBoard> teamAttendance(
    String workspaceId, {
    DateTime? day,
    String? projectId,
  });
  Future<PersonDay> personDay(String personId, DateTime day);

  /// Every day from [from] to [to] for the people the signed-in manager
  /// looks after, optionally only [projectId]'s people or [personIds].
  Future<AttendanceReport> attendanceReport(
    String workspaceId, {
    required DateTime from,
    required DateTime to,
    String? projectId,
    List<String>? personIds,
  });
  Future<void> reviewAttendance(String recordId, {required bool accept});

  /// Adds a worker without the app when [id] is null. Returns their id.
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
  });
  Future<void> removeWorker(String personId);

  /// The branch and shift of someone with the app (null = the default).
  Future<void> assignAttendance(
    String personId, {
    String? siteId,
    String? shiftId,
  });

  /// Checks people in (or out) at their own times. [at] is the manager's
  /// place; [photo] an optional group photo.
  Future<RollCallResult> rollCall(
    String workspaceId, {
    required bool checkIn,
    required Map<String, DateTime> times,
    LocationFix? at,
    Upload? photo,
  });
  Future<void> setAttendanceTimes(
    String recordId, {
    required DateTime inAt,
    DateTime? outAt,
    String? note,
  });
  Future<void> deleteAttendanceRecord(String recordId, {String? note});

  /// The signed-in user asks to correct [day].
  Future<void> requestAttendanceFix(
    String workspaceId,
    DateTime day, {
    DateTime? inAt,
    DateTime? outAt,
    required String note,
  });
  Future<void> cancelAttendanceFix(String fixId);
  Future<void> decideAttendanceFix(
    String fixId, {
    required bool accept,
    String? note,
  });
  Future<List<AttendanceFix>> myAttendanceFixes(
    String workspaceId,
    DateTime from,
    DateTime to,
  );
  Future<AttendanceRequests> attendanceRequests(String workspaceId);
}

class SupabaseWaslaApi implements WaslaApi {
  SupabaseWaslaApi(this._client);

  final SupabaseClient _client;

  String get _me => _client.auth.currentUser!.id;

  List<Json> _rows(Object? data) =>
      (data as List).map((e) => Json.from(e as Map)).toList();

  @override
  Stream<String?> userIdChanges() async* {
    yield _client.auth.currentUser?.id;
    // A failed background token refresh (e.g. offline) arrives as an error;
    // it is not a sign-out, so it must not knock the app into an error state.
    yield* _client.auth.onAuthStateChange
        .handleError((Object _) {})
        .map((e) => e.session?.user.id);
  }

  @override
  Future<void> sendEmailCode(String email) =>
      _client.auth.signInWithOtp(email: email, shouldCreateUser: true);

  @override
  Future<void> verifyEmailCode(String email, String code) async {
    await _client.auth.verifyOTP(
      email: email,
      token: code,
      type: OtpType.email,
    );
  }

  @override
  Future<void> signOut() async {
    try {
      await _client.auth.signOut();
    } catch (_) {
      // The session is already cleared on this phone; only telling the server
      // failed (usually offline).
    }
  }

  @override
  Future<Profile> myProfile() async {
    final row = await _client
        .from('profiles')
        .select('id, full_name, email, phone')
        .eq('id', _me)
        .single();
    return Profile.fromJson(row);
  }

  @override
  Future<void> updateProfile({
    String? fullName,
    String? locale,
    String? theme,
  }) async {
    final changes = {
      'full_name': ?fullName,
      'locale': ?locale,
      'theme': ?theme,
    };
    if (changes.isEmpty) return;
    await _client.from('profiles').update(changes).eq('id', _me);
  }

  @override
  Future<List<Membership>> myWorkspaces() async {
    final me = _me;
    final data = await _client
        .from('workspace_members')
        .select(
          'role, workspaces(id, name, company_id, discoverable, allow_sharing, '
          'plans(name, max_members), companies(name, owner_id))',
        )
        .eq('user_id', me)
        .eq('status', 'active');
    final list = _rows(data)
        .where((row) => row['workspaces'] != null)
        .map((row) => Membership.fromJson(row, me: me))
        .toList();
    list.sort((a, b) => a.workspaceName.compareTo(b.workspaceName));
    return list;
  }

  @override
  Future<List<MyInvite>> myInvites() async =>
      _rows(await _client.rpc('my_invites')).map(MyInvite.fromJson).toList();

  @override
  Future<String> acceptInvite(String token) async =>
      await _client.rpc('accept_invite', params: {'p_token': token}) as String;

  @override
  Future<void> declineInvite(String token) =>
      _client.rpc('decline_invite', params: {'p_token': token});

  @override
  Future<String> createCompanyWorkspace({
    required String companyName,
    required String countryCode,
    required String workspaceName,
  }) async => await _client.rpc(
    'create_company_workspace',
    params: {
      'p_company_name': companyName,
      'p_country_code': countryCode,
      'p_workspace_name': workspaceName,
    },
  ) as String;

  @override
  Future<String> createWorkspace({
    required String companyId,
    required String name,
  }) async => await _client.rpc(
    'create_workspace',
    params: {'p_company_id': companyId, 'p_name': name},
  ) as String;

  @override
  Future<void> setDiscoverable(String workspaceId, bool discoverable) => _client
      .from('workspaces')
      .update({'discoverable': discoverable})
      .eq('id', workspaceId);

  @override
  Future<void> setAllowSharing(String workspaceId, bool allow) => _client
      .from('workspaces')
      .update({'allow_sharing': allow})
      .eq('id', workspaceId);

  @override
  Future<void> renameWorkspace(String workspaceId, String name) async {
    // An update RLS refuses changes nothing and says nothing, so ask for the
    // row back to tell.
    final rows = await _client
        .from('workspaces')
        .update({'name': name})
        .eq('id', workspaceId)
        .select('id');
    if (rows.isEmpty) {
      throw const PostgrestException(message: 'not_allowed', code: '42501');
    }
  }

  @override
  Future<void> leaveWorkspace(String workspaceId) =>
      _client.rpc('leave_workspace', params: {'p_workspace': workspaceId});

  @override
  Future<void> deleteWorkspace(String workspaceId, String confirmName) =>
      _client.rpc(
        'delete_workspace',
        params: {'p_workspace': workspaceId, 'p_confirm_name': confirmName},
      );

  @override
  Future<List<DeletedWorkspace>> deletedWorkspaces() async =>
      _rows(await _client.rpc('my_deleted_workspaces'))
          .map(DeletedWorkspace.fromJson)
          .toList();

  @override
  Future<void> restoreWorkspace(String workspaceId) =>
      _client.rpc('restore_workspace', params: {'p_workspace': workspaceId});

  @override
  Future<List<WorkspaceHit>> searchWorkspaces(String query) async =>
      _rows(await _client.rpc('search_workspaces', params: {'p_query': query}))
          .map(WorkspaceHit.fromJson)
          .toList();

  @override
  Future<void> requestToJoin(String workspaceId, {String? message}) =>
      _client.rpc(
        'request_to_join',
        params: {'p_workspace_id': workspaceId, 'p_message': message},
      );

  @override
  Future<List<MyJoinRequest>> myJoinRequests() async =>
      _rows(await _client.rpc('my_join_requests'))
          .map(MyJoinRequest.fromJson)
          .toList();

  @override
  Future<void> cancelJoinRequest(String requestId) =>
      _client.rpc('cancel_join_request', params: {'p_request_id': requestId});

  @override
  Future<List<Member>> members(String workspaceId) async {
    final data = await _client
        .from('workspace_members')
        .select('user_id, role, profiles(full_name, email, phone)')
        .eq('workspace_id', workspaceId)
        .eq('status', 'active');
    final list = _rows(data).map(Member.fromJson).toList();
    list.sort((a, b) {
      final byRole = a.role.index.compareTo(b.role.index);
      return byRole != 0 ? byRole : a.fullName.compareTo(b.fullName);
    });
    return list;
  }

  @override
  Future<void> setMemberRole(
    String workspaceId,
    String userId,
    WorkspaceRole role,
  ) => _client
      .from('workspace_members')
      .update({'role': role.name})
      .eq('workspace_id', workspaceId)
      .eq('user_id', userId);

  @override
  Future<void> removeMember(String workspaceId, String userId) => _client
      .from('workspace_members')
      .update({'status': 'inactive'})
      .eq('workspace_id', workspaceId)
      .eq('user_id', userId);

  @override
  Future<void> invite(
    String workspaceId, {
    required String email,
    required WorkspaceRole role,
    List<String> projectIds = const [],
  }) => _client.from('invites').insert({
    'workspace_id': workspaceId,
    'email': email,
    'role': role.name,
    'project_ids': projectIds,
    'invited_by': _me,
  });

  @override
  Future<List<SentInvite>> sentInvites(String workspaceId) async {
    final data = await _client
        .from('invites')
        .select('id, email, phone, role, expires_at')
        .eq('workspace_id', workspaceId)
        .eq('status', 'pending')
        .gt('expires_at', DateTime.now().toUtc().toIso8601String())
        .order('created_at', ascending: false);
    return _rows(data).map(SentInvite.fromJson).toList();
  }

  @override
  Future<void> cancelInvite(String inviteId) => _client
      .from('invites')
      .update({'status': 'cancelled'})
      .eq('id', inviteId);

  @override
  Future<List<JoinRequest>> joinRequests(String workspaceId) async {
    final data = await _client
        .from('join_requests')
        .select(
          'id, user_id, message, created_at, '
          'profiles!join_requests_user_id_fkey(full_name, email, phone)',
        )
        .eq('workspace_id', workspaceId)
        .eq('status', 'pending')
        .order('created_at');
    return _rows(data).map(JoinRequest.fromJson).toList();
  }

  @override
  Future<void> decideJoinRequest(String requestId, {required bool accept}) =>
      _client.rpc(
        'decide_join_request',
        params: {'p_request_id': requestId, 'p_accept': accept},
      );

  @override
  Future<JoinCode?> joinCode(String workspaceId) async {
    final rows = _rows(
      await _client.rpc('join_code', params: {'p_workspace': workspaceId}),
    );
    return rows.isEmpty ? null : JoinCode.fromJson(rows.first);
  }

  @override
  Future<JoinCode?> setJoinCode(
    String workspaceId, {
    required bool enabled,
    bool autoJoin = false,
    bool renew = false,
  }) async {
    final rows = _rows(
      await _client.rpc(
        'set_join_code',
        params: {
          'p_workspace': workspaceId,
          'p_enabled': enabled,
          'p_auto': autoJoin,
          'p_renew': renew,
        },
      ),
    );
    return rows.isEmpty ? null : JoinCode.fromJson(rows.first);
  }

  @override
  Future<List<WorkspaceOverview>> managementOverview() async => [
    for (final w in await _client.rpc('management_overview') as List? ?? [])
      WorkspaceOverview.fromJson(Json.from(w as Map)),
  ];

  @override
  Future<CodeWorkspace?> workspaceByCode(String code) async {
    final rows = _rows(
      await _client.rpc('workspace_by_code', params: {'p_code': code}),
    );
    return rows.isEmpty ? null : CodeWorkspace.fromJson(rows.first);
  }

  @override
  Future<bool> joinWithCode(String code, {String? message}) async =>
      await _client.rpc(
        'join_with_code',
        params: {'p_code': code, 'p_message': message},
      ) ==
      'joined';

  @override
  Future<List<Project>> projects(String workspaceId) async {
    final data = await _client
        .from('projects')
        .select(
          'id, workspace_id, name, color, status, department_id, '
          'project_members(count)',
        )
        .eq('workspace_id', workspaceId)
        .order('created_at');
    return _rows(data).map(Project.fromJson).toList();
  }

  @override
  Future<Map<String, ProjectProgress>> projectProgress(
    String workspaceId,
  ) async {
    final data = await _client.rpc(
      'project_task_counts',
      params: {'p_workspace': workspaceId},
    );
    return {
      for (final row in _rows(data))
        row['project_id'] as String: ProjectProgress.fromJson(row),
    };
  }

  @override
  Future<String> createProject(
    String workspaceId, {
    required String name,
    required String color,
  }) async {
    final row = await _client
        .from('projects')
        .insert({
          'workspace_id': workspaceId,
          'name': name,
          'color': color,
          'created_by': _me,
        })
        .select('id')
        .single();
    return row['id'] as String;
  }

  @override
  Future<void> setProjectStatus(String projectId, ProjectStatus status) =>
      _client
          .from('projects')
          .update({'status': status.name})
          .eq('id', projectId);

  @override
  Future<List<ProjectMember>> projectMembers(String projectId) async {
    final data = await _client
        .from('project_members')
        .select('user_id, role, profiles(full_name, email)')
        .eq('project_id', projectId);
    final list = _rows(data).map(ProjectMember.fromJson).toList();
    list.sort((a, b) {
      final byRole = a.role.index.compareTo(b.role.index);
      return byRole != 0 ? byRole : a.fullName.compareTo(b.fullName);
    });
    return list;
  }

  @override
  Future<void> addProjectMember(String projectId, String userId) => _client
      .from('project_members')
      .insert({'project_id': projectId, 'user_id': userId});

  @override
  Future<void> removeProjectMember(String projectId, String userId) => _client
      .from('project_members')
      .delete()
      .eq('project_id', projectId)
      .eq('user_id', userId);

  @override
  Future<void> setProjectRole(
    String projectId,
    String userId,
    ProjectRole role,
  ) => _client
      .from('project_members')
      .update({'role': role.name})
      .eq('project_id', projectId)
      .eq('user_id', userId);

  // Chats

  static final _random = Random.secure();

  /// `workspace/me/random.ext`: the only place one may upload to.
  String _uploadPath(String workspaceId, String name) {
    final id = List.generate(
      16,
      (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final dot = name.lastIndexOf('.');
    final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    final safeExt = RegExp(r'^[a-z0-9]{1,10}$').hasMatch(ext) ? '.$ext' : '';
    return '$workspaceId/$_me/$id$safeExt';
  }

  Future<String> _upload(String workspaceId, Upload file) async {
    final path = _uploadPath(workspaceId, file.name);
    await _client.storage
        .from('files')
        .uploadBinary(
          path,
          file.bytes,
          fileOptions: FileOptions(contentType: file.mime),
        );
    return path;
  }

  /// Uploads [file], then records it with [record]. If recording fails the
  /// upload is removed again, so nothing is left behind.
  Future<void> _withUpload(
    String workspaceId,
    Upload file,
    Future<void> Function(String path) record,
  ) async {
    final path = await _upload(workspaceId, file);
    try {
      await record(path);
    } catch (_) {
      await _remove(path);
      rethrow;
    }
  }

  /// Best effort: the server only lets people remove their own unused files.
  Future<void> _remove(String? path) async {
    if (path == null) return;
    try {
      await _client.storage.from('files').remove([path]);
    } catch (_) {}
  }

  @override
  Future<List<Conversation>> conversations(String workspaceId) async => _rows(
    await _client.rpc('my_conversations', params: {'p_workspace': workspaceId}),
  ).map(Conversation.fromJson).toList();

  @override
  Future<void> muteConversation(String conversationId, {DateTime? until}) =>
      _client.rpc(
        'mute_conversation',
        params: {
          'p_conversation': conversationId,
          'p_until': until?.toUtc().toIso8601String(),
        },
      );

  @override
  Future<void> unmuteConversation(String conversationId) => _client.rpc(
    'unmute_conversation',
    params: {'p_conversation': conversationId},
  );

  @override
  Future<Map<String, DateTime?>> mutedConversations(String workspaceId) async {
    final rows = _rows(
      await _client.rpc(
        'my_muted_conversations',
        params: {'p_workspace': workspaceId},
      ),
    );
    return {
      for (final r in rows)
        r['conversation_id'] as String: r['until'] == null
            ? null
            : DateTime.parse(r['until'] as String),
    };
  }

  @override
  Future<QuietHours?> quietHours() async {
    final rows = _rows(await _client.rpc('my_notification_settings'));
    if (rows.isEmpty || rows.first['quiet_from'] == null) return null;
    return QuietHours(
      from: parseClock(rows.first['quiet_from']),
      to: parseClock(rows.first['quiet_to']),
      utcOffset: (rows.first['utc_offset'] as num).toInt(),
    );
  }

  @override
  Future<List<Department>> departments(String workspaceId) async => _rows(
    await _client.rpc(
      'workspace_departments',
      params: {'p_workspace': workspaceId},
    ),
  ).map(Department.fromJson).toList();

  @override
  Future<Map<String, String>> myDepartments(String workspaceId) async => {
    for (final r in _rows(
      await _client.rpc('my_departments', params: {'p_workspace': workspaceId}),
    ))
      r['id'] as String: r['name'] as String? ?? '',
  };

  @override
  Future<void> saveDepartment(
    String workspaceId, {
    String? departmentId,
    required String name,
    required List<String> managerIds,
    required List<String> projectIds,
  }) => _client.rpc(
    'save_department',
    params: {
      'p_workspace': workspaceId,
      'p_department': departmentId,
      'p_name': name,
      'p_managers': managerIds,
      'p_projects': projectIds,
    },
  );

  @override
  Future<void> deleteDepartment(String departmentId) =>
      _client.rpc('delete_department', params: {'p_department': departmentId});

  @override
  Future<Map<String, UserStatus>> workspaceStatuses(String workspaceId) async {
    final rows = _rows(
      await _client.rpc(
        'workspace_statuses',
        params: {'p_workspace': workspaceId},
      ),
    );
    return {
      for (final r in rows)
        if (StatusKind.parse(r['kind'] as String?) case final kind?)
          r['user_id'] as String: UserStatus(
            kind: kind,
            note: r['note'] as String?,
            until: r['until'] == null
                ? null
                : DateTime.parse(r['until'] as String),
          ),
    };
  }

  @override
  Future<void> setMyStatus(UserStatus? status) => _client.rpc(
    'set_my_status',
    params: {
      'p_kind': status?.kind.wire,
      'p_note': status?.note,
      'p_until': status?.until?.toUtc().toIso8601String(),
    },
  );

  @override
  Future<SetupProgress?> workspaceSetup(String workspaceId) async {
    final rows = _rows(
      await _client.rpc(
        'workspace_setup',
        params: {'p_workspace': workspaceId},
      ),
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    return SetupProgress(
      project: r['has_project'] == true,
      team: r['has_team'] == true,
      attendance: r['attendance_on'] == true,
      announcement: r['has_announcement'] == true,
    );
  }

  @override
  Future<bool> weeklyReport() async =>
      await _client.rpc('my_weekly_report') as bool? ?? true;

  @override
  Future<void> setWeeklyReport(bool on) =>
      _client.rpc('set_weekly_report', params: {'p_on': on});

  @override
  Future<void> setQuietHours(TimeOfDay? from, TimeOfDay? to, int utcOffset) =>
      _client.rpc(
        'set_quiet_hours',
        params: {
          'p_from': from == null ? null : clockParam(from),
          'p_to': to == null ? null : clockParam(to),
          'p_utc_offset': utcOffset,
        },
      );

  @override
  Future<String> openDirect(String workspaceId, String userId) async =>
      await _client.rpc(
        'open_direct',
        params: {'p_workspace': workspaceId, 'p_other': userId},
      ) as String;

  @override
  Future<String?> projectConversation(String projectId) async =>
      await _client.rpc(
        'project_conversation',
        params: {'p_project': projectId},
      ) as String?;

  @override
  Future<List<ChatMessage>> messages(
    String conversationId, {
    DateTime? before,
    DateTime? after,
    String? projectId,
    int limit = 50,
  }) async => _rows(
    await _client.rpc(
      'conversation_messages',
      params: {
        'p_conversation': conversationId,
        'p_before': before?.toUtc().toIso8601String(),
        'p_after': after?.toUtc().toIso8601String(),
        'p_project': projectId,
        'p_limit': limit,
      },
    ),
  ).map(ChatMessage.fromJson).toList();

  @override
  Future<void> createPoll(
    String conversationId, {
    required String question,
    required List<String> options,
    bool multiple = false,
    String? projectId,
  }) => _client.rpc(
    'create_poll',
    params: {
      'p_conversation': conversationId,
      'p_question': question,
      'p_options': options,
      'p_multiple': multiple,
      'p_project': projectId,
    },
  );

  @override
  Future<void> votePoll(String messageId, Set<int> options) => _client.rpc(
    'vote_poll',
    params: {'p_message': messageId, 'p_options': options.toList()},
  );

  @override
  Future<void> closePoll(String messageId) =>
      _client.rpc('close_poll', params: {'p_message': messageId});

  @override
  Future<void> pinMessage(String messageId, {bool pin = true}) => _client.rpc(
    'pin_message',
    params: {'p_message': messageId, 'p_pin': pin},
  );

  @override
  Future<ChatPin> chatPin(String conversationId) async {
    final rows = _rows(
      await _client.rpc(
        'conversation_pin',
        params: {'p_conversation': conversationId},
      ),
    );
    if (rows.isEmpty) return const ChatPin();
    final r = rows.first;
    return ChatPin(
      canPin: r['can_pin'] == true,
      message: r['message_id'] == null
          ? null
          : PinnedMessage(
              messageId: r['message_id'] as String,
              senderName: r['sender_name'] as String? ?? '',
              body: r['body'] as String?,
              fileName: r['file_name'] as String?,
            ),
    );
  }

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
    Future<void> send(String? path) => _client.rpc(
      'send_message',
      params: {
        'p_conversation': conversationId,
        'p_body': body,
        'p_reply_to': replyTo,
        'p_project': projectId,
        'p_file_path': path,
        'p_file_name': file?.name,
        'p_file_mime': file?.mime,
        'p_file_size': file?.bytes.length,
        if (mentions.isNotEmpty) 'p_mentions': mentions,
      },
    );
    if (file == null) {
      await send(null);
    } else {
      await _withUpload(workspaceId, file, send);
    }
  }

  @override
  Future<void> markRead(String conversationId, DateTime until) => _client.rpc(
    'mark_read',
    params: {
      'p_conversation': conversationId,
      'p_until': until.toUtc().toIso8601String(),
    },
  );

  @override
  Future<void> toggleReaction(String messageId, String emoji) => _client.rpc(
    'toggle_reaction',
    params: {'p_message': messageId, 'p_emoji': emoji},
  );

  @override
  Future<List<ChatMessage>> replyChain(String messageId) async =>
      _rows(await _client.rpc('reply_chain', params: {'p_message': messageId}))
          .map(ChatMessage.fromJson)
          .toList();

  @override
  Future<Set<DateTime>> messageDays(
    String conversationId, {
    String? projectId,
  }) async {
    final days =
        (await _client.rpc(
          'conversation_days',
          params: {
            'p_conversation': conversationId,
            'p_project': projectId,
            'p_utc_offset': DateTime.now().timeZoneOffset.inMinutes,
          },
        ) as List?) ??
        const [];
    return {
      for (final d in days)
        if (d is String) DateTime.parse(d),
    };
  }

  @override
  Future<void> deleteMessage(String messageId, {String? filePath}) async {
    await _client.rpc('delete_message', params: {'p_message': messageId});
    await _remove(filePath);
  }

  @override
  Future<List<ReadState>> readStates(String conversationId) async => _rows(
    await _client
        .from('conversation_reads')
        .select('user_id, last_read_at')
        .eq('conversation_id', conversationId),
  ).map(ReadState.fromJson).toList();

  @override
  Future<List<MessageHit>> searchMessages(
    String workspaceId,
    String query,
  ) async => _rows(
    await _client.rpc(
      'search_messages',
      params: {'p_workspace': workspaceId, 'p_query': query},
    ),
  ).map(MessageHit.fromJson).toList();

  @override
  Future<WorkspaceSearch> searchWorkspace(
    String workspaceId,
    String query,
  ) async {
    final result = await _client.rpc(
      'search_workspace',
      params: {'p_workspace': workspaceId, 'p_query': query},
    );
    return result is Map
        ? WorkspaceSearch.fromJson(Map<String, dynamic>.from(result))
        : const WorkspaceSearch();
  }

  @override
  Future<List<String>> sharedProjects(String conversationId) async =>
      ((await _client.rpc(
                'shared_projects',
                params: {'p_conversation': conversationId},
              ) as List?) ??
              const [])
          .cast<String>();

  @override
  Future<List<String>> projectsWith(String workspaceId, String userId) async =>
      ((await _client.rpc(
                'projects_with',
                params: {'p_workspace': workspaceId, 'p_user': userId},
              ) as List?) ??
              const [])
          .cast<String>();

  @override
  Stream<ChatEvent> chatEvents(String workspaceId) => _follow(
    name: 'chats:$workspaceId',
    tables: const ['messages', 'conversation_reads'],
    filter: PostgresChangeFilter(
      type: PostgresChangeFilterType.eq,
      column: 'workspace_id',
      value: workspaceId,
    ),
    event: (row) {
      final id = row['conversation_id'];
      if (id is! String) return null;
      final reader = row['user_id'];
      return ChatEvent(
        conversationId: id,
        readerId: reader is String ? reader : null,
      );
    },
    everything: const ChatEvent.everything(),
  );

  /// New and changed rows of [tables] that match [filter], as events. Rows
  /// are never hard-deleted, and delete events are not filtered anyway.
  /// Changes made while the connection was down are not replayed, so
  /// [everything] is sent after reconnecting and when the app comes back.
  Stream<T> _follow<T>({
    required String name,
    required List<String> tables,
    required PostgresChangeFilter filter,
    required T? Function(Json row) event,
    required T everything,
  }) {
    late final RealtimeChannel channel;
    late final StreamController<T> controller;
    AppLifecycleListener? lifecycle;
    var joined = false;

    void forward(PostgresChangePayload payload) {
      final e = event(payload.newRecord);
      if (e != null) controller.add(e);
    }

    controller = StreamController<T>(
      onListen: () {
        channel = _client.channel('$name:${_random.nextInt(1 << 30)}');
        for (final table in tables) {
          for (final change in [
            PostgresChangeEvent.insert,
            PostgresChangeEvent.update,
          ]) {
            channel.onPostgresChanges(
              event: change,
              schema: 'public',
              table: table,
              filter: filter,
              callback: forward,
            );
          }
        }
        channel.subscribe((status, _) {
          if (status != RealtimeSubscribeStatus.subscribed) return;
          if (joined) controller.add(everything);
          joined = true;
        });
        lifecycle = AppLifecycleListener(
          onResume: () => controller.add(everything),
        );
      },
      onCancel: () async {
        lifecycle?.dispose();
        await _client.removeChannel(channel);
      },
    );
    return controller.stream;
  }

  // Files

  @override
  Future<List<ProjectFile>> projectFiles(String projectId) async => _rows(
    await _client.rpc('project_files', params: {'p_project': projectId}),
  ).map(ProjectFile.fromJson).toList();

  @override
  Future<void> addProjectFile(
    String workspaceId,
    String projectId,
    Upload file,
  ) => _withUpload(
    workspaceId,
    file,
    (path) => _client.rpc(
      'add_project_file',
      params: {
        'p_project': projectId,
        'p_path': path,
        'p_name': file.name,
        'p_mime': file.mime,
        'p_size': file.bytes.length,
      },
    ),
  );

  @override
  Future<void> setFilePinned(String fileId, bool pinned) => _client.rpc(
    'set_file_pinned',
    params: {'p_file': fileId, 'p_pinned': pinned},
  );

  @override
  Future<void> deleteFile(String fileId, {String? filePath}) async {
    await _client.rpc('delete_file', params: {'p_file': fileId});
    await _remove(filePath);
  }

  @override
  Future<String> fileUrl(String path) =>
      _client.storage.from('files').createSignedUrl(path, 3600);

  @override
  Future<Uint8List> fileBytes(String path) =>
      _client.storage.from('files').download(path);

  // Announcements

  @override
  Future<List<Announcement>> announcements(
    String workspaceId, {
    String? projectId,
  }) async => _rows(
    await _client.rpc(
      'announcements_for',
      params: {'p_workspace': workspaceId, 'p_project': projectId},
    ),
  ).map(Announcement.fromJson).toList();

  @override
  Future<List<UnreadAnnouncement>> unreadAnnouncements(
    String workspaceId,
  ) async => _rows(
    await _client.rpc(
      'unread_announcements',
      params: {'p_workspace': workspaceId},
    ),
  ).map(UnreadAnnouncement.fromJson).toList();

  @override
  Future<void> postBroadcast(
    List<String> workspaceIds, {
    required String body,
    bool pinned = false,
    bool needsAck = false,
  }) => _client.rpc(
    'post_broadcast',
    params: {
      'p_workspaces': workspaceIds,
      'p_body': body,
      'p_pinned': pinned,
      'p_needs_ack': needsAck,
    },
  );

  @override
  Future<List<BroadcastReach>> broadcastReach(String broadcastId) async =>
      _rows(
        await _client.rpc(
          'broadcast_reach',
          params: {'p_broadcast': broadcastId},
        ),
      ).map(BroadcastReach.fromJson).toList();

  @override
  Future<void> postAnnouncement(
    String workspaceId, {
    String? projectId,
    required String body,
    bool pinned = false,
    bool needsAck = false,
  }) => _client.rpc(
    'post_announcement',
    params: {
      'p_workspace': workspaceId,
      'p_project': projectId,
      'p_body': body,
      'p_pinned': pinned,
      'p_needs_ack': needsAck,
    },
  );

  @override
  Future<void> acknowledgeAnnouncement(String id) =>
      _client.rpc('acknowledge_announcement', params: {'p_id': id});

  @override
  Future<List<AnnouncementReader>> announcementReaders(String id) async =>
      _rows(await _client.rpc('announcement_readers', params: {'p_id': id}))
          .map(AnnouncementReader.fromJson)
          .toList();

  @override
  Future<void> markAnnouncementsRead(List<String> ids) async {
    if (ids.isEmpty) return;
    await _client.rpc('mark_announcements_read', params: {'p_ids': ids});
  }

  @override
  Future<void> setAnnouncementPinned(String id, bool pinned) => _client.rpc(
    'set_announcement_pinned',
    params: {'p_id': id, 'p_pinned': pinned},
  );

  @override
  Future<void> deleteAnnouncement(String id) =>
      _client.rpc('delete_announcement', params: {'p_id': id});

  // Tasks

  List<TaskItem> _tasks(Object? data) =>
      _rows(data).map(TaskItem.fromJson).toList();

  @override
  Future<List<TaskItem>> myTasks() async =>
      _tasks(await _client.rpc('my_tasks'));

  @override
  Future<List<TaskItem>> projectTasks(String projectId) async => _tasks(
    await _client.rpc('project_tasks', params: {'p_project': projectId}),
  );

  @override
  Future<List<TaskItem>> managedTasks(String workspaceId) async => _tasks(
    await _client.rpc('managed_tasks', params: {'p_workspace': workspaceId}),
  );

  @override
  Future<TaskDetail> task(String taskId) async => TaskDetail.fromJson(
    Json.from(
      await _client.rpc('task_detail', params: {'p_task': taskId}) as Map,
    ),
  );

  @override
  Future<String> createTask(TaskDraft draft) async => await _client.rpc(
    'create_task',
    params: {
      'p_project': draft.projectId,
      'p_title': draft.title,
      'p_description': draft.description,
      'p_assignees': draft.assigneeIds,
      'p_due_at': draft.dueAt?.toUtc().toIso8601String(),
      'p_priority': draft.priority.name,
      'p_visibility': draft.visibility.name,
      'p_remind_before': draft.remindBefore,
      'p_source_message': draft.sourceMessageId,
    },
  ) as String;

  @override
  Future<void> updateTask(String taskId, TaskDraft draft) => _client.rpc(
    'update_task',
    params: {
      'p_task': taskId,
      'p_title': draft.title,
      'p_description': draft.description,
      'p_due_at': draft.dueAt?.toUtc().toIso8601String(),
      'p_priority': draft.priority.name,
      'p_visibility': draft.visibility.name,
      'p_remind_before': draft.remindBefore,
    },
  );

  @override
  Future<void> setTaskRepeat(String taskId, TaskRepeat? repeat) => _client.rpc(
    'set_task_repeat',
    params: {'p_task': taskId, 'p_repeat': repeat?.name},
  );

  @override
  Future<List<TaskTemplate>> taskTemplates(String workspaceId) async => _rows(
    await _client.rpc('task_templates', params: {'p_workspace': workspaceId}),
  ).map(TaskTemplate.fromJson).toList();

  @override
  Future<void> saveTaskTemplate(
    String workspaceId,
    String name,
    List<TemplateItem> items,
  ) => _client.rpc(
    'save_task_template',
    params: {
      'p_workspace': workspaceId,
      'p_name': name,
      'p_items': [for (final i in items) i.toJson()],
    },
  );

  @override
  Future<void> deleteTaskTemplate(String templateId) =>
      _client.rpc('delete_task_template', params: {'p_template': templateId});

  @override
  Future<int> applyTaskTemplate(
    String templateId,
    String projectId, {
    List<String>? assigneeIds,
    required DateTime start,
  }) async => (await _client.rpc(
    'apply_task_template',
    params: {
      'p_template': templateId,
      'p_project': projectId,
      'p_assignees': assigneeIds,
      'p_start': start.toUtc().toIso8601String(),
    },
  ) as num).toInt();

  @override
  Future<void> setTaskAssignees(String taskId, List<String> userIds) =>
      _client.rpc(
        'set_task_assignees',
        params: {'p_task': taskId, 'p_users': userIds},
      );

  @override
  Future<void> setTaskStatus(
    String taskId,
    TaskStatus status, {
    String? reason,
  }) => _client.rpc(
    'set_task_status',
    params: {'p_task': taskId, 'p_status': status.wire, 'p_reason': reason},
  );

  @override
  Future<void> addTaskComment(String taskId, String body) => _client.rpc(
    'add_task_comment',
    params: {'p_task': taskId, 'p_body': body},
  );

  @override
  Future<void> addTaskAttachment(
    String workspaceId,
    String taskId,
    Upload file,
  ) => _withUpload(
    workspaceId,
    file,
    (path) => _client.rpc(
      'add_task_attachment',
      params: {
        'p_task': taskId,
        'p_path': path,
        'p_name': file.name,
        'p_mime': file.mime,
        'p_size': file.bytes.length,
      },
    ),
  );

  @override
  Future<void> nudgeTask(String taskId) =>
      _client.rpc('nudge_task', params: {'p_task': taskId});

  @override
  Future<void> addTaskReminder(String taskId, DateTime at) => _client.rpc(
    'add_task_reminder',
    params: {'p_task': taskId, 'p_at': at.toUtc().toIso8601String()},
  );

  @override
  Future<void> deleteTaskReminder(String reminderId) =>
      _client.rpc('delete_task_reminder', params: {'p_reminder': reminderId});

  @override
  Future<void> deleteTask(String taskId) =>
      _client.rpc('delete_task', params: {'p_task': taskId});

  @override
  Stream<void> taskEvents(String workspaceId) => _follow<bool>(
    name: 'tasks:$workspaceId',
    tables: const ['tasks'],
    filter: PostgresChangeFilter(
      type: PostgresChangeFilterType.eq,
      column: 'workspace_id',
      value: workspaceId,
    ),
    event: (_) => true,
    everything: true,
  );

  // Notifications

  @override
  Future<List<AppNotification>> notifications() async => [
    for (final row in _rows(await _client.rpc('my_notifications')))
      ?AppNotification.fromJson(row),
  ];

  @override
  Future<void> markNotificationsRead([List<String>? ids]) async {
    if (ids != null && ids.isEmpty) return;
    await _client.rpc('mark_notifications_read', params: {'p_ids': ids});
  }

  @override
  Future<void> registerPushToken(
    String token,
    String platform,
    String locale,
  ) => _client.rpc(
    'register_push_token',
    params: {'p_token': token, 'p_platform': platform, 'p_locale': locale},
  );

  @override
  Future<void> unregisterPushToken(String token) =>
      _client.rpc('unregister_push_token', params: {'p_token': token});

  @override
  Future<String?> webPushKey() async =>
      await _client.rpc('web_push_key') as String?;

  @override
  Stream<void> notificationEvents() => _follow<bool>(
    name: 'notifications:$_me',
    tables: const ['notifications'],
    filter: PostgresChangeFilter(
      type: PostgresChangeFilterType.eq,
      column: 'user_id',
      value: _me,
    ),
    event: (_) => true,
    everything: true,
  );

  // Subscriptions

  Json _object(Object? data) => Json.from(data as Map);

  @override
  Future<String?> logoUrl() async {
    final data = _object(await _client.rpc('public_branding'));
    final path = data['logo_path'] as String?;
    if (path == null) return null;
    return _client.storage.from('branding').getPublicUrl(path);
  }

  @override
  Future<void> setLogo(Upload? file) async {
    String? path;
    if (file != null) {
      final ext = logoExtension(file.mime);
      if (ext == null) throw const UnsupportedLogo();
      if (file.bytes.length > maxLogoBytes) throw const FileTooLarge();
      final id = List.generate(
        16,
        (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      path = 'logo/$id.$ext';
      await _client.storage
          .from('branding')
          .uploadBinary(
            path,
            file.bytes,
            fileOptions: FileOptions(contentType: file.mime),
          );
    }
    final String? old;
    try {
      old = await _client.rpc('set_logo', params: {'p_path': path}) as String?;
    } catch (_) {
      if (path != null) {
        await _client.storage
            .from('branding')
            .remove([path])
            .catchError((_) => <FileObject>[]);
      }
      rethrow;
    }
    if (old != null) {
      try {
        await _client.storage.from('branding').remove([old]);
      } catch (_) {}
    }
  }

  @override
  Future<bool> isPlatformAdmin() async =>
      await _client.rpc('is_platform_admin') as bool? ?? false;

  @override
  Future<BillingOverview> billing(String companyId) async =>
      BillingOverview.fromJson(
        _object(
          await _client.rpc(
            'billing_overview',
            params: {'p_company': companyId},
          ),
        ),
      );

  @override
  Future<void> requestPlan(
    String workspaceId,
    String planId, {
    required int months,
    String? note,
  }) => _client.rpc(
    'request_plan',
    params: {
      'p_workspace': workspaceId,
      'p_plan': planId,
      'p_months': months,
      'p_note': note,
    },
  );

  @override
  Future<void> cancelPlanRequest(String requestId) =>
      _client.rpc('cancel_plan_request', params: {'p_request': requestId});

  @override
  Future<AdminOverview> adminOverview() async =>
      AdminOverview.fromJson(_object(await _client.rpc('admin_overview')));

  @override
  Future<List<AdminCompany>> adminCompanies({String? search}) async =>
      _rows(await _client.rpc('admin_companies', params: {'p_search': search}))
          .map(AdminCompany.fromJson)
          .toList();

  @override
  Future<List<AdminRequest>> adminRequests() async =>
      _rows(await _client.rpc('admin_requests'))
          .map(AdminRequest.fromJson)
          .toList();

  @override
  Future<List<Invoice>> adminInvoices({InvoiceStatus? status}) async => _rows(
    await _client.rpc('admin_invoices', params: {'p_status': status?.wire}),
  ).map(Invoice.fromJson).toList();

  @override
  Future<List<PlanOption>> adminPlans() async =>
      _rows(await _client.rpc('admin_plans')).map(PlanOption.fromJson).toList();

  @override
  Future<List<CountryRate>> adminRates() async =>
      _rows(await _client.rpc('admin_rates'))
          .map(CountryRate.fromJson)
          .toList();

  @override
  Future<PaymentInfo> adminPaymentInfo() async => PaymentInfo.fromJson(
    _object(await _client.rpc('admin_billing_settings')),
  );

  @override
  Future<void> adminSetRate(String countryCode, double rate) => _client.rpc(
    'admin_set_rate',
    params: {'p_country': countryCode, 'p_rate': rate},
  );

  @override
  Future<void> adminUpdatePlan(PlanOption plan) => _client.rpc(
    'admin_update_plan',
    params: {
      'p_plan': plan.id,
      'p_name': plan.name,
      'p_max_members': plan.maxMembers,
      'p_storage_gb': plan.storageGb,
      'p_price': plan.priceUsd,
      'p_offered': plan.offered,
    },
  );

  @override
  Future<void> adminSetPlanWorkers(
    String planId, {
    int? freeWorkers,
    double extraUsd = 0,
  }) => _client.rpc(
    'admin_set_plan_workers',
    params: {'p_plan': planId, 'p_free': freeWorkers, 'p_extra_usd': extraUsd},
  );

  @override
  Future<void> adminUpdatePaymentInfo(PaymentInfo info) => _client.rpc(
    'admin_update_billing_settings',
    params: {
      'p_instructions': info.instructions,
      'p_phone': info.phone,
      'p_email': info.email,
    },
  );

  @override
  Future<String> adminCreateInvoice(
    String companyId,
    List<InvoiceItem> items, {
    required int months,
    double discountPct = 0,
    String? note,
    int dueDays = 14,
  }) async => await _client.rpc(
    'admin_create_invoice',
    params: {
      'p_company': companyId,
      'p_items': [for (final i in items) i.toJson()],
      'p_months': months,
      'p_discount': discountPct,
      'p_note': note,
      'p_due_days': dueDays,
    },
  ) as String;

  @override
  Future<void> adminMarkInvoicePaid(String invoiceId, {String? reference}) =>
      _client.rpc(
        'admin_mark_invoice_paid',
        params: {'p_invoice': invoiceId, 'p_reference': reference},
      );

  @override
  Future<void> adminVoidInvoice(String invoiceId) =>
      _client.rpc('admin_void_invoice', params: {'p_invoice': invoiceId});

  @override
  Future<void> adminSetWorkspacePlan(
    String workspaceId,
    String planId, {
    DateTime? until,
  }) => _client.rpc(
    'admin_set_workspace_plan',
    params: {
      'p_workspace': workspaceId,
      'p_plan': planId,
      'p_until': until?.toUtc().toIso8601String(),
    },
  );

  // Attendance

  static String _date(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  @override
  Future<AttendanceToday> attendanceToday(String workspaceId) async =>
      AttendanceToday.fromJson(
        Json.from(
          await _client.rpc(
            'attendance_today',
            params: {'p_workspace': workspaceId},
          ) as Map,
        ),
      );

  /// Uploads [photo] if given, then runs [call] with its path; the upload is
  /// removed again if the call fails.
  Future<AttendanceRecord> _withPhoto(
    String workspaceId,
    Upload? photo,
    Future<Object?> Function(String? path) call,
  ) async {
    final path = photo == null ? null : await _upload(workspaceId, photo);
    try {
      return AttendanceRecord.fromJson(Json.from(await call(path) as Map));
    } catch (_) {
      await _remove(path);
      rethrow;
    }
  }

  @override
  Future<AttendanceRecord> checkIn(
    String workspaceId,
    LocationFix at, {
    Upload? photo,
    OutsideReason? reason,
    String? note,
  }) => _withPhoto(
    workspaceId,
    photo,
    (path) => _client.rpc(
      'attendance_check_in',
      params: {
        'p_workspace': workspaceId,
        'p_lat': at.lat,
        'p_lng': at.lng,
        'p_accuracy': at.accuracyM,
        'p_photo': path,
        'p_reason_kind': reason?.name,
        'p_reason_note': note,
      },
    ),
  );

  @override
  Future<AttendanceRecord> checkOut(
    String workspaceId,
    LocationFix at, {
    Upload? photo,
  }) => _withPhoto(
    workspaceId,
    photo,
    (path) => _client.rpc(
      'attendance_check_out',
      params: {
        'p_workspace': workspaceId,
        'p_lat': at.lat,
        'p_lng': at.lng,
        'p_accuracy': at.accuracyM,
        'p_photo': path,
      },
    ),
  );

  @override
  Future<List<AttendanceRecord>> myAttendance(
    String workspaceId,
    DateTime from,
    DateTime to,
  ) async => _rows(
    await _client.rpc(
      'my_attendance',
      params: {
        'p_workspace': workspaceId,
        'p_from': _date(from),
        'p_to': _date(to),
      },
    ),
  ).map(AttendanceRecord.fromJson).toList();

  @override
  Future<void> enableAttendance(String workspaceId, String shiftName) =>
      _client.rpc(
        'enable_attendance',
        params: {'p_workspace': workspaceId, 'p_shift_name': shiftName},
      );

  @override
  Future<AttendanceSetup> attendanceSetup(String workspaceId) async =>
      AttendanceSetup.fromJson(
        Json.from(
          await _client.rpc(
            'attendance_setup',
            params: {'p_workspace': workspaceId},
          ) as Map,
        ),
      );

  @override
  Future<void> saveAttendanceSettings(
    String workspaceId,
    AttendanceSetup s,
  ) => _client.rpc(
    'save_attendance_settings',
    params: {
      'p_workspace': workspaceId,
      'p_enabled': s.enabled,
      'p_weekend_days': (s.weekendDays.toList()..sort()),
      'p_require_selfie': s.requireSelfie,
      'p_allow_outside': s.allowOutside,
      'p_reminders': s.reminders,
      'p_default_shift': s.defaultShiftId,
      'p_ramadan_from': s.ramadanFrom == null ? null : _date(s.ramadanFrom!),
      'p_ramadan_to': s.ramadanTo == null ? null : _date(s.ramadanTo!),
      'p_ramadan_start': s.ramadanStart == null
          ? null
          : clockParam(s.ramadanStart!),
      'p_ramadan_end': s.ramadanEnd == null ? null : clockParam(s.ramadanEnd!),
    },
  );

  @override
  Future<String> saveShift(
    String workspaceId, {
    String? id,
    required String name,
    required TimeOfDay start,
    required TimeOfDay end,
    required int graceMinutes,
  }) async => await _client.rpc(
    'save_attendance_shift',
    params: {
      'p_workspace': workspaceId,
      'p_id': id,
      'p_name': name,
      'p_start': clockParam(start),
      'p_end': clockParam(end),
      'p_grace': graceMinutes,
    },
  ) as String;

  @override
  Future<void> deleteShift(String workspaceId, String id) => _client.rpc(
    'delete_attendance_shift',
    params: {'p_workspace': workspaceId, 'p_id': id},
  );

  @override
  Future<String> saveSite(
    String workspaceId, {
    String? id,
    required String name,
    double? lat,
    double? lng,
    int radiusM = 150,
  }) async => await _client.rpc(
    'save_attendance_site',
    params: {
      'p_workspace': workspaceId,
      'p_id': id,
      'p_name': name,
      'p_lat': lat,
      'p_lng': lng,
      'p_radius': radiusM,
    },
  ) as String;

  @override
  Future<void> deleteSite(String workspaceId, String id) => _client.rpc(
    'delete_attendance_site',
    params: {'p_workspace': workspaceId, 'p_id': id},
  );

  @override
  Future<TeamBoard> teamAttendance(
    String workspaceId, {
    DateTime? day,
    String? projectId,
  }) async => TeamBoard.fromJson(
    Json.from(
      await _client.rpc(
        'attendance_board',
        params: {
          'p_workspace': workspaceId,
          'p_day': day == null ? null : _date(day),
          'p_project': projectId,
        },
      ) as Map,
    ),
  );

  @override
  Future<AttendanceReport> attendanceReport(
    String workspaceId, {
    required DateTime from,
    required DateTime to,
    String? projectId,
    List<String>? personIds,
  }) async => AttendanceReport.fromJson(
    Json.from(
      await _client.rpc(
        'attendance_report',
        params: {
          'p_workspace': workspaceId,
          'p_from': _date(from),
          'p_to': _date(to),
          'p_project': projectId,
          'p_people': personIds,
        },
      ) as Map,
    ),
  );

  @override
  Future<PersonDay> personDay(String personId, DateTime day) async =>
      PersonDay.fromJson(
        Json.from(
          await _client.rpc(
            'attendance_person_day',
            params: {'p_person': personId, 'p_day': _date(day)},
          ) as Map,
        ),
      );

  @override
  Future<void> reviewAttendance(String recordId, {required bool accept}) =>
      _client.rpc(
        'review_attendance',
        params: {'p_record': recordId, 'p_accept': accept},
      );

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
  }) async => await _client.rpc(
    'save_attendance_worker',
    params: {
      'p_workspace': workspaceId,
      'p_id': id,
      'p_name': name,
      'p_job': jobTitle,
      'p_phone': phone,
      'p_code': code,
      'p_project': projectId,
      'p_site': siteId,
      'p_shift': shiftId,
    },
  ) as String;

  @override
  Future<void> removeWorker(String personId) =>
      _client.rpc('remove_attendance_worker', params: {'p_person': personId});

  @override
  Future<void> assignAttendance(
    String personId, {
    String? siteId,
    String? shiftId,
  }) => _client.rpc(
    'assign_attendance',
    params: {'p_person': personId, 'p_site': siteId, 'p_shift': shiftId},
  );

  @override
  Future<RollCallResult> rollCall(
    String workspaceId, {
    required bool checkIn,
    required Map<String, DateTime> times,
    LocationFix? at,
    Upload? photo,
  }) async {
    final path = photo == null ? null : await _upload(workspaceId, photo);
    try {
      return RollCallResult.fromJson(
        Json.from(
          await _client.rpc(
            'attendance_roll_call',
            params: {
              'p_workspace': workspaceId,
              'p_kind': checkIn ? 'in' : 'out',
              'p_entries': [
                for (final e in times.entries)
                  {'person': e.key, 'at': e.value.toUtc().toIso8601String()},
              ],
              'p_lat': at?.lat,
              'p_lng': at?.lng,
              'p_accuracy': at?.accuracyM,
              'p_photo': path,
            },
          ) as Map,
        ),
      );
    } catch (_) {
      await _remove(path);
      rethrow;
    }
  }

  @override
  Future<void> setAttendanceTimes(
    String recordId, {
    required DateTime inAt,
    DateTime? outAt,
    String? note,
  }) => _client.rpc(
    'set_attendance_times',
    params: {
      'p_record': recordId,
      'p_in': inAt.toUtc().toIso8601String(),
      'p_out': outAt?.toUtc().toIso8601String(),
      'p_note': note,
    },
  );

  @override
  Future<void> deleteAttendanceRecord(String recordId, {String? note}) =>
      _client.rpc(
        'delete_attendance_record',
        params: {'p_record': recordId, 'p_note': note},
      );

  @override
  Future<void> requestAttendanceFix(
    String workspaceId,
    DateTime day, {
    DateTime? inAt,
    DateTime? outAt,
    required String note,
  }) => _client.rpc(
    'request_attendance_fix',
    params: {
      'p_workspace': workspaceId,
      'p_day': _date(day),
      'p_in': inAt?.toUtc().toIso8601String(),
      'p_out': outAt?.toUtc().toIso8601String(),
      'p_note': note,
    },
  );

  @override
  Future<void> cancelAttendanceFix(String fixId) =>
      _client.rpc('cancel_attendance_fix', params: {'p_fix': fixId});

  @override
  Future<void> decideAttendanceFix(
    String fixId, {
    required bool accept,
    String? note,
  }) => _client.rpc(
    'decide_attendance_fix',
    params: {'p_fix': fixId, 'p_accept': accept, 'p_note': note},
  );

  @override
  Future<List<AttendanceFix>> myAttendanceFixes(
    String workspaceId,
    DateTime from,
    DateTime to,
  ) async => _rows(
    await _client.rpc(
      'my_attendance_fixes',
      params: {
        'p_workspace': workspaceId,
        'p_from': _date(from),
        'p_to': _date(to),
      },
    ),
  ).map(AttendanceFix.fromJson).toList();

  @override
  Future<AttendanceRequests> attendanceRequests(String workspaceId) async =>
      AttendanceRequests.fromJson(
        Json.from(
          await _client.rpc(
            'attendance_requests',
            params: {'p_workspace': workspaceId},
          ) as Map,
        ),
      );
}
