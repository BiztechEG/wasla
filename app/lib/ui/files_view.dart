import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/chat_models.dart';
import '../data/models.dart';
import '../l10n/app_localizations.dart';
import '../state/chat_providers.dart';
import '../state/providers.dart';
import '../theme.dart';
import 'chat_format.dart';
import 'chat_screen.dart';
import 'files_common.dart';
import 'widgets.dart';

/// What the files list shows.
enum _Filter { all, media, docs, audio, pinned }

/// Everything shared in a project: files sent in its chat, in private chats
/// tagged with it (for their two people), in its tasks, and added here.
/// Grouped by month, with where each came from.
class ProjectFilesView extends ConsumerStatefulWidget {
  const ProjectFilesView({
    super.key,
    required this.project,
    required this.membership,
    required this.canManage,
    required this.canAdd,
  });

  final Project project;

  /// To open a file's chat at its message; null while it loads.
  final Membership? membership;

  /// Admins and the project's lead pin and remove files.
  final bool canManage;

  /// False once the project is closed or archived.
  final bool canAdd;

  @override
  ConsumerState<ProjectFilesView> createState() => _ProjectFilesViewState();
}

class _ProjectFilesViewState extends ConsumerState<ProjectFilesView> {
  bool _uploading = false;
  String _query = '';
  _Filter _filter = _Filter.all;

  /// One key per file, to open its menu right under it.
  final _keys = <String, GlobalKey>{};

  String get _projectId => widget.project.id;

  Future<void> _add() async {
    final l = context.l10n;
    final upload = await pickUpload(context, ref);
    if (upload == null || !mounted) return;
    setState(() => _uploading = true);
    final ok = await runAction(
      context,
      () => ref
          .read(apiProvider)
          .addProjectFile(widget.project.workspaceId, _projectId, upload),
      done: l.fileAdded,
    );
    if (!mounted) return;
    setState(() => _uploading = false);
    if (ok) ref.invalidate(projectFilesProvider(_projectId));
  }

