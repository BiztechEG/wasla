import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../data/task_models.dart';
import '../state/providers.dart';
import '../state/task_providers.dart';
import 'followup_screen.dart';
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

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'newTask',
        onPressed: () => newTask(context, workspaceId: ws),
        icon: const Icon(Icons.add),
        label: Text(l.newTask),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: SegmentedButton<bool>(
                    showSelectedIcon: false,
                    segments: [
                      ButtonSegment(value: false, label: Text(l.assignedToMe)),
                      ButtonSegment(value: true, label: Text(l.createdByMe)),
                    ],
                    selected: {_created},
                    onSelectionChanged: (s) =>
                        setState(() => _created = s.first),
                  ),
                ),
                if (follows) ...[
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    tooltip: l.followUp,
                    icon: const Icon(Icons.insights_outlined),
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
                              icon: Icons.task_alt,
                              title: _created ? l.createdEmpty : l.myTasksEmpty,
                              body: _created
                                  ? l.createdEmptyBody
                                  : l.myTasksEmptyBody,
                            ),
                          ],
                        )
                      : ListView(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
                          children: taskGroups(
                            context,
                            shown,
                            onTap: (TaskItem t) =>
                                openTask(context, t.workspaceId, t.id),
                            showAssignees: _created,
                            currentWorkspaceId: ws,
                          ),
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
