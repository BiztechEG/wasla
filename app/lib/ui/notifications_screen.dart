import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/models.dart';
import '../data/task_models.dart';
import '../l10n/app_localizations.dart';
import '../state/providers.dart';
import '../state/task_providers.dart';
import 'admin_screen.dart';
import 'billing_format.dart';
import 'billing_screen.dart';
import 'chat_format.dart';
import 'inbox.dart';
import 'join_requests_screen.dart';
import 'members_screen.dart';
import 'my_tasks_tab.dart';
import 'start_screen.dart';
import 'task_format.dart';
import 'widgets.dart';
import 'dashboard_screen.dart';

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
    NotificationKind.planRequest => l.notePlanRequest(
      who,
      planLabel(l, n.detail ?? ''),
    ),
    NotificationKind.invoice => l.noteInvoice(n.detail ?? ''),
    NotificationKind.planActive => l.notePlanActive(
      planLabel(l, n.detail ?? ''),
    ),
    NotificationKind.planEnding => l.notePlanEnding(
      planLabel(l, n.detail ?? ''),
    ),
    NotificationKind.planExpired => l.notePlanExpired(
      planLabel(l, n.detail ?? ''),
    ),
    NotificationKind.invite => l.noteInvite(
      who,
      roleLabel(l, WorkspaceRole.parse(n.detail)),
    ),
    NotificationKind.inviteAccepted => l.noteInviteAccepted(who),
    NotificationKind.joinRequest => l.noteJoinRequest(who),
    NotificationKind.requestAccepted => l.noteRequestAccepted,
    NotificationKind.requestDeclined => l.noteRequestDeclined,
    NotificationKind.memberJoined => l.noteMemberJoined(who),
    NotificationKind.weeklyReport => weekSummary(l, n.detail),
  };
}

IconData _icon(NotificationKind kind) => switch (kind) {
  NotificationKind.assigned => LucideIcons.squareUser,
  NotificationKind.status => LucideIcons.arrowLeftRight,
  NotificationKind.comment => LucideIcons.messageCircle,
  NotificationKind.dueChanged => LucideIcons.calendar,
  NotificationKind.nudge => LucideIcons.bellRing,
  NotificationKind.dueSoon => LucideIcons.alarmClock,
  NotificationKind.overdue => LucideIcons.alarmClock,
  NotificationKind.reminder => LucideIcons.alarmClock,
  NotificationKind.unassigned => LucideIcons.userMinus,
  NotificationKind.deleted => LucideIcons.trash2,
  NotificationKind.planRequest => LucideIcons.badgeDollarSign,
  NotificationKind.invoice => LucideIcons.receiptText,
  NotificationKind.planActive => LucideIcons.badgeCheck,
  NotificationKind.planEnding => LucideIcons.hourglass,
  NotificationKind.planExpired => LucideIcons.hourglass,
  NotificationKind.invite => LucideIcons.mail,
  NotificationKind.inviteAccepted => LucideIcons.userCheck,
  NotificationKind.joinRequest => LucideIcons.userPlus,
  NotificationKind.requestAccepted => LucideIcons.circleCheck,
  NotificationKind.requestDeclined => LucideIcons.circleMinus,
  NotificationKind.memberJoined => LucideIcons.userPlus,
  NotificationKind.weeklyReport => LucideIcons.chartLine,
};

/// How an invitation or request ended, for the small tag on it.
String? _answerLabel(AppLocalizations l, AppNotification n) =>
    switch (n.requestStatus) {
      null || AnswerStatus.pending => null,
      AnswerStatus.accepted => l.answerAccepted,
      AnswerStatus.rejected => l.answerDeclined,
      AnswerStatus.cancelled =>
        n.kind == NotificationKind.joinRequest
            ? l.answerWithdrawn
            : l.answerCancelled,
      AnswerStatus.expired => l.answerExpired,
    };

