import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/chat_models.dart';
import '../data/models.dart';
import '../state/chat_providers.dart';
import '../state/providers.dart';
import 'chat_format.dart';
import 'widgets.dart';

/// Shows an unread announcement from the chat list and marks it read.
Future<void> showAnnouncement(
  BuildContext context,
  WidgetRef ref, {
  required String workspaceId,
  required UnreadAnnouncement note,
}) async {
  final l = context.l10n;
  final theme = Theme.of(context);
  ref
      .read(apiProvider)
      .markAnnouncementsRead([note.id])
      .then((_) => ref.invalidate(unreadAnnouncementsProvider(workspaceId)))
      .catchError((Object _) {});
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (note.projectColor != null) ...[
                  ColorDot(hex: note.projectColor!),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    note.projectName == null
                        ? l.announcementForAll
                        : l.announcementFor(note.projectName!),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${note.authorName} · ${listTime(context, note.createdAt)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            SelectableText(note.body, style: theme.textTheme.bodyLarge),
          ],
        ),
      ),
    ),
  );
}

/// A project's or the whole workspace's announcements.
class AnnouncementsView extends ConsumerStatefulWidget {
  const AnnouncementsView({
    super.key,
    required this.workspaceId,
    required this.canPost,
    this.projectId,
    this.readOnly = false,
  });

  final String workspaceId;
  final String? projectId;
  final bool canPost;

  /// True for a closed or archived project.
  final bool readOnly;

  @override
  ConsumerState<AnnouncementsView> createState() => _AnnouncementsViewState();
}

class _AnnouncementsViewState extends ConsumerState<AnnouncementsView> {
  final _marked = <String>{};

  AnnouncementScope get _scope =>
      (workspaceId: widget.workspaceId, projectId: widget.projectId);

  /// Opening the list counts as reading what is in it.
  void _markRead(List<Announcement> list) {
    final ids = [
      for (final a in list)
        if (!a.readByMe && !_marked.contains(a.id)) a.id,
    ];
    if (ids.isEmpty) return;
    _marked.addAll(ids);
    ref
        .read(apiProvider)
        .markAnnouncementsRead(ids)
        .then(
          (_) =>
              ref.invalidate(unreadAnnouncementsProvider(widget.workspaceId)),
        )
        .catchError((Object _) {});
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final me = ref.watch(authProvider).value;
    final list = ref.watch(announcementsProvider(_scope));
    final canPost = widget.canPost && !widget.readOnly;

    return AsyncView(
      value: list,
      onRetry: () => ref.invalidate(announcementsProvider(_scope)),
      builder: (items) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _markRead(items);
        });
        return RefreshIndicator(
          onRefresh: () => ref.refresh(announcementsProvider(_scope).future),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              if (canPost)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: FilledButton.tonalIcon(
                    onPressed: () => _compose(context),
                    icon: const Icon(Icons.campaign_outlined),
                    label: Text(l.newAnnouncement),
                  ),
                ),
              if (items.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 40),
                  child: EmptyState(
                    icon: Icons.campaign_outlined,
                    title: l.announcementsEmpty,
                    body: canPost
                        ? (widget.projectId == null
                              ? l.workspaceAnnouncementsHint
                              : l.projectAnnouncementsHint)
                        : null,
                  ),
                ),
              for (final a in items)
                _AnnouncementCard(
                  announcement: a,
                  showReads: widget.canPost || a.authorId == me,
                  canManage: widget.canPost,
                  canDelete: widget.canPost || a.authorId == me,
                  onChanged: () =>
                      ref.invalidate(announcementsProvider(_scope)),
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _compose(BuildContext context) async {
    final posted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ComposeSheet(scope: _scope),
    );
    if (mounted && (posted ?? false)) {
      ref.invalidate(announcementsProvider(_scope));
    }
  }
}

class _AnnouncementCard extends ConsumerWidget {
  const _AnnouncementCard({
    required this.announcement,
    required this.showReads,
    required this.canManage,
    required this.canDelete,
    required this.onChanged,
  });

