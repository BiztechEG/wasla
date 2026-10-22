import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/google.dart';
import '../data/models.dart';
import '../state/billing_providers.dart';
import '../state/google_providers.dart';
import '../push/push.dart';
import '../state/providers.dart';
import '../state/settings.dart';
import '../state/task_providers.dart';
import '../state/attendance_providers.dart';
import 'admin_screen.dart';
import 'approvals_screen.dart';
import 'attendance_screen.dart';
import 'attendance_setup_screen.dart';
import 'attendance_team_screen.dart';
import 'announcements_view.dart';
import 'billing_format.dart';
import 'billing_screen.dart';
import 'invite_sheet.dart';
import 'join_link.dart';
import 'join_requests_screen.dart';
import 'members_screen.dart';
import 'modern.dart';
import 'start_screen.dart';
import 'widgets.dart';
import 'workspaces_screen.dart';

class MoreTab extends ConsumerWidget {
  const MoreTab({super.key, required this.membership});

  final Membership membership;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final profile = ref.watch(profileProvider).value;
    final settings = ref.watch(settingsProvider);
    final ws = membership.workspaceId;
    final canManage = membership.role.canManage;
    final members = ref.watch(membersProvider(ws)).value;
    final requests = canManage
        ? ref.watch(joinRequestsProvider(ws)).value
        : null;
    final invites = ref.watch(myInvitesProvider).value ?? const <MyInvite>[];
    final approvals = ref.watch(approvalsProvider(ws)).count;
    final attendance = ref.watch(attendanceTodayProvider(ws)).value;
    final attendanceOn = attendance?.enabled ?? false;

    void push(Widget screen) =>
        Navigator.of(context)
            .push(MaterialPageRoute<void>(builder: (_) => screen));

    final plan = planLabel(l, membership.planName);
    final platformAdmin = ref.watch(platformAdminProvider).value ?? false;
    final seats = members == null
        ? null
        : membership.maxMembers == null
        ? l.seatsUnlimited(members.length, plan)
        : l.seats(members.length, membership.maxMembers!, plan);

    return ListView(
      padding: EdgeInsets.fromLTRB(16, 4, 16, navClearance(context) + 88),
      children: [
        // Who is signed in.
        Card(
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 8,
            ),
            leading: Avatar(name: profile?.fullName ?? '', radius: 24),
            title: Text(
              profile?.fullName ?? '',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: LtrLine(profile?.email ?? profile?.phone ?? ''),
            trailing: IconButton(
              tooltip: l.editName,
              icon: const Icon(Icons.edit_outlined),
              onPressed: () async {
                final name = await promptText(
                  context,
                  title: l.editName,
                  label: l.fullNameLabel,
                  initial: profile?.fullName ?? '',
                );
                if (name == null || !context.mounted) return;
                final ok = await runAction(
                  context,
                  () => ref.read(apiProvider).updateProfile(fullName: name),
                );
                if (ok && context.mounted) ref.invalidate(profileProvider);
              },
            ),
          ),
        ),

        SectionTitle(l.workspaceSection),
        TileGroup(
          children: [
            ListTile(
              leading: Avatar(name: membership.workspaceName),
              title: Text(
                membership.workspaceName,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: seats == null ? null : Text(seats),
              trailing: Tag(roleLabel(l, membership.role), strong: true),
            ),
            if (canManage || (attendance?.isManager ?? false) || approvals > 0)
              ListTile(
                key: const Key('approvalsTile'),
                leading: const Icon(Icons.fact_check_outlined),
                title: Text(l.approvalsTitle),
                subtitle: Text(l.approvalsHint),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (approvals > 0) Badge(label: Text('$approvals')),
                    const Icon(Icons.chevron_right),
                  ],
                ),
                onTap: () => openApprovals(context, membership),
              ),
            ListTile(
              leading: const Icon(Icons.groups_outlined),
              title: Text(l.members),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => push(MembersScreen(membership: membership)),
            ),
            ListTile(
              leading: const Icon(Icons.campaign_outlined),
              title: Text(l.workspaceAnnouncements),
              trailing: const Icon(Icons.chevron_right),
              onTap: () =>
                  push(WorkspaceAnnouncementsScreen(membership: membership)),
            ),
            if (attendanceOn)
              ListTile(
                key: const Key('attendanceTile'),
                leading: const Icon(Icons.schedule_outlined),
                title: Text(l.attendance),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => openAttendance(context, membership),
              ),
            if (attendanceOn && attendance!.isManager)
              ListTile(
                key: const Key('teamAttendanceTile'),
                leading: const Icon(Icons.groups_2_outlined),
                title: Text(l.teamAttendance),
                subtitle: Text(l.teamAttendanceHint),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => openTeamAttendance(context, membership),
              ),
          ],
        ),

