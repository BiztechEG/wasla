import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/chat_models.dart';
import '../data/task_models.dart';
import '../state/chat_providers.dart';
import '../state/providers.dart';
import '../state/task_providers.dart';
import '../theme.dart';
import 'chat_format.dart';
import 'chat_screen.dart';
import 'files_common.dart';
import 'task_editor.dart';
import 'task_format.dart';
import 'widgets.dart';

/// One task: its status, who it is for, when it is due, its files and its
/// updates, with a box to add an update for the people on it.
class TaskScreen extends ConsumerWidget {
  const TaskScreen({
    super.key,
    required this.workspaceId,
    required this.taskId,
  });

  final String workspaceId;
  final String taskId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = (workspaceId: workspaceId, taskId: taskId);
    final detail = ref.watch(taskDetailProvider(key));
    final d = detail.value;

    return Scaffold(
      appBar: AppBar(
        title: d == null
            ? null
            : Row(
                children: [
                  ColorDot(hex: d.task.projectColor, size: 12),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      d.task.projectName,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
        actions: [if (d != null) _TaskMenu(detail: d)],
      ),
      body: AsyncView(
        value: detail,
        onRetry: () => ref.invalidate(taskDetailProvider(key)),
        builder: (d) => _TaskBody(detail: d),
      ),
    );
  }
}

enum _MenuAction { edit, reminder, nudge, delete }

class _TaskMenu extends ConsumerWidget {
  const _TaskMenu({required this.detail});

  final TaskDetail detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final task = detail.task;
    final me = ref.watch(authProvider).value;
    final editable = detail.canEdit && detail.projectOpen;
    final others = task.assignees.any((a) => a.id != me);
    final open = task.status.isOpen;
    // An archived or closed project's tasks can't change at all.
    if (!editable) return const SizedBox();

    Future<void> run(_MenuAction action) async {
      final api = ref.read(apiProvider);
      switch (action) {
        case _MenuAction.edit:
          await Navigator.of(context).push<String>(
            MaterialPageRoute(
              fullscreenDialog: true,
              builder: (_) => TaskEditorScreen(
                workspaceId: task.workspaceId,
                existing: detail,
              ),
            ),
          );
        case _MenuAction.reminder:
          final at = await pickDateTime(context);
          if (at == null || !context.mounted) return;
          if (await runAction(
            context,
            () => api.addTaskReminder(task.id, at),
            done: l.taskSaved,
          )) {
            refreshTasks(ref);
          }
        case _MenuAction.nudge:
          await runAction(
            context,
            () => api.nudgeTask(task.id),
            done: l.reminderSent,
          );
        case _MenuAction.delete:
          if (!await confirm(
            context,
            message: l.confirmDeleteTask(task.title),
            action: l.delete,
            destructive: true,
          )) {
            return;
          }
          if (!context.mounted) return;
          final navigator = Navigator.of(context);
          if (await runAction(context, () => api.deleteTask(task.id))) {
            refreshTasks(ref);
            navigator.pop();
          }
      }
    }

    return PopupMenuButton<_MenuAction>(
      onSelected: run,
      itemBuilder: (_) => [
        PopupMenuItem(value: _MenuAction.edit, child: Text(l.editTask)),
        if (open)
          PopupMenuItem(
            value: _MenuAction.reminder,
            child: Text(l.addReminder),
          ),
        if (open && others)
          PopupMenuItem(value: _MenuAction.nudge, child: Text(l.remindNow)),
        PopupMenuItem(value: _MenuAction.delete, child: Text(l.deleteTask)),
      ],
    );
  }
}

class _TaskBody extends ConsumerWidget {
  const _TaskBody({required this.detail});

