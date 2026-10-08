import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../state/providers.dart';
import 'widgets.dart';

/// A project's people. Files, announcements and chat join it in phase 2.
class ProjectScreen extends ConsumerWidget {
  const ProjectScreen({super.key, required this.project});

  final Project project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final theme = Theme.of(context);
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

    final members = ref.watch(projectMembersProvider(project.id));
    final isLead =
        members.value?.any(
          (m) => m.userId == me && m.role == ProjectRole.lead,
        ) ??
        false;
    final canEdit = isAdmin || isLead;

    void refresh() {
      ref.invalidate(projectMembersProvider(project.id));
      ref.invalidate(projectsProvider(project.workspaceId));
    }

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
      if (ok && context.mounted) refresh();
    }

    return Scaffold(
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
      ),
      floatingActionButton: canEdit && current.status == ProjectStatus.active
          ? FloatingActionButton.extended(
              heroTag: 'addMember',
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (_) => _AddMemberSheet(
                  project: current,
                  existing: {
                    for (final m in members.value ?? <ProjectMember>[])
                      m.userId,
                  },
                ),
              ),
              icon: const Icon(Icons.person_add_alt_1_outlined),
              label: Text(l.addMember),
            )
          : null,
      body: AsyncView(
        value: members,
        onRetry: refresh,
        builder: (list) => RefreshIndicator(
          onRefresh: () =>
              ref.refresh(projectMembersProvider(project.id).future),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            children: [
              if (current.status != ProjectStatus.active)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Card(
                    color: theme.colorScheme.surfaceContainerHighest,
                    child: ListTile(
                      leading: Icon(
                        current.status == ProjectStatus.archived
                            ? Icons.inventory_2_outlined
                            : Icons.lock_outline,
                      ),
                      title: Text(
                        current.status == ProjectStatus.archived
                            ? l.statusArchived
                            : l.statusClosed,
                      ),
                    ),
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
                      trailing: canEdit && m.userId != me
                          ? _MemberMenu(
                              project: current,
                              member: m,
                              onDone: refresh,
                            )
                          : null,
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.attach_file),
                  title: Text(
                    l.projectExtrasSoon,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ],
          ),
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
                          title: Text(m.fullName),
                          subtitle: Text(ltr(m.contact)),
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
