import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/models.dart';
import '../data/task_models.dart';
import '../state/providers.dart';
import '../state/task_providers.dart';
import '../theme.dart';
import 'attendance_screen.dart';
import 'followup_screen.dart';
import 'modern.dart';
import 'task_format.dart';
import 'task_editor.dart';
import 'task_list.dart';
import 'task_screen.dart';
import 'widgets.dart';

/// Opens a task's screen.
void openTask(BuildContext context, String workspaceId, String taskId) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => TaskScreen(workspaceId: workspaceId, taskId: taskId),
    ),
  );
}

/// Opens the editor for a new task, then the task once it is made.
Future<void> newTask(
  BuildContext context, {
  required String workspaceId,
  String? projectId,
  bool lockProject = false,
  String? title,
  String? description,
  String? sourceMessageId,
  List<String>? assigneeIds,
}) async {
  final navigator = Navigator.of(context);
  final id = await navigator.push<String>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => TaskEditorScreen(
        workspaceId: workspaceId,
        projectId: projectId,
        lockProject: lockProject,
        title: title,
        description: description,
        sourceMessageId: sourceMessageId,
        assigneeIds: assigneeIds,
      ),
    ),
  );
  if (id == null) return;
  navigator.push(
    MaterialPageRoute<void>(
      builder: (_) => TaskScreen(workspaceId: workspaceId, taskId: id),
    ),
  );
}

/// One's own tasks from every workspace: the ones given to them, and the
/// ones they gave others.
class MyTasksTab extends ConsumerStatefulWidget {
  const MyTasksTab({super.key, required this.membership});

  final Membership membership;

  @override
  ConsumerState<MyTasksTab> createState() => _MyTasksTabState();
}

class _MyTasksTabState extends ConsumerState<MyTasksTab> {
  bool _created = false;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final me = ref.watch(authProvider).value;
    final ws = widget.membership.workspaceId;
    final tasks = ref.watch(myTasksProvider);
    // Admins follow every project; leads see the projects they lead.
    final follows =
        widget.membership.role.canManage ||
        (ref.watch(managedTasksProvider(ws)).value?.isNotEmpty ?? false);

    return FabScaffold(
      fab: WaslaFab(
        icon: LucideIcons.plus,
        tooltip: l.newTask,
        onPressed: () => newTask(context, workspaceId: ws),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: _Switch(
                    labels: [l.assignedToMe, l.createdByMe],
                    selected: _created ? 1 : 0,
                    onSelected: (i) => setState(() => _created = i == 1),
                  ),
                ),
                if (follows) ...[
                  const SizedBox(width: 8),
                  SoftIconButton(
                    size: 44,
                    tooltip: l.followUp,
                    icon: const Icon(LucideIcons.chartColumn, size: 20),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => FollowUpScreen(workspaceId: ws),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          AttendanceStrip(membership: widget.membership),
          Expanded(
            child: AsyncView(
              value: tasks,
              onRetry: () => ref.invalidate(myTasksProvider),
              builder: (all) {
                final shown = [
                  for (final t in all)
                    if (_created
                        ? t.createdBy == me &&
                              t.assignees.any((a) => a.id != me)
                        : t.isAssignedTo(me))
                      t,
                ];
                return RefreshIndicator(
                  onRefresh: () => ref.refresh(myTasksProvider.future),
                  child: shown.isEmpty
                      ? ListView(
                          children: [
                            const SizedBox(height: 60),
                            EmptyState(
                              icon: LucideIcons.circleCheck,
                              title: _created ? l.createdEmpty : l.myTasksEmpty,
                              body: _created
                                  ? l.createdEmptyBody
                                  : l.myTasksEmptyBody,
                            ),
                          ],
                        )
                      : ListView(
                          padding: EdgeInsets.fromLTRB(
                            16,
                            14,
                            16,
                            navClearance(context) + 80,
                          ),
                          children: [
                            if (!_created) _Summary(tasks: shown),
                            ...taskGroups(
                              context,
                              shown,
                              onTap: (TaskItem t) =>
                                  openTask(context, t.workspaceId, t.id),
                              showAssignees: _created,
                              currentWorkspaceId: ws,
                            ),
                          ],
                        ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Two choices side by side on a light track; the chosen one is raised.
class _Switch extends StatelessWidget {
  const _Switch({
    required this.labels,
    required this.selected,
    required this.onSelected,
  });

  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            Expanded(
              child: Semantics(
                button: true,
                selected: i == selected,
                child: Material(
                  color: i == selected
                      ? (dark ? const Color(0xFF2E3332) : scheme.surface)
                      : Colors.transparent,
                  elevation: i == selected && !dark ? 1 : 0,
                  shadowColor: Colors.black26,
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => onSelected(i),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        labels[i],
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: i == selected
                              ? FontWeight.w600
                              : FontWeight.w500,
                          color: i == selected
                              ? scheme.onSurface
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// What needs doing soon: late, due today and due this week.
class _Summary extends StatelessWidget {
  const _Summary({required this.tasks});

  final List<TaskItem> tasks;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final now = DateTime.now();
    int count(DueGroup g) => tasks.where((t) => dueGroup(t, now) == g).length;
    return StatRow(
      tiles: [
        StatTile(
          label: groupLabel(l, DueGroup.late),
          value: count(DueGroup.late),
          color: lateColor(context),
        ),
        StatTile(
          label: groupLabel(l, DueGroup.today),
          value: count(DueGroup.today),
          color: WaslaColors.project('#C2660A', theme.brightness),
        ),
        StatTile(
          label: groupLabel(l, DueGroup.week),
          value: count(DueGroup.week),
        ),
      ],
    );
  }
}