        // Running the workspace: who gets in and how it works.
        if (canManage || membership.isCompanyOwner) ...[
          SectionTitle(l.manageSection),
          TileGroup(
            children: [
              if (canManage) ...[
                ListTile(
                  leading: const Icon(Icons.person_add_alt_1_outlined),
                  title: Text(l.inviteMembers),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => showInviteSheet(context, membership),
                ),
                ListTile(
                  key: const Key('joinLinkTile'),
                  leading: const Icon(Icons.link),
                  title: Text(l.joinLinkTitle),
                  subtitle: Text(l.joinLinkHint),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => push(JoinLinkScreen(membership: membership)),
                ),
                ListTile(
                  leading: const Icon(Icons.how_to_reg_outlined),
                  title: Text(l.joinRequests),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (requests != null && requests.isNotEmpty)
                        Badge(label: Text('${requests.length}')),
                      const Icon(Icons.chevron_right),
                    ],
                  ),
                  onTap: () => push(JoinRequestsScreen(membership: membership)),
                ),
                ListTile(
                  key: const Key('attendanceSetupTile'),
                  leading: const Icon(Icons.more_time_outlined),
                  title: Text(l.attendanceSetup),
                  subtitle: attendanceOn ? null : Text(l.attendanceSetupHint),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => openAttendanceSetup(context, membership),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.travel_explore_outlined),
                  title: Text(l.discoverable),
                  subtitle: Text(l.discoverableHint),
                  value: membership.discoverable,
                  onChanged: (value) async {
                    final ok = await runAction(
                      context,
                      () => ref.read(apiProvider).setDiscoverable(ws, value),
                    );
                    if (ok && context.mounted) {
                      ref.invalidate(membershipsProvider);
                    }
                  },
                ),
                SwitchListTile(
                  key: const Key('allowSharing'),
                  secondary: const Icon(Icons.ios_share),
                  title: Text(l.allowSharing),
                  subtitle: Text(l.allowSharingHint),
                  value: membership.allowSharing,
                  onChanged: (value) async {
                    final ok = await runAction(
                      context,
                      () => ref.read(apiProvider).setAllowSharing(ws, value),
                    );
                    if (ok && context.mounted) {
                      ref.invalidate(membershipsProvider);
                    }
                  },
                ),
              ],
              if (membership.isCompanyOwner)
                ListTile(
                  leading: const Icon(Icons.workspace_premium_outlined),
                  title: Text(l.subscriptionTitle),
                  subtitle: Text(l.subscriptionHint(membership.companyName)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () =>
                      push(BillingScreen(companyId: membership.companyId)),
                ),
              if (membership.isCompanyOwner)
                ListTile(
                  leading: const Icon(Icons.add_business_outlined),
                  title: Text(l.newWorkspaceInCompany(membership.companyName)),
                  onTap: () async {
                    final name = await promptText(
                      context,
                      title: l.newWorkspaceTitle,
                      label: l.workspaceNameLabel,
                      action: l.create,
                    );
                    if (name == null || !context.mounted) return;
                    String? id;
                    final ok = await runAction(context, () async {
                      id = await ref
                          .read(apiProvider)
                          .createWorkspace(
                            companyId: membership.companyId,
                            name: name,
                          );
                    });
                    if (ok && context.mounted) {
                      await openWorkspace(context, ref, id!);
                    }
                  },
                ),
            ],
          ),
        ],

        SectionTitle(l.workspacesSection),
        TileGroup(
          children: [
            ListTile(
              key: const Key('manageWorkspaces'),
              leading: const Icon(Icons.tune),
              title: Text(l.manageWorkspaces),
              subtitle: Text(l.manageWorkspacesHint),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => push(const WorkspacesScreen()),
            ),
            ListTile(
              leading: const Icon(Icons.add_circle_outline),
              title: Text(l.addWorkspace),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (invites.isNotEmpty)
                    Badge(label: Text('${invites.length}')),
                  const Icon(Icons.chevron_right),
                ],
              ),
              onTap: () => push(const StartScreen(asPage: true)),
            ),
          ],
        ),

        if (platformAdmin) ...[
          SectionTitle(l.platformSection),
          TileGroup(
            children: [
              ListTile(
                leading: const Icon(Icons.admin_panel_settings_outlined),
                title: Text(l.adminTitle),
                subtitle: Text(l.adminHint),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => push(const AdminScreen()),
              ),
            ],
          ),
        ],

        if (ref.watch(googleAccountProvider).available) ...[
          SectionTitle(l.googleSection),
          const _GoogleCard(),
        ],
        SectionTitle(l.settingsSection),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.appearance, style: theme.textTheme.labelLarge),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<ThemeMode>(
                    showSelectedIcon: false,
                    segments: [
                      ButtonSegment(
                        value: ThemeMode.system,
                        label: Text(l.themeSystem),
                      ),
                      ButtonSegment(
                        value: ThemeMode.light,
                        label: Text(l.themeLight),
                      ),
                      ButtonSegment(
                        value: ThemeMode.dark,
                        label: Text(l.themeDark),
                      ),
                    ],
                    selected: {settings.themeMode},
                    onSelectionChanged: (s) {
                      ref.read(settingsProvider.notifier).setThemeMode(s.first);
                      _remember(ref, theme: s.first.name);
                    },
                  ),
                ),
                const SizedBox(height: 16),
                Text(l.language, style: theme.textTheme.labelLarge),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 'ar', label: Text('العربية')),
                      ButtonSegment(value: 'en', label: Text('English')),
                    ],
                    selected: {settings.locale.languageCode},
                    onSelectionChanged: (s) {
                      ref
                          .read(settingsProvider.notifier)
                          .setLocale(Locale(s.first));
                      _remember(ref, locale: s.first);
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: ListTile(
            leading: Icon(Icons.logout, color: theme.colorScheme.error),
            title: Text(
              l.signOut,
              style: TextStyle(color: theme.colorScheme.error),
            ),
            onTap: () async {
              final yes = await confirm(
                context,
                message: l.signOutConfirm,
                action: l.signOut,
                destructive: true,
              );
              if (yes) await signOut(ref);
            },
          ),
        ),
      ],
    );
  }

  /// Also keeps the choice on the account; failing that is harmless.
  void _remember(WidgetRef ref, {String? theme, String? locale}) {
    ref
        .read(apiProvider)
        .updateProfile(theme: theme, locale: locale)
        .catchError((_) {});
  }
}

/// The person's own Google account: tasks in their calendar. Saving files to
/// Drive is offered on each file.
class _GoogleCard extends ConsumerWidget {
  const _GoogleCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final calendar = ref.watch(calendarProvider);
    final notifier = ref.read(calendarProvider.notifier);
    return Card(
      child: Column(
        children: [
          SwitchListTile(
            key: const Key('calendarAuto'),
            secondary: const Icon(Icons.calendar_month_outlined),
            title: Text(l.googleCalendarAuto),
            subtitle: Text(l.googleCalendarAutoHint),
            value: calendar.auto,
            onChanged: (on) => runAction(context, () async {
              final tasks = on
                  ? await ref.read(myTasksProvider.future)
                  : const <Never>[];
              if (!await notifier.setAuto(on, tasks)) {
                throw const GoogleNotConnected();
              }
            }),
          ),
          ListTile(
            key: const Key('googleDisconnect'),
            leading: const Icon(Icons.link_off),
            title: Text(l.googleDisconnect),
            onTap: () => runAction(context, () async {
              await notifier.forget();
              await ref.read(googleAccountProvider).disconnect();
            }, done: l.googleDisconnected),
          ),
        ],
      ),
    );
  }
}
