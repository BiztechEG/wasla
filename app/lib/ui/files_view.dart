import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/chat_models.dart';
import '../state/chat_providers.dart';
import '../state/providers.dart';
import 'chat_format.dart';
import 'files_common.dart';
import 'widgets.dart';

/// Everything shared in a project: files sent in its chats (including
/// private chats tagged with it, for their two people) and files added here.
class ProjectFilesView extends ConsumerStatefulWidget {
  const ProjectFilesView({
    super.key,
    required this.workspaceId,
    required this.projectId,
    required this.canManage,
    required this.canAdd,
  });

  final String workspaceId;
  final String projectId;

  /// Admins and the project's lead pin and remove files.
  final bool canManage;

  /// False once the project is closed or archived.
  final bool canAdd;

  @override
  ConsumerState<ProjectFilesView> createState() => _ProjectFilesViewState();
}

class _ProjectFilesViewState extends ConsumerState<ProjectFilesView> {
  bool _uploading = false;

  Future<void> _add() async {
    final l = context.l10n;
    final upload = await pickUpload(context, ref);
    if (upload == null || !mounted) return;
    setState(() => _uploading = true);
    final ok = await runAction(
      context,
      () => ref
          .read(apiProvider)
          .addProjectFile(widget.workspaceId, widget.projectId, upload),
      done: l.fileAdded,
    );
    if (!mounted) return;
    setState(() => _uploading = false);
    if (ok) ref.invalidate(projectFilesProvider(widget.projectId));
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final files = ref.watch(projectFilesProvider(widget.projectId));
    final me = ref.watch(authProvider).value;

    return AsyncView(
      value: files,
      onRetry: () => ref.invalidate(projectFilesProvider(widget.projectId)),
      builder: (all) {
        final pinned = all.where((f) => f.pinned).toList();
        final rest = all.where((f) => !f.pinned).toList();
        return RefreshIndicator(
          onRefresh: () =>
              ref.refresh(projectFilesProvider(widget.projectId).future),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              if (widget.canAdd)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: FilledButton.tonalIcon(
                    onPressed: _uploading ? null : _add,
                    icon: _uploading
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.upload_file),
                    label: Text(_uploading ? l.uploading : l.addFile),
                  ),
                ),
              if (all.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 40),
                  child: EmptyState(
                    icon: Icons.folder_open_outlined,
                    title: l.filesEmpty,
                    body: l.filesEmptyBody,
                  ),
                ),
              if (pinned.isNotEmpty) ...[
                SectionTitle(l.pinned),
                TileGroup(
                  children: [for (final f in pinned) _fileTile(context, f, me)],
                ),
              ],
              if (rest.isNotEmpty) ...[
                if (pinned.isNotEmpty) SectionTitle(l.allFiles),
                if (pinned.isEmpty) const SizedBox(height: 12),
                TileGroup(
                  children: [for (final f in rest) _fileTile(context, f, me)],
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _fileTile(BuildContext context, ProjectFile f, String? me) {
    final l = context.l10n;
    final canPin = widget.canManage && !f.privateChat;
    final canDelete =
        f.conversationId == null && (widget.canManage || f.uploadedBy == me);
    final detail = [
      f.uploaderName,
      listTime(context, f.createdAt),
      fileSize(l, f.file.size),
      if (f.privateChat) l.fromPrivateChat,
    ].join(' · ');

    return ListTile(
      contentPadding: const EdgeInsetsDirectional.fromSTEB(16, 4, 4, 4),
      title: FileRow(file: f.file, detail: detail, dense: true),
      onTap: () => openFile(context, ref, f.file),
      trailing: canPin || canDelete
          ? PopupMenuButton<String>(
              onSelected: (action) => _act(context, f, action),
              itemBuilder: (_) => [
                if (canPin)
                  PopupMenuItem(
                    value: 'pin',
                    child: Text(f.pinned ? l.unpin : l.pin),
                  ),
                if (canDelete)
                  PopupMenuItem(value: 'delete', child: Text(l.delete)),
              ],
            )
          : null,
    );
  }

  Future<void> _act(BuildContext context, ProjectFile f, String action) async {
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
    if (!context.mounted) return;
    final ok = await runAction(
      context,
      () => action == 'pin'
          ? api.setFilePinned(f.file.id, !f.pinned)
          : api.deleteFile(f.file.id),
    );
    if (ok) ref.invalidate(projectFilesProvider(widget.projectId));
  }
}