  final TaskDetail detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final task = detail.task;
    final me = ref.watch(authProvider).value;
    final late = task.isLate(DateTime.now());
    final writable = detail.isParty && detail.projectOpen;

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              Text(
                task.title,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  if (task.priority != TaskPriority.normal)
                    Tag(priorityLabel(l, task.priority), strong: true),
                  Tag(
                    task.visibility == TaskVisibility.public
                        ? l.publicTask
                        : l.privateTask,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _StatusPicker(detail: detail),
              if (task.status == TaskStatus.onHold &&
                  (detail.holdReason ?? '').isNotEmpty) ...[
                const SizedBox(height: 12),
                _Note(
                  icon: Icons.pause_circle_outline,
                  color: statusColor(TaskStatus.onHold, theme.brightness),
                  text: l.onHoldBecause(detail.holdReason!),
                ),
              ],
              const SizedBox(height: 16),
              TileGroup(
                children: [
                  _InfoRow(
                    icon: Icons.person_outline,
                    label: l.assigneesLabel,
                    value: joinNames(context, [
                      for (final a in task.assignees)
                        a.id == me ? l.you : a.name,
                    ]),
                  ),
                  _InfoRow(
                    icon: Icons.edit_outlined,
                    label: l.createdByLabel,
                    value: task.createdBy == me ? l.you : task.creatorName,
                  ),
                  _InfoRow(
                    icon: Icons.event_outlined,
                    label: l.dueLabel,
                    value: task.dueAt == null
                        ? '—'
                        : late
                        ? l.wasDue(dueFull(context, task.dueAt!))
                        : dueFull(context, task.dueAt!),
                    color: late ? lateColor(context) : null,
                  ),
                  if (detail.repeat != null)
                    _InfoRow(
                      icon: Icons.repeat,
                      label: l.repeatLabel,
                      value: repeatLabel(l, detail.repeat),
                    ),
                  if (task.dueAt != null && task.status.isOpen)
                    _InfoRow(
                      icon: Icons.notifications_none,
                      label: l.reminderLabel,
                      value: remindersLabel(l, detail.remindBefore),
                    ),
                ],
              ),
              if ((detail.description ?? '').isNotEmpty) ...[
                SectionTitle(l.taskDetailsTitle),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: SelectableText(
                      detail.description!,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ),
              ],
              if (detail.reminders.isNotEmpty) ...[
                SectionTitle(l.extraReminders),
                TileGroup(
                  children: [
                    for (final r in detail.reminders)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.alarm),
                        title: Text(dueFull(context, r.remindAt)),
                        trailing: detail.canEdit && detail.projectOpen
                            ? IconButton(
                                tooltip: l.remove,
                                icon: const Icon(Icons.close),
                                onPressed: () async {
                                  if (await runAction(
                                    context,
                                    () => ref
                                        .read(apiProvider)
                                        .deleteTaskReminder(r.id),
                                  )) {
                                    refreshTasks(ref);
                                  }
                                },
                              )
                            : null,
                      ),
                  ],
                ),
              ],
              if (detail.files.isNotEmpty) ...[
                SectionTitle(l.attachments),
                TileGroup(
                  children: [
                    for (final f in detail.files)
                      InkWell(
                        onTap: () => openFile(context, ref, f.file),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          child: FileRow(
                            file: f.file,
                            dense: true,
                            detail:
                                '${fileSize(l, f.file.size)} · ${f.uploaderName}',
                          ),
                        ),
                      ),
                  ],
                ),
              ],
              if (detail.sourceConversationId != null) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    onPressed: () => _openSource(context, ref),
                    icon: const Icon(Icons.forum_outlined),
                    label: Text(l.openChat),
                  ),
                ),
              ],
              SectionTitle(l.updates),
              for (final a in detail.activity.reversed)
                _ActivityItem(activity: a, me: me),
              if (detail.isParty &&
                  task.visibility == TaskVisibility.public) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(Icons.lock_outline, size: 16, color: muted),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        l.commentsPrivateNote,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: muted,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        if (writable) _UpdateComposer(task: task),
      ],
    );
  }

  Future<void> _openSource(BuildContext context, WidgetRef ref) async {
    final l = context.l10n;
    final task = detail.task;
    final id = detail.sourceConversationId!;
    final navigator = Navigator.of(context);
    final membership = (ref.read(membershipsProvider).value ?? const [])
        .where((m) => m.workspaceId == task.workspaceId)
        .firstOrNull;
    if (membership == null) return;
    List<Conversation> chats;
    try {
      chats = await ref.read(conversationsProvider(task.workspaceId).future);
    } catch (e) {
      if (context.mounted) showMessage(context, errorText(l, e));
      return;
    }
    final chat = chats.where((c) => c.id == id).firstOrNull;
    ChatTarget? target = chat == null ? null : ChatTarget.of(chat);
    // The project's own chat may not be in the list yet.
    if (target == null) {
      final projectChat = await ref
          .read(projectConversationProvider(task.projectId).future)
          .catchError((_) => null);
      if (projectChat == id) {
        target = ChatTarget(
          conversationId: id,
          title: task.projectName,
          projectId: task.projectId,
          projectColor: task.projectColor,
        );
      }
    }
    if (!context.mounted) return;
    if (target == null) {
      showMessage(context, l.errorNotAllowed);
      return;
    }
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => ChatScreen(membership: membership, target: target!),
      ),
    );
  }
}

/// The five statuses as chips; the ones one may not move to are disabled.
class _StatusPicker extends ConsumerWidget {
  const _StatusPicker({required this.detail});

  final TaskDetail detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final current = detail.task.status;
    final movable = TaskStatus.values.any(detail.canMoveTo);

    if (!movable) {
      return Align(
        alignment: AlignmentDirectional.centerStart,
        child: StatusTag(current),
      );
    }

    Future<void> move(TaskStatus next) async {
      String? reason;
      if (next == TaskStatus.onHold) {
        reason = await promptText(
          context,
          title: l.holdReasonTitle,
          label: l.holdReasonHint,
          maxLength: 500,
        );
        if (reason == null) return;
      }
      if (!context.mounted) return;
      if (await runAction(
        context,
        () => ref
            .read(apiProvider)
            .setTaskStatus(detail.task.id, next, reason: reason),
      )) {
        refreshTasks(ref);
      }
    }

    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        for (final s in TaskStatus.values)
          ChoiceChip(
            label: Text(statusLabel(l, s)),
            selected: s == current,
            selectedColor: statusColor(
              s,
              theme.brightness,
            ).withValues(alpha: 0.2),
            // The current status stays bright; ones out of reach are dimmed.
            onSelected: s == current
                ? (_) {}
                : detail.canMoveTo(s)
                ? (_) => move(s)
                : null,
          ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.color, required this.text});

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: WaslaColors.onTint(color, brightness)),
            ),
          ),
        ],
      ),
    );
  }
}

