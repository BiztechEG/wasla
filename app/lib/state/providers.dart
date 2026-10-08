import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api.dart';
import '../data/models.dart';
import 'settings.dart';

final apiProvider = Provider<WaslaApi>(
  (ref) => throw UnimplementedError('apiProvider must be overridden'),
);

/// The signed-in user's id, or null when signed out.
final authProvider = StreamProvider<String?>(
  (ref) => ref.watch(apiProvider).userIdChanges().distinct(),
);

/// Everything below re-runs when the signed-in user changes, so one person's
/// data never shows up for the next person on the same phone.
Future<String?> _user(Ref ref) => ref.watch(authProvider.future);

final profileProvider = FutureProvider<Profile?>((ref) async {
  if (await _user(ref) == null) return null;
  return ref.watch(apiProvider).myProfile();
});

final membershipsProvider = FutureProvider<List<Membership>>((ref) async {
  if (await _user(ref) == null) return const [];
  return ref.watch(apiProvider).myWorkspaces();
});

final myInvitesProvider = FutureProvider.autoDispose<List<MyInvite>>((
  ref,
) async {
  if (await _user(ref) == null) return const [];
  return ref.watch(apiProvider).myInvites();
});

final myJoinRequestsProvider = FutureProvider.autoDispose<List<MyJoinRequest>>((
  ref,
) async {
  if (await _user(ref) == null) return const [];
  return ref.watch(apiProvider).myJoinRequests();
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
    await _user(ref);
    return ref.watch(apiProvider).members(workspaceId);
  },
);

final sentInvitesProvider = FutureProvider.autoDispose
    .family<List<SentInvite>, String>((ref, workspaceId) async {
      await _user(ref);
      return ref.watch(apiProvider).sentInvites(workspaceId);
    });

final joinRequestsProvider = FutureProvider.autoDispose
    .family<List<JoinRequest>, String>((ref, workspaceId) async {
      await _user(ref);
      return ref.watch(apiProvider).joinRequests(workspaceId);
    });

final projectsProvider = FutureProvider.autoDispose
    .family<List<Project>, String>((ref, workspaceId) async {
      await _user(ref);
      return ref.watch(apiProvider).projects(workspaceId);
    });

final projectMembersProvider = FutureProvider.autoDispose
    .family<List<ProjectMember>, String>((ref, projectId) async {
      await _user(ref);
      return ref.watch(apiProvider).projectMembers(projectId);
    });