  final Announcement announcement;
  final bool showReads;
  final bool canManage;
  final bool canDelete;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final a = announcement;
    final pinnedColor = theme.brightness == Brightness.dark
        ? const Color(0xFFF0A35E)
        : const Color(0xFF8A4806);

    return Card(
      margin: const EdgeInsets.only(top: 12),
      color: a.pinned
          ? pinnedColor.withValues(alpha: 0.10)
          : theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 4, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (a.pinned) ...[
                  Icon(Icons.push_pin, size: 16, color: pinnedColor),
                  const SizedBox(width: 4),
                ],
                Expanded(
                  child: Text(
                    a.pinned ? '${l.pinned} · ${a.authorName}' : a.authorName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: a.pinned ? pinnedColor : null,
                    ),
                  ),
                ),
                Text(
                  listTime(context, a.createdAt),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (canManage || canDelete)
                  PopupMenuButton<String>(
                    onSelected: (action) => _act(context, ref, action),
                    itemBuilder: (_) => [
                      if (canManage)
                        PopupMenuItem(
                          value: 'pin',
                          child: Text(a.pinned ? l.unpin : l.pin),
                        ),
                      PopupMenuItem(value: 'copy', child: Text(l.copy)),
                      if (canDelete)
                        PopupMenuItem(value: 'delete', child: Text(l.delete)),
                    ],
                  )
                else
                  const SizedBox(height: 40),
              ],
            ),
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 12),
              child: SelectableText(a.body, style: theme.textTheme.bodyLarge),
            ),
            if (showReads && a.audience > 0) ...[
              const SizedBox(height: 6),
              Text(
                l.readByCount(a.readCount, a.audience),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _act(BuildContext context, WidgetRef ref, String action) async {
    final l = context.l10n;
    final api = ref.read(apiProvider);
    switch (action) {
      case 'pin':
        if (await runAction(
          context,
          () =>
              api.setAnnouncementPinned(announcement.id, !announcement.pinned),
        )) {
          onChanged();
        }
      case 'copy':
        await Clipboard.setData(ClipboardData(text: announcement.body));
        if (context.mounted) showMessage(context, l.copied);
      case 'delete':
        if (!await confirm(
          context,
          message: l.confirmDeleteAnnouncement,
          action: l.delete,
          destructive: true,
        )) {
          return;
        }
        if (!context.mounted) return;
        if (await runAction(
          context,
          () => api.deleteAnnouncement(announcement.id),
        )) {
          onChanged();
        }
    }
  }
}

class _ComposeSheet extends ConsumerStatefulWidget {
  const _ComposeSheet({required this.scope});

  final AnnouncementScope scope;

  @override
  ConsumerState<_ComposeSheet> createState() => _ComposeSheetState();
}

class _ComposeSheetState extends ConsumerState<_ComposeSheet> {
  final _text = TextEditingController();
  bool _pinned = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l.newAnnouncement,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('announcementText'),
              controller: _text,
              autofocus: true,
              minLines: 3,
              maxLines: 8,
              inputFormatters: [LengthLimitingTextInputFormatter(2000)],
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(hintText: l.announcementHint),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l.pinAnnouncement),
              value: _pinned,
              onChanged: (v) => setState(() => _pinned = v),
            ),
            const SizedBox(height: 8),
            BusyButton(
              label: l.publish,
              onPressed: _text.text.trim().isEmpty
                  ? null
                  : () async {
                      final ok = await runAction(
                        context,
                        () => ref
                            .read(apiProvider)
                            .postAnnouncement(
                              widget.scope.workspaceId,
                              projectId: widget.scope.projectId,
                              body: _text.text.trim(),
                              pinned: _pinned,
                            ),
                      );
                      if (ok && context.mounted) Navigator.pop(context, true);
                    },
            ),
          ],
        ),
      ),
    );
  }
}

/// The whole workspace's announcements, from the More tab.
class WorkspaceAnnouncementsScreen extends StatelessWidget {
  const WorkspaceAnnouncementsScreen({super.key, required this.membership});

  final Membership membership;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.workspaceAnnouncements)),
      body: AnnouncementsView(
        workspaceId: membership.workspaceId,
        canPost: membership.role.canManage,
      ),
    );
  }
}
