import 'package:flutter/material.dart';

import '../data/task_models.dart';
import 'task_format.dart';
import 'widgets.dart';

/// A task in a list: its state, title, where it belongs and when it is due.
class TaskTile extends StatelessWidget {
  const TaskTile({
    super.key,
    required this.task,
    required this.onTap,
    this.showProject = true,
    this.showAssignees = false,
    this.workspaceName,
  });

  final TaskItem task;
  final VoidCallback onTap;

  /// Off in a project's own list.
  final bool showProject;

  /// On where the reader follows other people's tasks.
  final bool showAssignees;

  /// Set when the task is in a workspace other than the one on screen.
  final String? workspaceName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final late = task.isLate(DateTime.now());
    final done = task.status == TaskStatus.done;

    final details = <InlineSpan>[];
    void add(InlineSpan span) {
      if (details.isNotEmpty) details.add(const TextSpan(text: ' · '));
      details.add(span);
    }

    if (workspaceName != null) add(TextSpan(text: workspaceName));
    if (showProject) add(TextSpan(text: task.projectName));
    if (showAssignees && task.assignees.isNotEmpty) {
      add(TextSpan(text: task.assigneeNames));
    }
    if (task.dueAt != null && !done) {
      add(
        TextSpan(
          text: dueText(context, task.dueAt!, late: late),
          style: late
              ? TextStyle(
                  color: lateColor(context),
                  fontWeight: FontWeight.w600,
                )
              : null,
        ),
      );
    }

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              _StateMark(status: task.status, late: late),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        decoration: done ? TextDecoration.lineThrough : null,
                        color: done ? muted : null,
                      ),
                    ),
                    if (details.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          if (showProject) ...[
                            ColorDot(hex: task.projectColor, size: 8),
                            const SizedBox(width: 6),
                          ],
                          Expanded(
                            child: Text.rich(
                              TextSpan(children: details),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: muted,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              if (task.status != TaskStatus.todo && !done) ...[
                const SizedBox(width: 8),
                StatusTag(task.status),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The ring at the start of a task row: red when late, ticked when done.
class _StateMark extends StatelessWidget {
  const _StateMark({required this.status, required this.late});

  final TaskStatus status;
  final bool late;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (status == TaskStatus.done) {
      return Icon(
        Icons.check_circle,
        size: 24,
        color: theme.colorScheme.primary,
      );
    }
    final color = late
        ? lateColor(context)
        : status == TaskStatus.todo
        ? theme.colorScheme.outline
        : statusColor(status, theme.brightness);
    return Container(
      width: 22,
      height: 22,
      margin: const EdgeInsets.all(1),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: color, width: 2),
      ),
    );
  }
}

/// Tasks grouped by when they are due, as slivers-free list children.
List<Widget> taskGroups(
  BuildContext context,
  List<TaskItem> tasks, {
  required void Function(TaskItem task) onTap,
  bool showProject = true,
  bool showAssignees = false,
  String? currentWorkspaceId,
}) {
  final l = context.l10n;
  final theme = Theme.of(context);
  final groups = groupByDue(tasks, DateTime.now());
  return [
    for (final entry in groups.entries) ...[
      Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(4, 16, 4, 8),
        child: Text(
          l.groupCount(groupLabel(l, entry.key), entry.value.length),
          style: theme.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w700,
            color: entry.key == DueGroup.late
                ? lateColor(context)
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      for (final t in entry.value)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: TaskTile(
            task: t,
            onTap: () => onTap(t),
            showProject: showProject,
            showAssignees: showAssignees,
            workspaceName:
                currentWorkspaceId != null &&
                    t.workspaceId != currentWorkspaceId
                ? t.workspaceName
                : null,
          ),
        ),
    ],
  ];
}

/// A number with its label, in a row of counts at the top of a screen.
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    this.color,
  });

  final String label;
  final int value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        child: Column(
          children: [
            Text(
              '$value',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: value > 0 ? color : null,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Counts in a row of equal tiles.
class StatRow extends StatelessWidget {
  const StatRow({super.key, required this.tiles});

  final List<StatTile> tiles;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < tiles.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(child: tiles[i]),
        ],
      ],
    );
  }
}
