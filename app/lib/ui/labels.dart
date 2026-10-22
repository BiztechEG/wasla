import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/chat_models.dart';
import '../data/models.dart';
import '../state/chat_providers.dart';
import '../state/providers.dart';
import '../state/settings.dart';
import '../theme.dart';
import 'chat_format.dart';
import 'chat_screen.dart';
import 'widgets.dart';

/// Labels: one files messages from any chat under names of one's own, to
/// come back to them by topic. Nobody else sees them.

/// A label's color, the same for its name on every device.
Color labelColor(String name, Brightness brightness) {
  var hash = 0;
  for (final unit in name.toLowerCase().codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  const colors = WaslaColors.projectColors;
  return WaslaColors.project(colors[hash % colors.length], brightness);
}

/// Refreshes what shows labels, after one changed them.
void _labelsChanged(WidgetRef ref) {
  ref.invalidate(myLabelsProvider);
  ref.invalidate(chatLabelsProvider);
  ref.invalidate(labelledProvider);
}

/// The labels one put on a message, under it; a tap opens one.
class LabelChips extends StatelessWidget {
  const LabelChips({super.key, required this.labels, required this.onTap});

  final List<MessageLabel> labels;
  final void Function(MessageLabel label) onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final label in labels)
            _LabelChip(
              key: Key('label-${label.name}'),
              name: label.name,
              color: labelColor(label.name, theme.brightness),
              onTap: () => onTap(label),
            ),
        ],
      ),
    );
  }
}

class _LabelChip extends StatelessWidget {
  const _LabelChip({
    super.key,
    required this.name,
    required this.color,
    required this.onTap,
  });

  final String name;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = WaslaColors.onTint(color, theme.brightness);
    return Material(
      color: color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 2, 8, 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.hash, size: 12, color: ink),
              const SizedBox(width: 2),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 160),
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: ink,
                    fontWeight: FontWeight.w600,
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

