import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/chat_models.dart';
import '../data/models.dart';
import '../data/task_models.dart';
import '../state/chat_providers.dart';
import '../state/providers.dart';
import '../state/task_providers.dart';
import 'chat_format.dart';
import 'files_common.dart';
import 'my_tasks_tab.dart';
import 'project_screen.dart';
import 'task_editor.dart';
import 'task_list.dart';
import 'templates.dart';
import 'widgets.dart';

import 'package:lucide_icons_flutter/lucide_icons.dart';

/// How a project is going, for everyone in it: its lead, its latest
/// announcement, task counts, public tasks and pinned files.
class ProjectStatusView extends ConsumerWidget {
  const ProjectStatusView({super.key, required this.project});

  final Project project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final now = DateTime.now();
    final key = (workspaceId: project.workspaceId, projectId: project.id);
    final tasks = ref.watch(projectTasksProvider(key));
    final members =
        ref.watch(projectMembersProvider(project.id)).value ?? const [];
    final announcements =
        ref.watch(announcementsProvider(key)).value ?? const <Announcement>[];
    final files =
        ref.watch(projectFilesProvider(project.id)).value ??
        const <ProjectFile>[];

    void goTo(ProjectTab tab) =>
        DefaultTabController.of(context).animateTo(tab.index);

    final leads = [
      for (final m in members)
        if (m.role == ProjectRole.lead) m.fullName,
    ];
    final announcement =
        announcements.where((a) => a.pinned).firstOrNull ??
        announcements.firstOrNull;
    final pinned = files.where((f) => f.pinned).take(3).toList();

    return AsyncView(
      value: tasks,
      onRetry: () => ref.invalidate(projectTasksProvider(key)),
      builder: (all) {
        final open = all.where((t) => t.status.isOpen).toList();
        final late = open.where((t) => t.isLate(now)).length;
        final soon = open.where((t) {
          final g = dueGroup(t, now);
          return g == DueGroup.today || g == DueGroup.week;
        }).length;
        final public = [
          for (final t in open)
            if (t.visibility == TaskVisibility.public) t,
        ];

        return RefreshIndicator(
          onRefresh: () => ref.refresh(projectTasksProvider(key).future),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              Row(
                children: [
                  Icon(
                    LucideIcons.user,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      [
                        if (leads.isNotEmpty)
                          l.leadIs(joinNames(context, leads)),
                        l.memberCount(members.length),
                      ].join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              if (announcement != null) ...[
                const SizedBox(height: 12),
                Card(
                  margin: EdgeInsets.zero,
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => goTo(ProjectTab.announcements),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                announcement.pinned
                                    ? LucideIcons.pin
                                    : LucideIcons.megaphone,
                                size: 18,
                                color: theme.colorScheme.primary,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  announcement.pinned
                                      ? l.pinnedAnnouncement(
                                          announcement.authorName,
                                        )
                                      : l.latestAnnouncement(
                                          announcement.authorName,
                                        ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelLarge?.copyWith(
                                    color: theme.colorScheme.primary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              Text(
                                listTime(context, announcement.createdAt),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            announcement.body,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              StatRow(
                tiles: [
                  StatTile(label: l.statOpen, value: open.length),
                  StatTile(
                    label: l.groupLate,
                    value: late,
                    color: theme.colorScheme.error,
                  ),
                  StatTile(label: l.statDueWeek, value: soon),
                ],
              ),
              SectionTitle(
                l.publicTasks,
                trailing: _SeeAll(onTap: () => goTo(ProjectTab.tasks)),
              ),
              if (public.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    l.noPublicTasks,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              else
                for (final t in public.take(5))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: TaskTile(
                      task: t,
                      showProject: false,
                      showAssignees: true,
                      onTap: () => openTask(context, t.workspaceId, t.id),
                    ),
                  ),
              if (pinned.isNotEmpty) ...[
                SectionTitle(
                  l.pinnedFiles,
                  trailing: _SeeAll(onTap: () => goTo(ProjectTab.files)),
                ),
                TileGroup(
                  children: [
                    for (final f in pinned)
                      InkWell(
                        onTap: () => openFile(context, ref, f.file),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          child: FileRow(
                            file: f.file,
                            dense: true,
                            detail:
                                '${fileSize(l, f.file.size)} · ${f.uploaderName}',
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _SeeAll extends StatelessWidget {
  const _SeeAll({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: onTap,
    style: TextButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 8),
    ),
    child: Text(context.l10n.seeAll),
  );
}

/// The project's tasks one can see, by due date, with a button to add one.
class ProjectTasksView extends ConsumerWidget {
  const ProjectTasksView({super.key, required this.project});

  final Project project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final key = (workspaceId: project.workspaceId, projectId: project.id);
    final tasks = ref.watch(projectTasksProvider(key));
    final active = project.status == ProjectStatus.active;

    return Scaffold(
      floatingActionButton: active
          ? FloatingActionButton.extended(
              heroTag: 'projectTask',
              onPressed: () => newTask(
                context,
                workspaceId: project.workspaceId,
                projectId: project.id,
                lockProject: true,
              ),
              icon: const Icon(LucideIcons.plus),
              label: Text(l.newTask),
            )
          : null,
      body: AsyncView(
        value: tasks,
        onRetry: () => ref.invalidate(projectTasksProvider(key)),
        builder: (all) => RefreshIndicator(
          onRefresh: () => ref.refresh(projectTasksProvider(key).future),
          child: all.isEmpty
              ? ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    if (active)
                      TemplateActions(
                        project: project,
                        tasks: all,
                        canSave: false,
                      ),
                    const SizedBox(height: 60),
                    EmptyState(
                      icon: LucideIcons.circleCheck,
                      title: l.projectTasksEmpty,
                    ),
                  ],
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
                  children: [
                    if (active)
                      TemplateActions(
                        project: project,
                        tasks: all,
                        canSave: managesProject(
                          ref,
                          project.workspaceId,
                          ref.watch(projectMembersProvider(project.id)).value,
                        ),
                      ),
                    ...taskGroups(
                      context,
                      all,
                      onTap: (t) => openTask(context, t.workspaceId, t.id),
                      showProject: false,
                      showAssignees: true,
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
