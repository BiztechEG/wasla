import 'dart:async';

import 'package:wasla/data/api.dart';
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
    list.add(
      Project(
        id: id,
        workspaceId: workspaceId,
        name: name,
        color: color,
        status: ProjectStatus.active,
        memberCount: 1,
      ),
    );
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
}