/// Puts a message under labels, or takes it off them: one's labels to tick,
/// and a field that finds one or makes a new one.
Future<void> showLabelSheet(
  BuildContext context, {
  required String workspaceId,
  required String conversationId,
  required String messageId,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _LabelSheet(
    workspaceId: workspaceId,
    conversationId: conversationId,
    messageId: messageId,
  ),
);

class _LabelSheet extends ConsumerStatefulWidget {
  const _LabelSheet({
    required this.workspaceId,
    required this.conversationId,
    required this.messageId,
  });

  final String workspaceId;
  final String conversationId;
  final String messageId;

  @override
  ConsumerState<_LabelSheet> createState() => _LabelSheetState();
}

class _LabelSheetState extends ConsumerState<_LabelSheet> {
  final _name = TextEditingController();

  /// The labels the message is under, as changed here; null until known.
  Set<String>? _on;

  /// Labels made here, until the list has them.
  final _made = <MessageLabel>[];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _toggle(MessageLabel label) async {
    final on = _on!;
    final adding = !on.contains(label.id);
    setState(() => adding ? on.add(label.id) : on.remove(label.id));
    final api = ref.read(apiProvider);
    final ok = await runAction(
      context,
      () => adding
          ? api.labelMessage(widget.messageId, labelId: label.id)
          : api.unlabelMessage(widget.messageId, label.id),
    );
    if (!mounted) return;
    if (!ok) setState(() => adding ? on.remove(label.id) : on.add(label.id));
    _labelsChanged(ref);
  }

  Future<void> _add() async {
    final name = _name.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (name.isEmpty || _busy) return;
    setState(() => _busy = true);
    String? id;
    final ok = await runAction(context, () async {
      id = await ref
          .read(apiProvider)
          .labelMessage(widget.messageId, name: name);
    });
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) {
        _on!.add(id!);
        _made.add(MessageLabel(id: id!, name: name));
        _name.clear();
      }
    });
    _labelsChanged(ref);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final labels = ref.watch(myLabelsProvider(widget.workspaceId));
    final onChat = ref.watch(chatLabelsProvider(widget.conversationId));
    if (_on == null && onChat.hasValue) {
      _on = {...?onChat.value![widget.messageId]};
    }
    final known = labels.value;
    final all = [
      ...?known,
      for (final m in _made)
        if (!(known ?? const []).any((k) => k.id == m.id)) m,
    ];
    final typed = _name.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    final q = normalizeSearch(typed);
    final shown = q.isEmpty
        ? all
        : all.where((x) => normalizeSearch(x.name).contains(q)).toList();
    final exact = all.any((x) => x.name.toLowerCase() == typed.toLowerCase());
    final ready = _on != null && known != null;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.75,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  l.labelSheetTitle,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 2, 20, 8),
                child: Row(
                  children: [
                    Icon(
                      LucideIcons.lock,
                      size: 14,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      l.labelsPrivate,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  key: const Key('labelField'),
                  controller: _name,
                  maxLength: 40,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _add(),
                  decoration: InputDecoration(
                    hintText: l.labelSearchHint,
                    prefixIcon: const Icon(LucideIcons.hash),
                    counterText: '',
                  ),
                ),
              ),
              if (typed.isNotEmpty && !exact && ready)
                ListTile(
                  key: const Key('newLabel'),
                  leading: _busy
                      ? const SizedBox.square(
                          dimension: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          LucideIcons.plus,
                          color: theme.colorScheme.primary,
                        ),
                  title: Text(
                    l.newLabel(typed),
                    style: TextStyle(color: theme.colorScheme.primary),
                  ),
                  onTap: _add,
                ),
              Flexible(
                child: !ready
                    ? const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    : all.isEmpty && typed.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          l.labelsNone,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : ListView(
                        shrinkWrap: true,
                        padding: const EdgeInsets.only(top: 4),
                        children: [
                          for (final x in shown)
                            CheckboxListTile(
                              key: Key('pickLabel-${x.name}'),
                              value: _on!.contains(x.id),
                              onChanged: (_) => _toggle(x),
                              secondary: Icon(
                                LucideIcons.hash,
                                color: labelColor(x.name, theme.brightness),
                              ),
                              title: Text(
                                x.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                      ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton(
                    key: const Key('labelsDone'),
                    onPressed: () => Navigator.pop(context),
                    child: Text(l.done),
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

/// Where the user last chose to look under a label from a chat: in that chat
/// only, or in every chat.
const _thisChatKey = 'labels_this_chat';

/// The messages under a label, from every chat. Opened from a chat
/// ([conversationId]), it can show only that chat's; the choice is kept.
/// It closes with a message id when one in that chat is picked, for the chat
/// to go to it.
class LabelScreen extends ConsumerStatefulWidget {
  const LabelScreen({
    super.key,
    required this.membership,
    required this.label,
    this.conversationId,
  });

  final Membership membership;
  final MessageLabel label;
  final String? conversationId;

  @override
  ConsumerState<LabelScreen> createState() => _LabelScreenState();
}

class _LabelScreenState extends ConsumerState<LabelScreen> {
  late String _name = widget.label.name;

  bool get _thisChat =>
      widget.conversationId != null &&
      (ref.read(prefsProvider).getBool(_thisChatKey) ?? false);

  Future<void> _setThisChat(bool value) async {
    await ref.read(prefsProvider).setBool(_thisChatKey, value);
    if (mounted) setState(() {});
  }

  void _open(MessageHit hit) {
    if (hit.conversationId == widget.conversationId) {
      Navigator.pop(context, hit.messageId);
      return;
    }
    // Chats outside the list (a closed project) open from the hit itself.
    final chats =
        ref.read(conversationsProvider(widget.membership.workspaceId)).value ??
        const <Conversation>[];
    final chat =
        chats.where((c) => c.id == hit.conversationId).firstOrNull ?? hit.chat;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatScreen(
          membership: widget.membership,
          target: ChatTarget.of(chat),
          initialMessageId: hit.messageId,
        ),
      ),
    );
  }

  Future<void> _rename() async {
    final l = context.l10n;
    final name = await promptText(
      context,
      title: l.renameLabel,
      label: l.labelName,
      initial: _name,
      maxLength: 40,
    );
    final clean = name?.trim().replaceAll(RegExp(r'\s+'), ' ') ?? '';
    if (clean.isEmpty || clean == _name || !mounted) return;
    final ok = await runAction(
      context,
      () => ref.read(apiProvider).renameLabel(widget.label.id, clean),
    );
    if (!mounted) return;
    if (ok) setState(() => _name = clean);
    _labelsChanged(ref);
  }

  Future<void> _delete() async {
    final l = context.l10n;
    if (!await confirm(
      context,
      message: l.confirmDeleteLabel(_name),
      action: l.delete,
      destructive: true,
    )) {
      return;
    }
    if (!mounted) return;
    final ok = await runAction(
      context,
      () => ref.read(apiProvider).deleteLabel(widget.label.id),
    );
    if (!mounted) return;
    _labelsChanged(ref);
    if (ok) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final thisChat = _thisChat;
    final key = (
      labelId: widget.label.id,
      conversationId: thisChat ? widget.conversationId : null,
    );
    final hits = ref.watch(labelledProvider(key));

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(LucideIcons.hash, color: labelColor(_name, theme.brightness)),
            const SizedBox(width: 6),
            Flexible(child: Text(_name, overflow: TextOverflow.ellipsis)),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            key: const Key('labelMenu'),
            icon: const Icon(LucideIcons.ellipsisVertical),
            onSelected: (v) => v == 'rename' ? _rename() : _delete(),
            itemBuilder: (_) => [
              PopupMenuItem(value: 'rename', child: Text(l.renameLabel)),
              PopupMenuItem(
                value: 'delete',
                child: Text(
                  l.deleteLabel,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (widget.conversationId != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<bool>(
                  key: const Key('labelScope'),
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(
                      value: false,
                      label: Text(l.labelAllChats),
                      icon: const Icon(LucideIcons.messagesSquare),
                    ),
                    ButtonSegment(
                      value: true,
                      label: Text(l.labelThisChat),
                      icon: const Icon(LucideIcons.messageSquare),
                    ),
                  ],
                  selected: {thisChat},
                  onSelectionChanged: (v) => _setThisChat(v.first),
                ),
              ),
            ),
          Expanded(
            child: AsyncView(
              value: hits,
              onRetry: () => ref.invalidate(labelledProvider(key)),
              builder: (hits) => hits.isEmpty
                  ? EmptyState(
                      icon: LucideIcons.hash,
                      title: thisChat ? l.labelEmptyHere : l.labelEmpty,
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(top: 4, bottom: 24),
                      itemCount: hits.length,
                      itemBuilder: (context, i) => _HitTile(
                        hit: hits[i],
                        showChat: !thisChat,
                        onTap: () => _open(hits[i]),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HitTile extends StatelessWidget {
  const _HitTile({
    required this.hit,
    required this.showChat,
    required this.onTap,
  });

  final MessageHit hit;
  final bool showChat;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final where = [
      if (showChat) hit.chat.title,
      hit.senderName,
      listTime(context, hit.createdAt),
    ].join(' · ');
    return ListTile(
      key: Key('labelled-${hit.messageId}'),
      leading: hit.fileName != null
          ? FileBadge(name: hit.fileName!)
          : Avatar(name: hit.senderName),
      title: Text(
        (hit.body?.isNotEmpty ?? false) ? hit.body! : hit.fileName ?? '',
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(where, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: onTap,
    );
  }
}

/// All of one's labels in the workspace, to get to their messages.
class LabelsScreen extends ConsumerWidget {
  const LabelsScreen({super.key, required this.membership});

  final Membership membership;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final ws = membership.workspaceId;
    final labels = ref.watch(myLabelsProvider(ws));
    return Scaffold(
      appBar: AppBar(title: Text(l.labelsTitle)),
      body: AsyncView(
        value: labels,
        onRetry: () => ref.invalidate(myLabelsProvider(ws)),
        builder: (labels) => labels.isEmpty
            ? EmptyState(
                icon: LucideIcons.hash,
                title: l.labelsEmpty,
                body: l.labelsEmptyHint,
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  TileGroup(
                    children: [
                      for (final label in labels)
                        ListTile(
                          key: Key('labelTile-${label.name}'),
                          leading: CircleAvatar(
                            radius: 18,
                            backgroundColor: labelColor(
                              label.name,
                              theme.brightness,
                            ).withValues(alpha: 0.14),
                            child: Icon(
                              LucideIcons.hash,
                              size: 18,
                              color: labelColor(label.name, theme.brightness),
                            ),
                          ),
                          title: Text(
                            label.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(l.labelMessages(label.messages)),
                          trailing: const Icon(LucideIcons.chevronRightDir),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => LabelScreen(
                                membership: membership,
                                label: label,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}
