import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import '../data/task_models.dart';
import 'providers.dart';

/// Live changes to the tasks one sees in a workspace, counted so each one
/// is a new value.
final taskEventsProvider = StreamProvider.autoDispose.family<int, String>((
  ref,
  workspaceId,
) {
  final api = ref.watch(apiProvider);
  // Starts over for whoever signs in next; quiet while signed out.
  if (ref.watch(authProvider).value == null) return const Stream.empty();
  var n = 0;
  return api.taskEvents(workspaceId).map((_) => ++n);
});

/// Notifications arriving for the signed-in user, counted.
final notificationEventsProvider = StreamProvider.autoDispose<int>((ref) {
  final api = ref.watch(apiProvider);
  if (ref.watch(authProvider).value == null) return const Stream.empty();
  var n = 0;
  return api.notificationEvents().map((_) => ++n);
});

/// Calls [refresh] shortly after the last of a burst of changes from
/// [source].
void refreshOn(
  Ref ref,
  ProviderListenable<AsyncValue<int>> source,
  void Function() refresh,
) {
  Timer? timer;
  ref.listen<AsyncValue<int>>(source, (_, next) {
    if (!next.hasValue) return;
    timer?.cancel();
    timer = Timer(const Duration(milliseconds: 250), refresh);
  });
  ref.onDispose(() => timer?.cancel());
}

/// Tasks one created or is assigned, in every workspace. Changes reach it
/// as notifications, and as task changes in the workspace on screen.
final myTasksProvider = FutureProvider.autoDispose<List<TaskItem>>((ref) async {
  final api = ref.watch(apiProvider);
  refreshOn(ref, notificationEventsProvider, ref.invalidateSelf);
  final workspaceId = ref.watch(currentMembershipProvider)?.workspaceId;
  if (workspaceId != null) {
    refreshOn(ref, taskEventsProvider(workspaceId), ref.invalidateSelf);
  }
  if (await ref.watch(authProvider.future) == null) return const [];
  return api.myTasks();
});

/// Task counts for the cards on the projects tab, kept up to date as tasks
/// change.
final projectProgressProvider = FutureProvider.autoDispose
    .family<Map<String, ProjectProgress>, String>((ref, workspaceId) async {
      final api = ref.watch(apiProvider);
      refreshOn(ref, taskEventsProvider(workspaceId), ref.invalidateSelf);
      if (await ref.watch(authProvider.future) == null) return const {};
      return api.projectProgress(workspaceId);
    });

typedef ProjectKey = ({String workspaceId, String projectId});

/// Live task changes only reach those who still see the task, so one taken
/// off a private task hears of it as a notification.
final projectTasksProvider = FutureProvider.autoDispose
    .family<List<TaskItem>, ProjectKey>((ref, key) async {
      final api = ref.watch(apiProvider);
      refreshOn(ref, taskEventsProvider(key.workspaceId), ref.invalidateSelf);
      refreshOn(ref, notificationEventsProvider, ref.invalidateSelf);
      await ref.watch(authProvider.future);
      return api.projectTasks(key.projectId);
    });

/// For the follow-up screen: tasks in the projects one leads.
final managedTasksProvider = FutureProvider.autoDispose
    .family<List<TaskItem>, String>((ref, workspaceId) async {
      final api = ref.watch(apiProvider);
      refreshOn(ref, taskEventsProvider(workspaceId), ref.invalidateSelf);
      await ref.watch(authProvider.future);
      return api.managedTasks(workspaceId);
    });

typedef TaskKey = ({String workspaceId, String taskId});

final taskDetailProvider = FutureProvider.autoDispose
    .family<TaskDetail, TaskKey>((ref, key) async {
      final api = ref.watch(apiProvider);
      refreshOn(ref, taskEventsProvider(key.workspaceId), ref.invalidateSelf);
      refreshOn(ref, notificationEventsProvider, ref.invalidateSelf);
      await ref.watch(authProvider.future);
      return api.task(key.taskId);
    });

final notificationsProvider = FutureProvider.autoDispose<List<AppNotification>>(
  (ref) async {
    final api = ref.watch(apiProvider);
    refreshOn(ref, notificationEventsProvider, ref.invalidateSelf);
    if (await ref.watch(authProvider.future) == null) return const [];
    return api.notifications();
  },
);

/// For the badge on the bell.
final unreadNotificationsProvider = Provider.autoDispose<int>((ref) {
  final list = ref.watch(notificationsProvider).value ?? const [];
  return list.where((n) => n.unread).length;
});

/// After changing a task here: every list that may show it reloads.
void refreshTasks(WidgetRef ref) {
  ref.invalidate(myTasksProvider);
  ref.invalidate(projectTasksProvider);
  ref.invalidate(managedTasksProvider);
  ref.invalidate(taskDetailProvider);
}