  bool _matches(ProjectFile f) {
    final file = f.file;
    final kept = switch (_filter) {
      _Filter.all => true,
      _Filter.media => file.isImage || file.isVideo,
      _Filter.audio => file.isAudio,
      _Filter.docs => !file.isImage && !file.isVideo && !file.isAudio,
      _Filter.pinned => f.pinned,
    };
    if (!kept) return false;
    final q = normalizeSearch(_query);
    return q.isEmpty ||
        normalizeSearch(fileLabel(context.l10n, file.name)).contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final files = ref.watch(projectFilesProvider(_projectId));

    return Column(
      children: [
        _ContextBar(project: widget.project),
        Expanded(
          child: AsyncView(
            value: files,
            onRetry: () => ref.invalidate(projectFilesProvider(_projectId)),
            builder: (all) {
              final shown = all.where(_matches).toList()
                ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
              final months = <DateTime, List<ProjectFile>>{};
              for (final f in shown) {
                final t = f.createdAt.toLocal();
                months.putIfAbsent(DateTime(t.year, t.month), () => []).add(f);
              }
              return Stack(
                children: [
                  RefreshIndicator(
                    onRefresh: () =>
                        ref.refresh(projectFilesProvider(_projectId).future),
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                      children: [
                        if (all.isNotEmpty) ...[
                          TextField(
                            key: const Key('fileSearch'),
                            decoration: InputDecoration(
                              hintText: l.searchFileName,
                              prefixIcon: const Icon(LucideIcons.search),
                              isDense: true,
                            ),
                            onChanged: (v) => setState(() => _query = v),
                          ),
                          const SizedBox(height: 10),
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                for (final f in _Filter.values)
                                  Padding(
                                    padding: const EdgeInsetsDirectional.only(
                                      end: 8,
                                    ),
                                    child: ChoiceChip(
                                      key: Key('fileFilter-${f.name}'),
                                      label: Text(switch (f) {
                                        _Filter.all => l.filterAll,
                                        _Filter.media => l.filterMedia,
                                        _Filter.docs => l.filterDocs,
                                        _Filter.audio => l.filterAudio,
                                        _Filter.pinned => l.filterPinned,
                                      }),
                                      selected: _filter == f,
                                      onSelected: (_) =>
                                          setState(() => _filter = f),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                        if (all.isEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 40),
                            child: EmptyState(
                              icon: Icons.folder_open_outlined,
                              title: l.filesEmpty,
                              body: l.filesEmptyBody,
                            ),
                          )
                        else if (shown.isEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 40),
                            child: EmptyState(
                              icon: LucideIcons.searchX,
                              title: l.noFilesMatch,
                            ),
                          ),
                        for (final MapEntry(key: month, value: list)
                            in months.entries) ...[
                          _MonthHeader(month: month, count: list.length),
                          TileGroup(children: [for (final f in list) _tile(f)]),
                        ],
                      ],
                    ),
                  ),
                  if (widget.canAdd)
                    PositionedDirectional(
                      end: 16,
                      bottom: 16,
                      child: FloatingActionButton.extended(
                        key: const Key('addFile'),
                        heroTag: null,
                        onPressed: _uploading ? null : _add,
                        icon: _uploading
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(LucideIcons.upload),
                        label: Text(_uploading ? l.uploading : l.addFile),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _tile(ProjectFile f) {
    final key = _keys.putIfAbsent(f.file.id, GlobalKey.new);
    return KeyedSubtree(
      key: key,
      child: _FileTile(
        file: f,
        onTap: () => openFile(context, ref, f.file),
        onMenu: () => _menu(f, key),
      ),
    );
  }

  Future<void> _menu(ProjectFile f, GlobalKey key) async {
    final l = context.l10n;
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    final me = ref.read(authProvider).value;
    final allowShare = widget.membership?.allowSharing ?? true;
    final canPin = widget.canManage && f.source != FileSource.direct;
    final canDelete = f.removable && (widget.canManage || f.uploadedBy == me);
    final actions = <_Action>[
      if (f.messageId != null &&
          f.conversationId != null &&
          widget.membership != null)
        _Action('goto', LucideIcons.messageSquareShare, l.goToMessage),
      _Action('download', LucideIcons.download, l.download),
      if (allowShare) _Action('share', LucideIcons.share2, l.share),
      _Action('drive', Icons.add_to_drive_outlined, l.saveToDrive),
      if (canPin)
        _Action(
          'pin',
          f.pinned ? LucideIcons.pinOff : LucideIcons.pin,
          f.pinned ? l.unpin : l.pin,
        ),
      if (canDelete)
        _Action('delete', LucideIcons.trash2, l.delete, destructive: true),
    ];
    final choice = await Navigator.of(context).push(
      _FileMenuRoute(
        rect: rect,
        file: f,
        source: '${widget.project.name} · ${_sourceText(l, f)}',
        actions: actions,
        barrierLabel: MaterialLocalizations.of(context)
            .modalBarrierDismissLabel,
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'goto':
        await _goTo(f);
      case 'download':
        await downloadFile(context, ref, f.file);
      case 'share':
        await shareOut(context, ref, file: f.file);
      case 'drive':
        await saveFileToDrive(context, ref, f.file);
      case 'pin' || 'delete':
        await _act(f, choice);
    }
  }

  Future<void> _goTo(ProjectFile f) async {
    final membership = widget.membership!;
    final project = widget.project;
    final ChatTarget target;
    if (f.source == FileSource.direct) {
      final people = ref.read(membersProvider(project.workspaceId)).value;
      target = ChatTarget(
        conversationId: f.conversationId!,
        title: f.otherName ?? '',
        otherId: f.otherId,
        otherActive: people?.any((m) => m.userId == f.otherId) ?? true,
      );
    } else {
      target = ChatTarget(
        conversationId: f.conversationId!,
        title: project.name,
        projectId: project.id,
        projectColor: project.color,
      );
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatScreen(
          membership: membership,
          target: target,
          initialMessageId: f.messageId,
        ),
      ),
    );
  }

  Future<void> _act(ProjectFile f, String action) async {
    final l = context.l10n;
    final api = ref.read(apiProvider);
    if (action == 'delete' &&
        !await confirm(
          context,
          message: l.confirmDeleteFile(f.file.name),
          action: l.delete,
          destructive: true,
        )) {
      return;
    }
    if (!mounted) return;
    final mine = f.uploadedBy == ref.read(authProvider).value;
    final ok = await runAction(
      context,
      () => action == 'pin'
          ? api.setFilePinned(f.file.id, !f.pinned)
          : api.deleteFile(f.file.id, filePath: mine ? f.file.path : null),
    );
    if (ok && mounted) ref.invalidate(projectFilesProvider(_projectId));
  }
}

String _sourceText(AppLocalizations l, ProjectFile f) => switch (f.source) {
  FileSource.project => l.fromProjectChat,
  FileSource.direct => l.privateWith(ltr(f.otherName ?? '')),
  FileSource.files => l.fromFilesTab,
  FileSource.task => l.fromTask,
};

IconData _sourceIcon(FileSource source) => switch (source) {
  FileSource.project => LucideIcons.messagesSquare,
  FileSource.direct => LucideIcons.lock,
  FileSource.files => LucideIcons.folderUp,
  FileSource.task => LucideIcons.squareCheck,
};

/// Over the list, in the project's color: whose files these are.
class _ContextBar extends StatelessWidget {
  const _ContextBar({required this.project});

  final Project project;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final color = WaslaColors.project(project.color, theme.brightness);
    return Container(
      key: const Key('filesContext'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      decoration: BoxDecoration(
        color: color.withValues(
          alpha: theme.brightness == Brightness.dark ? 0.16 : 0.10,
        ),
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          ProjectAvatar(name: project.name, hex: project.color, size: 34),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l.filesOf(project.name),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  l.filesOfHint,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MonthHeader extends StatelessWidget {
  const _MonthHeader({required this.month, required this.count});

  final DateTime month;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
      child: Row(
        children: [
          Text(
            monthLabel(context, month),
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            context.l10n.fileCount(count),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// A file's picture: a thumbnail for photos, a play mark for videos, a
/// microphone for voice, else its type.
class _Thumb extends StatelessWidget {
  const _Thumb({required this.file});

  final ChatFile file;
  static const size = 48.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (file.isImage) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox.square(
          dimension: size,
          child: StoredImage(path: file.path, placeholderHeight: size),
        ),
      );
    }
    if (file.isVideo || file.isAudio) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: file.isVideo
              ? const Color(0xFF1B2422)
              : scheme.primaryContainer,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(
          file.isVideo ? Icons.play_arrow_rounded : LucideIcons.mic,
          color: file.isVideo ? Colors.white : scheme.primary,
        ),
      );
    }
    return FileBadge(name: file.name, size: size);
  }
}

class _FileTile extends StatelessWidget {
  const _FileTile({required this.file, this.onTap, this.onMenu});

  final ProjectFile file;
  final VoidCallback? onTap;

  /// Null where the row is only shown (above its open menu).
  final VoidCallback? onMenu;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final f = file;
    final small = theme.textTheme.bodySmall?.copyWith(color: muted);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(12, 10, 4, 10),
        child: Row(
          children: [
            _Thumb(file: f.file),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          fileLabel(l, f.file.name),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (f.pinned) ...[
                        const SizedBox(width: 6),
                        Icon(
                          LucideIcons.pin,
                          key: const Key('pinnedMark'),
                          size: 14,
                          color: theme.colorScheme.primary,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${f.uploaderName} · ${fullTime(context, f.createdAt)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: small,
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Icon(_sourceIcon(f.source), size: 13, color: muted),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          [
                            _sourceText(l, f),
                            if (!f.file.isAudio) fileSize(l, f.file.size),
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: small,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (onMenu != null)
              IconButton(
                key: Key('fileMenu-${f.file.id}'),
                tooltip: l.moreActions,
                icon: const Icon(LucideIcons.ellipsisVertical, size: 20),
                onPressed: onMenu,
              )
            else
              const SizedBox(width: 48),
          ],
        ),
      ),
    );
  }
}

class _Action {
  const _Action(this.id, this.icon, this.label, {this.destructive = false});

  final String id;
  final IconData icon;
  final String label;
  final bool destructive;
}

/// A file's menu: the screen dims, the file stays lit where it was, and
/// the menu hangs right under it (or above, near the bottom), headed by
/// the file's name and where it came from.
class _FileMenuRoute extends PopupRoute<String> {
  _FileMenuRoute({
    required this.rect,
    required this.file,
    required this.source,
    required this.actions,
    required this.barrierLabel,
  });

  final Rect rect;
  final ProjectFile file;
  final String source;
  final List<_Action> actions;

  @override
  final String barrierLabel;

  @override
  Color? get barrierColor => Colors.black54;

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 150);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final theme = Theme.of(context);
    final screen = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final width = math.min(rect.width - 16, 300.0);
    final height = 66.0 + actions.length * 48.0;
    final below =
        rect.bottom + 12 + height < screen.height - padding.bottom - 8 ||
        rect.top - 12 - height < padding.top;
    // The menu lines up with the "⋯" button, at the row's end.
    final side = rtl ? rect.left + 8 : screen.width - rect.right + 8;
    final error = theme.colorScheme.error;
    final menu = Material(
      key: const Key('fileMenu'),
      color: theme.colorScheme.surface,
      elevation: 8,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: width,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      fileLabel(context.l10n, file.file.name),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      source,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              for (final a in actions)
                InkWell(
                  key: Key('fileAction-${a.id}'),
                  onTap: () => Navigator.pop(context, a.id),
                  child: SizedBox(
                    height: 48,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Icon(
                            a.icon,
                            size: 20,
                            color: a.destructive ? error : null,
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Text(
                              a.label,
                              style: a.destructive
                                  ? TextStyle(color: error)
                                  : null,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    final arrow = CustomPaint(
      size: const Size(18, 9),
      painter: _ArrowPainter(color: theme.colorScheme.surface, up: below),
    );
    return FadeTransition(
      opacity: animation,
      child: Stack(
        children: [
          // The chosen file, lit above the dim.
          Positioned.fromRect(
            rect: rect,
            child: Material(
              key: const Key('pickedFile'),
              color: theme.colorScheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: theme.colorScheme.primary, width: 2),
              ),
              clipBehavior: Clip.antiAlias,
              child: _FileTile(file: file),
            ),
          ),
          Positioned(
            top: below ? rect.bottom + 3 : null,
            bottom: below ? null : screen.height - rect.top + 3,
            left: rtl ? side : null,
            right: rtl ? null : side,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              // The arrow points at the "⋯" button, at the row's end.
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (below)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: arrow,
                  ),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: below
                        ? screen.height - rect.bottom - padding.bottom - 24
                        : rect.top - padding.top - 24,
                  ),
                  child: menu,
                ),
                if (!below)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: arrow,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ArrowPainter extends CustomPainter {
  const _ArrowPainter({required this.color, required this.up});

  final Color color;
  final bool up;

  @override
  void paint(Canvas canvas, Size size) {
    final path = up
        ? (Path()
            ..moveTo(0, size.height)
            ..lineTo(size.width / 2, 0)
            ..lineTo(size.width, size.height))
        : (Path()
            ..moveTo(0, 0)
            ..lineTo(size.width / 2, size.height)
            ..lineTo(size.width, 0));
    canvas.drawPath(path..close(), Paint()..color = color);
  }

  @override
  bool shouldRepaint(_ArrowPainter old) => old.color != color || old.up != up;
}
