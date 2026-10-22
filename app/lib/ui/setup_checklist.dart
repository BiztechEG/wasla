import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/models.dart';
import '../state/providers.dart';
import '../state/settings.dart';
import 'announcements_view.dart';
import 'attendance_setup_screen.dart';
import 'invite_sheet.dart';
import 'projects_tab.dart';
import 'widgets.dart';

/// Whether [SetupChecklist] shows for [membership] now.
bool setupChecklistShown(WidgetRef ref, Membership membership) {
  if (!membership.role.canManage) return false;
  final setup = ref.watch(setupProvider(membership.workspaceId)).value;
  return setup != null &&
      !setup.complete &&
      !ref.watch(setupHiddenProvider(membership.workspaceId));
}

/// Whether a workspace's first steps were hidden on this device.
final setupHiddenProvider = NotifierProvider.family<SetupHidden, bool, String>(
  SetupHidden.new,
);

class SetupHidden extends Notifier<bool> {
  SetupHidden(this.workspaceId);

  final String workspaceId;

  String get _key => 'setup_hidden_$workspaceId';

  @override
  bool build() => ref.watch(prefsProvider).getBool(_key) == true;

  Future<void> hide() async {
    state = true;
    await ref.read(prefsProvider).setBool(_key, true);
  }
}

/// On the home screen of a new workspace, for its owners and admins: the
/// first steps, each ticked once done, until all are or it is hidden.
class SetupChecklist extends ConsumerStatefulWidget {
  const SetupChecklist({super.key, required this.membership});

  final Membership membership;

  @override
  ConsumerState<SetupChecklist> createState() => _SetupChecklistState();
}

class _SetupChecklistState extends ConsumerState<SetupChecklist> {
  /// Only the next step shows until all are asked for.
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    if (!setupChecklistShown(ref, widget.membership)) {
      return const SizedBox.shrink();
    }
    final ws = widget.membership.workspaceId;
    final setup = ref.watch(setupProvider(ws)).value!;
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // Each step's screen; the list is checked again when it closes.
    Future<void> run(Future<void> Function() step) async {
      await step();
      if (mounted) ref.invalidate(setupProvider(ws));
    }

    Future<void> push(Widget screen) =>
        Navigator.of(context)
            .push(MaterialPageRoute<void>(builder: (_) => screen));

    final steps = [
      (
        key: 'project',
        done: setup.project,
        icon: LucideIcons.folderPlus,
        title: l.setupProject,
        hint: l.setupProjectHint,
        action: () => showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (_) => NewProjectSheet(workspaceId: ws),
        ),
      ),
      (
        key: 'team',
        done: setup.team,
        icon: LucideIcons.userPlus,
        title: l.setupTeam,
        hint: l.setupTeamHint,
        action: () => showInviteSheet(context, widget.membership),
      ),
      (
        key: 'attendance',
        done: setup.attendance,
        icon: LucideIcons.mapPin,
        title: l.setupAttendance,
        hint: l.setupAttendanceHint,
        action: () =>
            push(AttendanceSetupScreen(membership: widget.membership)),
      ),
      (
        key: 'announcement',
        done: setup.announcement,
        icon: LucideIcons.megaphone,
        title: l.setupAnnouncement,
        hint: l.setupAnnouncementHint,
        action: () =>
            push(WorkspaceAnnouncementsScreen(membership: widget.membership)),
      ),
    ];

    final next = steps.firstWhere((s) => !s.done);
    return Padding(
      key: const Key('setupChecklist'),
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Material(
        color: scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l.setupTitle,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    l.setupProgress(setup.done, steps.length),
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  IconButton(
                    key: const Key('hideSetup'),
                    tooltip: l.setupHide,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(LucideIcons.x, size: 18),
                    onPressed: () =>
                        ref.read(setupHiddenProvider(ws).notifier).hide(),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 8, bottom: 4),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: setup.done / steps.length,
                    minHeight: 6,
                    backgroundColor: scheme.surfaceContainerHighest,
                  ),
                ),
              ),
              for (final s in steps)
                if (_all || s == next)
                  ListTile(
                    key: Key('setup-${s.key}'),
                    contentPadding: const EdgeInsetsDirectional.only(end: 8),
                    enabled: !s.done,
                    leading: Icon(
                      s.done ? LucideIcons.circleCheckBig : s.icon,
                      color: s.done ? scheme.primary : scheme.onSurfaceVariant,
                    ),
                    title: Text(
                      s.title,
                      style: s.done
                          ? TextStyle(
                              decoration: TextDecoration.lineThrough,
                              color: scheme.onSurfaceVariant,
                            )
                          : const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: s.done ? null : Text(s.hint),
                    trailing: s.done
                        ? null
                        : const Icon(LucideIcons.chevronRightDir, size: 18),
                    onTap: s.done ? null : () => run(s.action),
                  ),
              if (!_all)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton(
                    key: const Key('allSetupSteps'),
                    onPressed: () => setState(() => _all = true),
                    child: Text(l.setupAllSteps),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
