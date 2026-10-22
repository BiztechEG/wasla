import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/models.dart';
import '../state/chat_providers.dart';
import '../state/providers.dart';
import 'chats_tab.dart';
import 'my_tasks_tab.dart';
import 'project_screen.dart';
import 'widgets.dart';

/// Someone's card, from the bottom: who they are, how to reach them, and
/// the projects you share. [name] shows while it loads, or if they left.
/// [inPrivateChat]: opened from the private chat with them, so "Message"
/// just goes back to it. [projectId]: the project the chat is about, for
/// "Assign task".
Future<void> showProfileCard(
  BuildContext context,
  WidgetRef ref, {
  required Membership membership,
  required String userId,
  required String name,
  bool inPrivateChat = false,
  String? projectId,
}) async {
  final choice = await showModalBottomSheet<Object>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) =>
        _ProfileCard(membership: membership, userId: userId, name: name),
  );
  if (!context.mounted) return;
  switch (choice) {
    case Member person when !inPrivateChat:
      await openPrivateChat(context, ref, membership, person);
    case _assign:
      await newTask(
        context,
        workspaceId: membership.workspaceId,
        projectId: projectId,
        assigneeIds: [userId],
      );
    case Project project:
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ProjectScreen(project: project),
        ),
      );
  }
}

const _assign = 'assign';

class _ProfileCard extends ConsumerWidget {
  const _ProfileCard({
    required this.membership,
    required this.userId,
    required this.name,
  });

  final Membership membership;
  final String userId;
  final String name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final ws = membership.workspaceId;
    final me = ref.watch(authProvider).value;
    final members = ref.watch(membersProvider(ws));
    final member = members.value?.where((m) => m.userId == userId).firstOrNull;
    final left = members.hasValue && member == null;
    final projects = ref.watch(projectsProvider(ws)).value ?? const [];
    final shared = [
      for (final id
          in ref
                  .watch(
                    projectsWithProvider((workspaceId: ws, userId: userId)),
                  )
                  .value ??
              const <String>[])
        ?projects.where((p) => p.id == id).firstOrNull,
    ];
    final fullName = member?.fullName ?? name;

    return SafeArea(
      child: SingleChildScrollView(
        key: const Key('profileCard'),
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(child: Avatar(name: fullName, radius: 36)),
            const SizedBox(height: 10),
            Text(
              fullName,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            if (member != null || left)
              Text(
                left ? l.leftWorkspace : roleLabel(l, member!.role),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(color: muted),
              ),
            if (member != null && userId != me) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      key: const Key('profileMessage'),
                      icon: const Icon(LucideIcons.messageCircle, size: 20),
                      label: Text(l.sendMessage),
                      onPressed: () => Navigator.pop(context, member),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const Key('profileAssign'),
                      icon: const Icon(LucideIcons.listPlus, size: 20),
                      label: Text(l.assignTask),
                      onPressed: () => Navigator.pop(context, _assign),
                    ),
                  ),
                ],
              ),
            ],
            if (member != null &&
                (member.email != null || member.phone != null)) ...[
              const SizedBox(height: 12),
              for (final (icon, value) in [
                (LucideIcons.mail, member.email),
                (LucideIcons.phone, member.phone),
              ])
                if (value != null && value.isNotEmpty)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: Icon(icon, color: muted),
                    title: LtrLine(value),
                  ),
            ],
            if (shared.isNotEmpty) ...[
              const SizedBox(height: 8),
              SectionTitle(l.sharedProjects(shared.length)),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final p in shared)
                    ActionChip(
                      avatar: ColorDot(hex: p.color),
                      label: Text(p.name),
                      onPressed: () => Navigator.pop(context, p),
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
