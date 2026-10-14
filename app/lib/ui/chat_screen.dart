import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/chat_models.dart';
import '../data/models.dart';
import '../data/voice.dart';
import '../state/chat_providers.dart';
import '../state/providers.dart';
import '../theme.dart';
import 'chat_format.dart';
import 'files_common.dart';
import 'my_tasks_tab.dart';
import 'project_screen.dart';
import 'widgets.dart';

/// Who or what a chat is with, enough to draw it before anything loads.
class ChatTarget {
  const ChatTarget({
    required this.conversationId,
    required this.title,
    this.projectId,
    this.projectColor,
    this.otherId,
    this.otherActive = true,
    this.tagProjectIds = const [],
  });

  factory ChatTarget.of(Conversation c) => ChatTarget(
    conversationId: c.id,
    title: c.title,
    projectId: c.isProject ? c.projectId : null,
    projectColor: c.projectColor,
    otherId: c.otherId,
    otherActive: c.otherActive,
    tagProjectIds: c.tagProjectIds,
  );

  final String conversationId;
  final String title;

  /// Set for a project's group chat.
  final String? projectId;
  final String? projectColor;

  /// Set for a private chat.
  final String? otherId;
  final bool otherActive;
  final List<String> tagProjectIds;

  bool get isProject => projectId != null;
}

