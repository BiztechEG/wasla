import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../state/providers.dart';
import 'inbox.dart';
import 'invite_sheet.dart';
import 'profile_card.dart';
import 'widgets.dart';

import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Everyone in the workspace. Admins change roles, remove people and see
/// invitations nobody has answered yet.
class MembersScreen extends ConsumerWidget {
  const MembersScreen({super.key, required this.membership});

  final Membership membership;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final ws = membership.workspaceId;
    final me = ref.watch(authProvider).value;
    final canManage = membership.role.canManage;
    final members = ref.watch(membersProvider(ws));
    final invites = canManage ? ref.watch(sentInvitesProvider(ws)).value : null;

    return Scaffold(
      appBar: AppBar(title: Text(l.members)),
      floatingActionButton: canManage
          ? FloatingActionButton.extended(
              heroTag: 'invite',
              onPressed: () => showInviteSheet(context, membership),
              icon: const Icon(LucideIcons.userPlus),
              label: Text(l.inviteMembers),
            )
          : null,
      body: AsyncView(
        value: members,
        onRetry: () => ref.invalidate(membersProvider(ws)),
        builder: (list) => RefreshIndicator(
          onRefresh: () {
            ref.invalidate(sentInvitesProvider(ws));
            return ref.refresh(membersProvider(ws).future);
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
            children: [
              SectionTitle(l.memberCount(list.length)),
              TileGroup(
                children: [
                  for (final m in list)
                    PersonTile(
                      name: m.userId == me
                          ? '${m.fullName} (${l.you})'
                          : m.fullName,
                      avatarName: m.fullName,
                      contact: m.contact,
                      tag: roleLabel(l, m.role),
                      strongTag: m.role != WorkspaceRole.member,
                      trailing: _canChange(m, me)
                          ? IconButton(
                              tooltip: l.moreActions,
                              icon: const Icon(LucideIcons.ellipsisVertical),
                              onPressed: () => _showActions(context, ref, m),
                            )
                          : null,
                      onTap: m.userId == me
                          ? null
                          : () => showProfileCard(
                              context,
                              ref,
                              membership: membership,
                              userId: m.userId,
                              name: m.fullName,
                            ),
                    ),
                ],
              ),
              if (invites != null && invites.isNotEmpty) ...[
                SectionTitle(l.pendingInvites),
                TileGroup(
                  children: [
                    for (final invite in invites)
                      ListTile(
                        leading: const CircleAvatar(
                          child: Icon(LucideIcons.mail, size: 20),
                        ),
                        title: LtrLine(invite.contact),
                        subtitle: Text(roleLabel(l, invite.role)),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (invite.email != null)
                              IconButton(
                                tooltip: l.shareInvite,
                                icon: const Icon(LucideIcons.sendHorizontalDir),
                                onPressed: () => shareText(
                                  context,
                                  ref,
                                  inviteMessage(
                                    context,
                                    membership.workspaceName,
                                    invite.email!,
                                  ),
                                ),
                              ),
                            IconButton(
                              tooltip: l.cancelInvite,
                              icon: const Icon(LucideIcons.x),
                              onPressed: () async {
                                final ok = await runAction(
                                  context,
                                  () => ref
                                      .read(apiProvider)
                                      .cancelInvite(invite.id),
                                );
                                if (ok && context.mounted) {
                                  ref.invalidate(sentInvitesProvider(ws));
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Admins manage everyone but themselves; only an owner touches owners.
  bool _canChange(Member m, String? me) {
    if (!membership.role.canManage || m.userId == me) return false;
    return m.role != WorkspaceRole.owner ||
        membership.role == WorkspaceRole.owner;
  }

  Future<void> _showActions(
    BuildContext context,
    WidgetRef ref,
    Member member,
  ) async {
    final l = context.l10n;
    final ws = membership.workspaceId;
    final roles = [
      if (membership.role == WorkspaceRole.owner) WorkspaceRole.owner,
      WorkspaceRole.admin,
      WorkspaceRole.member,
    ];

    final choice = await showModalBottomSheet<Object>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Avatar(name: member.fullName),
                title: Text(
                  member.fullName,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: LtrLine(member.contact),
              ),
              const Divider(),
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(20, 8, 20, 0),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(l.changeRole),
                ),
              ),
              RadioGroup<WorkspaceRole>(
                groupValue: member.role,
                onChanged: (role) => Navigator.pop(context, role),
                child: Column(
                  children: [
                    for (final role in roles)
                      RadioListTile<WorkspaceRole>(
                        value: role,
                        title: Text(roleLabel(l, role)),
                      ),
                  ],
                ),
              ),
              const Divider(),
              ListTile(
                leading: Icon(
                  LucideIcons.userMinus,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: Text(
                  l.removeFromWorkspace,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                onTap: () => Navigator.pop(context, 'remove'),
              ),
            ],
          ),
        ),
      ),
    );
    if (choice == null || !context.mounted) return;

    final api = ref.read(apiProvider);
    if (choice is WorkspaceRole) {
      if (choice == member.role) return;
      if (choice == WorkspaceRole.owner &&
          !await confirm(
            context,
            message: l.confirmMakeOwner(member.fullName),
            action: l.continueAction,
          )) {
        return;
      }
      if (!context.mounted) return;
      final ok = await runAction(
        context,
        () => api.setMemberRole(ws, member.userId, choice),
        done: l.roleChanged(member.fullName, roleLabel(l, choice)),
      );
      if (ok && context.mounted) ref.invalidate(membersProvider(ws));
      return;
    }

    final yes = await confirm(
      context,
      message: l.removeMemberConfirm(member.fullName),
      action: l.remove,
      destructive: true,
    );
    if (!yes || !context.mounted) return;
    final ok = await runAction(
      context,
      () => api.removeMember(ws, member.userId),
    );
    if (ok && context.mounted) ref.invalidate(membersProvider(ws));
  }
}
