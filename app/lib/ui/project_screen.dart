import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../state/chat_providers.dart';
import '../state/providers.dart';
import 'announcements_view.dart';
import 'chat_screen.dart';
import 'chats_tab.dart';
import 'files_view.dart';
import 'followup_screen.dart';
import 'project_overview.dart';
import 'widgets.dart';

/// The project screen's tabs, in order.
enum ProjectTab { status, chat, files, tasks, announcements }

/// A project: how it is going, its chat, files, tasks and announcements.
/// Its people are one tap away in the top bar.
class ProjectScreen extends ConsumerWidget {
  const ProjectScreen({
    super.key,
    required this.project,
    this.initialTab = ProjectTab.status,
  });

  final Project project;
  final ProjectTab initialTab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final membership = ref.watch(currentMembershipProvider);
    final isAdmin = membership?.role.canManage ?? false;
    final current = _latest(ref, project);
    final active = current.status == ProjectStatus.active;
    final canEdit = _canEdit(ref, current);

    Future<void> setStatus(ProjectStatus status) async {
      final question = switch (status) {
        ProjectStatus.archived => l.confirmArchive,
        ProjectStatus.closed => l.confirmClose,
        ProjectStatus.active => null,
      };
      if (question != null &&
          !await confirm(
            context,
            message: question,
            action: l.continueAction,
          )) {
        return;
      }
      if (!context.mounted) return;
      final ok = await runAction(
        context,
        () => ref.read(apiProvider).setProjectStatus(project.id, status),
      );
      if (ok && context.mounted) {
        ref.invalidate(projectsProvider(project.workspaceId));
      }
    }

    final conversation = ref.watch(projectConversationProvider(project.id));

    return DefaultTabController(
      length: ProjectTab.values.length,
      initialIndex: initialTab.index,
      child: Scaffold(
        appBar: AppBar(
          title: Row(
            children: [
              ColorDot(hex: current.color, size: 14),
              const SizedBox(width: 10),
              Expanded(
                child: Text(current.name, overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
          actions: [
            if (canEdit && active)
              IconButton(
                tooltip: l.followUp,
                icon: const Icon(Icons.insights_outlined),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => FollowUpScreen(
                      workspaceId: current.workspaceId,
                      projectId: current.id,
                    ),
                  ),
                ),
              ),
            IconButton(
              tooltip: l.projectMembersAction,
              icon: const Icon(Icons.group_outlined),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => _MembersScreen(project: current),
                ),
              ),
            ),
            if (isAdmin)
              PopupMenuButton<ProjectStatus>(
                onSelected: setStatus,
                itemBuilder: (_) => [
                  if (current.status != ProjectStatus.active)
                    PopupMenuItem(
                      value: ProjectStatus.active,
                      child: Text(l.reopenProject),
                    ),
                  if (current.status != ProjectStatus.archived)
                    PopupMenuItem(
                      value: ProjectStatus.archived,
                      child: Text(l.archiveProject),
                    ),
                  if (current.status != ProjectStatus.closed)
                    PopupMenuItem(
                      value: ProjectStatus.closed,
                      child: Text(l.closeProject),
                    ),
                ],
              ),
          ],
          bottom: TabBar(
            // Five tabs don't fit a small phone with large text: they scroll.
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              for (final tab in ProjectTab.values)
                Tab(
                  text: switch (tab) {
                    ProjectTab.status => l.tabStatus,
                    ProjectTab.chat => l.tabChat,
                    ProjectTab.files => l.tabFiles,
                    ProjectTab.tasks => l.tabTasks,
                    ProjectTab.announcements => l.tabAnnouncements,
                  },
                ),
            ],
          ),
        ),
        body: Column(
          children: [
            if (!active) _StatusBanner(status: current.status),
            Expanded(
              child: TabBarView(
                children: [
                  ProjectStatusView(project: current),
                  if (membership == null)
                    const SizedBox()
                  else
                    AsyncView(
                      value: conversation,
                      onRetry: () => ref.invalidate(
                        projectConversationProvider(project.id),
                      ),
                      builder: (id) => id == null
                          ? EmptyState(
                              icon: Icons.lock_outline,
                              title: l.errorNotAllowed,
                            )
                          : ChatView(
                              membership: membership,
                              target: ChatTarget(
                                conversationId: id,
                                title: current.name,
                                projectId: current.id,
                                projectColor: current.color,
                              ),
                            ),
                    ),
                  ProjectFilesView(
                    workspaceId: current.workspaceId,
                    projectId: current.id,
                    canManage: canEdit,
                    canAdd: active,
                  ),
                  ProjectTasksView(project: current),
                  AnnouncementsView(
                    workspaceId: current.workspaceId,
                    projectId: current.id,
                    canPost: canEdit,
                    readOnly: !active,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The latest copy of [project] once the list refreshes.
Project _latest(WidgetRef ref, Project project) =>
    ref
        .watch(projectsProvider(project.workspaceId))
        .value
        ?.where((p) => p.id == project.id)
        .firstOrNull ??
    project;

/// Admins and the project's leads change its people, files and
/// announcements.
bool _canEdit(WidgetRef ref, Project project) {
  final me = ref.watch(authProvider).value;
  final isAdmin = ref.watch(currentMembershipProvider)?.role.canManage ?? false;
  final members = ref.watch(projectMembersProvider(project.id)).value;
  return isAdmin ||
      (members?.any((m) => m.userId == me && m.role == ProjectRole.lead) ??
          false);
}

class _MembersScreen extends ConsumerWidget {
  const _MembersScreen({required this.project});

  final Project project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = _latest(ref, project);
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.projectMembers)),
      body: _MembersTab(
        project: current,
        members: ref.watch(projectMembersProvider(project.id)),
        me: ref.watch(authProvider).value,
        canEdit: _canEdit(ref, current),
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.status});

  final ProjectStatus status;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final archived = status == ProjectStatus.archived;
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(
              archived ? Icons.inventory_2_outlined : Icons.lock_outline,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(archived ? l.statusArchived : l.statusClosed)),
          ],
        ),
      ),
    );
  }
}

