import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../state/chat_providers.dart';
import '../state/providers.dart';
import 'announcements_view.dart';
import 'chat_screen.dart';
import 'chats_tab.dart';
import 'files_view.dart';
import 'widgets.dart';

/// A project: its chat, files, announcements and people.
class ProjectScreen extends ConsumerWidget {
  const ProjectScreen({super.key, required this.project, this.initialTab = 0});

  final Project project;

  /// 0 chat, 1 files, 2 announcements, 3 members.
  final int initialTab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final me = ref.watch(authProvider).value;
    final membership = ref.watch(currentMembershipProvider);
    final isAdmin = membership?.role.canManage ?? false;

    // Show the latest copy of the project once the list refreshes.
    final latest = ref
        .watch(projectsProvider(project.workspaceId))
        .value
        ?.where((p) => p.id == project.id)
        .firstOrNull;
    final current = latest ?? project;
    final active = current.status == ProjectStatus.active;

    final members = ref.watch(projectMembersProvider(project.id));
    final isLead =
        members.value?.any(
          (m) => m.userId == me && m.role == ProjectRole.lead,
        ) ??
        false;
    final canEdit = isAdmin || isLead;

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
      length: 4,
      initialIndex: initialTab,
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
            tabs: [
              Tab(text: l.tabChat),
              Tab(text: l.tabFiles),
              Tab(text: l.tabAnnouncements),
              Tab(text: l.members),
            ],
          ),
        ),
        body: Column(
          children: [
            if (!active) _StatusBanner(status: current.status),
            Expanded(
              child: TabBarView(
                children: [
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
                  AnnouncementsView(
                    workspaceId: current.workspaceId,
                    projectId: current.id,
                    canPost: canEdit,
                    readOnly: !active,
                  ),
                  _MembersTab(
                    project: current,
                    members: members,
                    me: me,
                    canEdit: canEdit,
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
