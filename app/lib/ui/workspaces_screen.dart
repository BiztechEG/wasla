import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/models.dart';
import '../state/providers.dart';
import 'billing_format.dart';
import 'start_screen.dart';
import 'widgets.dart';

/// Every workspace one belongs to: switch, rename, leave or delete each one,
/// and bring back one deleted in the last 30 days.
class WorkspacesScreen extends ConsumerWidget {
  const WorkspacesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final memberships = ref.watch(membershipsProvider);
    final current = ref.watch(currentMembershipProvider);
    final deleted = ref.watch(deletedWorkspacesProvider).value ?? const [];

    Future<void> refresh() async {
      ref.invalidate(deletedWorkspacesProvider);
      ref.invalidate(membershipsProvider);
      await ref.read(membershipsProvider.future);
    }

    return Scaffold(
      appBar: AppBar(title: Text(l.manageWorkspaces)),
      body: AsyncView(
        value: memberships,
        onRetry: () => ref.invalidate(membershipsProvider),
        builder: (list) => RefreshIndicator(
          onRefresh: refresh,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              if (list.isNotEmpty)
                TileGroup(
                  children: [
                    for (final m in list)
                      _WorkspaceTile(
                        membership: m,
                        current: m.workspaceId == current?.workspaceId,
                      ),
                  ],
                ),
              if (deleted.isNotEmpty) ...[
                SectionTitle(l.deletedWorkspaces),
                TileGroup(
                  children: [
                    for (final d in deleted) _DeletedTile(workspace: d),
                  ],
                ),
              ],
              const SizedBox(height: 20),
              OutlinedButton.icon(
                icon: const Icon(LucideIcons.plus, size: 18),
                label: Text(l.addWorkspace),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  textStyle: theme.textTheme.titleSmall,
                ),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const StartScreen(asPage: true),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The rounded square with a workspace's first letter, as in the top bar.
class WorkspaceMark extends StatelessWidget {
  const WorkspaceMark({super.key, required this.name, this.faded = false});

  final String name;
  final bool faded;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = name.trim();
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: faded ? scheme.surfaceContainerHighest : scheme.primary,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text.isEmpty ? '؟' : text.characters.first,
        style: TextStyle(
          color: faded ? scheme.onSurfaceVariant : scheme.onPrimary,
          fontWeight: FontWeight.w700,
          fontSize: 17,
        ),
      ),
    );
  }
}

class _WorkspaceTile extends StatelessWidget {
  const _WorkspaceTile({required this.membership, required this.current});

  final Membership membership;
  final bool current;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final m = membership;
    return ListTile(
      key: ValueKey('workspace-${m.workspaceId}'),
      contentPadding: const EdgeInsetsDirectional.fromSTEB(16, 4, 4, 4),
      leading: WorkspaceMark(name: m.workspaceName),
      title: Row(
        children: [
          Flexible(
            child: Text(
              m.workspaceName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          if (current) ...[
            const SizedBox(width: 8),
            Tag(l.currentWorkspace, strong: true),
          ],
        ],
      ),
      subtitle: Text(
        '${m.companyName} · ${roleLabel(l, m.role)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        tooltip: l.manageWorkspaces,
        icon: const Icon(LucideIcons.ellipsisVertical, size: 20),
        onPressed: () => _showActions(context, m, current: current),
      ),
      onTap: () => _showActions(context, m, current: current),
    );
  }
}

class _DeletedTile extends ConsumerWidget {
  const _DeletedTile({required this.workspace});

