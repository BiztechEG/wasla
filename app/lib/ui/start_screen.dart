import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../push/push.dart';
import '../state/providers.dart';
import '../state/task_providers.dart';
import 'create_workspace_screen.dart';
import 'inbox.dart';
import 'search_screen.dart';
import 'widgets.dart';

/// Where someone lands with no workspace yet, and where anyone goes to add
/// one: answer invitations, follow up on requests, join their team or start
/// a workspace for their company.
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

    // An admin's answer arrives as a notification; once someone is let in,
    // the app moves on to the workspace by itself.
    ref.listen(notificationEventsProvider, (_, _) {
      ref.invalidate(membershipsProvider);
    });

    final pending = requests.value ?? const <MyJoinRequest>[];
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
            // First what is waiting for an answer, then the ways in.
            ...switch (invites) {
              AsyncData(value: final list) when list.isNotEmpty => [
                SectionTitle(l.invitesSection),
                for (final invite in list) InviteCard(invite: invite),
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
            if (pending.isNotEmpty) ...[
              SectionTitle(l.myRequestsSection),
              TileGroup(
                children: [
                  for (final r in pending)
                    ListTile(
                      leading: const Icon(Icons.hourglass_top_outlined),
                      title: Text(r.workspaceName),
                      subtitle: Text(l.requestWaiting),
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
            _JoinTeamCard(email: email),
            SectionTitle(l.newCompanySection),
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
          ],
        ),
      ),
    );
  }
}

/// How an employee gets in: their admin invites this email, or they find
/// the workspace and ask. The email is right there to copy or send.
class _JoinTeamCard extends ConsumerWidget {
  const _JoinTeamCard({required this.email});

  final String? email;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final address = email;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 22,
                  backgroundColor: scheme.primaryContainer,
                  child: Icon(Icons.groups_outlined, color: scheme.primary),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    l.joinTeamTitle,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            if (address != null && address.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                l.joinTeamBody,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsetsDirectional.fromSTEB(14, 4, 4, 4),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: LtrLine(
                        address,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: l.copy,
                      icon: const Icon(Icons.copy_rounded, size: 20),
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: address));
                        if (context.mounted) showMessage(context, l.copied);
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              FilledButton.tonalIcon(
                icon: const Icon(Icons.send_outlined, size: 18),
                label: Text(l.sendMyEmail),
                onPressed: () =>
                    shareText(context, ref, l.myEmailShare(address)),
              ),
              const SizedBox(height: 8),
            ] else
              const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.search, size: 18),
              label: Text(l.orFindWorkspace),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const SearchScreen()),
              ),
            ),
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
