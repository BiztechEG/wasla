import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/overview_models.dart';
import '../state/providers.dart';
import '../theme.dart';
import 'start_screen.dart';
import 'task_format.dart';
import 'task_list.dart';
import 'widgets.dart';

final managementOverviewProvider =
    FutureProvider.autoDispose<List<WorkspaceOverview>>((ref) async {
      final api = ref.watch(apiProvider);
      await ref.watch(authProvider.future);
      return api.managementOverview();
    });

/// For company owners and admins: every workspace they run, side by side,
/// in numbers. Nothing anyone wrote is shown, and private chats are not
/// counted.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final value = ref.watch(managementOverviewProvider);
    return Scaffold(
      appBar: AppBar(title: Text(l.dashboardTitle)),
      body: AsyncView(
        value: value,
        onRetry: () => ref.invalidate(managementOverviewProvider),
        builder: (list) => RefreshIndicator(
          onRefresh: () => ref.refresh(managementOverviewProvider.future),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
            children: [
              if (list.isEmpty) ...[
                const SizedBox(height: 60),
                EmptyState(icon: LucideIcons.chartLine, title: l.dashEmpty),
              ] else ...[
                if (list.length > 1) ...[
                  SectionTitle(l.dashAll),
                  _Totals(list: list),
                ],
                for (final w in list) _WorkspaceCard(overview: w),
              ],
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    LucideIcons.lock,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      l.dashPrivacy,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Totals extends StatelessWidget {
  const _Totals({required this.list});

  final List<WorkspaceOverview> list;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    int sum(int Function(WorkspaceOverview) f) =>
        list.fold(0, (n, w) => n + f(w));
    return StatRow(
      tiles: [
        StatTile(label: l.dashPeople, value: sum((w) => w.members)),
        StatTile(label: l.dashOpen, value: sum((w) => w.open)),
        StatTile(
          label: l.dashLate,
          value: sum((w) => w.late),
          color: lateColor(context),
        ),
        StatTile(
          label: l.dashReview,
          value: sum((w) => w.review),
          color: Theme.of(context).colorScheme.primary,
        ),
      ],
    );
  }
}

class _WorkspaceCard extends ConsumerWidget {
  const _WorkspaceCard({required this.overview});

  final WorkspaceOverview overview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final w = overview;
    final member = (ref.watch(membershipsProvider).value ?? const []).any(
      (m) => m.workspaceId == w.workspaceId,
    );
    final a = w.attendance;
    final trend = w.doneWeek.compareTo(w.doneWeekBefore);

    Widget line(IconData icon, String text, {Color? color}) => Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Icon(icon, size: 17, color: color ?? scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: color == null ? null : TextStyle(color: color),
            ),
          ),
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Avatar(name: w.workspaceName),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          w.workspaceName,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(w.companyName, style: muted),
                      ],
                    ),
                  ),
                  if (member)
                    TextButton(
                      onPressed: () =>
                          openWorkspace(context, ref, w.workspaceId),
                      child: Text(l.view),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              StatRow(
                tiles: [
                  StatTile(label: l.dashPeople, value: w.members),
                  StatTile(label: l.dashOpen, value: w.open),
                  StatTile(
                    label: l.dashLate,
                    value: w.late,
                    color: lateColor(context),
                  ),
                  StatTile(
                    label: l.dashReview,
                    value: w.review,
                    color: scheme.primary,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              line(
                trend > 0
                    ? LucideIcons.trendingUp
                    : trend < 0
                    ? LucideIcons.trendingDown
                    : LucideIcons.minus,
                l.dashDoneWeek(w.doneWeek, w.doneWeekBefore),
                color: trend < 0 ? lateColor(context) : null,
              ),
              line(
                LucideIcons.messagesSquare,
                l.dashChat(w.messagesWeek, w.activePeopleWeek),
              ),
              if (a != null)
                line(
                  LucideIcons.clock,
                  a.dayOff
                      ? l.dashDayOff
                      : l.dashAttendance(a.present, a.people, a.late),
                ),
              const SizedBox(height: 12),
              const Divider(height: 1),
              const SizedBox(height: 4),
              if (w.projectList.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(l.dashNoProjects, style: muted),
                )
              else
                for (final p in w.projectList) _ProjectBar(project: p),
            ],
          ),
        ),
      ),
    );
  }
}

/// A project's tasks: done of all, with the late ones called out.
class _ProjectBar extends StatelessWidget {
  const _ProjectBar({required this.project});

  final ProjectOverview project;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final p = project;
    final color = WaslaColors.project(p.color, theme.brightness);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ColorDot(hex: p.color, size: 10),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  p.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              if (p.late > 0) ...[
                Text(
                  '${p.late} ${l.dashLate}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: lateColor(context),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Text(
                l.dashDoneOf(p.done, p.total),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: p.fraction,
              minHeight: 6,
              color: color,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          ),
        ],
      ),
    );
  }
}