class _MembersTab extends ConsumerWidget {
  const _MembersTab({
    required this.project,
    required this.members,
    required this.me,
    required this.canEdit,
  });

  final Project project;
  final AsyncValue<List<ProjectMember>> members;
  final String? me;
  final bool canEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final membership = ref.watch(currentMembershipProvider);

    void refresh() {
      ref.invalidate(projectMembersProvider(project.id));
      ref.invalidate(projectsProvider(project.workspaceId));
    }

    return AsyncView(
      value: members,
      onRetry: refresh,
      builder: (list) => RefreshIndicator(
        onRefresh: () => ref.refresh(projectMembersProvider(project.id).future),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            if (canEdit && project.status == ProjectStatus.active)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: FilledButton.tonalIcon(
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => _AddMemberSheet(
                      project: project,
                      existing: {for (final m in list) m.userId},
                    ),
                  ),
                  icon: const Icon(Icons.person_add_alt_1_outlined),
                  label: Text(l.addMember),
                ),
              ),
            SectionTitle(
              l.projectMembers,
              trailing: Text(
                '${list.length}',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            TileGroup(
              children: [
                for (final m in list)
                  PersonTile(
                    name: m.userId == me
                        ? '${m.fullName} (${l.you})'
                        : m.fullName,
                    avatarName: m.fullName,
                    contact: m.email,
                    tag: m.role == ProjectRole.lead ? l.roleLead : null,
                    onTap: m.userId == me || membership == null
                        ? null
                        : () => openPrivateChat(
                            context,
                            ref,
                            membership,
                            Member(
                              userId: m.userId,
                              fullName: m.fullName,
                              role: WorkspaceRole.member,
                              email: m.email,
                            ),
                          ),
                    trailing: canEdit && m.userId != me
                        ? _MemberMenu(
                            project: project,
                            member: m,
                            onDone: refresh,
                          )
                        : null,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MemberMenu extends ConsumerWidget {
  const _MemberMenu({
    required this.project,
    required this.member,
    required this.onDone,
  });

  final Project project;
  final ProjectMember member;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final api = ref.read(apiProvider);
    final isLead = member.role == ProjectRole.lead;

    return PopupMenuButton<String>(
      onSelected: (action) async {
        if (action == 'remove' &&
            !await confirm(
              context,
              message: l.confirmRemoveFromProject(member.fullName),
              action: l.remove,
              destructive: true,
            )) {
          return;
        }
        if (!context.mounted) return;
        final ok = await runAction(context, () {
          return switch (action) {
            'lead' => api.setProjectRole(
              project.id,
              member.userId,
              isLead ? ProjectRole.member : ProjectRole.lead,
            ),
            _ => api.removeProjectMember(project.id, member.userId),
          };
        });
        if (ok) onDone();
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'lead',
          child: Text(isLead ? l.removeLead : l.makeLead),
        ),
        PopupMenuItem(value: 'remove', child: Text(l.removeFromProject)),
      ],
    );
  }
}

class _AddMemberSheet extends ConsumerWidget {
  const _AddMemberSheet({required this.project, required this.existing});

  final Project project;
  final Set<String> existing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final members = ref.watch(membersProvider(project.workspaceId));

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.6,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                l.addMember,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Expanded(
              child: AsyncView(
                value: members,
                onRetry: () =>
                    ref.invalidate(membersProvider(project.workspaceId)),
                builder: (all) {
                  final candidates = all
                      .where((m) => !existing.contains(m.userId))
                      .toList();
                  if (candidates.isEmpty) {
                    return EmptyState(
                      icon: Icons.groups_outlined,
                      title: l.everyoneAdded,
                    );
                  }
                  return ListView(
                    children: [
                      for (final m in candidates)
                        ListTile(
                          leading: Avatar(name: m.fullName),
                          title: Text(
                            m.fullName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: LtrLine(m.contact),
                          trailing: const Icon(Icons.add_circle_outline),
                          onTap: () async {
                            final ok = await runAction(
                              context,
                              () => ref
                                  .read(apiProvider)
                                  .addProjectMember(project.id, m.userId),
                            );
                            if (ok && context.mounted) {
                              ref.invalidate(
                                projectMembersProvider(project.id),
                              );
                              ref.invalidate(
                                projectsProvider(project.workspaceId),
                              );
                              Navigator.pop(context);
                            }
                          },
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
