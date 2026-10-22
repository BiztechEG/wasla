// Plain data classes for what the app reads from the backend.

import 'package:flutter/material.dart' show TimeOfDay;

typedef Json = Map<String, dynamic>;

enum WorkspaceRole {
  owner,
  admin,
  member;

  static WorkspaceRole parse(Object? value) => WorkspaceRole.values.firstWhere(
    (r) => r.name == value,
    orElse: () => WorkspaceRole.member,
  );

  bool get canManage => this == owner || this == admin;
}

enum ProjectRole {
  lead,
  member;

  static ProjectRole parse(Object? value) =>
      value == 'lead' ? ProjectRole.lead : ProjectRole.member;
}

enum ProjectStatus {
  active,
  archived,
  closed;

  static ProjectStatus parse(Object? value) => ProjectStatus.values.firstWhere(
    (s) => s.name == value,
    orElse: () => ProjectStatus.active,
  );
}

Json _object(Object? value) => value is Map ? Json.from(value) : const {};

String _text(Object? value) => value as String? ?? '';

class Profile {
  const Profile({
    required this.id,
    required this.fullName,
    this.email,
    this.phone,
  });

  final String id;
  final String fullName;
  final String? email;
  final String? phone;

  factory Profile.fromJson(Json json) => Profile(
    id: json['id'] as String,
    fullName: _text(json['full_name']),
    email: json['email'] as String?,
    phone: json['phone'] as String?,
  );
}

/// A workspace the signed-in user belongs to, with their role in it.
class Membership {
  const Membership({
    required this.workspaceId,
    required this.workspaceName,
    required this.companyId,
    required this.companyName,
    required this.isCompanyOwner,
    required this.role,
    required this.planName,
    required this.maxMembers,
    required this.discoverable,
    this.allowSharing = true,
  });

  final String workspaceId;
  final String workspaceName;
  final String companyId;
  final String companyName;
  final bool isCompanyOwner;
  final WorkspaceRole role;
  final String planName;

  /// Seats in the plan; null means unlimited.
  final int? maxMembers;
  final bool discoverable;

  /// People may share messages and files to other apps.
  final bool allowSharing;

  /// Workspace owners and the company owner delete a workspace.
  bool get canDelete => role == WorkspaceRole.owner || isCompanyOwner;

  factory Membership.fromJson(Json json, {required String me}) {
    final ws = _object(json['workspaces']);
    final plan = _object(ws['plans']);
    final company = _object(ws['companies']);
    return Membership(
      workspaceId: ws['id'] as String,
      workspaceName: _text(ws['name']),
      companyId: _text(ws['company_id']),
      companyName: _text(company['name']),
      isCompanyOwner: company['owner_id'] == me,
      role: WorkspaceRole.parse(json['role']),
      planName: _text(plan['name']),
      maxMembers: plan['max_members'] as int?,
      discoverable: ws['discoverable'] as bool? ?? false,
      allowSharing: ws['allow_sharing'] as bool? ?? true,
    );
  }
}

/// A deleted workspace the signed-in user can still restore.
class DeletedWorkspace {
  const DeletedWorkspace({
    required this.id,
    required this.name,
    required this.companyName,
    required this.deletedAt,
    required this.purgeAt,
  });

  final String id;
  final String name;
  final String companyName;
  final DateTime deletedAt;

  /// When it is removed for good.
  final DateTime purgeAt;

  factory DeletedWorkspace.fromJson(Json json) => DeletedWorkspace(
    id: json['id'] as String,
    name: _text(json['name']),
    companyName: _text(json['company_name']),
    deletedAt: DateTime.parse(json['deleted_at'] as String),
    purgeAt: DateTime.parse(json['purge_at'] as String),
  );
}

/// An invitation addressed to the signed-in user.
class MyInvite {
  const MyInvite({
    this.id = '',
    required this.token,
    required this.workspaceId,
    required this.workspaceName,
    required this.role,
    required this.invitedByName,
  });

  final String id;
  final String token;
  final String workspaceId;
  final String workspaceName;
  final WorkspaceRole role;
  final String invitedByName;

  factory MyInvite.fromJson(Json json) => MyInvite(
    id: json['id'] as String? ?? '',
    token: json['token'] as String,
    workspaceId: json['workspace_id'] as String,
    workspaceName: _text(json['workspace_name']),
    role: WorkspaceRole.parse(json['role']),
    invitedByName: _text(json['invited_by_name']),
  );
}

/// A request the signed-in user sent and is still waiting on.
class MyJoinRequest {
  const MyJoinRequest({
    required this.id,
    required this.workspaceId,
    required this.workspaceName,
  });

  final String id;
  final String workspaceId;
  final String workspaceName;

  factory MyJoinRequest.fromJson(Json json) => MyJoinRequest(
    id: json['id'] as String,
    workspaceId: json['workspace_id'] as String,
    workspaceName: _text(json['workspace_name']),
  );
}

/// Hours of the day when nothing reaches one's phone, where the phone is
/// [utcOffset] minutes from UTC. [from] after [to] runs past midnight.
class QuietHours {
  const QuietHours({
    required this.from,
    required this.to,
    required this.utcOffset,
  });

  final TimeOfDay from;
  final TimeOfDay to;
  final int utcOffset;
}

/// What someone is up to, besides being available.
enum StatusKind {
  meeting('meeting'),
  busy('busy'),
  leave('leave');

  const StatusKind(this.wire);

  final String wire;

