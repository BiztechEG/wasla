import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/task_models.dart';
import '../state/providers.dart';
import '../state/task_providers.dart';
import 'my_tasks_tab.dart';
import 'task_format.dart';
import 'task_list.dart';
import 'widgets.dart';

/// For admins and leads: what is late or waiting on them in the projects
/// they lead, and how much each person has on their plate.
class FollowUpScreen extends ConsumerStatefulWidget {
  const FollowUpScreen({super.key, required this.workspaceId, this.projectId});

  final String workspaceId;

  /// Opens on one project.
  final String? projectId;

  @override
  ConsumerState<FollowUpScreen> createState() => _FollowUpScreenState();
}

class _FollowUpScreenState extends ConsumerState<FollowUpScreen> {
  late String? _project = widget.projectId;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final ws = widget.workspaceId;
    final tasks = ref.watch(managedTasksProvider(ws));

    return Scaffold(
      appBar: AppBar(title: Text(l.followUp)),
      body: AsyncView(
        value: tasks,
        onRetry: () => ref.invalidate(managedTasksProvider(ws)),
        builder: (all) {
          // The projects in the list, in the order they first appear.
          final projects = <String, TaskItem>{};
          for (final t in all) {
            projects.putIfAbsent(t.projectId, () => t);
          }
          final shown = [
            for (final t in all)
              if (_project == null || t.projectId == _project) t,
          ];
          return RefreshIndicator(
            onRefresh: () => ref.refresh(managedTasksProvider(ws).future),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                if (projects.length > 1 || _project != null)
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _ProjectChip(
                          label: l.allProjects,
                          selected: _project == null,
                          onTap: () => setState(() => _project = null),
                        ),
                        for (final p in projects.values)
                          _ProjectChip(
                            label: p.projectName,
                            color: p.projectColor,
                            selected: _project == p.projectId,
                            onTap: () => setState(() => _project = p.projectId),
                          ),
                      ],
                    ),
                  ),
                if (shown.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 60),
                    child: EmptyState(
                      icon: Icons.insights_outlined,
                      title: l.followUpEmpty,
                    ),
                  )
                else
                  ..._overview(
                    context,
                    shown,
                    mixed: _project == null && projects.length > 1,
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// [mixed]: the tasks come from several projects, so each row names its
  /// project.
  List<Widget> _overview(
    BuildContext context,
    List<TaskItem> tasks, {
    required bool mixed,
  }) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final now = DateTime.now();
    final me = ref.watch(authProvider).value;
    final open = tasks.where((t) => t.status.isOpen).toList();
    final late = open.where((t) => t.isLate(now)).toList();
    final review = open.where((t) => t.status == TaskStatus.review).toList();
    final held = open.where((t) => t.status == TaskStatus.onHold).toList();
    final soon = open.where((t) {
      final g = dueGroup(t, now);
      return g == DueGroup.today || g == DueGroup.week;
    }).length;

    // Open and late tasks per person, busiest first.
    final load = <String, ({String name, int open, int late})>{};
    for (final t in open) {
      for (final a in t.assignees) {
        final was = load[a.id] ?? (name: a.name, open: 0, late: 0);
        load[a.id] = (
          name: a.id == me ? l.you : a.name,
          open: was.open + 1,
          late: was.late + (t.isLate(now) ? 1 : 0),
        );
      }
    }
    final people = load.values.toList()
      ..sort((a, b) => b.open.compareTo(a.open));
    final most = people.isEmpty ? 1 : people.first.open;

    final needs = [...late, ...review, ...held.where((t) => !t.isLate(now))];

    return [
      const SizedBox(height: 12),
      StatRow(
        tiles: [
          StatTile(label: l.statOpen, value: open.length),
          StatTile(
            label: l.groupLate,
            value: late.length,
            color: theme.colorScheme.error,
          ),
          StatTile(label: l.statDueWeek, value: soon),
          StatTile(
            label: l.taskStatusReview,
            value: review.length,
            color: statusColor(TaskStatus.review, theme.brightness),
          ),
        ],
      ),
      SectionTitle(l.needsYou),
      if (needs.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            l.nothingNeedsYou,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        )
      else
        TileGroup(
          children: [
            for (final t in needs) _NeedsRow(task: t, showProject: mixed),
          ],
        ),
      if (people.isNotEmpty) ...[
        SectionTitle(l.workload),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
            child: Column(
              children: [
                for (final p in people)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 96,
                          child: Text(
                            p.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: p.open / most,
                              minHeight: 8,
                              color: p.late > 0
                                  ? theme.colorScheme.error
                                  : theme.colorScheme.primary,
                              backgroundColor:
                                  theme.colorScheme.surfaceContainerHighest,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          '${p.open}',
                          style: theme.textTheme.labelLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
      SectionTitle(l.tabTasks),
      ...taskGroups(
        context,
        tasks,
        onTap: (t) => openTask(context, t.workspaceId, t.id),
        showProject: mixed,
        showAssignees: true,
      ),
    ];
  }
}

class _ProjectChip extends StatelessWidget {
  const _ProjectChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.color,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final String? color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 8),
      child: ChoiceChip(
        avatar: color == null ? null : ColorDot(hex: color!, size: 10),
        label: Text(label),
        selected: selected,
        showCheckmark: false,
        onSelected: (_) => onTap(),
      ),
    );
  }
}

/// A task that needs the reader: late ones can be nudged, the rest opened.
class _NeedsRow extends ConsumerWidget {
  const _NeedsRow({required this.task, required this.showProject});

  final TaskItem task;
  final bool showProject;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final now = DateTime.now();
    final me = ref.watch(authProvider).value;
    final late = task.isLate(now);
    // Nudging reminds the assignees; there is no one to remind but oneself.
    final nudge = late && task.assignees.any((a) => a.id != me);
    final String why;
    final Color color;
    if (late) {
      final due = task.dueAt!.toLocal();
      final days = DateTime(
        now.year,
        now.month,
        now.day,
      ).difference(DateTime(due.year, due.month, due.day)).inDays;
      why = l.lateDays(days);
      color = theme.colorScheme.error;
    } else if (task.status == TaskStatus.review) {
      why = l.waitingReview;
      color = statusColor(TaskStatus.review, theme.brightness);
    } else {
      why = statusLabel(l, task.status);
      color = statusColor(task.status, theme.brightness);
    }
    final who = [
      if (showProject) task.projectName,
      if (task.assignees.isNotEmpty) task.assigneeNames,
    ].join(' · ');

    return ListTile(
      onTap: () => openTask(context, task.workspaceId, task.id),
      title: Text(task.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: why,
              style: TextStyle(color: color, fontWeight: FontWeight.w600),
            ),
            if (who.isNotEmpty) TextSpan(text: ' · $who'),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: nudge
          ? OutlinedButton(
              onPressed: () => runAction(
                context,
                () => ref.read(apiProvider).nudgeTask(task.id),
                done: l.reminderSent,
              ),
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
              child: Text(l.remindShort),
            )
          : task.status == TaskStatus.review
          ? FilledButton.tonal(
              onPressed: () => openTask(context, task.workspaceId, task.id),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
              child: Text(l.reviewAction),
            )
          : const Icon(Icons.chevron_right),
    );
  }
}
