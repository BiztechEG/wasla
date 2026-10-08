import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/task_models.dart';
import '../l10n/app_localizations.dart';
import '../state/providers.dart';
import '../state/task_providers.dart';
import 'chat_format.dart';
import 'my_tasks_tab.dart';
import 'task_format.dart';
import 'widgets.dart';

String noteText(AppLocalizations l, AppNotification n) {
  final who = n.actorName ?? '';
  return switch (n.kind) {
    NotificationKind.assigned => l.noteAssigned(who),
    NotificationKind.status => l.noteStatus(
      statusLabel(l, TaskStatus.parse(n.detail)),
      who,
    ),
    NotificationKind.comment => l.noteComment(who),
    NotificationKind.dueChanged => l.noteDueChanged(who),
    NotificationKind.nudge => l.noteNudge(who),
    NotificationKind.dueSoon => l.noteDueSoon,
    NotificationKind.overdue => l.noteOverdue,
    NotificationKind.reminder => l.noteReminder,
    NotificationKind.unassigned => l.noteUnassigned(who),
    NotificationKind.deleted => l.noteDeleted(who),
  };
}

IconData _icon(NotificationKind kind) => switch (kind) {
  NotificationKind.assigned => Icons.assignment_ind_outlined,
  NotificationKind.status => Icons.swap_horiz,
  NotificationKind.comment => Icons.chat_bubble_outline,
  NotificationKind.dueChanged => Icons.event_outlined,
  NotificationKind.nudge => Icons.notifications_active_outlined,
  NotificationKind.dueSoon => Icons.alarm,
  NotificationKind.overdue => Icons.alarm,
  NotificationKind.reminder => Icons.alarm,
  NotificationKind.unassigned => Icons.person_remove_outlined,
  NotificationKind.deleted => Icons.delete_outline,
};

/// What happened to one's tasks, newest first.
class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final list = ref.watch(notificationsProvider);
    final unread = ref.watch(unreadNotificationsProvider);
    final ws = ref.watch(currentMembershipProvider)?.workspaceId;

    Future<void> markRead([List<String>? ids]) async {
      try {
        await ref.read(apiProvider).markNotificationsRead(ids);
      } catch (_) {
        // Stays unread; nothing else depends on it.
      }
      ref.invalidate(notificationsProvider);
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(l.notificationsTitle),
        actions: [
          if (unread > 0)
            TextButton(onPressed: markRead, child: Text(l.markAllRead)),
        ],
      ),
      body: AsyncView(
        value: list,
        onRetry: () => ref.invalidate(notificationsProvider),
        builder: (items) => RefreshIndicator(
          onRefresh: () => ref.refresh(notificationsProvider.future),
          child: items.isEmpty
              ? ListView(
                  children: [
                    const SizedBox(height: 60),
                    EmptyState(
                      icon: Icons.notifications_none,
                      title: l.notificationsEmpty,
                    ),
                  ],
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: items.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, indent: 72),
                  itemBuilder: (context, i) {
                    final n = items[i];
                    return _NotificationTile(
                      note: n,
                      otherWorkspace: n.workspaceId != ws,
                      onTap: () {
                        if (n.unread) markRead([n.id]);
                        // A deleted task has nothing left to open.
                        if (n.taskId != null &&
                            n.kind != NotificationKind.deleted) {
                          openTask(context, n.workspaceId, n.taskId!);
                        }
                      },
                    );
                  },
                ),
        ),
      ),
    );
  }
}

class _NotificationTile extends StatelessWidget {
  const _NotificationTile({
    required this.note,
    required this.otherWorkspace,
    required this.onTap,
  });

  final AppNotification note;
  final bool otherWorkspace;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final n = note;
    final muted = theme.colorScheme.onSurfaceVariant;
    final alarm =
        n.kind == NotificationKind.overdue || n.kind == NotificationKind.nudge;
    final where = [
      if (otherWorkspace) n.workspaceName,
      ?n.projectName,
      listTime(context, n.createdAt),
    ].join(' · ');

    return Material(
      color: n.unread
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.35)
          : Colors.transparent,
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: alarm
              ? theme.colorScheme.error.withValues(alpha: 0.14)
              : theme.colorScheme.primaryContainer,
          child: Icon(
            _icon(n.kind),
            size: 20,
            color: alarm ? theme.colorScheme.error : theme.colorScheme.primary,
          ),
        ),
        title: Text(
          n.taskTitle ?? noteText(l, n),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: n.unread ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (n.taskTitle != null) Text(noteText(l, n)),
            Text(
              where,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ],
        ),
      ),
    );
  }
}