/// A chat on its own screen, optionally showing one project's messages.
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({
    super.key,
    required this.membership,
    required this.target,
    this.projectFilter,
  });

  final Membership membership;
  final ChatTarget target;
  final String? projectFilter;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  late String? _filter = widget.projectFilter;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final target = widget.target;
    final ws = widget.membership.workspaceId;
    final projects = ref.watch(projectsProvider(ws)).value ?? const [];
    Project? projectOf(String? id) =>
        projects.where((p) => p.id == id).firstOrNull;
    final filtered = projectOf(_filter);
    final project = projectOf(target.projectId);

    // Projects this private chat has been about, for the filter menu.
    final filterChoices = target.isProject
        ? const <Project>[]
        : [for (final id in target.tagProjectIds) ?projectOf(id)];

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        backgroundColor: theme.scaffoldBackgroundColor,
        shape: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
        title: InkWell(
          onTap: project == null
              ? null
              : () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ProjectScreen(
                      project: project,
                      initialTab: ProjectTab.files,
                    ),
                  ),
                ),
          child: Row(
            children: [
              if (target.isProject)
                ProjectAvatar(
                  name: target.title,
                  hex: target.projectColor ?? '#0F6E6A',
                  size: 40,
                )
              else
                Avatar(name: target.title, radius: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      target.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (project != null)
                      Text(
                        l.memberCount(project.memberCount),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      )
                    else if (!target.otherActive)
                      Text(
                        l.leftWorkspace,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (filterChoices.isNotEmpty && _filter == null)
            PopupMenuButton<String>(
              tooltip: l.filterByProject,
              icon: const Icon(LucideIcons.listFilter, size: 21),
              onSelected: (id) => setState(() => _filter = id),
              itemBuilder: (_) => [
                for (final p in filterChoices)
                  PopupMenuItem(
                    value: p.id,
                    child: Row(
                      children: [
                        ColorDot(hex: p.color),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(p.name, overflow: TextOverflow.ellipsis),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
        ],
      ),
      body: Column(
        children: [
          if (filtered != null)
            Material(
              color: theme.appBarTheme.backgroundColor,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Row(
                  children: [
                    Text(
                      l.viewing,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: InputChip(
                        avatar: ColorDot(hex: filtered.color),
                        label: Text(
                          filtered.name,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onDeleted: () => setState(() => _filter = null),
                        deleteButtonTooltipMessage: l.showAll,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Expanded(
            child: ChatView(
              key: ValueKey(_filter),
              membership: widget.membership,
              target: target,
              projectFilter: _filter,
            ),
          ),
        ],
      ),
    );
  }
}

/// A project's square avatar in its color.
class ProjectAvatar extends StatelessWidget {
  const ProjectAvatar({
    super.key,
    required this.name,
    required this.hex,
    this.size = 48,
  });

  final String name;
  final String hex;
  final double size;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final color = WaslaColors.project(hex, brightness);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(
          alpha: brightness == Brightness.dark ? 0.22 : 0.16,
        ),
        borderRadius: BorderRadius.circular(size / 3),
      ),
      child: Text(
        initials(name),
        style: TextStyle(
          color: WaslaColors.onTint(color, brightness),
          fontWeight: FontWeight.w700,
          fontSize: size * 0.38,
        ),
      ),
    );
  }
}

/// The messages and the box to write in. Also used inside a project.
class ChatView extends ConsumerStatefulWidget {
  const ChatView({
    super.key,
    required this.membership,
    required this.target,
    this.projectFilter,
  });

  final Membership membership;
  final ChatTarget target;
  final String? projectFilter;

  @override
  ConsumerState<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends ConsumerState<ChatView> {
  final _text = TextEditingController();
  ChatMessage? _replyTo;
  late String? _tag = widget.projectFilter;

  ChatKey get _key => (
    workspaceId: widget.membership.workspaceId,
    conversationId: widget.target.conversationId,
    projectId: widget.projectFilter,
  );

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _text.dispose();
    _recTick?.cancel();
    if (_rec != _Rec.off) ref.read(voiceRecorderProvider).cancel();
    super.dispose();
  }

  Future<void> _send({Upload? file}) async {
    final body = _text.text.trim();
    if (body.isEmpty && file == null) return;
    // Keep what was typed until the chat has loaded.
    if (!ref.read(chatProvider(_key)).hasValue) return;
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final reply = _replyTo;
    _text.clear();
    setState(() => _replyTo = null);
    try {
      await ref
          .read(chatProvider(_key).notifier)
          .send(
            body: body.isEmpty ? null : body,
            file: file,
            replyTo: reply,
            projectId: widget.target.isProject ? null : _tag,
          );
    } catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(errorText(l, e))));
    }
  }

  // Voice messages record while the mic is held, like WhatsApp: sliding up
  // locks the recording (hands free), sliding toward the text cancels it.
  _Rec _rec = _Rec.off;
  bool _pressed = false;
  Offset _drag = Offset.zero;
  final _recClock = Stopwatch();
  Timer? _recTick;

  Future<void> _pressMic() async {
    final l = context.l10n;
    final recorder = ref.read(voiceRecorderProvider);
    _pressed = true;
    _drag = Offset.zero;
    try {
      final started = await recorder.start();
      if (!mounted) return;
      if (!started) {
        showMessage(context, l.micDenied);
        return;
      }
      // Let go while the microphone was starting: that was a tap.
      if (!_pressed) {
        await recorder.cancel();
        if (mounted) showMessage(context, l.holdToRecord);
        return;
      }
      HapticFeedback.mediumImpact();
      _recClock
        ..reset()
        ..start();
      _recTick = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (_recClock.elapsed >= maxVoiceLength) {
          _finishRecording(send: true);
        } else {
          setState(() {});
        }
      });
      setState(() => _rec = _Rec.holding);
    } catch (e) {
      if (mounted) showMessage(context, errorText(l, e));
    }
  }

  void _dragMic(Offset offset) {
    if (_rec != _Rec.holding) return;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final inward = rtl ? offset.dx : -offset.dx;
    if (-offset.dy > _lockDistance) {
      HapticFeedback.selectionClick();
      setState(() {
        _rec = _Rec.locked;
        _drag = Offset.zero;
      });
    } else if (inward > _cancelDistance(context)) {
      HapticFeedback.heavyImpact();
      _finishRecording(send: false);
    } else {
      setState(() => _drag = offset);
    }
  }

  void _releaseMic() {
    _pressed = false;
    if (_rec == _Rec.holding) _finishRecording(send: true, tapHint: true);
  }

  void _cancelMic() {
    _pressed = false;
    if (_rec == _Rec.holding) _finishRecording(send: false);
  }

  Future<void> _finishRecording({
    required bool send,
    bool tapHint = false,
  }) async {
    if (_rec == _Rec.off) return;
    final l = context.l10n;
    final recorder = ref.read(voiceRecorderProvider);
    final length = _recClock.elapsed;
    _recTick?.cancel();
    _recClock.stop();
    setState(() {
      _rec = _Rec.off;
      _drag = Offset.zero;
    });
    // Under a second is a slip of the finger, not a message.
    if (!send || length < const Duration(seconds: 1)) {
      await recorder.cancel();
      if (send && tapHint && mounted) showMessage(context, l.holdToRecord);
      return;
    }
    try {
      final voice = await recorder.stop(length);
      if (voice != null && mounted) await _send(file: voice);
    } catch (e) {
      if (mounted) showMessage(context, errorText(l, e));
    }
  }

  Future<void> _attach() async {
    if (!ref.read(chatProvider(_key)).hasValue) return;
    final upload = await pickUpload(context, ref);
    if (upload != null && mounted) await _send(file: upload);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final chat = ref.watch(chatProvider(_key));
    final me = ref.watch(authProvider).value;
    final target = widget.target;
    final ws = widget.membership.workspaceId;
    final projects = ref.watch(projectsProvider(ws)).value ?? const [];
    final project = projects.where((p) => p.id == target.projectId).firstOrNull;
    final members = target.isProject
        ? ref.watch(projectMembersProvider(target.projectId!)).value
        : null;

    final closed = target.isProject
        ? (project != null && project.status != ProjectStatus.active)
        : !target.otherActive;
    final canModerate =
        target.isProject &&
        (widget.membership.role.canManage ||
            (members?.any(
                  (m) => m.userId == me && m.role == ProjectRole.lead,
                ) ??
                false));

    // Everyone who should read a message (besides its sender).
    List<String> readers(ChatMessage m) => target.isProject
        ? [
            for (final p in members ?? const <ProjectMember>[])
              if (p.userId != m.senderId) p.userId,
          ]
        : [
            if (target.otherId != null && target.otherId != m.senderId)
              target.otherId!,
          ];

    return Column(
      children: [
        Expanded(
          child: AsyncView(
            value: chat,
            onRetry: () => ref.invalidate(chatProvider(_key)),
            builder: (state) => _MessageList(
              state: state,
              me: me,
              showSenders: target.isProject,
              showTags: !target.isProject && widget.projectFilter == null,
              projects: projects,
              readers: readers,
              onLoadOlder: () =>
                  ref.read(chatProvider(_key).notifier).loadOlder(),
              onLongPress: (m) =>
                  _actions(m, me, canModerate, members, closed: closed),
              onRetry: (p) async {
                try {
                  await ref.read(chatProvider(_key).notifier).retry(p);
                } catch (e) {
                  if (context.mounted) showMessage(context, errorText(l, e));
                }
              },
              onDiscard: (p) =>
                  ref.read(chatProvider(_key).notifier).discard(p),
            ),
          ),
        ),
        if (_rec == _Rec.locked && !closed)
          _RecordingBar(
            elapsed: _recClock.elapsed,
            onCancel: () => _finishRecording(send: false),
            onSend: () => _finishRecording(send: true),
          )
        else if (closed)
          _ClosedNote(
            text: target.isProject
                ? l.chatClosedProject
                : l.chatClosedPerson(target.title),
          )
        else
          _Composer(
            controller: _text,
            replyTo: _replyTo,
            onCancelReply: () => setState(() => _replyTo = null),
            tagChoices: target.isProject
                ? null
                : [
                    for (final id
                        in ref
                                .watch(
                                  sharedProjectsProvider(target.conversationId),
                                )
                                .value ??
                            const <String>[])
                      ?projects.where((p) => p.id == id).firstOrNull,
                  ],
            tag: _tag,
            onTag: (id) => setState(() => _tag = id),
            onAttach: chat.hasValue ? _attach : null,
            onSend: chat.hasValue ? () => _send() : null,
            mic: chat.hasValue
                ? _Mic(
                    holding: _rec == _Rec.holding,
                    elapsed: _recClock.elapsed,
                    drag: _drag,
                    onPress: _pressMic,
                    onDrag: _dragMic,
                    onRelease: _releaseMic,
                    onCancel: _cancelMic,
                  )
                : null,
          ),
      ],
    );
  }

  Future<void> _actions(
    ChatMessage m,
    String? me,
    bool canModerate,
    List<ProjectMember>? members, {
    required bool closed,
  }) async {
    if (m.deleted) return;
    final l = context.l10n;
    final mine = m.senderId == me;
    // A task belongs to a project: this chat's, or the one the message is
    // tagged with; in an untagged private message one is picked.
    final taskProject = widget.target.projectId ?? m.projectId;
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.reply),
              title: Text(l.reply),
              onTap: () => Navigator.pop(context, 'reply'),
            ),
            if (m.body != null && m.body!.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.copy),
                title: Text(l.copy),
                onTap: () => Navigator.pop(context, 'copy'),
              ),
            if (m.file != null)
              ListTile(
                leading: const Icon(Icons.add_to_drive_outlined),
                title: Text(l.saveToDrive),
                onTap: () => Navigator.pop(context, 'drive'),
              ),
            if (!closed)
              ListTile(
                leading: const Icon(Icons.add_task),
                title: Text(l.makeTask),
                onTap: () => Navigator.pop(context, 'task'),
              ),
            if (mine && widget.target.isProject)
              ListTile(
                leading: const Icon(Icons.done_all),
                title: Text(l.seenByTitle),
                onTap: () => Navigator.pop(context, 'seen'),
              ),
            if (mine || canModerate)
              ListTile(
                leading: Icon(
                  Icons.delete_outline,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: Text(
                  l.deleteMessage,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                onTap: () => Navigator.pop(context, 'delete'),
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'reply':
        setState(() => _replyTo = m);
      case 'drive':
        await saveFileToDrive(context, ref, m.file!);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: m.body!));
        if (mounted) showMessage(context, l.copied);
      case 'task':
        final text = (m.body ?? '').trim();
        final firstLine = text.isEmpty
            ? m.file?.name ?? ''
            : text.split('\n').first;
        final title = firstLine.length > 200
            ? firstLine.substring(0, 200)
            : firstLine;
        await newTask(
          context,
          workspaceId: widget.membership.workspaceId,
          projectId: taskProject,
          lockProject: widget.target.isProject,
          title: title,
          description: text.isEmpty || text == title ? null : text,
          sourceMessageId: m.id,
        );
      case 'seen':
        _showSeenBy(m, members ?? const []);
      case 'delete':
        if (!await confirm(
          context,
          message: l.confirmDeleteMessage,
          action: l.delete,
          destructive: true,
        )) {
          return;
        }
        if (!mounted) return;
        await runAction(
          context,
          () => ref.read(chatProvider(_key).notifier).delete(m),
        );
    }
  }

  void _showSeenBy(ChatMessage m, List<ProjectMember> members) {
    final l = context.l10n;
    final state = ref.read(chatProvider(_key)).value;
    final seen = [
      for (final p in members)
        if (p.userId != m.senderId)
          if (state?.readBy(p.userId) case final at?
              when !at.isBefore(m.createdAt))
            (p, at),
    ];
    final notSeen = [
      for (final p in members)
        if (p.userId != m.senderId && !seen.any((s) => s.$1.userId == p.userId))
          p,
    ];
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  l.seenByTitle,
                  style: Theme.of(context).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              if (seen.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(l.notSeenYet),
                ),
              for (final (p, at) in seen)
                ListTile(
                  leading: Avatar(name: p.fullName),
                  title: Text(p.fullName),
                  trailing: Text(listTime(context, at)),
                ),
              if (notSeen.isNotEmpty && seen.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SectionTitle('${l.seenNotYet} (${notSeen.length})'),
                ),
                for (final p in notSeen)
                  ListTile(
                    leading: Avatar(name: p.fullName),
                    title: Text(p.fullName),
                  ),
              ],
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

