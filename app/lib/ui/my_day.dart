import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/chat_models.dart';
import '../data/models.dart';
import '../data/task_models.dart';
import '../state/chat_providers.dart';
import '../state/providers.dart';
import '../state/task_providers.dart';
import '../theme.dart';
import 'announcements_view.dart';
import 'chat_screen.dart';
import 'task_format.dart';
import 'widgets.dart';

/// At the top of the home screen: what needs me today in this workspace,
/// each a tap from where it is answered. Gone when nothing does.
class MyDayCard extends ConsumerWidget {
  const MyDayCard({
    super.key,
    required this.membership,
    required this.onOpenTasks,
  });

  final Membership membership;

  /// Switches to the my-tasks tab.
  final VoidCallback onOpenTasks;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final ws = membership.workspaceId;
    final me = ref.watch(authProvider).value;
    final now = DateTime.now();
    final tasks = [
      for (final t in ref.watch(myTasksProvider).value ?? const <TaskItem>[])
        if (t.workspaceId == ws && t.isAssignedTo(me)) t,
    ];
    final late = tasks.where((t) => dueGroup(t, now) == DueGroup.late).length;
    final today = tasks.where((t) => dueGroup(t, now) == DueGroup.today).length;
    final mentioned = [
      for (final c
          in ref.watch(conversationsProvider(ws)).value ??
              const <Conversation>[])
        if (c.unreadMentions > 0) c,
    ];
    final mentions = mentioned.fold(0, (n, c) => n + c.unreadMentions);
    final toAck = [
      for (final n
          in ref.watch(unreadAnnouncementsProvider(ws)).value ??
              const <UnreadAnnouncement>[])
        if (n.needsAck) n,
    ];
    if (late + today + mentions + toAck.length == 0) {
      return const SizedBox.shrink();
    }

    return Padding(
      key: const Key('myDay'),
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(8, 0, 8, 8),
            child: Text(
              l.myDayTitle,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Row(
            children: [
              if (late > 0)
                _DayTile(
                  key: const Key('myDayLate'),
                  icon: LucideIcons.triangleAlert,
                  count: late,
                  label: l.myDayLate,
                  color: lateColor(context),
                  onTap: onOpenTasks,
                ),
              if (today > 0)
                _DayTile(
                  key: const Key('myDayToday'),
                  icon: LucideIcons.calendarCheck,
                  count: today,
                  label: l.myDayToday,
                  color: WaslaColors.project('#C2660A', theme.brightness),
                  onTap: onOpenTasks,
                ),
              if (mentions > 0)
                _DayTile(
                  key: const Key('myDayMentions'),
                  icon: LucideIcons.atSign,
                  count: mentions,
                  label: l.myDayMentions,
                  color: theme.colorScheme.primary,
                  // The chat that mentioned me last.
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ChatScreen(
                        membership: membership,
                        target: ChatTarget.of(mentioned.first),
                      ),
                    ),
                  ),
                ),
              if (toAck.isNotEmpty)
                _DayTile(
                  key: const Key('myDayAcks'),
                  icon: LucideIcons.megaphone,
                  count: toAck.length,
                  label: l.myDayAcks,
                  color: theme.colorScheme.tertiary,
                  onTap: () => showAnnouncement(
                    context,
                    ref,
                    workspaceId: ws,
                    note: toAck.first,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DayTile extends StatelessWidget {
  const _DayTile({
    super.key,
    required this.icon,
    required this.count,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final int count;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Material(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(icon, size: 16, color: color),
                      const SizedBox(width: 6),
                      Text(
                        '$count',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: color,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
