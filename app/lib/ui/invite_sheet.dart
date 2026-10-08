import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../state/providers.dart';
import 'widgets.dart';

Future<void> showInviteSheet(BuildContext context, Membership membership) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => InviteSheet(membership: membership),
    );

/// Invites someone by email, with a role and optionally straight into
/// projects. They see it in the app when they sign in with that email.
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
    final l = context.l10n;
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
      done: l.inviteSent(ltr(email)),
    );
    if (ok && mounted) {
      ref.invalidate(sentInvitesProvider(ws));
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
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
                        label: Text(p.name),
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