class _ClosedNote extends StatelessWidget {
  const _ClosedNote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.appBarTheme.backgroundColor,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(
                Icons.lock_outline,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
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

/// One row in the list: a message, a message being sent, or a day line.
sealed class _Item {
  const _Item();
}

class _MessageItem extends _Item {
  const _MessageItem(
    this.message, {
    required this.showSender,
    required this.showAvatar,
  });
  final ChatMessage message;
  final bool showSender;

  /// Null in a private chat; otherwise whether this is the last of a run
  /// from one person, which carries their picture.
  final bool? showAvatar;
}

class _PendingItem extends _Item {
  const _PendingItem(this.message);
  final PendingMessage message;
}

class _DayItem extends _Item {
  const _DayItem(this.day);
  final DateTime day;
}

class _MessageList extends StatelessWidget {
  const _MessageList({
    required this.state,
    required this.me,
    required this.showSenders,
    required this.showTags,
    required this.projects,
    required this.readers,
    required this.onLoadOlder,
    required this.onLongPress,
    required this.onRetry,
    required this.onDiscard,
  });

  final ChatState state;
  final String? me;
  final bool showSenders;
  final bool showTags;
  final List<Project> projects;
  final List<String> Function(ChatMessage) readers;
  final VoidCallback onLoadOlder;
  final void Function(ChatMessage) onLongPress;
  final void Function(PendingMessage) onRetry;
  final void Function(PendingMessage) onDiscard;

  static bool _sameDay(DateTime a, DateTime b) {
    final x = a.toLocal(), y = b.toLocal();
    return x.year == y.year && x.month == y.month && x.day == y.day;
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final messages = state.messages;
    if (messages.isEmpty && state.pending.isEmpty) {
      return EmptyState(
        icon: Icons.chat_bubble_outline,
        title: l.noMessagesYet,
        body: l.firstMessageHint,
      );
    }

    // Newest first, because the list grows upwards from the bottom.
    final items = <_Item>[
      for (final p in state.pending.reversed) _PendingItem(p),
    ];
    for (var i = 0; i < messages.length; i++) {
      final m = messages[i];
      final older = i + 1 < messages.length ? messages[i + 1] : null;
      final newer = i > 0 ? messages[i - 1] : null;
      final newDay = older == null || !_sameDay(older.createdAt, m.createdAt);
      final lastOfRun =
          newer == null ||
          newer.senderId != m.senderId ||
          !_sameDay(newer.createdAt, m.createdAt);
      items.add(
        _MessageItem(
          m,
          showSender:
              showSenders &&
              m.senderId != me &&
              (newDay || older.senderId != m.senderId),
          showAvatar: showSenders && m.senderId != me ? lastOfRun : null,
        ),
      );
      if (newDay && (older != null || !state.hasMore)) {
        items.add(_DayItem(m.createdAt));
      }
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.extentAfter < 400) onLoadOlder();
        return false;
      },
      child: ListView.builder(
        reverse: true,
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        itemCount: items.length + (state.loadingOlder ? 1 : 0),
        itemBuilder: (context, i) {
          if (i == items.length) {
            return const Padding(
              padding: EdgeInsets.all(12),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          return switch (items[i]) {
            _DayItem(:final day) => _DayLine(day: day),
            _PendingItem(:final message) => _PendingBubble(
              message: message,
              onRetry: () => onRetry(message),
              onDiscard: () => onDiscard(message),
            ),
            _MessageItem(
              :final message,
              :final showSender,
              :final showAvatar,
            ) =>
              _Bubble(
                message: message,
                showAvatar: showAvatar,
                mine: message.senderId == me,
                showSender: showSender,
                tag: showTags
                    ? projects
                          .where((p) => p.id == message.projectId)
                          .firstOrNull
                    : null,
                read: _readByAll(message),
                onLongPress: () => onLongPress(message),
              ),
          };
        },
      ),
    );
  }

  bool _readByAll(ChatMessage m) {
    final who = readers(m);
    if (who.isEmpty) return false;
    for (final id in who) {
      final at = state.readBy(id);
      if (at == null || at.isBefore(m.createdAt)) return false;
    }
    return true;
  }
}

class _DayLine extends StatelessWidget {
  const _DayLine({required this.day});

  final DateTime day;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 10),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(99),
        ),
        child: Text(
          dayLabel(context, day),
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

Color _bubbleColor(BuildContext context, bool mine) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  if (!mine) return Theme.of(context).colorScheme.surface;
  return dark ? const Color(0xFF145550) : WaslaColors.accent;
}

/// Rounded, with a small corner on the side the bubble hangs from.
BorderRadiusDirectional _bubbleShape(bool mine) => BorderRadiusDirectional.only(
  topStart: const Radius.circular(18),
  topEnd: const Radius.circular(18),
  bottomStart: Radius.circular(mine ? 18 : 6),
  bottomEnd: Radius.circular(mine ? 6 : 18),
);

/// My messages sit on solid teal, so what is inside them reads in light
/// colors.
ThemeData _bubbleTheme(BuildContext context, bool mine) {
  final theme = Theme.of(context);
  if (!mine) return theme;
  final dark = theme.brightness == Brightness.dark;
  final fg = dark ? const Color(0xFFEAF6F4) : Colors.white;
  return theme.copyWith(
    colorScheme: theme.colorScheme.copyWith(
      onSurface: fg,
      onSurfaceVariant: fg.withValues(alpha: 0.78),
      primary: dark ? const Color(0xFF8FE3DA) : const Color(0xFFB5ECE5),
      error: const Color(0xFFFFC9B8),
    ),
    textTheme: theme.textTheme.apply(bodyColor: fg, displayColor: fg),
    iconTheme: theme.iconTheme.copyWith(color: fg),
  );
}

/// The inside of a bubble, in the bubble's colors.
Widget _inBubble(ThemeData theme, Widget child) => Theme(
  data: theme,
  child: DefaultTextStyle.merge(
    style: TextStyle(color: theme.colorScheme.onSurface),
    child: IconTheme.merge(
      data: IconThemeData(color: theme.colorScheme.onSurface),
      child: child,
    ),
  ),
);

class _Bubble extends ConsumerWidget {
  const _Bubble({
    required this.message,
    this.showAvatar,
    required this.mine,
    required this.showSender,
    required this.tag,
    required this.read,
    required this.onLongPress,
  });

