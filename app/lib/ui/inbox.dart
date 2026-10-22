import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../config.dart';
import '../data/models.dart';
import '../state/chat_providers.dart';
import '../state/providers.dart';
import '../state/task_providers.dart';
import 'join_requests_screen.dart';
import 'start_screen.dart';
import 'widgets.dart';

// Answering invitations and requests to join, from wherever they show up:
// the start page, the bell, the banner on the home screen and the
// workspace switcher. Each answer works the same everywhere.

/// Hands [text] to the share sheet, or copies it where there is none.
Future<void> shareText(BuildContext context, WidgetRef ref, String text) async {
  final l = context.l10n;
  if (await ref.read(sharerProvider).share(text: text) || !context.mounted) {
    return;
  }
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) showMessage(context, l.shareUnavailableCopied);
}

/// Where people get the app, for invitations sent outside it: the site the
/// app was built for, or in a browser the site it is served from.
String? siteLink() {
  if (AppConfig.siteUrl.isNotEmpty) return AppConfig.siteUrl;
  if (kIsWeb && Uri.base.hasScheme && Uri.base.scheme.startsWith('http')) {
    return Uri.base.origin;
  }
  return null;
}

/// What an admin sends someone they invited, so they know to sign in.
String inviteMessage(BuildContext context, String workspace, String email) {
  final l = context.l10n;
  final link = siteLink();
  return [
    l.inviteShareText(workspace, email),
    if (link != null) l.inviteShareLink(link),
  ].join('\n');
}

/// Joins the workspace and opens it.
Future<void> acceptInvite(
  BuildContext context,
  WidgetRef ref,
  MyInvite invite,
) async {
  String? workspaceId;
  final ok = await runAction(context, () async {
    workspaceId = await ref.read(apiProvider).acceptInvite(invite.token);
  });
  if (!context.mounted) return;
  ref.invalidate(myInvitesProvider);
  ref.invalidate(notificationsProvider);
  if (ok) await openWorkspace(context, ref, workspaceId!);
}

Future<void> declineInvite(
  BuildContext context,
  WidgetRef ref,
  MyInvite invite,
) async {
  final l = context.l10n;
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
    () => ref.read(apiProvider).declineInvite(invite.token),
  );
  if (!context.mounted) return;
  ref.invalidate(myInvitesProvider);
  ref.invalidate(notificationsProvider);
}

/// An admin's answer to someone asking to join; declining asks first.
Future<void> answerJoinRequest(
  BuildContext context,
  WidgetRef ref, {
  required String workspaceId,
  required String requestId,
  required bool accept,
}) async {
  final l = context.l10n;
  if (!accept &&
      !await confirm(
        context,
        message: l.confirmDecline,
        action: l.decline,
        destructive: true,
      )) {
    return;
  }
  if (!context.mounted) return;
  final ok = await runAction(
    context,
    () => ref.read(apiProvider).decideJoinRequest(requestId, accept: accept),
  );
  if (!context.mounted) return;
  ref.invalidate(notificationsProvider);
  if (ok) {
    ref.invalidate(joinRequestsProvider(workspaceId));
    ref.invalidate(membersProvider(workspaceId));
  }
}

/// Accept and Decline side by side, Accept first.
class AnswerButtons extends StatelessWidget {
  const AnswerButtons({
    super.key,
    required this.onAccept,
    required this.onDecline,
  });

  final Future<void> Function() onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Row(
      children: [
        Expanded(
          child: BusyButton(label: l.accept, onPressed: onAccept),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: OutlinedButton(onPressed: onDecline, child: Text(l.decline)),
        ),
      ],
    );
  }
}

