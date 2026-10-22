import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api.dart';
import '../data/models.dart';
import 'settings.dart';
import 'task_providers.dart' show notificationEventsProvider, refreshOn;

final apiProvider = Provider<WaslaApi>(
  (ref) => throw UnimplementedError('apiProvider must be overridden'),
);

/// Wasla's logo from the admin dashboard; null shows the built-in one.
final logoUrlProvider = FutureProvider<String?>(
  (ref) => ref.watch(apiProvider).logoUrl(),
);

/// The signed-in user's id, or null when signed out.
final authProvider = StreamProvider<String?>(
  (ref) => ref.watch(apiProvider).userIdChanges().distinct(),
);

/// Everything below re-runs when the signed-in user changes, so one person's
/// data never shows up for the next person on the same phone.
Future<String?> _user(Ref ref) => ref.watch(authProvider.future);

final profileProvider = FutureProvider<Profile?>((ref) async {
  final api = ref.watch(apiProvider);
  if (await _user(ref) == null) return null;
  return api.myProfile();
});

final membershipsProvider = FutureProvider<List<Membership>>((ref) async {
  final api = ref.watch(apiProvider);
  if (await _user(ref) == null) return const [];
  return api.myWorkspaces();
});

/// Deleted workspaces one may still restore.
final deletedWorkspacesProvider =
    FutureProvider.autoDispose<List<DeletedWorkspace>>((ref) async {
      final api = ref.watch(apiProvider);
      if (await _user(ref) == null) return const [];
      return api.deletedWorkspaces();
    });

/// Invitations waiting for the signed-in user; a new one arrives as a
/// notification.
final myInvitesProvider = FutureProvider.autoDispose<List<MyInvite>>((
  ref,
) async {
  final api = ref.watch(apiProvider);
  refreshOn(ref, notificationEventsProvider, ref.invalidateSelf);
  if (await _user(ref) == null) return const [];
  return api.myInvites();
});

/// Requests to join that the signed-in user is still waiting on; the answer
/// arrives as a notification.
final myJoinRequestsProvider = FutureProvider.autoDispose<List<MyJoinRequest>>((
  ref,
) async {
  final api = ref.watch(apiProvider);
  refreshOn(ref, notificationEventsProvider, ref.invalidateSelf);
  if (await _user(ref) == null) return const [];
  return api.myJoinRequests();
});

/// The workspace picked in the switcher, remembered on the device.
class CurrentWorkspaceNotifier extends Notifier<String?> {
  static const _key = 'workspace';

  @override
  String? build() => ref.watch(prefsProvider).getString(_key);

  Future<void> select(String workspaceId) async {
    state = workspaceId;
    await ref.read(prefsProvider).setString(_key, workspaceId);
  }
}

final currentWorkspaceIdProvider =
    NotifierProvider<CurrentWorkspaceNotifier, String?>(
      CurrentWorkspaceNotifier.new,
    );

/// The workspace on screen: the one picked, else the first one.
final currentMembershipProvider = Provider<Membership?>((ref) {
  final list = ref.watch(membershipsProvider).value ?? const <Membership>[];
  if (list.isEmpty) return null;
  final picked = ref.watch(currentWorkspaceIdProvider);
  for (final m in list) {
    if (m.workspaceId == picked) return m;
  }
  return list.first;
});

final membersProvider = FutureProvider.autoDispose.family<List<Member>, String>(
  (ref, workspaceId) async {
    final api = ref.watch(apiProvider);
    await _user(ref);
    return api.members(workspaceId);
  },
);

final sentInvitesProvider = FutureProvider.autoDispose
    .family<List<SentInvite>, String>((ref, workspaceId) async {
      final api = ref.watch(apiProvider);
      await _user(ref);
      return api.sentInvites(workspaceId);
    });

/// People asking to join a workspace, for its admins; each new one arrives
/// as a notification.
final joinRequestsProvider = FutureProvider.autoDispose
    .family<List<JoinRequest>, String>((ref, workspaceId) async {
      final api = ref.watch(apiProvider);
      refreshOn(ref, notificationEventsProvider, ref.invalidateSelf);
      await _user(ref);
      return api.joinRequests(workspaceId);
    });

final projectsProvider = FutureProvider.autoDispose
    .family<List<Project>, String>((ref, workspaceId) async {
      final api = ref.watch(apiProvider);
      await _user(ref);
      return api.projects(workspaceId);
    });

final projectMembersProvider = FutureProvider.autoDispose
    .family<List<ProjectMember>, String>((ref, projectId) async {
      final api = ref.watch(apiProvider);
      await _user(ref);
      return api.projectMembers(projectId);
    });
