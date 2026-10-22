import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/attendance_models.dart';
import '../data/models.dart';
import '../data/task_models.dart';
import '../state/attendance_providers.dart';
import '../state/providers.dart';
import '../state/task_providers.dart';
import 'attendance_team_screen.dart';
import 'join_requests_screen.dart';
import 'my_tasks_tab.dart';
import 'task_list.dart';
import 'widgets.dart';

/// Everything in a workspace that waits for the signed-in user's approval.
class Approvals {
  const Approvals({
    this.joinRequests = const [],
    this.attendance = const AttendanceRequests(),
    this.tasks = const [],
  });

  /// People asking to join (for owners and admins).
  final List<JoinRequest> joinRequests;

  /// Check-ins from outside a branch and corrections (for attendance
  /// managers).
  final AttendanceRequests attendance;

  /// Tasks in review that one may close: one's own, and those in the
  /// projects one leads.
  final List<TaskItem> tasks;

  int get count =>
      joinRequests.length +
      attendance.reviews.length +
      attendance.fixes.length +
      tasks.length;

  /// One key per item, so a banner put away comes back for new ones.
  Iterable<String> get keys => [
    for (final r in joinRequests) r.id,
    for (final (r, _) in attendance.reviews) r.id,
    for (final f in attendance.fixes) f.id,
    for (final t in tasks) '${t.id}:review',
  ];
}

/// What waits for my approval in a workspace, gathered from the lists that
/// already exist; each part loads only for those who can approve it.
final approvalsProvider = Provider.autoDispose.family<Approvals, String>((
  ref,
  workspaceId,
) {
  final memberships = ref.watch(membershipsProvider).value ?? const [];
  final m = memberships.where((m) => m.workspaceId == workspaceId).firstOrNull;
  if (m == null) return const Approvals();
  final me = ref.watch(authProvider).value;

  final today = ref.watch(attendanceTodayProvider(workspaceId)).value;
  final manager = (today?.enabled ?? false) && today!.isManager;

  // Leads and admins close any task in their projects; others their own.
  final tasks = <String, TaskItem>{
    for (final t in ref.watch(managedTasksProvider(workspaceId)).value ?? [])
      if (t.status == TaskStatus.review) t.id: t,
    for (final t in ref.watch(myTasksProvider).value ?? const <TaskItem>[])
      if (t.workspaceId == workspaceId &&
          t.status == TaskStatus.review &&
          t.createdBy == me)
        t.id: t,
  };
  return Approvals(
    joinRequests: m.role.canManage
        ? ref.watch(joinRequestsProvider(workspaceId)).value ?? const []
        : const [],
    attendance: manager
        ? ref.watch(attendanceRequestsProvider(workspaceId)).value ??
              const AttendanceRequests()
        : const AttendanceRequests(),
    tasks: tasks.values.toList()
      ..sort((a, b) => a.updatedAt.compareTo(b.updatedAt)),
  );
});

void openApprovals(BuildContext context, Membership membership) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ApprovalsScreen(membership: membership),
      ),
    );

/// One place for a manager's answers: requests to join, attendance and
/// tasks to review, each answered right where it is listed.
class ApprovalsScreen extends ConsumerWidget {
  const ApprovalsScreen({super.key, required this.membership});

  final Membership membership;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final ws = membership.workspaceId;
    final a = ref.watch(approvalsProvider(ws));

    Future<void> refresh() async {
      ref.invalidate(joinRequestsProvider(ws));
      ref.invalidate(attendanceRequestsProvider(ws));
      ref.invalidate(managedTasksProvider(ws));
      ref.invalidate(myTasksProvider);
      await ref.read(myTasksProvider.future);
    }

    return Scaffold(
      appBar: AppBar(title: Text(l.approvalsTitle)),
      body: RefreshIndicator(
        onRefresh: refresh,
        child: a.count == 0
            ? ListView(
                children: [
                  const SizedBox(height: 60),
                  EmptyState(
                    icon: LucideIcons.inbox,
                    title: l.noRequests,
                    body: l.approvalsEmptyBody,
                  ),
                ],
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                children: [
                  if (a.joinRequests.isNotEmpty) ...[
                    SectionTitle(l.joinRequests),
                    for (final r in a.joinRequests)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: JoinRequestCard(workspaceId: ws, request: r),
                      ),
                  ],
                  if (a.attendance.reviews.isNotEmpty) ...[
                    SectionTitle(l.checkInsToReview),
                    for (final (r, name) in a.attendance.reviews)
                      AttendanceReviewCard(
                        membership: membership,
                        record: r,
                        name: name,
                      ),
                  ],
                  if (a.attendance.fixes.isNotEmpty) ...[
                    SectionTitle(l.correctionsToDecide),
                    for (final f in a.attendance.fixes)
                      AttendanceFixCard(
                        membership: membership,
                        fix: f,
                        canDecide: true,
                        showName: true,
                      ),
                  ],
                  if (a.tasks.isNotEmpty) ...[
                    SectionTitle(l.tasksToReview),
                    TileGroup(
                      children: [
                        for (final t in a.tasks)
                          TaskTile(
                            task: t,
                            showAssignees: true,
                            onTap: () => openTask(context, ws, t.id),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
      ),
    );
  }
}
