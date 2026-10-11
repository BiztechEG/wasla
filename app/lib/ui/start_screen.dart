import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../push/push.dart';
import '../state/providers.dart';
import 'create_workspace_screen.dart';
import 'search_screen.dart';
import 'widgets.dart';

/// Where someone lands with no workspace yet, and where anyone goes to add
/// one: answer invitations, follow up on requests, create or find a workspace.
class StartScreen extends ConsumerWidget {
  const StartScreen({super.key, this.asPage = false});

  /// True when opened from inside the app rather than as the first screen.
  final bool asPage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final invites = ref.watch(myInvitesProvider);
    final requests = ref.watch(myJoinRequestsProvider);
    final email = ref.watch(profileProvider).value?.email;

    Future<void> refresh() async {
      ref.invalidate(myInvitesProvider);
      ref.invalidate(myJoinRequestsProvider);
      // An admin may have accepted a request meanwhile.
      ref.invalidate(membershipsProvider);
      await ref.read(myInvitesProvider.future);
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(asPage ? l.addWorkspace : l.appName),
        actions: [
          if (!asPage)
            IconButton(
              tooltip: l.signOut,
              icon: const Icon(Icons.logout),
              onPressed: () async {
                if (await confirm(
                  context,
                  message: l.signOutConfirm,
                  action: l.signOut,
                  destructive: true,
                )) {
                  await signOut(ref);
                }
              },
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            if (!asPage) ...[
              const SizedBox(height: 12),
              Text(
                l.startTitle,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                l.startSubtitle,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            ...switch (invites) {
              AsyncData(value: final list) when list.isNotEmpty => [
                SectionTitle(l.invitesSection),
                for (final invite in list) _InviteCard(invite: invite),
              ],
              AsyncError(:final error) => [
                const SizedBox(height: 16),
                ErrorView(
                  error: error,
                  onRetry: () => ref.invalidate(myInvitesProvider),
                ),
              ],
              _ => const <Widget>[],
            },
            if (requests.value case final list? when list.isNotEmpty) ...[
              SectionTitle(l.myRequestsSection),
              TileGroup(
                children: [
                  for (final r in list)
                    ListTile(
                      leading: const Icon(Icons.hourglass_top_outlined),
                      title: Text(r.workspaceName),
                      subtitle: Text(l.waitingForAdmin),
                      trailing: TextButton(
                        onPressed: () async {
                          final ok = await runAction(
                            context,
                            () => ref.read(apiProvider).cancelJoinRequest(r.id),
                          );
                          if (ok && context.mounted) {
                            ref.invalidate(myJoinRequestsProvider);
                          }
                        },
                        child: Text(l.withdraw),
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 20),
            _ActionCard(
              icon: Icons.add_business_outlined,
              title: l.createWorkspaceAction,
              body: l.createWorkspaceHint,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const CreateWorkspaceScreen(),
                ),
              ),
            ),
            const SizedBox(height: 12),
            _ActionCard(
              icon: Icons.search,
              title: l.findWorkspaceAction,
              body: l.findWorkspaceHint,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const SearchScreen()),
              ),
            ),
            if (invites.value?.isEmpty ?? false) ...[
              const SizedBox(height: 24),
              Text(
                l.noInvitesHint,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (email != null) ...[
                const SizedBox(height: 4),
                Text(
                  l.signedInAs(ltr(email)),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

/// Opens [workspaceId] once the membership list has caught up.
Future<void> openWorkspace(
  BuildContext context,
  WidgetRef ref,
  String workspaceId,
) async {
  await ref.read(currentWorkspaceIdProvider.notifier).select(workspaceId);
  ref.invalidate(membershipsProvider);
  if (context.mounted) {
    Navigator.of(context).popUntil((route) => route.isFirst);
  }
}

class _InviteCard extends ConsumerWidget {
  const _InviteCard({required this.invite});

  final MyInvite invite;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Avatar(name: invite.workspaceName),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          invite.workspaceName,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          l.invitedBy(
                            invite.invitedByName,
                            roleLabel(l, invite.role),
                          ),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: BusyButton(
                      label: l.accept,
                      onPressed: () async {
                        String? workspaceId;
                        final ok = await runAction(context, () async {
                          workspaceId = await ref
                              .read(apiProvider)
                              .acceptInvite(invite.token);
                        });
                        if (!context.mounted) return;
                        ref.invalidate(myInvitesProvider);
                        if (ok) await openWorkspace(context, ref, workspaceId!);
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () async {
                        if (!await confirm(
                          context,
                          message: l.confirmDeclineInvite(invite.workspaceName),
                          action: l.decline,
                          destructive: true,
                        )) {
                          return;
                        }
                        if (!context.mounted) return;
                        await runAction(
                          context,
                          () =>
                              ref.read(apiProvider).declineInvite(invite.token),
                        );
                        if (context.mounted) ref.invalidate(myInvitesProvider);
                      },
                      child: Text(l.decline),
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

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.icon,
    required this.title,
    required this.body,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String body;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Icon(icon, color: theme.colorScheme.primary),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      body,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