  final ChatMessage message;
  final bool? showAvatar;
  final bool mine;
  final bool showSender;
  final Project? tag;
  final bool read;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final theme = _bubbleTheme(context, mine);
    final muted = theme.colorScheme.onSurfaceVariant;
    final m = message;
    final file = m.file;
    final maxWidth = MediaQuery.sizeOf(context).width * 0.78;
    // A photo or video fills its bubble, with only a thin edge around it.
    final media = !m.deleted && file != null && (file.isImage || file.isVideo);

    final content = <Widget>[
      if (showSender)
        Padding(
          padding: media
              ? const EdgeInsets.fromLTRB(6, 2, 6, 4)
              : const EdgeInsets.only(bottom: 2),
          child: Text(
            m.senderName,
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: WaslaColors.onTint(
                WaslaColors.project(
                  WaslaColors.projectColors[m.senderName.hashCode.abs() %
                      WaslaColors.projectColors.length],
                  theme.brightness,
                ),
                theme.brightness,
              ),
            ),
          ),
        ),
      if (m.deleted)
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.block, size: 16, color: muted),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                l.messageDeleted,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: muted,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          ],
        )
      else ...[
        if (m.replyTo != null) _Quote(message: m),
        if (file != null && (file.isImage || file.isVideo))
          ChatMedia(
            file: file,
            width: math.min(maxWidth - 8, 260),
            onTap: () => openFile(context, ref, file),
          )
        else if (file != null && file.isAudio)
          VoicePlayer(file: file, width: math.min(maxWidth - 24, 240))
        else if (file != null)
          InkWell(
            onTap: () => openFile(context, ref, file),
            borderRadius: BorderRadius.circular(10),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: mine
                    ? Colors.white.withValues(alpha: 0.14)
                    : theme.scaffoldBackgroundColor,
                borderRadius: BorderRadius.circular(10),
              ),
              child: FileRow(file: file, detail: fileSize(l, file.size)),
            ),
          ),
        if (m.body != null && m.body!.isNotEmpty)
          Padding(
            padding: media
                ? const EdgeInsets.fromLTRB(6, 6, 6, 0)
                : EdgeInsets.only(top: file != null ? 6 : 0),
            child: Text(
              m.body!,
              style: theme.textTheme.bodyLarge?.copyWith(height: 1.45),
            ),
          ),
        for (final link in linksIn(m.body ?? '').take(3))
          Padding(
            padding: EdgeInsets.fromLTRB(media ? 6 : 0, 6, media ? 6 : 0, 0),
            child: _LinkChip(url: link),
          ),
      ],
      const SizedBox(height: 4),
      Padding(
        padding: EdgeInsets.symmetric(horizontal: media ? 6 : 0),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (tag != null) ...[
              Flexible(child: _TagChip(project: tag!)),
              const SizedBox(width: 8),
            ],
            Text(
              clockTime(context, m.createdAt),
              style: theme.textTheme.labelSmall?.copyWith(color: muted),
            ),
            if (mine && !m.deleted) ...[
              const SizedBox(width: 4),
              Icon(
                read ? Icons.done_all : Icons.done,
                size: 16,
                color: read ? theme.colorScheme.primary : muted,
              ),
            ],
          ],
        ),
      ),
    ];

    final avatar = showAvatar;
    return Align(
      alignment: mine
          ? AlignmentDirectional.centerEnd
          : AlignmentDirectional.centerStart,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (avatar != null) ...[
              avatar
                  ? Avatar(name: m.senderName, radius: 14)
                  : const SizedBox(width: 28),
              const SizedBox(width: 8),
            ],
            Flexible(child: _bubbleBody(context, theme, content, maxWidth)),
          ],
        ),
      ),
    );
  }

  Widget _bubbleBody(
    BuildContext context,
    ThemeData theme,
    List<Widget> content,
    double maxWidth,
  ) {
    final m = message;
    final file = m.file;
    final media = !m.deleted && file != null && (file.isImage || file.isVideo);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Material(
        color: _bubbleColor(context, mine),
        borderRadius: _bubbleShape(mine),
        child: InkWell(
          customBorder: RoundedRectangleBorder(
            borderRadius: _bubbleShape(mine),
          ),
          onLongPress: onLongPress,
          child: Padding(
            padding: media
                ? const EdgeInsets.fromLTRB(4, 4, 4, 4)
                : const EdgeInsets.fromLTRB(12, 8, 12, 6),
            child: _inBubble(
              theme,
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: content,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A link in a message, one tap from opening; Google Drive and Docs links
/// say so.
class _LinkChip extends StatelessWidget {
  const _LinkChip({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final host = Uri.tryParse(url)?.host ?? '';
    final drive =
        host == 'drive.google.com' ||
        host == 'docs.google.com' ||
        host == 'sheets.google.com';
    return Material(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => openLink(context, url),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(drive ? Icons.add_to_drive : Icons.link, size: 20),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  drive ? l.googleDriveLink : host,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge,
                ),
              ),
              const SizedBox(width: 6),
              const Icon(Icons.open_in_new, size: 16),
            ],
          ),
        ),
      ),
    );
  }
}

