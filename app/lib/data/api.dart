import 'package:supabase_flutter/supabase_flutter.dart';

import 'models.dart';

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

  Future<List<Project>> projects(String workspaceId);
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
          'role, workspaces(id, name, company_id, discoverable, '
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
  Future<List<Project>> projects(String workspaceId) async {
    final data = await _client
        .from('projects')
        .select('id, workspace_id, name, color, status, project_members(count)')
        .eq('workspace_id', workspaceId)
        .order('created_at');
    return _rows(data).map(Project.fromJson).toList();
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
}