/// Everything that happened for me, newest first: invitations and requests
/// still waiting for my answer on top, then the rest by day.
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

    void open(AppNotification n) {
      if (n.unread) markRead([n.id]);
      _open(context, ref, n);
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
        builder: (items) {
          if (items.isEmpty) {
            return RefreshIndicator(
              onRefresh: () => ref.refresh(notificationsProvider.future),
              child: ListView(
                children: [
                  const SizedBox(height: 60),
                  EmptyState(
                    icon: LucideIcons.bell,
                    title: l.notificationsEmpty,
                    body: l.notificationsEmptyHint,
                  ),
                ],
              ),
            );
          }

          final waiting = [
            for (final n in items)
              if (n.awaitsAnswer) n,
          ];
          final now = DateTime.now();
          final today = DateTime(now.year, now.month, now.day);
          final byDay = <String, List<AppNotification>>{};
          for (final n in items) {
            if (n.awaitsAnswer) continue;
            final t = n.createdAt.toLocal();
            final days = today
                .difference(DateTime(t.year, t.month, t.day))
                .inDays;
            final label = switch (days) {
              <= 0 => l.today,
              1 => l.yesterday,
              _ => l.earlierSection,
            };
            byDay.putIfAbsent(label, () => []).add(n);
          }

          Widget tile(AppNotification n) => _NotificationTile(
            note: n,
            // Billing news is about a workspace, so it says which.
            otherWorkspace: n.workspaceId != ws || n.kind.isBilling,
            onTap: () => open(n),
          );

          return RefreshIndicator(
            onRefresh: () {
              ref.invalidate(myInvitesProvider);
              return ref.refresh(notificationsProvider.future);
            },
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              children: [
                if (waiting.isNotEmpty) ...[
                  SectionTitle(l.needsAnswerSection),
                  for (final n in waiting)
                    _AnswerCard(note: n, onOpen: () => open(n)),
                ],
                for (final MapEntry(key: label, value: group)
                    in byDay.entries) ...[
                  SectionTitle(label),
                  TileGroup(children: [for (final n in group) tile(n)]),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Opens what a notification is about, in the workspace it came from.
Future<void> _open(
  BuildContext context,
  WidgetRef ref,
  AppNotification n,
) async {
  final navigator = Navigator.of(context);
  void push(Widget screen) =>
      navigator.push(MaterialPageRoute<void>(builder: (_) => screen));
  Membership? membership() => (ref.read(membershipsProvider).value ?? [])
      .where((m) => m.workspaceId == n.workspaceId)
      .firstOrNull;

  switch (n.kind) {
    case NotificationKind.planRequest:
      push(const AdminScreen());
    case _ when n.kind.isBilling:
      openBilling(context, ref, n.workspaceId);
    case NotificationKind.invite:
      if (n.requestStatus == AnswerStatus.accepted && membership() != null) {
        await openWorkspace(context, ref, n.workspaceId);
      }
    case NotificationKind.requestAccepted:
      // Just let in: the list of workspaces may not have it yet.
      if (membership() == null) {
        ref.invalidate(membershipsProvider);
        await ref.read(membershipsProvider.future);
      }
      if (context.mounted && membership() != null) {
        await openWorkspace(context, ref, n.workspaceId);
      }
    case NotificationKind.joinRequest:
      final m = membership();
      if (m == null) return;
      push(
        n.awaitsAnswer
            ? JoinRequestsScreen(membership: m)
            : MembersScreen(membership: m),
      );
    case NotificationKind.inviteAccepted || NotificationKind.memberJoined:
      final m = membership();
      if (m != null) push(MembersScreen(membership: m));
    case NotificationKind.requestDeclined:
      break;
    case NotificationKind.weeklyReport:
      push(const DashboardScreen());
    case _:
      // A deleted task has nothing left to open.
      if (n.taskId != null && n.kind != NotificationKind.deleted) {
        openTask(context, n.workspaceId, n.taskId!);
      }
  }
}

/// An invitation or a request to join that is still open, with the answer
/// right on it.
class _AnswerCard extends ConsumerWidget {
  const _AnswerCard({required this.note, required this.onOpen});

  final AppNotification note;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final n = note;
    final message = n.kind == NotificationKind.joinRequest
        ? n.detail?.trim()
        : null;

    final Widget actions;
    if (n.kind == NotificationKind.invite) {
      final invite = (ref.watch(myInvitesProvider).value ?? const <MyInvite>[])
          .where((i) => i.id == n.inviteId)
          .firstOrNull;
      actions = invite == null
          // Not loaded yet, or no longer open: the start page has the rest.
          ? OutlinedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const StartScreen(asPage: true),
                ),
              ),
              child: Text(l.view),
            )
          : AnswerButtons(
              onAccept: () => acceptInvite(context, ref, invite),
              onDecline: () => declineInvite(context, ref, invite),
            );
    } else {
      Future<void> answer(bool accept) => answerJoinRequest(
        context,
        ref,
        workspaceId: n.workspaceId,
        requestId: n.joinRequestId!,
        accept: accept,
      );
      actions = AnswerButtons(
        onAccept: () => answer(true),
        onDecline: () => answer(false),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Avatar(
                      name: n.kind == NotificationKind.joinRequest
                          ? n.actorName ?? ''
                          : n.workspaceName,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            n.workspaceName,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(noteText(l, n)),
                          if (message != null && message.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                '«$message»',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontStyle: FontStyle.italic,
                                  color: muted,
                                ),
                              ),
                            ),
                          const SizedBox(height: 2),
                          Text(
                            listTime(context, n.createdAt),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                actions,
              ],
            ),
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
    final alarm = switch (n.kind) {
      NotificationKind.overdue ||
      NotificationKind.nudge ||
      NotificationKind.planEnding ||
      NotificationKind.planExpired ||
      NotificationKind.requestDeclined => true,
      _ => false,
    };
    // Joining news is about a workspace, so the workspace is its title.
    final title = n.kind.isJoining ? n.workspaceName : n.taskTitle;
    final where = [
      if (otherWorkspace && !n.kind.isJoining) n.workspaceName,
      ?n.projectName,
      listTime(context, n.createdAt),
    ].join(' · ');
    final answer = _answerLabel(l, n);

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
          title ?? noteText(l, n),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: n.unread ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null) Text(noteText(l, n)),
            Row(
              children: [
                if (answer != null) ...[Tag(answer), const SizedBox(width: 6)],
                Flexible(
                  child: Text(
                    where,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A weekly report's numbers (the notification's detail) in one line.
String weekSummary(AppLocalizations l, String? detail) {
  Map<String, dynamic> w;
  try {
    w = Map<String, dynamic>.from(jsonDecode(detail ?? '') as Map);
  } catch (_) {
    return l.weeklyReportTitle;
  }
  int n(String k) => (w[k] as num?)?.toInt() ?? 0;
  return [
    l.weekDone(n('done'), n('done_before')),
    l.weekLate(n('late')),
    l.weekReview(n('review')),
    if (w['late_arrivals'] != null) l.weekLateArrivals(n('late_arrivals')),
  ].join(' · ');
}