  static StatusKind? parse(String? wire) =>
      values.where((k) => k.wire == wire).firstOrNull;
}

/// Someone's status; [until] null: until they change it.
class UserStatus {
  const UserStatus({required this.kind, this.note, this.until});

  final StatusKind kind;
  final String? note;
  final DateTime? until;
}

/// Which of a new workspace's first steps are done.
class SetupProgress {
  const SetupProgress({
    this.project = false,
    this.team = false,
    this.attendance = false,
    this.announcement = false,
  });

  final bool project;
  final bool team;
  final bool attendance;
  final bool announcement;

  int get done =>
      [project, team, attendance, announcement].where((d) => d).length;
  bool get complete => done == 4;
}

/// A workspace's join code, as its admins see it.
class JoinCode {
  const JoinCode({required this.code, required this.autoJoin});

  final String code;

  /// People with the code join straight away instead of asking.
  final bool autoJoin;

  /// Easier to read out and type: ABCD-EFGH.
  String get shown =>
      code.length == 8 ? '${code.substring(0, 4)}-${code.substring(4)}' : code;

  factory JoinCode.fromJson(Json json) => JoinCode(
    code: json['code'] as String,
    autoJoin: json['auto_join'] as bool? ?? false,
  );
}

/// Where a join code leads, shown before joining.
class CodeWorkspace {
  const CodeWorkspace({
    required this.workspaceId,
    required this.workspaceName,
    required this.companyName,
    required this.autoJoin,
    this.member = false,
    this.requested = false,
  });

  final String workspaceId;
  final String workspaceName;
  final String companyName;
  final bool autoJoin;

  /// Already in it, or already waiting for an answer.
  final bool member;
  final bool requested;

  factory CodeWorkspace.fromJson(Json json) => CodeWorkspace(
    workspaceId: json['workspace_id'] as String,
    workspaceName: _text(json['workspace_name']),
    companyName: _text(json['company_name']),
    autoJoin: json['auto_join'] as bool? ?? false,
    member: json['member'] as bool? ?? false,
    requested: json['requested'] as bool? ?? false,
  );
}

class WorkspaceHit {
  const WorkspaceHit({required this.id, required this.name});

  final String id;
  final String name;

  factory WorkspaceHit.fromJson(Json json) =>
      WorkspaceHit(id: json['id'] as String, name: _text(json['name']));
}

class Project {
  const Project({
    required this.id,
    required this.workspaceId,
    required this.name,
    required this.color,
    required this.status,
    required this.memberCount,
  });

  final String id;
  final String workspaceId;
  final String name;
  final String color;
  final ProjectStatus status;
  final int memberCount;

  factory Project.fromJson(Json json) {
    final counts = json['project_members'];
    final count = counts is List && counts.isNotEmpty
        ? (_object(counts.first)['count'] as int? ?? 0)
        : 0;
    return Project(
      id: json['id'] as String,
      workspaceId: json['workspace_id'] as String,
      name: _text(json['name']),
      color: json['color'] as String? ?? '#0F6E6A',
      status: ProjectStatus.parse(json['status']),
      memberCount: count,
    );
  }
}

/// Someone in a workspace.
class Member {
  const Member({
    required this.userId,
    required this.fullName,
    required this.role,
    this.email,
    this.phone,
  });

  final String userId;
  final String fullName;
  final WorkspaceRole role;
  final String? email;
  final String? phone;

  String get contact => email ?? phone ?? '';

  factory Member.fromJson(Json json) {
    final profile = _object(json['profiles']);
    return Member(
      userId: json['user_id'] as String,
      fullName: _text(profile['full_name']),
      role: WorkspaceRole.parse(json['role']),
      email: profile['email'] as String?,
      phone: profile['phone'] as String?,
    );
  }
}

class ProjectMember {
  const ProjectMember({
    required this.userId,
    required this.fullName,
    required this.role,
    this.email,
  });

  final String userId;
  final String fullName;
  final ProjectRole role;
  final String? email;

  factory ProjectMember.fromJson(Json json) {
    final profile = _object(json['profiles']);
    return ProjectMember(
      userId: json['user_id'] as String,
      fullName: _text(profile['full_name']),
      role: ProjectRole.parse(json['role']),
      email: profile['email'] as String?,
    );
  }
}

/// An invitation an admin sent that nobody has answered yet.
class SentInvite {
  const SentInvite({
    required this.id,
    required this.role,
    required this.expiresAt,
    this.email,
    this.phone,
  });

  final String id;
  final WorkspaceRole role;
  final DateTime expiresAt;
  final String? email;
  final String? phone;

  String get contact => email ?? phone ?? '';

  factory SentInvite.fromJson(Json json) => SentInvite(
    id: json['id'] as String,
    role: WorkspaceRole.parse(json['role']),
    expiresAt: DateTime.parse(json['expires_at'] as String),
    email: json['email'] as String?,
    phone: json['phone'] as String?,
  );
}

/// Someone asking to join a workspace, as an admin sees it.
class JoinRequest {
  const JoinRequest({
    required this.id,
    required this.userId,
    required this.fullName,
    required this.createdAt,
    this.email,
    this.message,
  });

  final String id;
  final String userId;
  final String fullName;
  final DateTime createdAt;
  final String? email;
  final String? message;

  factory JoinRequest.fromJson(Json json) {
    final profile = _object(json['profiles']);
    return JoinRequest(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      fullName: _text(profile['full_name']),
      email: profile['email'] as String? ?? profile['phone'] as String?,
      message: json['message'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }
}