class _Quote extends StatelessWidget {
  const _Quote({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final file = message.replyFileName;
    final text =
        message.replyBody ??
        (file == null ? null : fileLabel(l, file)) ??
        l.messageDeleted;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsetsDirectional.fromSTEB(10, 6, 10, 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: BorderDirectional(
          start: BorderSide(color: theme.colorScheme.primary, width: 3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message.replySenderName ?? '',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
          Text(
            text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _TagChip extends StatelessWidget {
  const _TagChip({required this.project});

  final Project project;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final color = WaslaColors.project(project.color, brightness);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        project.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          color: WaslaColors.onTint(color, brightness),
        ),
      ),
    );
  }
}

class _PendingBubble extends StatelessWidget {
  const _PendingBubble({
    required this.message,
    required this.onRetry,
    required this.onDiscard,
  });

  final PendingMessage message;
  final VoidCallback onRetry;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = _bubbleTheme(context, true);
    final muted = theme.colorScheme.onSurfaceVariant;
    final file = message.file;
    return Align(
      alignment: AlignmentDirectional.centerEnd,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.78,
          ),
          child: Material(
            color: _bubbleColor(context, true),
            borderRadius: _bubbleShape(true),
            child: InkWell(
              customBorder: RoundedRectangleBorder(
                borderRadius: _bubbleShape(true),
              ),
              onTap: message.failed ? onRetry : null,
              onLongPress: message.failed ? onDiscard : null,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                child: _inBubble(
                  theme,
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (file != null)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            FileBadge(name: file.name, size: 32),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                fileLabel(l, file.name),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      if (message.body != null)
                        Text(message.body!, style: theme.textTheme.bodyLarge),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (message.failed)
                            Flexible(
                              child: Text(
                                l.sendFailed,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.error,
                                ),
                              ),
                            )
                          else
                            Text(
                              l.sending,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: muted,
                              ),
                            ),
                          const SizedBox(width: 4),
                          Icon(
                            message.failed
                                ? Icons.error_outline
                                : Icons.schedule,
                            size: 16,
                            color: message.failed
                                ? theme.colorScheme.error
                                : muted,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _Rec { off, holding, locked }

/// How far the mic is slid up to lock a recording: all the way to the lock
/// above it.
const _lockDistance = 130.0;

/// Where the lock sits above the mic button.
const _lockHintBottom = 100.0;

/// How far the mic is slid toward the text to cancel: most of the way to
/// the "slide to cancel" label.
double _cancelDistance(BuildContext context) =>
    math.max(150.0, MediaQuery.sizeOf(context).width * 0.45);

String _clockText(Duration t) =>
    '${t.inMinutes}:${(t.inSeconds % 60).toString().padLeft(2, '0')}';

/// The mic and what holding it is doing right now.
class _Mic {
  const _Mic({
    required this.holding,
    required this.elapsed,
    required this.drag,
    required this.onPress,
    required this.onDrag,
    required this.onRelease,
    required this.onCancel,
  });

  final bool holding;
  final Duration elapsed;

  /// Where the finger is from where it pressed.
  final Offset drag;
  final VoidCallback onPress;
  final void Function(Offset) onDrag;
  final VoidCallback onRelease;
  final VoidCallback onCancel;
}

/// Shown instead of the composer once a recording is locked.
class _RecordingBar extends StatelessWidget {
  const _RecordingBar({
    required this.elapsed,
    required this.onCancel,
    required this.onSend,
  });

  final Duration elapsed;
  final VoidCallback onCancel;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    return Material(
      color: theme.scaffoldBackgroundColor,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
          child: Row(
            children: [
              IconButton(
                key: const Key('cancelRecording'),
                tooltip: l.cancelRecording,
                onPressed: onCancel,
                color: theme.colorScheme.error,
                icon: const Icon(Icons.delete_outline),
              ),
              Expanded(
                child: Container(
                  height: 50,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    borderRadius: BorderRadius.circular(25),
                  ),
                  child: Row(
                    children: [
                      const _RecordingDot(),
                      const SizedBox(width: 8),
                      Expanded(child: Text(l.recording)),
                      _Clock(elapsed),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox.square(
                dimension: 50,
                child: IconButton.filled(
                  key: const Key('sendVoice'),
                  tooltip: l.send,
                  onPressed: onSend,
                  icon: const Icon(Icons.send),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Clock extends StatelessWidget {
  const _Clock(this.elapsed);

  final Duration elapsed;

  @override
  Widget build(BuildContext context) => Text(
    _clockText(elapsed),
    textDirection: TextDirection.ltr,
    style: Theme.of(context).textTheme.titleSmall
        ?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
  );
}

/// A red dot that fades in and out while recording.
class _RecordingDot extends StatefulWidget {
  const _RecordingDot();

  @override
  State<_RecordingDot> createState() => _RecordingDotState();
}

class _RecordingDotState extends State<_RecordingDot>
    with SingleTickerProviderStateMixin {
  late final _blink = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: Tween(begin: 1.0, end: 0.25).animate(_blink),
    child: Icon(
      Icons.mic,
      size: 20,
      color: Theme.of(context).colorScheme.error,
    ),
  );
}

/// Over the text field while the mic is held: the time, and how to cancel.
class _HoldingStrip extends StatelessWidget {
  const _HoldingStrip({required this.mic});

  final _Mic mic;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final inward = math.max(0.0, rtl ? mic.drag.dx : -mic.drag.dx);
    final progress = (inward / _cancelDistance(context)).clamp(0.0, 1.0);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(25),
      ),
      child: Row(
        children: [
          const _RecordingDot(),
          const SizedBox(width: 8),
          _Clock(mic.elapsed),
          const Spacer(),
          Opacity(
            opacity: 1 - progress * 0.8,
            child: Transform.translate(
              offset: Offset(rtl ? inward * 0.5 : -inward * 0.5, 0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.arrow_back_ios,
                    size: 14,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  Text(
                    l.slideToCancel,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The mic: press and hold to record. It grows and pulses while held,
/// follows the finger, and shows the lock to slide up to.
class _MicButton extends StatefulWidget {
  const _MicButton({required this.mic});

  final _Mic mic;

  @override
  State<_MicButton> createState() => _MicButtonState();
}

class _MicButtonState extends State<_MicButton>
    with SingleTickerProviderStateMixin {
  Offset? _down;
  late final _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void didUpdateWidget(_MicButton old) {
    super.didUpdateWidget(old);
    if (widget.mic.holding && !_pulse.isAnimating) {
      _pulse.repeat();
    } else if (!widget.mic.holding && _pulse.isAnimating) {
      _pulse
        ..stop()
        ..reset();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final mic = widget.mic;
    final holding = mic.holding;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    // The button follows the finger up toward the lock and inward toward
    // cancel, no further.
    final up = holding ? (-mic.drag.dy).clamp(0.0, _lockDistance) : 0.0;
    final inward = holding
        ? (rtl ? mic.drag.dx : -mic.drag.dx).clamp(
            0.0,
            _cancelDistance(context),
          )
        : 0.0;
    final follow = Offset(rtl ? inward : -inward, -up);
    final color = holding ? theme.colorScheme.error : theme.colorScheme.primary;

    return Semantics(
      button: true,
      label: l.holdToRecord,
      child: Listener(
        key: const Key('micButton'),
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) {
          _down = e.position;
          mic.onPress();
        },
        onPointerMove: (e) {
          if (_down != null) mic.onDrag(e.position - _down!);
        },
        onPointerUp: (_) {
          _down = null;
          mic.onRelease();
        },
        onPointerCancel: (_) {
          _down = null;
          mic.onCancel();
        },
        // Claims the drag, so sliding the mic doesn't also swipe the
        // project's tabs or scroll the page.
        child: GestureDetector(
          onPanStart: (_) {},
          onPanUpdate: (_) {},
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              if (holding)
                Positioned(
                  bottom: _lockHintBottom,
                  child: _LockHint(progress: up / _lockDistance),
                ),
              Transform.translate(
                offset: follow,
                child: AnimatedScale(
                  scale: holding ? 1.45 : 1,
                  duration: const Duration(milliseconds: 150),
                  curve: Curves.easeOut,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      if (holding)
                        AnimatedBuilder(
                          animation: _pulse,
                          builder: (context, _) => Container(
                            width: 50 + 24 * _pulse.value,
                            height: 50 + 24 * _pulse.value,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: color.withValues(
                                alpha: 0.35 * (1 - _pulse.value),
                              ),
                            ),
                          ),
                        ),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        width: 50,
                        height: 50,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: color,
                        ),
                        child: Icon(
                          LucideIcons.mic,
                          size: 22,
                          color: theme.colorScheme.onPrimary,
                        ),
                      ),
                    ],
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

/// Above the held mic: slide up to here to keep recording hands free.
class _LockHint extends StatelessWidget {
  const _LockHint({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const Key('lockHint'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [BoxShadow(blurRadius: 6, color: Color(0x22000000))],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            progress > 0.6 ? Icons.lock : Icons.lock_open,
            size: 20,
            color: Color.lerp(
              theme.colorScheme.onSurfaceVariant,
              theme.colorScheme.primary,
              progress,
            ),
          ),
          Icon(
            Icons.keyboard_arrow_up,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.replyTo,
    required this.onCancelReply,
    required this.tagChoices,
    required this.tag,
    required this.onTag,
    required this.onAttach,
    required this.onSend,
    required this.mic,
  });

  final TextEditingController controller;
  final ChatMessage? replyTo;
  final VoidCallback onCancelReply;

  /// Projects a private message can be filed under; null in a project chat.
  final List<Project>? tagChoices;
  final String? tag;
  final void Function(String?) onTag;

  /// Null until the chat has loaded.
  final VoidCallback? onAttach;
  final VoidCallback? onSend;

  /// The voice-message mic; null until the chat has loaded.
  final _Mic? mic;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final choices = tagChoices;
    final tagged = choices?.where((p) => p.id == tag).firstOrNull;
    final canSend = controller.text.trim().isNotEmpty;

    return Material(
      color: theme.scaffoldBackgroundColor,
      child: SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (replyTo case final r?)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 0, 6),
                  child: Row(
                    children: [
                      Icon(Icons.reply, size: 18, color: muted),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '${l.replyingTo(r.senderName)}: '
                          '${r.body ?? r.file?.name ?? ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: muted,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: l.cancel,
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: onCancelReply,
                      ),
                    ],
                  ),
                ),
              if (choices != null && choices.isNotEmpty)
                Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(8, 0, 8, 6),
                  child: Row(
                    children: [
                      Text(
                        l.sendTo,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: muted,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: PopupMenuButton<String>(
                          tooltip: l.sendTo,
                          onSelected: (id) => onTag(id.isEmpty ? null : id),
                          itemBuilder: (_) => [
                            PopupMenuItem(
                              value: '',
                              child: Text(l.noProjectTag),
                            ),
                            for (final p in choices)
                              PopupMenuItem(
                                value: p.id,
                                child: Row(
                                  children: [
                                    ColorDot(hex: p.color),
                                    const SizedBox(width: 10),
                                    Flexible(
                                      child: Text(
                                        p.name,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: tagged == null
                                  ? null
                                  : theme.colorScheme.primaryContainer,
                              border: Border.all(
                                color: theme.colorScheme.outlineVariant,
                              ),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (tagged != null) ...[
                                  ColorDot(hex: tagged.color, size: 8),
                                  const SizedBox(width: 6),
                                ],
                                Flexible(
                                  child: Text(
                                    tagged?.name ?? l.noProjectTag,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.labelMedium
                                        ?.copyWith(
                                          color: tagged == null
                                              ? muted
                                              : theme.colorScheme.primary,
                                          fontWeight: FontWeight.w600,
                                        ),
                                  ),
                                ),
                                Icon(
                                  Icons.arrow_drop_down,
                                  size: 18,
                                  color: muted,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Stack(
                      children: [
                        Container(
                          constraints: const BoxConstraints(minHeight: 48),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surface,
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(
                              color: theme.colorScheme.outlineVariant,
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Expanded(
                                child: TextField(
                                  key: const Key('messageField'),
                                  controller: controller,
                                  minLines: 1,
                                  maxLines: 5,
                                  inputFormatters: const [RuneLimit(4000)],
                                  textCapitalization:
                                      TextCapitalization.sentences,
                                  decoration: InputDecoration(
                                    hintText: l.typeMessage,
                                    isDense: true,
                                    filled: false,
                                    border: InputBorder.none,
                                    enabledBorder: InputBorder.none,
                                    focusedBorder: InputBorder.none,
                                    contentPadding:
                                        const EdgeInsetsDirectional.fromSTEB(
                                          18,
                                          15,
                                          4,
                                          15,
                                        ),
                                  ),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.all(3),
                                child: IconButton(
                                  tooltip: l.attach,
                                  onPressed: onAttach,
                                  color: muted,
                                  icon: const Icon(
                                    LucideIcons.paperclip,
                                    size: 21,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (mic?.holding ?? false)
                          Positioned.fill(child: _HoldingStrip(mic: mic!)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox.square(
                    dimension: 50,
                    child: canSend || mic == null
                        ? IconButton.filled(
                            key: const Key('sendButton'),
                            tooltip: l.send,
                            onPressed: canSend ? onSend : null,
                            icon: const Icon(
                              LucideIcons.sendHorizontalDir,
                              size: 21,
                            ),
                          )
                        : _MicButton(mic: mic!),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