/// One update: a comment in a bubble, anything else as a quiet line.
class _ActivityItem extends StatelessWidget {
  const _ActivityItem({required this.activity, required this.me});

  final TaskActivity activity;
  final String? me;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final a = activity;
    final who = a.actorId == me ? l.you : a.actorName;
    final day = listTime(context, a.createdAt);
    final clock = clockTime(context, a.createdAt);
    final when = day == clock ? clock : '$day $clock';

    if (a.kind == TaskEvent.comment) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Avatar(name: a.actorName, radius: 16),
            const SizedBox(width: 10),
            Expanded(
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            who,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        Text(
                          when,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: muted,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    SelectableText(a.body ?? ''),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    final (icon, text) = _describe(context, a);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 32, child: Icon(icon, size: 18, color: muted)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text, style: theme.textTheme.bodyMedium),
                if (a.kind == TaskEvent.status && (a.body ?? '').isNotEmpty)
                  Text(
                    a.body!,
                    style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                  ),
                Text(
                  '$who · $when',
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static (IconData, String) _describe(BuildContext context, TaskActivity a) {
    final l = context.l10n;
    switch (a.kind) {
      case TaskEvent.created:
        return (
          Icons.add_task,
          switch (a.newValue) {
            'message' => l.actCreatedFromMessage,
            'repeat' => l.actCreatedRepeat,
            _ => l.actCreated,
          },
        );
      case TaskEvent.status:
        return (
          Icons.swap_horiz,
          l.actStatus(statusLabel(l, TaskStatus.parse(a.newValue))),
        );
      case TaskEvent.due:
        final due = a.newValue == null ? null : DateTime.tryParse(a.newValue!);
        return (
          Icons.event_outlined,
          due == null ? l.actDueRemoved : l.actDue(dueFull(context, due)),
        );
      case TaskEvent.priority:
        return (
          Icons.flag_outlined,
          l.actPriority(priorityLabel(l, TaskPriority.parse(a.newValue))),
        );
      case TaskEvent.title:
        return (Icons.edit_outlined, l.actTitle(a.newValue ?? ''));
      case TaskEvent.visibility:
        return a.newValue == 'public'
            ? (Icons.public, l.actMadePublic)
            : (Icons.lock_outline, l.actMadePrivate);
      case TaskEvent.assignees:
        // The server joins the names with an Arabic comma.
        final names = (a.newValue ?? '').split('، ');
        return (Icons.person_outline, l.actAssigned(joinNames(context, names)));
      case TaskEvent.attachment:
        return (Icons.attach_file, l.actAttached(a.newValue ?? ''));
      case TaskEvent.comment:
        return (Icons.chat_bubble_outline, a.body ?? '');
      case TaskEvent.repeat:
        final repeat = TaskRepeat.parse(a.newValue);
        return (
          Icons.repeat,
          repeat == null
              ? l.actRepeatStopped
              : l.actRepeat(repeatLabel(l, repeat)),
        );
    }
  }
}

/// Adds a comment or a file to the task.
class _UpdateComposer extends ConsumerStatefulWidget {
  const _UpdateComposer({required this.task});

  final TaskItem task;

  @override
  ConsumerState<_UpdateComposer> createState() => _UpdateComposerState();
}

class _UpdateComposerState extends ConsumerState<_UpdateComposer> {
  final _text = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    final ok = await runAction(context, action);
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) refreshTasks(ref);
  }

  Future<void> _send() async {
    final body = _text.text.trim();
    if (body.isEmpty) return;
    await _run(() async {
      await ref.read(apiProvider).addTaskComment(widget.task.id, body);
      _text.clear();
    });
  }

  Future<void> _attach() async {
    final file = await pickUpload(context, ref);
    if (file == null || !mounted) return;
    await _run(
      () => ref
          .read(apiProvider)
          .addTaskAttachment(widget.task.workspaceId, widget.task.id, file),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final canSend = !_busy && _text.text.trim().isNotEmpty;
    return Material(
      color: theme.colorScheme.surface,
      elevation: 3,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                tooltip: l.attach,
                onPressed: _busy ? null : _attach,
                icon: const Icon(Icons.attach_file),
              ),
              Expanded(
                child: TextField(
                  controller: _text,
                  minLines: 1,
                  maxLines: 5,
                  textCapitalization: TextCapitalization.sentences,
                  inputFormatters: const [RuneLimit(2000)],
                  decoration: InputDecoration(
                    hintText: l.addUpdateHint,
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              _busy
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      ),
                    )
                  : IconButton.filled(
                      tooltip: l.send,
                      onPressed: canSend ? _send : null,
                      icon: const Icon(Icons.send),
                    ),
            ],
          ),
        ),
      ),
    );
  }
}