/// An invitation: which workspace, who sent it and as what, and the answer.
class InviteCard extends ConsumerWidget {
  const InviteCard({super.key, required this.invite});

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
              AnswerButtons(
                onAccept: () => acceptInvite(context, ref, invite),
                onDecline: () => declineInvite(context, ref, invite),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Banners put away with "Later", until the app is opened again.
class DismissedBanners extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void dismiss(Iterable<String> keys) => state = {...state, ...keys};
}

final dismissedBannersProvider =
    NotifierProvider<DismissedBanners, Set<String>>(DismissedBanners.new);

/// On the home screen, what waits for an answer from me: invitations to
/// other workspaces, then (for admins) people asking to join this one. One
/// banner at a time, each with its next step on it.
class PendingBanner extends ConsumerWidget {
  const PendingBanner({super.key, required this.membership});

  final Membership membership;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final dismissed = ref.watch(dismissedBannersProvider);
    final mine = {
      for (final m in ref.watch(membershipsProvider).value ?? <Membership>[])
        m.workspaceId,
    };
    final invites = [
      for (final i in ref.watch(myInvitesProvider).value ?? <MyInvite>[])
        if (!mine.contains(i.workspaceId) && !dismissed.contains(i.token)) i,
    ];
    final ws = membership.workspaceId;
    final requests = membership.role.canManage
        ? [
            for (final r
                in ref.watch(joinRequestsProvider(ws)).value ?? <JoinRequest>[])
              if (!dismissed.contains(r.id)) r,
          ]
        : const <JoinRequest>[];

    void later(Iterable<String> keys) =>
        ref.read(dismissedBannersProvider.notifier).dismiss(keys);
    void push(Widget screen) =>
        Navigator.of(context)
            .push(MaterialPageRoute<void>(builder: (_) => screen));

    final Widget? banner;
    if (invites.length == 1) {
      final invite = invites.single;
      banner = _Banner(
        key: const Key('inviteBanner'),
        icon: LucideIcons.mailPlus,
        text: l.bannerInvite(invite.invitedByName, invite.workspaceName),
        action: l.accept,
        onAction: () => acceptInvite(context, ref, invite),
        onLater: () => later([invite.token]),
      );
    } else if (invites.isNotEmpty) {
      banner = _Banner(
        key: const Key('inviteBanner'),
        icon: LucideIcons.mailPlus,
        text: l.bannerInvites(invites.length),
        action: l.view,
        onAction: () async => push(const StartScreen(asPage: true)),
        onLater: () => later(invites.map((i) => i.token)),
      );
    } else if (requests.isNotEmpty) {
      banner = _Banner(
        key: const Key('joinRequestsBanner'),
        icon: LucideIcons.userPlus,
        text: l.bannerJoinRequests(requests.length),
        action: l.review,
        onAction: () async => push(JoinRequestsScreen(membership: membership)),
        onLater: () => later(requests.map((r) => r.id)),
      );
    } else {
      banner = null;
    }

    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      alignment: AlignmentDirectional.topCenter,
      child: banner == null
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: banner,
            ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    super.key,
    required this.icon,
    required this.text,
    required this.action,
    required this.onAction,
    required this.onLater,
  });

  final IconData icon;
  final String text;
  final String action;
  final Future<void> Function() onAction;
  final VoidCallback onLater;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsetsDirectional.fromSTEB(14, 12, 8, 6),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: scheme.primary,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(icon, size: 18, color: scheme.onPrimary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    text,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: onLater, child: Text(l.later)),
              const SizedBox(width: 4),
              _BusyTonal(label: action, onPressed: onAction),
            ],
          ),
        ],
      ),
    );
  }
}

/// A tonal button that shows a spinner while its action runs.
class _BusyTonal extends StatefulWidget {
  const _BusyTonal({required this.label, required this.onPressed});

  final String label;
  final Future<void> Function() onPressed;

  @override
  State<_BusyTonal> createState() => _BusyTonalState();
}

class _BusyTonalState extends State<_BusyTonal> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
      onPressed: _busy
          ? null
          : () async {
              setState(() => _busy = true);
              try {
                await widget.onPressed();
              } finally {
                if (mounted) setState(() => _busy = false);
              }
            },
      child: _busy
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(widget.label),
    );
  }
}