  final DeletedWorkspace workspace;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final w = workspace;
    return ListTile(
      contentPadding: const EdgeInsetsDirectional.fromSTEB(16, 4, 8, 4),
      leading: WorkspaceMark(name: w.name, faded: true),
      title: Text(w.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(l.deletedWorkspaceInfo(dateText(context, w.purgeAt))),
      trailing: TextButton.icon(
        icon: const Icon(LucideIcons.archiveRestore, size: 18),
        label: Text(l.restore),
        onPressed: () async {
          final ok = await runAction(
            context,
            () => ref.read(apiProvider).restoreWorkspace(w.id),
            done: l.workspaceRestored(w.name),
          );
          if (ok && context.mounted) {
            ref.invalidate(deletedWorkspacesProvider);
            ref.invalidate(membershipsProvider);
          }
        },
      ),
    );
  }
}

enum _Action { open, rename, leave, delete }

Future<void> _showActions(
  BuildContext context,
  Membership m, {
  required bool current,
}) async {
  final l = context.l10n;
  final scheme = Theme.of(context).colorScheme;
  // The tile goes away once the workspace does; these outlive it.
  final navigator = Navigator.of(context);
  final container = ProviderScope.containerOf(context);
  final api = container.read(apiProvider);
  final action = await showModalBottomSheet<_Action>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              m.workspaceName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          if (!current)
            ListTile(
              leading: const Icon(LucideIcons.arrowLeftRight),
              title: Text(l.switchToWorkspace),
              onTap: () => Navigator.pop(context, _Action.open),
            ),
          if (m.role.canManage)
            ListTile(
              leading: const Icon(LucideIcons.pencil),
              title: Text(l.renameWorkspace),
              onTap: () => Navigator.pop(context, _Action.rename),
            ),
          ListTile(
            leading: const Icon(LucideIcons.logOut),
            title: Text(l.leaveWorkspace),
            onTap: () => Navigator.pop(context, _Action.leave),
          ),
          if (m.canDelete)
            ListTile(
              leading: Icon(LucideIcons.trash2, color: scheme.error),
              title: Text(
                l.deleteWorkspace,
                style: TextStyle(color: scheme.error),
              ),
              onTap: () => Navigator.pop(context, _Action.delete),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (action == null || !context.mounted) return;
  switch (action) {
    case _Action.open:
      await container
          .read(currentWorkspaceIdProvider.notifier)
          .select(m.workspaceId);
      navigator.pop();
    case _Action.rename:
      final name = await promptText(
        context,
        title: l.renameWorkspace,
        label: l.workspaceNameLabel,
        initial: m.workspaceName,
      );
      if (name == null || name == m.workspaceName || !context.mounted) return;
      final ok = await runAction(
        context,
        () => api.renameWorkspace(m.workspaceId, name),
        done: l.workspaceRenamed,
      );
      if (ok) container.invalidate(membershipsProvider);
    case _Action.leave:
      final yes = await confirm(
        context,
        message: l.leaveWorkspaceConfirm(m.workspaceName),
        action: l.leave,
        destructive: true,
      );
      if (!yes || !context.mounted) return;
      final ok = await runAction(
        context,
        () => api.leaveWorkspace(m.workspaceId),
        done: l.youLeftWorkspace(m.workspaceName),
      );
      if (ok) await _afterGone(navigator, container);
    case _Action.delete:
      final typed = await showDialog<String>(
        context: context,
        builder: (_) => _DeleteDialog(name: m.workspaceName),
      );
      if (typed == null || !context.mounted) return;
      final ok = await runAction(
        context,
        () => api.deleteWorkspace(m.workspaceId, typed),
        done: l.workspaceDeleted(m.workspaceName),
      );
      if (ok) {
        container.invalidate(deletedWorkspacesProvider);
        await _afterGone(navigator, container);
      }
  }
}

/// With no workspace left, the app goes back to its start page.
Future<void> _afterGone(
  NavigatorState navigator,
  ProviderContainer container,
) async {
  final left = await container.refresh(membershipsProvider.future);
  if (left.isEmpty && navigator.mounted) {
    navigator.popUntil((route) => route.isFirst);
  }
}

/// Deleting asks for the workspace's name, so it never happens by a slip.
class _DeleteDialog extends StatefulWidget {
  const _DeleteDialog({required this.name});

  final String name;

  @override
  State<_DeleteDialog> createState() => _DeleteDialogState();
}

class _DeleteDialogState extends State<_DeleteDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _matches => _controller.text.trim() == widget.name.trim();

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return AlertDialog(
      icon: Icon(LucideIcons.trash2, color: scheme.error),
      title: Text(l.deleteWorkspace),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.deleteWorkspaceWarning(widget.name)),
            const SizedBox(height: 16),
            Text(l.deleteWorkspaceType, style: theme.textTheme.labelLarge),
            const SizedBox(height: 4),
            Text(
              widget.name,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('deleteConfirmName'),
              controller: _controller,
              autofocus: true,
              inputFormatters: nameLimit,
              decoration: InputDecoration(hintText: widget.name),
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.cancel),
        ),
        FilledButton(
          key: const Key('deleteWorkspaceButton'),
          style: FilledButton.styleFrom(
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
          ),
          onPressed: _matches
              ? () => Navigator.pop(context, _controller.text.trim())
              : null,
          child: Text(l.deleteForGood),
        ),
      ],
    );
  }
}
