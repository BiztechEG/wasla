import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../state/providers.dart';
import 'inbox.dart';
import 'widgets.dart';

Future<void> showInviteSheet(BuildContext context, Membership membership) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => InviteSheet(membership: membership),
    );

/// Invites someone by email, with a role and optionally straight into
/// projects. They see it in the app when they sign in with that email, so
/// the sheet then offers to send them word through WhatsApp, email or any
/// other app.
class InviteSheet extends ConsumerStatefulWidget {
  const InviteSheet({super.key, required this.membership});

  final Membership membership;

  @override
  ConsumerState<InviteSheet> createState() => _InviteSheetState();
}

class _InviteSheetState extends ConsumerState<InviteSheet> {
  final _email = TextEditingController();
  final _form = GlobalKey<FormState>();
  WorkspaceRole _role = WorkspaceRole.member;
  final _projects = <String>{};

  static final _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (!_form.currentState!.validate()) return;
    final ws = widget.membership.workspaceId;
    final email = _email.text.trim().toLowerCase();
    final ok = await runAction(
      context,
      () => ref
          .read(apiProvider)
          .invite(
            ws,
            email: email,
            role: _role,
            projectIds: _projects.toList(),
          ),
    );
    if (ok && mounted) {
      ref.invalidate(sentInvitesProvider(ws));
      setState(() => _sentTo = email);
    }
  }

  /// Set once the invitation exists: the sheet then offers to send it.
  String? _sentTo;

  @override
  Widget build(BuildContext context) {
    final sentTo = _sentTo;
    if (sentTo != null) {
      return _InviteReady(
        workspace: widget.membership.workspaceName,
        email: sentTo,
      );
    }
    final l = context.l10n;
    final theme = Theme.of(context);
    final projects =
        ref
            .watch(projectsProvider(widget.membership.workspaceId))
            .value
            ?.where((p) => p.status == ProjectStatus.active)
            .toList() ??
        const <Project>[];

    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Form(
        key: _form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l.inviteTitle(widget.membership.workspaceName),
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                key: const Key('inviteEmail'),
                controller: _email,
                autofocus: true,
                keyboardType: TextInputType.emailAddress,
                textDirection: TextDirection.ltr,
                decoration: InputDecoration(
                  labelText: l.emailLabel,
                  helperText: l.inviteEmailHint,
                  helperMaxLines: 2,
                  prefixIcon: const Icon(Icons.mail_outline),
                ),
                validator: (v) => _emailPattern.hasMatch(v?.trim() ?? '')
                    ? null
                    : l.invalidEmail,
              ),
              const SizedBox(height: 16),
              Text(l.roleLabel, style: theme.textTheme.labelLarge),
              const SizedBox(height: 8),
              SegmentedButton<WorkspaceRole>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(
                    value: WorkspaceRole.member,
                    label: Text(l.roleMember),
                  ),
                  ButtonSegment(
                    value: WorkspaceRole.admin,
                    label: Text(l.roleAdmin),
                  ),
                ],
                selected: {_role},
                onSelectionChanged: (s) => setState(() => _role = s.first),
              ),
              if (projects.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(l.addToProjects, style: theme.textTheme.labelLarge),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final p in projects)
                      FilterChip(
                        avatar: ColorDot(hex: p.color),
                        label: Text(
                          p.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        selected: _projects.contains(p.id),
                        onSelected: (on) => setState(
                          () =>
                              on ? _projects.add(p.id) : _projects.remove(p.id),
                        ),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 24),
              BusyButton(label: l.sendInvite, onPressed: _send),
            ],
          ),
        ),
      ),
    );
  }
}

/// The invitation exists; nobody has told the person yet.
class _InviteReady extends ConsumerWidget {
  const _InviteReady({required this.workspace, required this.email});

  final String workspace;
  final String email;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: CircleAvatar(
                radius: 30,
                backgroundColor: scheme.primaryContainer,
                child: Icon(
                  Icons.mark_email_read_outlined,
                  size: 30,
                  color: scheme.primary,
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              l.inviteReadyTitle,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              l.inviteReadyBody(ltr(email)),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              key: const Key('shareInvite'),
              icon: const Icon(Icons.send_outlined, size: 18),
              label: Text(l.shareInvite),
              onPressed: () => shareText(
                context,
                ref,
                inviteMessage(context, workspace, email),
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l.done),
            ),
          ],
        ),
      ),
    );
  }
}
