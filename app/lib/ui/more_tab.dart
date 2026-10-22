import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/models.dart';
import '../state/billing_providers.dart';
import '../state/providers.dart';
import '../state/attendance_providers.dart';
import 'account_screen.dart';
import 'admin_screen.dart';
import 'approvals_screen.dart';
import 'attendance_screen.dart';
import 'attendance_setup_screen.dart';
import 'attendance_team_screen.dart';
import 'announcements_view.dart';
import 'billing_format.dart';
import 'billing_screen.dart';
import 'dashboard_screen.dart';
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
        // Who is signed in; their own settings are one tap away.
        Card(
          child: ListTile(
            key: const Key('accountTile'),
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
            subtitle: Text(l.myAccountHint),
            trailing: const Icon(LucideIcons.chevronRightDir),
            onTap: () => openAccount(context),
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
                leading: const Icon(LucideIcons.clipboardCheck),
                title: Text(l.approvalsTitle),
                subtitle: Text(l.approvalsHint),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (approvals > 0) Badge(label: Text('$approvals')),
                    const Icon(LucideIcons.chevronRightDir),
                  ],
                ),
                onTap: () => openApprovals(context, membership),
              ),
            ListTile(
              leading: const Icon(LucideIcons.users),
              title: Text(l.members),
              trailing: const Icon(LucideIcons.chevronRightDir),
              onTap: () => push(MembersScreen(membership: membership)),
            ),
            ListTile(
              leading: const Icon(LucideIcons.megaphone),
              title: Text(l.workspaceAnnouncements),
              trailing: const Icon(LucideIcons.chevronRightDir),
              onTap: () =>
                  push(WorkspaceAnnouncementsScreen(membership: membership)),
            ),
            if (attendanceOn)
              ListTile(
                key: const Key('attendanceTile'),
                leading: const Icon(LucideIcons.clock),
                title: Text(l.attendance),
                trailing: const Icon(LucideIcons.chevronRightDir),
                onTap: () => openAttendance(context, membership),
              ),
            if (attendanceOn && attendance!.isManager)
              ListTile(
                key: const Key('teamAttendanceTile'),
                leading: const Icon(LucideIcons.users),
                title: Text(l.teamAttendance),
                subtitle: Text(l.teamAttendanceHint),
                trailing: const Icon(LucideIcons.chevronRightDir),
                onTap: () => openTeamAttendance(context, membership),
              ),
          ],
        ),

        // Running the workspace: who gets in and how it works.
        if (canManage || membership.isCompanyOwner) ...[
          SectionTitle(l.manageSection),
          TileGroup(
            children: [
              ListTile(
                key: const Key('dashboardTile'),
                leading: const Icon(LucideIcons.chartLine),
                title: Text(l.dashboardTitle),
                subtitle: Text(l.dashboardHint),
                trailing: const Icon(LucideIcons.chevronRightDir),
                onTap: () => push(const DashboardScreen()),
              ),
              if (canManage) ...[
                ListTile(
                  leading: const Icon(LucideIcons.userPlus),
                  title: Text(l.inviteMembers),
                  trailing: const Icon(LucideIcons.chevronRightDir),
                  onTap: () => showInviteSheet(context, membership),
                ),
                ListTile(
                  key: const Key('joinLinkTile'),
                  leading: const Icon(LucideIcons.link),
                  title: Text(l.joinLinkTitle),
                  subtitle: Text(l.joinLinkHint),
                  trailing: const Icon(LucideIcons.chevronRightDir),
                  onTap: () => push(JoinLinkScreen(membership: membership)),
                ),
                ListTile(
                  leading: const Icon(LucideIcons.userCheck),
                  title: Text(l.joinRequests),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (requests != null && requests.isNotEmpty)
                        Badge(label: Text('${requests.length}')),
                      const Icon(LucideIcons.chevronRightDir),
                    ],
                  ),
                  onTap: () => push(JoinRequestsScreen(membership: membership)),
                ),
                ListTile(
                  key: const Key('attendanceSetupTile'),
                  leading: const Icon(LucideIcons.clockPlus),
                  title: Text(l.attendanceSetup),
                  subtitle: attendanceOn ? null : Text(l.attendanceSetupHint),
                  trailing: const Icon(LucideIcons.chevronRightDir),
                  onTap: () => openAttendanceSetup(context, membership),
                ),
                SwitchListTile(
                  secondary: const Icon(LucideIcons.telescope),
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
                  secondary: const Icon(LucideIcons.share),
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
                  leading: const Icon(LucideIcons.crown),
                  title: Text(l.subscriptionTitle),
                  subtitle: Text(l.subscriptionHint(membership.companyName)),
                  trailing: const Icon(LucideIcons.chevronRightDir),
                  onTap: () =>
                      push(BillingScreen(companyId: membership.companyId)),
                ),
              if (membership.isCompanyOwner)
                ListTile(
                  leading: const Icon(LucideIcons.building2),
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
              leading: const Icon(LucideIcons.slidersHorizontal),
              title: Text(l.manageWorkspaces),
              subtitle: Text(l.manageWorkspacesHint),
              trailing: const Icon(LucideIcons.chevronRightDir),
              onTap: () => push(const WorkspacesScreen()),
            ),
            ListTile(
              leading: const Icon(LucideIcons.circlePlus),
              title: Text(l.addWorkspace),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (invites.isNotEmpty)
                    Badge(label: Text('${invites.length}')),
                  const Icon(LucideIcons.chevronRightDir),
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
                leading: const Icon(LucideIcons.shieldUser),
                title: Text(l.adminTitle),
                subtitle: Text(l.adminHint),
                trailing: const Icon(LucideIcons.chevronRightDir),
                onTap: () => push(const AdminScreen()),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
