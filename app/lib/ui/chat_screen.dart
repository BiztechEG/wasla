import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show NumberFormat;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/chat_models.dart';
import '../data/drops.dart';
import '../data/models.dart';
import '../data/voice.dart';
import '../state/chat_providers.dart';
import '../state/providers.dart';
import '../theme.dart';
import 'chat_format.dart';
import 'emoji.dart';
import 'files_common.dart';
import 'mentions.dart';
import 'my_tasks_tab.dart';
import 'profile_card.dart';
import 'project_screen.dart';
import 'status.dart';
import 'task_editor.dart';
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
    this.initialMessageId,
  });

  final Membership membership;
  final ChatTarget target;
  final String? projectFilter;

  /// Opens the chat at this message, lit up, as when jumping to a quote.
  final String? initialMessageId;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  late String? _filter = widget.projectFilter;

  /// Unmutes, or asks for how long to mute.
  Future<void> _toggleMute(bool muted) async {
    final l = context.l10n;
    final api = ref.read(apiProvider);
    final id = widget.target.conversationId;
    final ws = widget.membership.workspaceId;
    if (muted) {
      final ok = await runAction(
        context,
        () => api.unmuteConversation(id),
        done: l.chatUnmuted,
      );
      if (ok) ref.invalidate(mutedChatsProvider(ws));
      return;
    }
    final choice = await showModalBottomSheet<Duration>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text(
                l.muteChat,
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(l.muteHint),
            ),
            for (final (label, length) in [
              (l.mute8h, const Duration(hours: 8)),
              (l.muteWeek, const Duration(days: 7)),
              // Zero stands for "until unmuted".
              (l.muteAlways, Duration.zero),
            ])
              ListTile(
                leading: const Icon(LucideIcons.bellOff),
                title: Text(label),
                onTap: () => Navigator.pop(context, length),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    final ok = await runAction(
      context,
      () => api.muteConversation(
        id,
        until: choice == Duration.zero ? null : DateTime.now().add(choice),
      ),
      done: l.chatMuted,
    );
    if (ok) ref.invalidate(mutedChatsProvider(ws));
  }

  /// The chat as shown with each project filter, for the calendar button.
  final _views = <String?, GlobalKey<_ChatViewState>>{};

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final target = widget.target;
    final ws = widget.membership.workspaceId;
    final projects = ref.watch(projectsProvider(ws)).value ?? const [];
    final muted =
        ref
            .watch(mutedChatsProvider(ws))
            .value
            ?.containsKey(target.conversationId) ??
        false;
    Project? projectOf(String? id) =>
        projects.where((p) => p.id == id).firstOrNull;
    final filtered = projectOf(_filter);
    final project = projectOf(target.projectId);
    final otherStatus = target.otherId == null
        ? null
        : ref.watch(statusesProvider(ws)).value?[target.otherId];

    // Projects this private chat has been about, for the filter menu.
    final filterChoices = target.isProject
        ? const <Project>[]
        : [for (final id in target.tagProjectIds) ?projectOf(id)];

    // A project's status, or the other person's card.
    final VoidCallback? openDetails;
    if (project != null) {
      openDetails = () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              ProjectScreen(project: project, initialTab: ProjectTab.status),
        ),
      );
    } else if (target.otherId case final other?) {
      openDetails = () => showProfileCard(
        context,
        ref,
        membership: widget.membership,
        userId: other,
        name: target.title,
        inPrivateChat: true,
      );
    } else {
      openDetails = null;
    }

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        backgroundColor: theme.scaffoldBackgroundColor,
        shape: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
        title: InkWell(
          onTap: openDetails,
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
                        '${l.memberCount(project.memberCount)} · '
                        '${l.tapForDetails}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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
                      )
                    else if (otherStatus != null)
                      Row(
                        key: const Key('chatStatus'),
                        children: [
                          PresenceDot(kind: otherStatus.kind, size: 9),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              presenceText(context, otherStatus),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      )
                    else if (openDetails != null)
                      Text(
                        l.tapForProfile,
                        maxLines: 1,
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
          IconButton(
            key: const Key('muteChat'),
            tooltip: muted ? l.unmuteChat : l.muteChat,
            icon: Icon(
              muted ? LucideIcons.bellOff : LucideIcons.bell,
              size: 21,
            ),
            onPressed: () => _toggleMute(muted),
          ),
          IconButton(
            key: const Key('jumpToDate'),
            tooltip: l.jumpToDate,
            icon: const Icon(LucideIcons.calendarSearch, size: 21),
            onPressed: () => _views[_filter]?.currentState?._pickDate(),
          ),
          if (openDetails != null)
            IconButton(
              key: const Key('chatDetails'),
              tooltip: l.chatDetails,
              icon: const Icon(LucideIcons.info, size: 21),
              onPressed: openDetails,
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
              key: _views.putIfAbsent(_filter, GlobalKey.new),
              membership: widget.membership,
              target: target,
              projectFilter: _filter,
              initialMessageId: _filter == widget.projectFilter
                  ? widget.initialMessageId
                  : null,
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
    this.initialMessageId,
  });

  final Membership membership;
  final ChatTarget target;
  final String? projectFilter;

  /// Opens the chat at this message, lit up.
  final String? initialMessageId;

  @override
  ConsumerState<ChatView> createState() => _ChatViewState();
}

/// Over a chat while files from the computer are dragged onto it.
class _DropHint extends StatelessWidget {
  const _DropHint();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const Key('dropHint'),
      margin: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.primary, width: 2),
      ),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.upload, size: 40, color: scheme.onPrimaryContainer),
          const SizedBox(height: 12),
          Text(
            context.l10n.dropFilesHere,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: scheme.onPrimaryContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// A phone's on-screen keyboard; with a real keyboard (web, a computer)
/// Enter sends.
bool get _onPhone =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// Enter sends (through [onEnter]) and Shift+Enter starts a new line, as in
/// WhatsApp Web. On a phone Enter keeps making new lines.
FocusOnKeyEventCallback _enterSends(
  TextEditingController text,
  VoidCallback onEnter,
) => (node, event) {
  if (_onPhone || event is! KeyDownEvent) return KeyEventResult.ignored;
  final key = event.logicalKey;
  if (key != LogicalKeyboardKey.enter &&
      key != LogicalKeyboardKey.numpadEnter) {
    return KeyEventResult.ignored;
  }
  // Shift+Enter is a new line; Enter while typing with an input method
  // (composing a word) belongs to it.
  if (HardwareKeyboard.instance.isShiftPressed ||
      text.value.composing.isValid) {
    return KeyEventResult.ignored;
  }
  onEnter();
  return KeyEventResult.handled;
};

class _ChatViewState extends ConsumerState<ChatView> {
  final _text = TextEditingController();
  late final _focus = FocusNode(onKeyEvent: _enterSends(_text, _onEnter));
  final _scroll = ScrollController();
  ChatMessage? _replyTo;

  /// The emoji picker is open under the message field.
  bool _emojiOpen = false;

  /// Who can be mentioned here, as of the last build.
  List<MentionCandidate> _candidates = const [];

  /// The mention being typed and who it could be, as of the last build.
  ({int start, String query})? _mentionAt;
  List<MentionCandidate> _suggestions = const [];
  late String? _tag = widget.projectFilter;

  /// Text too long for one message, waiting to go as a file (or, if the
  /// person prefers, as several messages in a row).
  String? _long;
  bool _longAsFile = true;

  /// One key per message, so a quoted message can be scrolled to.
  final _keys = <String, GlobalKey>{};

  /// The message just jumped to, lit up for a moment.
  String? _flash;
  Timer? _flashTimer;
  bool _jumping = false;

  /// Files from the computer are being dragged over this chat.
  bool _dropHover = false;

  /// Whether files can be sent here now, as of the last build.
  bool _takesFiles = false;
  final _dropSubs = <StreamSubscription<Object?>>[];

  ChatKey get _key => (
    workspaceId: widget.membership.workspaceId,
    conversationId: widget.target.conversationId,
    projectId: widget.projectFilter,
  );

  /// Wraps the list, to tell which messages are below the screen.
  final _listKey = GlobalKey();

  /// Messages newer than the newest one on screen; null when the newest
  /// messages are in view (and "Latest" is hidden).
  int? _newer;

  @override
  void initState() {
    super.initState();
    _text.addListener(_onText);
    _scroll.addListener(_countNewer);
    final drops = ref.read(fileDropsProvider);
    _dropSubs.addAll([
      drops.hover.listen((at) {
        final over = at != null && _takesDropAt(at);
        if (over != _dropHover && mounted) setState(() => _dropHover = over);
      }),
      drops.dropped.listen(_dropped),
    ]);
    if (widget.initialMessageId case final id?) {
      var done = false;
      ref.listenManual(chatProvider(_key), (_, next) {
        if (done || !next.hasValue) return;
        done = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _jumpTo(id);
        });
      }, fireImmediately: true);
    }
  }

  /// Far from the bottom, counts the messages below the screen.
  void _countNewer() {
    if (!_scroll.hasClients || !mounted) return;
    final at = _scroll.position;
    int? count;
    if (at.pixels > at.viewportDimension * 1.5) {
      count = 0;
      final list = _listKey.currentContext?.findRenderObject() as RenderBox?;
      final messages = ref.read(chatProvider(_key)).value?.messages;
      if (list != null && list.attached && messages != null) {
        final bottom = list.localToGlobal(Offset(0, list.size.height)).dy;
        for (final m in messages) {
          final box = _keys[m.id]?.currentContext?.findRenderObject();
          if (box is RenderBox && box.attached && box.hasSize) {
            if (box.localToGlobal(Offset.zero).dy < bottom - 24) break;
          }
          count = count! + 1;
        }
      }
    }
    if (count != _newer) setState(() => _newer = count);
  }

  void _toLatest() {
    if (!_scroll.hasClients) return;
    final at = _scroll.position;
    if (at.pixels > at.viewportDimension * 6) {
      _scroll.jumpTo(0);
    } else {
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  /// The calendar: picks a day and opens the chat at its first message.
  Future<void> _pickDate([DateTime? initial]) async {
    final key = (
      conversationId: widget.target.conversationId,
      projectId: widget.projectFilter,
    );
    ref.invalidate(messageDaysProvider(key));
    final day = await showModalBottomSheet<DateTime>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _DateSheet(days: key, initial: initial),
    );
    if (day != null && mounted) await _jumpToDay(day, key);
  }

  Future<void> _jumpToDay(DateTime day, DaysKey key) async {
    if (_jumping) return;
    _jumping = true;
    try {
      final days = await ref.read(messageDaysProvider(key).future);
      DateTime? target;
      for (final d in days) {
        if (!d.isBefore(day) && (target == null || d.isBefore(target))) {
          target = d;
        }
      }
      if (!mounted) return;
      if (target == null) {
        _toLatest();
        return;
      }
      final start = DateTime(target.year, target.month, target.day);
      final chat = ref.read(chatProvider(_key).notifier);
      // Loads back to that day; up to 20000 messages.
      for (var tries = 0; tries < 100; tries++) {
        final now = ref.read(chatProvider(_key)).value;
        if (now == null || !mounted) return;
        if (now.messages.isEmpty ||
            !now.hasMore ||
            now.messages.last.createdAt.isBefore(start)) {
          break;
        }
        if (now.loadingOlder) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        } else {
          await chat.loadOlder(limit: 200);
        }
      }
      final messages = ref.read(chatProvider(_key)).value?.messages ?? [];
      ChatMessage? first;
      for (final m in messages.reversed) {
        if (!m.createdAt.toLocal().isBefore(start)) {
          first = m;
          break;
        }
      }
      if (first == null || !mounted) return;
      await _jump(first.id);
    } catch (e) {
      if (mounted) showMessage(context, errorText(context.l10n, e));
    } finally {
      _jumping = false;
    }
  }

  /// A message's replies on their own screen; a reply tapped there is
  /// shown in the chat.
  Future<void> _openThread(ChatMessage root) async {
    final id = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => ReplyThreadScreen(
          membership: widget.membership,
          target: widget.target,
          chat: _key,
          rootId: root.id,
        ),
      ),
    );
    if (id != null && mounted) await _jumpTo(id);
  }

  void _onText() {
    // Pasted (or typed) past what one message holds: keep all of it, to
    // send as a file, instead of cutting it off.
    if (_text.text.runes.length > maxMessageLength) {
      final long = _text.text;
      _text.value = TextEditingValue.empty;
      setState(() {
        _long = _long == null ? long : '$_long\n$long';
        _longAsFile = true;
      });
      return;
    }
    setState(() {});
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    _scroll.removeListener(_countNewer);
    _scroll.dispose();
    _flashTimer?.cancel();
    _recTick?.cancel();
    for (final sub in _dropSubs) {
      sub.cancel();
    }
    if (_rec != _Rec.off) ref.read(voiceRecorderProvider).cancel();
    super.dispose();
  }

  Future<void> _send({List<Upload> files = const []}) async {
    final body = _text.text.trim();
    final long = files.isEmpty ? _long : null;
    if (body.isEmpty && files.isEmpty && long == null) return;
    // Keep what was typed until the chat has loaded.
    if (!ref.read(chatProvider(_key)).hasValue) return;
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final reply = _replyTo;
    final asFile = _longAsFile;
    final candidates = _candidates;
    _text.clear();
    setState(() {
      _replyTo = null;
      if (long != null) _long = null;
    });
    final chat = ref.read(chatProvider(_key).notifier);
    final project = widget.target.isProject ? null : _tag;
    try {
      if (long != null && asFile) {
        await chat.send(
          body: body.isEmpty ? null : body,
          file: Upload(
            bytes: utf8.encode(long),
            name: l.longTextFile,
            mime: 'text/plain',
          ),
          replyTo: reply,
          projectId: project,
          mentions: mentionedIds(body, candidates),
        );
      } else if (long != null) {
        final parts = [
          ...splitLongText(long, maxMessageLength),
          if (body.isNotEmpty) body,
        ];
        for (final (i, part) in parts.indexed) {
          await chat.send(
            body: part,
            replyTo: i == 0 ? reply : null,
            projectId: project,
            mentions: mentionedIds(part, candidates),
          );
        }
      } else if (files.isNotEmpty) {
        await chat.sendFiles(
          files,
          body: body.isEmpty ? null : body,
          replyTo: reply,
          projectId: project,
          mentions: mentionedIds(body, candidates),
        );
      } else {
        await chat.send(
          body: body,
          replyTo: reply,
          projectId: project,
          mentions: mentionedIds(body, candidates),
        );
      }
    } catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(errorText(l, e))));
    }
  }

  /// Scrolls to a message (loading older ones until it is there) and lights
  /// it up for a moment.
  Future<void> _jumpTo(String id) async {
    if (_jumping) return;
    _jumping = true;
    try {
      await _jump(id);
    } finally {
      _jumping = false;
    }
  }

  Future<void> _jump(String id) async {
    final l = context.l10n;
    final chat = ref.read(chatProvider(_key).notifier);
    // Up to 2000 messages back; past that it is quicker to search.
    for (var tries = 0; tries < 400; tries++) {
      final now = ref.read(chatProvider(_key)).value;
      if (now == null || !mounted) return;
      if (now.messages.any((m) => m.id == id)) break;
      if (!now.hasMore || now.messages.length > 2000) {
        showMessage(context, l.originalNotFound);
        return;
      }
      if (now.loadingOlder) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      } else {
        await chat.loadOlder();
      }
    }
    if (!mounted) return;
    _flashTimer?.cancel();
    setState(() => _flash = id);
    _flashTimer = Timer(const Duration(milliseconds: 2200), () {
      if (mounted) setState(() => _flash = null);
    });
    // The list only builds what is near the screen: move up a screen at a
    // time until the message is built, then bring it to the middle.
    for (var step = 0; step < 300; step++) {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final target = _keys[id]?.currentContext;
      if (target != null && target.mounted) {
        await Scrollable.ensureVisible(
          target,
          alignment: 0.5,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
        return;
      }
      if (!_scroll.hasClients) return;
      final at = _scroll.position;
      if (at.pixels >= at.maxScrollExtent && step > 0) {
        // At the top of what is loaded; let the older page arrive.
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      _scroll.jumpTo(
        math.min(at.pixels + at.viewportDimension * 0.8, at.maxScrollExtent),
      );
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
      if (voice != null && mounted) await _send(files: [voice]);
    } catch (e) {
      if (mounted) showMessage(context, errorText(l, e));
    }
  }

  /// On a phone the emoji picker takes the keyboard's place; with a
  /// keyboard (web, a computer) both stay.
  bool get _touch => _onPhone;

  void _toggleEmoji() {
    if (_emojiOpen) {
      setState(() => _emojiOpen = false);
      if (_touch) _focus.requestFocus();
    } else {
      if (_touch) _focus.unfocus();
      setState(() => _emojiOpen = true);
    }
  }

  void _pickMention(int start, MentionCandidate c) {
    _text.value = applyMention(_text.value, start, c.name);
    _focusField();
  }

  /// Enter picks the first suggested name while a mention is being typed,
  /// and sends otherwise.
  void _onEnter() {
    final at = _mentionAt;
    if (at != null && _suggestions.isNotEmpty) {
      _pickMention(at.start, _suggestions.first);
    } else if (ref.read(chatProvider(_key)).hasValue) {
      _send();
    }
  }

  void _replyWith(ChatMessage m) {
    setState(() => _replyTo = m);
    _focusField();
  }

  /// Puts the cursor back in the message field, after the frame so a
  /// closing menu or the tap that got here does not take it away again.
  void _focusField() {
    if (_emojiOpen && _touch) setState(() => _emojiOpen = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  Future<void> _react(ChatMessage m, String emoji) async {
    try {
      await ref.read(chatProvider(_key).notifier).react(m, emoji);
    } catch (e) {
      if (mounted) showMessage(context, errorText(context.l10n, e));
    }
  }

  Future<void> _reactMore(ChatMessage m) async {
    final emoji = await pickEmoji(context);
    if (emoji != null && mounted) await _react(m, emoji);
  }

  /// The quick reactions in a small menu where the mouse is.
  Future<void> _reactMenu(ChatMessage m, String? me, Offset at) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        at & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [_ReactionMenuEntry(mine: _mine(m, me))],
    );
    if (!mounted || choice == null) return;
    await _onReactChoice(m, choice);
  }

  Future<void> _onReactChoice(ChatMessage m, String choice) async {
    if (choice == _moreReactions) {
      await _reactMore(m);
    } else if (choice.startsWith(_reactPrefix)) {
      await _react(m, choice.substring(_reactPrefix.length));
    }
  }

  static Set<String> _mine(ChatMessage m, String? me) => {
    for (final e in m.reactions.entries)
      if (e.value.contains(me)) e.key,
  };

  void _profile(String userId, String name) {
    if (userId == ref.read(authProvider).value) return;
    showProfileCard(
      context,
      ref,
      membership: widget.membership,
      userId: userId,
      name: name,
      inPrivateChat: userId == widget.target.otherId,
      projectId: widget.target.projectId ?? widget.projectFilter,
    );
  }

  /// Who reacted with what.
  void _showReactions(ChatMessage m, Map<String, String> names, String? me) {
    final l = context.l10n;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          key: const Key('whoReacted'),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final e in m.reactions.entries) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                  child: Text(
                    '${e.key}  ${e.value.length}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                for (final id in e.value)
                  ListTile(
                    leading: Avatar(name: names[id] ?? '', radius: 18),
                    title: Text(id == me ? l.you : names[id] ?? l.formerMember),
                  ),
              ],
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  /// Whether files dropped at [at] (in the window) land on this chat, on
  /// the screen in front, and can be sent here.
  bool _takesDropAt(Offset at) {
    if (!mounted || !_takesFiles) return false;
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return false;
    return (Offset.zero & box.size).contains(box.globalToLocal(at));
  }

  Future<void> _dropped(FileDrop drop) async {
    if (_dropHover && mounted) setState(() => _dropHover = false);
    if (!_takesDropAt(drop.at)) return;
    final files = takeFiles(context, (
      files: drop.files,
      tooLarge: drop.tooLarge,
    ));
    if (files.isNotEmpty) await _send(files: files);
  }

  Future<void> _attach() async {
    if (!ref.read(chatProvider(_key)).hasValue) return;
    final uploads = await pickUploads(context, ref, onPoll: _newPoll);
    if (uploads.isNotEmpty && mounted) await _send(files: uploads);
  }

  Future<void> _pin(String messageId, {required bool pin}) async {
    final ok = await runAction(
      context,
      () => ref.read(apiProvider).pinMessage(messageId, pin: pin),
    );
    if (ok && mounted) {
      ref.invalidate(
        chatPinProvider((
          workspaceId: widget.membership.workspaceId,
          conversationId: widget.target.conversationId,
        )),
      );
    }
  }

  Future<void> _newPoll() async {
    final poll = await showModalBottomSheet<_PollDraft>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _PollComposer(),
    );
    if (poll == null || !mounted) return;
    final target = widget.target;
    final ok = await runAction(
      context,
      () => ref
          .read(apiProvider)
          .createPoll(
            target.conversationId,
            question: poll.question,
            options: poll.options,
            multiple: poll.multiple,
            projectId: target.isProject ? null : _tag,
          ),
    );
    if (ok && mounted) {
      await ref.read(chatProvider(_key).notifier).refresh();
    }
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
            managesDepartment(ref, ws, project?.departmentId) ||
            (members?.any(
                  (m) => m.userId == me && m.role == ProjectRole.lead,
                ) ??
                false));

    final names = {
      for (final m in ref.watch(membersProvider(ws)).value ?? const <Member>[])
        m.userId: m.fullName,
    };
    final others = [
      for (final p in members ?? const <ProjectMember>[])
        if (p.userId != me) p,
    ];
    _candidates = target.isProject
        ? [
            if (others.length > 1)
              MentionCandidate(id: null, name: l.mentionEveryone),
            for (final p in others)
              MentionCandidate(id: p.userId, name: p.fullName),
          ]
        : [
            if (target.otherId case final other? when target.otherActive)
              MentionCandidate(id: other, name: target.title),
          ];
    final mentionAt = closed ? null : mentionQuery(_text.value);
    final suggestions = mentionAt == null
        ? const <MentionCandidate>[]
        : matchMentions(_candidates, mentionAt.query);
    _mentionAt = mentionAt;
    _suggestions = suggestions;

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

    // New or older messages move what is below the screen.
    ref.listen(chatProvider(_key), (_, _) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _countNewer());
    });

    final pin = ref
        .watch(
          chatPinProvider((
            workspaceId: ws,
            conversationId: target.conversationId,
          )),
        )
        .value;

    _takesFiles = chat.hasValue && !closed;
    final column = Column(
      children: [
        if (pin?.message case final pinned?)
          _PinnedBar(
            pin: pinned,
            onTap: () => _jumpTo(pinned.messageId),
            onUnpin: pin!.canPin && !closed
                ? () => _pin(pinned.messageId, pin: false)
                : null,
          ),
        Expanded(
          child: Stack(
            children: [
              KeyedSubtree(
                key: _listKey,
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
                    names: names,
                    controller: _scroll,
                    keyFor: (id) => _keys.putIfAbsent(id, GlobalKey.new),
                    flash: _flash,
                    onLoadOlder: () =>
                        ref.read(chatProvider(_key).notifier).loadOlder(),
                    onMenu: (m, at) => _actions(
                      m,
                      me,
                      canModerate,
                      members,
                      closed: closed,
                      at: at,
                    ),
                    onReply: closed ? null : _replyWith,
                    onQuoteTap: _jumpTo,
                    onProfile: _profile,
                    onReact: closed ? null : _react,
                    onVote: closed
                        ? null
                        : (m, picks) => runAction(
                            context,
                            () => ref
                                .read(chatProvider(_key).notifier)
                                .vote(m, picks),
                          ),
                    onReactMenu: closed
                        ? null
                        : (m, at) => _reactMenu(m, me, at),
                    onReactions: (m) => _showReactions(m, names, me),
                    onRetry: (p) async {
                      try {
                        await ref.read(chatProvider(_key).notifier).retry(p);
                      } catch (e) {
                        if (context.mounted) {
                          showMessage(context, errorText(l, e));
                        }
                      }
                    },
                    onDiscard: (p) =>
                        ref.read(chatProvider(_key).notifier).discard(p),
                    onDayTap: _pickDate,
                    onThread: _openThread,
                  ),
                ),
              ),
              if (_newer != null)
                PositionedDirectional(
                  end: 14,
                  bottom: 12,
                  child: _LatestButton(count: _newer!, onTap: _toLatest),
                ),
            ],
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
        else ...[
          // On leave, the other person's note answers before one writes.
          if (target.otherId case final other?)
            if (ref.watch(statusesProvider(ws)).value?[other] case final away?
                when away.kind == StatusKind.leave)
              _AwayNote(name: target.title, status: away),
          if (suggestions.isNotEmpty)
            // Clicking a name does not take the cursor out of the field.
            TextFieldTapRegion(
              child: MentionSuggestions(
                choices: suggestions,
                memberCount: others.length,
                onPick: (c) => _pickMention(mentionAt!.start, c),
              ),
            ),
          _Composer(
            controller: _text,
            focusNode: _focus,
            emojiOpen: _emojiOpen,
            onEmoji: _toggleEmoji,
            onFieldTap: () {
              if (_emojiOpen && _touch) setState(() => _emojiOpen = false);
            },
            replyTo: _replyTo,
            onCancelReply: () => setState(() => _replyTo = null),
            long: _long,
            longAsFile: _longAsFile,
            onLongMode: (asFile) => setState(() => _longAsFile = asFile),
            onDropLong: () => setState(() => _long = null),
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
      ],
    );
    if (!_dropHover) return column;
    return Stack(
      children: [
        column,
        const Positioned.fill(child: IgnorePointer(child: _DropHint())),
      ],
    );
  }

  /// What can be done with a message: a sheet from the bottom on a long
  /// press, or a menu where the mouse is on a right click or the ⋯ button.
  Future<void> _actions(
    ChatMessage m,
    String? me,
    bool canModerate,
    List<ProjectMember>? members, {
    required bool closed,
    Offset? at,
  }) async {
    if (m.deleted) return;
    final l = context.l10n;
    final mine = m.senderId == me;
    final hasText = m.body != null && m.body!.isNotEmpty;
    // A task belongs to a project: this chat's, or the one the message is
    // tagged with; in an untagged private message one is picked.
    final taskProject = widget.target.projectId ?? m.projectId;
    final pin = ref
        .read(
          chatPinProvider((
            workspaceId: widget.membership.workspaceId,
            conversationId: widget.target.conversationId,
          )),
        )
        .value;
    final choices = <_Action>[
      if (!closed) _Action('reply', LucideIcons.replyDir, l.reply),
      if (hasText) _Action('copy', LucideIcons.copy, l.copy),
      if (hasText) _Action('select', LucideIcons.type, l.selectText),
      if (m.file != null) _Action('download', LucideIcons.download, l.download),
      if (m.file != null)
        _Action('drive', LucideIcons.cloudUpload, l.saveToDrive),
      if (!closed)
        _Action('task', LucideIcons.listPlus, l.makeTask, short: l.taskShort),
      if (widget.membership.allowSharing && (hasText || m.file != null))
        _Action('share', LucideIcons.share2, l.share),
      if (mine && widget.target.isProject)
        _Action('seen', LucideIcons.checkCheck, l.seenByTitle),
      if (m.poll != null && !m.poll!.closed && !closed && (mine || canModerate))
        _Action('closePoll', LucideIcons.lock, l.closePoll),
      if (!closed && (pin?.canPin ?? false))
        pin?.message?.messageId == m.id
            ? _Action('unpin', LucideIcons.pinOff, l.unpin)
            : _Action('pin', LucideIcons.pin, l.pin),
      if (mine || canModerate)
        _Action(
          'delete',
          LucideIcons.trash2,
          l.deleteMessage,
          destructive: true,
        ),
    ];
    final String? choice;
    if (at != null) {
      final overlay =
          Overlay.of(context).context.findRenderObject()! as RenderBox;
      final error = Theme.of(context).colorScheme.error;
      choice = await showMenu<String>(
        context: context,
        position: RelativeRect.fromRect(
          at & const Size(1, 1),
          Offset.zero & overlay.size,
        ),
        items: [
          if (!closed) ...[
            _ReactionMenuEntry(mine: _mine(m, me)),
            const PopupMenuDivider(),
          ],
          for (final a in choices)
            PopupMenuItem(
              value: a.id,
              child: Row(
                children: [
                  Icon(a.icon, size: 20, color: a.destructive ? error : null),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      a.label,
                      style: a.destructive ? TextStyle(color: error) : null,
                    ),
                  ),
                ],
              ),
            ),
        ],
      );
    } else {
      choice = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        builder: (context) => _ActionSheet(
          choices: choices,
          reactions: closed
              ? null
              : ReactionBar(
                  mine: _mine(m, me),
                  onPick: (e) => Navigator.pop(context, '$_reactPrefix$e'),
                  onMore: () => Navigator.pop(context, _moreReactions),
                ),
        ),
      );
    }
    if (!mounted) return;
    if (choice != null &&
        (choice == _moreReactions || choice.startsWith(_reactPrefix))) {
      return _onReactChoice(m, choice);
    }
    switch (choice) {
      case 'reply':
        _replyWith(m);
      case 'drive':
        await saveFileToDrive(context, ref, m.file!);
      case 'download':
        await downloadFile(context, ref, m.file!);
      case 'share':
        await shareOut(context, ref, text: m.body, file: m.file);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: m.body!));
        if (mounted) showMessage(context, l.copied);
      case 'select':
        _selectText(m);
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
      case 'pin' || 'unpin':
        await _pin(m.id, pin: choice == 'pin');
      case 'closePoll':
        final ok = await runAction(
          context,
          () => ref.read(apiProvider).closePoll(m.id),
        );
        if (ok && mounted) {
          await ref.read(chatProvider(_key).notifier).refresh();
        }
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

  /// The whole message, to select and copy any part of it.
  void _selectText(ChatMessage m) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        final theme = Theme.of(context);
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.8,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 8, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          m.senderName,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: context.l10n.copy,
                        icon: const Icon(LucideIcons.copy),
                        onPressed: () async {
                          final copied = this.context.l10n.copied;
                          await Clipboard.setData(ClipboardData(text: m.body!));
                          if (!context.mounted) return;
                          Navigator.pop(context);
                          if (mounted) showMessage(this.context, copied);
                        },
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                    child: SelectableText(
                      m.body!,
                      key: const Key('selectableMessage'),
                      style: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
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

/// Above the message field of a private chat with someone on leave: until
/// when, and their note.
class _AwayNote extends StatelessWidget {
  const _AwayNote({required this.name, required this.status});

  final String name;
  final UserStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = presenceColor(context, status.kind);
    return Container(
      key: const Key('awayNote'),
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(presenceIcon(status.kind), size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${firstName(name)} · ${presenceText(context, status)}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (status.note != null)
                  Text(status.note!, style: theme.textTheme.bodyMedium),
              ],
            ),
          ),
        ],
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
                LucideIcons.lock,
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
    required this.names,
    required this.controller,
    required this.keyFor,
    required this.flash,
    required this.onLoadOlder,
    required this.onMenu,
    required this.onReply,
    required this.onQuoteTap,
    required this.onProfile,
    required this.onReact,
    required this.onReactMenu,
    required this.onReactions,
    this.onVote,
    required this.onRetry,
    required this.onDiscard,
    required this.onDayTap,
    required this.onThread,
  });

  final ChatState state;
  final String? me;
  final bool showSenders;
  final bool showTags;
  final List<Project> projects;
  final List<String> Function(ChatMessage) readers;

  /// The workspace's people by id, for mentions and reactions.
  final Map<String, String> names;
  final ScrollController controller;
  final GlobalKey Function(String id) keyFor;
  final String? flash;
  final VoidCallback onLoadOlder;

  /// The message's actions; [Offset] is where the mouse is, if it opened
  /// them, else they come up from the bottom.
  final void Function(ChatMessage, Offset?) onMenu;

  /// Null where replying is not possible (a closed chat).
  final void Function(ChatMessage)? onReply;
  final void Function(String id) onQuoteTap;
  final void Function(String userId, String name) onProfile;

  /// Null where reacting is not possible (a closed chat).
  final void Function(ChatMessage, String emoji)? onReact;

  /// Answers a poll; null where the chat is closed.
  final void Function(ChatMessage, Set<int> picks)? onVote;
  final void Function(ChatMessage, Offset at)? onReactMenu;
  final void Function(ChatMessage) onReactions;
  final void Function(PendingMessage) onRetry;
  final void Function(PendingMessage) onDiscard;

  /// Opens the calendar at the day tapped.
  final void Function(DateTime day) onDayTap;

  /// Opens a message's replies.
  final void Function(ChatMessage root) onThread;

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
        icon: LucideIcons.messageCircle,
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
        controller: controller,
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
            _DayItem(:final day) => _DayLine(
              day: day,
              onTap: () => onDayTap(day.toLocal()),
            ),
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
                key: keyFor(message.id),
                message: message,
                highlight: message.id == flash,
                showAvatar: showAvatar,
                mine: message.senderId == me,
                showSender: showSender,
                tag: showTags
                    ? projects
                          .where((p) => p.id == message.projectId)
                          .firstOrNull
                    : null,
                read: _readByAll(message),
                onMenu: (at) => onMenu(message, at),
                onReply: onReply == null ? null : () => onReply!(message),
                onQuoteTap: message.replyTo == null
                    ? null
                    : () => onQuoteTap(message.replyTo!),
                me: me,
                mentions: mentionTargets(message.mentions, names, me),
                onProfile: onProfile,
                onReact: onReact == null ? null : (e) => onReact!(message, e),
                onVote: onVote == null ? null : (p) => onVote!(message, p),
                onReactMenu: onReactMenu == null
                    ? null
                    : (at) => onReactMenu!(message, at),
                onReactions: () => onReactions(message),
                names: names,
                onThread: () => onThread(message),
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
  const _DayLine({required this.day, this.onTap});

  final DateTime day;

  /// Opens the calendar.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Material(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(99),
          child: InkWell(
            key: const Key('dayLine'),
            borderRadius: BorderRadius.circular(99),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
              child: Text(
                dayLabel(context, day),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
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

/// How wide a message gets on a wide screen (a computer, a tablet): about
/// a comfortable line of text, instead of most of the window.
const _maxBubbleWidth = 520.0;

/// How wide a file's card gets.
const _maxFileCardWidth = 320.0;

/// Longer messages fold, with "Read more" under them.
const _foldLines = 15;

/// How far a message is swiped to reply to it.
const _swipeToReply = 56.0;

class _Bubble extends ConsumerWidget {
  const _Bubble({
    super.key,
    required this.message,
    this.highlight = false,
    this.showAvatar,
    required this.mine,
    required this.showSender,
    required this.tag,
    required this.read,
    required this.onMenu,
    required this.onReply,
    required this.onQuoteTap,
    required this.me,
    required this.mentions,
    required this.onProfile,
    required this.onReact,
    required this.onReactMenu,
    required this.onReactions,
    this.onVote,
    this.names = const {},
    this.onThread,
    this.replyLabel,
    this.showQuote = true,
  });

  final ChatMessage message;

  /// Lit up for a moment, after jumping to it from a reply.
  final bool highlight;
  final bool? showAvatar;
  final bool mine;
  final bool showSender;
  final Project? tag;
  final bool read;

  /// Null where a message has no actions (in a reply chain).
  final void Function(Offset? at)? onMenu;
  final VoidCallback? onReply;
  final VoidCallback? onQuoteTap;
  final String? me;
  final List<MentionTarget> mentions;
  final void Function(String userId, String name) onProfile;
  final void Function(String emoji)? onReact;
  final void Function(Offset at)? onReactMenu;
  final VoidCallback onReactions;

  /// Answers the message's poll; null where it cannot be answered.
  final void Function(Set<int> picks)? onVote;

  /// The workspace's people by id, for who replied.
  final Map<String, String> names;

  /// Opens its replies; null where they are not shown (in a reply chain).
  final VoidCallback? onThread;

  /// In a reply chain: "In reply to X", shown instead of the quote.
  final String? replyLabel;
  final bool showQuote;

  /// One to three emoji and nothing else: big, without a bubble.
  bool get _bigEmoji =>
      !message.deleted &&
      message.file == null &&
      message.replyTo == null &&
      isBigEmoji(message.body ?? '');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final big = _bigEmoji;
    final theme = big ? Theme.of(context) : _bubbleTheme(context, mine);
    final muted = theme.colorScheme.onSurfaceVariant;
    final m = message;
    final file = m.file;
    final maxWidth = math.min(
      MediaQuery.sizeOf(context).width * 0.78,
      _maxBubbleWidth,
    );
    // A photo or video fills its bubble, with only a thin edge around it.
    final media = !m.deleted && file != null && (file.isImage || file.isVideo);

    final content = <Widget>[
      if (showSender)
        Padding(
          padding: media
              ? const EdgeInsets.fromLTRB(6, 2, 6, 4)
              : const EdgeInsets.only(bottom: 2),
          child: GestureDetector(
            onTap: () => onProfile(m.senderId, m.senderName),
            child: Text(
              m.senderName,
              key: const Key('senderName'),
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
        ),
      if (m.deleted)
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.ban, size: 16, color: muted),
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
        if (replyLabel != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.replyDir, size: 14, color: muted),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    replyLabel!,
                    key: const Key('replyLabel'),
                    style: theme.textTheme.labelSmall?.copyWith(color: muted),
                  ),
                ),
              ],
            ),
          )
        else if (m.replyTo != null && showQuote)
          _Quote(message: m, onTap: onQuoteTap),
        if (file != null && (file.isImage || file.isVideo))
          ChatMedia(
            file: file,
            width: math.min(maxWidth - 8, 260),
            onTap: () => openFile(context, ref, file),
          )
        else if (file != null && file.isAudio)
          VoicePlayer(file: file, width: math.min(maxWidth - 24, 240))
        else if (file != null)
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _maxFileCardWidth),
            child: Container(
              decoration: BoxDecoration(
                color: mine
                    ? Colors.white.withValues(alpha: 0.14)
                    : theme.scaffoldBackgroundColor,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: InkWell(
                      onTap: () => openFile(context, ref, file),
                      borderRadius: BorderRadius.circular(10),
                      child: Padding(
                        padding: const EdgeInsetsDirectional.fromSTEB(
                          10,
                          10,
                          4,
                          10,
                        ),
                        child: FileRow(
                          file: file,
                          detail: fileSize(l, file.size),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 6),
                    child: IconButton.filledTonal(
                      key: const Key('bubbleDownload'),
                      tooltip: l.download,
                      visualDensity: VisualDensity.compact,
                      style: IconButton.styleFrom(
                        backgroundColor: theme.colorScheme.surface,
                        foregroundColor: mine
                            ? WaslaColors.accent
                            : theme.colorScheme.primary,
                      ),
                      icon: const Icon(LucideIcons.download, size: 20),
                      onPressed: () => downloadFile(context, ref, file),
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (big)
          Text(
            m.body!.trim(),
            key: const Key('bigEmoji'),
            style: const TextStyle(fontSize: 44, height: 1.2),
          )
        else if (m.body != null && m.body!.isNotEmpty)
          Padding(
            padding: media
                ? const EdgeInsets.fromLTRB(6, 6, 6, 0)
                : EdgeInsets.only(top: file != null ? 6 : 0),
            child: _FoldText(
              m.body!,
              style: theme.textTheme.bodyLarge?.copyWith(height: 1.45),
              mentions: mentions,
              onMention: (t) => onProfile(t.id!, t.name),
            ),
          ),
        if (m.poll case final poll?)
          _PollView(poll: poll, me: me, mine: mine, onVote: onVote),
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
            if (m.fromFiles && !m.deleted) ...[
              Icon(LucideIcons.folderUp, size: 12, color: muted),
              const SizedBox(width: 3),
              Text(
                l.fromFilesTab,
                key: const Key('fromFiles'),
                style: theme.textTheme.labelSmall?.copyWith(color: muted),
              ),
              const SizedBox(width: 6),
            ],
            Text(
              clockTime(context, m.createdAt),
              style: theme.textTheme.labelSmall?.copyWith(color: muted),
            ),
            if (mine && !m.deleted) ...[
              const SizedBox(width: 4),
              Icon(
                read ? LucideIcons.checkCheck : LucideIcons.check,
                size: 16,
                color: read ? theme.colorScheme.primary : muted,
              ),
            ],
          ],
        ),
      ),
    ];

    final avatar = showAvatar;
    final flash = Theme.of(context).colorScheme.tertiary;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 350),
      decoration: BoxDecoration(
        color: highlight ? flash.withValues(alpha: 0.18) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
      ),
      child: _SwipeToReply(
        onReply: m.deleted ? null : onReply,
        child: Align(
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
                      ? GestureDetector(
                          onTap: () => onProfile(m.senderId, m.senderName),
                          child: Avatar(name: m.senderName, radius: 14),
                        )
                      : const SizedBox(width: 28),
                  const SizedBox(width: 8),
                ],
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: mine
                        ? CrossAxisAlignment.end
                        : CrossAxisAlignment.start,
                    children: [
                      _HoverActions(
                        onReply: m.deleted || onMenu == null ? null : onReply,
                        onMenu: m.deleted ? null : onMenu,
                        onReact: m.deleted ? null : onReactMenu,
                        child: _bubbleBody(
                          context,
                          theme,
                          content,
                          maxWidth,
                          big: big,
                        ),
                      ),
                      if (m.reactions.isNotEmpty && !m.deleted)
                        _Reactions(
                          reactions: m.reactions,
                          me: me,
                          onTap: onReact,
                          onLongPress: onReactions,
                        ),
                      if (onThread != null && m.replyCount > 0)
                        _ThreadPill(
                          count: m.replyCount,
                          people: [
                            for (final id in m.repliers) names[id] ?? '',
                          ],
                          onTap: onThread!,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _bubbleBody(
    BuildContext context,
    ThemeData theme,
    List<Widget> content,
    double maxWidth, {
    required bool big,
  }) {
    final m = message;
    final file = m.file;
    final media = !m.deleted && file != null && (file.isImage || file.isVideo);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Material(
        color: big ? Colors.transparent : _bubbleColor(context, mine),
        borderRadius: _bubbleShape(mine),
        child: InkWell(
          customBorder: RoundedRectangleBorder(
            borderRadius: _bubbleShape(mine),
          ),
          onLongPress: onMenu == null ? null : () => onMenu!(null),
          onSecondaryTapUp: onMenu == null
              ? null
              : (d) => onMenu!(d.globalPosition),
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

/// A message's text; a long one shows its first lines and "Read more".
class _FoldText extends StatefulWidget {
  const _FoldText(
    this.text, {
    this.style,
    this.mentions = const [],
    this.onMention,
  });

  final String text;
  final TextStyle? style;

  /// Names the message mentions, drawn and (people) tappable.
  final List<MentionTarget> mentions;
  final void Function(MentionTarget)? onMention;

  @override
  State<_FoldText> createState() => _FoldTextState();
}

class _FoldTextState extends State<_FoldText> {
  bool _open = false;
  final _recognizers = <GestureRecognizer>[];

  void _dropRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _dropRecognizers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    _dropRecognizers();
    final spans = mentionSpans(
      context,
      widget.text,
      widget.mentions,
      recognizers: _recognizers,
      onTap: (t) => widget.onMention?.call(t),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final style = DefaultTextStyle.of(context).style.merge(widget.style);
        final painter = TextPainter(
          text: TextSpan(children: spans, style: style),
          maxLines: _foldLines,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: constraints.maxWidth);
        final long = painter.didExceedMaxLines;
        painter.dispose();
        if (!long) {
          return Text.rich(TextSpan(children: spans), style: widget.style);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text.rich(
              TextSpan(children: spans),
              style: widget.style,
              maxLines: _open ? null : _foldLines,
              overflow: _open ? null : TextOverflow.ellipsis,
            ),
            InkWell(
              key: const Key('readMore'),
              onTap: () => setState(() => _open = !_open),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  _open ? l.showLess : l.readMore,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Swiping a message toward the middle of the screen replies to it, like
/// WhatsApp.
class _SwipeToReply extends StatefulWidget {
  const _SwipeToReply({required this.onReply, required this.child});

  final VoidCallback? onReply;
  final Widget child;

  @override
  State<_SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<_SwipeToReply>
    with SingleTickerProviderStateMixin {
  late final AnimationController _back = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  )..addListener(() => setState(() => _drag = _from * (1 - _back.value)));
  double _drag = 0;
  double _from = 0;
  bool _armed = false;

  @override
  void dispose() {
    _back.dispose();
    super.dispose();
  }

  bool get _rtl => Directionality.of(context) == TextDirection.rtl;

  void _update(DragUpdateDetails d) {
    // Toward the middle: left in Arabic, right in English.
    final inward = _rtl ? -d.delta.dx : d.delta.dx;
    setState(() => _drag = (_drag + inward).clamp(0.0, _swipeToReply * 1.4));
    if (!_armed && _drag >= _swipeToReply) {
      _armed = true;
      HapticFeedback.selectionClick();
    } else if (_armed && _drag < _swipeToReply) {
      _armed = false;
    }
  }

  void _end() {
    if (_armed) widget.onReply?.call();
    _armed = false;
    _from = _drag;
    _back.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.onReply == null) return widget.child;
    final theme = Theme.of(context);
    final progress = (_drag / _swipeToReply).clamp(0.0, 1.0);
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragUpdate: _update,
      onHorizontalDragEnd: (_) => _end(),
      onHorizontalDragCancel: _end,
      child: Stack(
        alignment: AlignmentDirectional.centerStart,
        children: [
          if (_drag > 0)
            PositionedDirectional(
              start: 4,
              child: Opacity(
                opacity: progress,
                child: Transform.scale(
                  scale: 0.6 + 0.4 * progress,
                  child: CircleAvatar(
                    key: const Key('swipeReplyIcon'),
                    radius: 15,
                    backgroundColor: theme.colorScheme.primaryContainer,
                    child: Icon(
                      LucideIcons.replyDir,
                      size: 18,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
              ),
            ),
          Transform.translate(
            offset: Offset(_rtl ? -_drag : _drag, 0),
            child: widget.child,
          ),
        ],
      ),
    );
  }
}

/// With a mouse: reply and ⋯ buttons on the message under the pointer.
class _HoverActions extends StatefulWidget {
  const _HoverActions({
    required this.onReply,
    required this.onMenu,
    this.onReact,
    required this.child,
  });

  final VoidCallback? onReply;
  final void Function(Offset? at)? onMenu;
  final void Function(Offset at)? onReact;
  final Widget child;

  @override
  State<_HoverActions> createState() => _HoverActionsState();
}

class _HoverActionsState extends State<_HoverActions> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final onMenu = widget.onMenu;
    if (onMenu == null) return widget.child;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          widget.child,
          if (_hover)
            PositionedDirectional(
              top: 4,
              end: 4,
              child: Material(
                color: theme.colorScheme.surface,
                elevation: 3,
                borderRadius: BorderRadius.circular(10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.onReact != null)
                      _HoverButton(
                        key: const Key('hoverReact'),
                        icon: LucideIcons.smilePlus,
                        tooltip: l.react,
                        onTap: widget.onReact!,
                      ),
                    if (widget.onReply != null)
                      _HoverButton(
                        key: const Key('hoverReply'),
                        icon: LucideIcons.replyDir,
                        tooltip: l.reply,
                        onTap: (_) => widget.onReply!(),
                      ),
                    _HoverButton(
                      key: const Key('hoverMore'),
                      icon: LucideIcons.ellipsis,
                      tooltip: l.moreActions,
                      onTap: onMenu,
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

class _HoverButton extends StatelessWidget {
  const _HoverButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final void Function(Offset at) onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: InkWell(
      borderRadius: BorderRadius.circular(8),
      onTapUp: (d) => onTap(d.globalPosition),
      onTap: () {},
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(
          icon,
          size: 18,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ),
  );
}

/// What the reaction row hands back to the menu or sheet it is in.
const _reactPrefix = 'react:';
const _moreReactions = 'react+';

/// The quick reactions as the first row of a message's menu.
class _ReactionMenuEntry extends PopupMenuEntry<String> {
  const _ReactionMenuEntry({required this.mine});

  final Set<String> mine;

  @override
  double get height => 52;

  @override
  bool represents(String? value) => false;

  @override
  State<_ReactionMenuEntry> createState() => _ReactionMenuEntryState();
}

class _ReactionMenuEntryState extends State<_ReactionMenuEntry> {
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
    child: FittedBox(
      fit: BoxFit.scaleDown,
      child: ReactionBar(
        mine: widget.mine,
        onPick: (e) => Navigator.pop(context, '$_reactPrefix$e'),
        onMore: () => Navigator.pop(context, _moreReactions),
      ),
    ),
  );
}

/// The reactions under a message, each with how many chose it; one's own
/// are outlined. A tap adds or takes back one's own, a long press shows who.
class _Reactions extends StatelessWidget {
  const _Reactions({
    required this.reactions,
    required this.me,
    required this.onTap,
    required this.onLongPress,
  });

  final Map<String, List<String>> reactions;
  final String? me;

  /// Null in a closed chat.
  final void Function(String emoji)? onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 2),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final e in reactions.entries)
            Builder(
              builder: (context) {
                final mine = e.value.contains(me);
                return Material(
                  color: mine ? scheme.primaryContainer : scheme.surface,
                  shape: StadiumBorder(
                    side: BorderSide(
                      color: mine ? scheme.primary : scheme.outlineVariant,
                      width: mine ? 1.5 : 1,
                    ),
                  ),
                  child: InkWell(
                    key: Key('reaction-${e.key}'),
                    customBorder: const StadiumBorder(),
                    onTap: onTap == null ? onLongPress : () => onTap!(e.key),
                    onLongPress: onLongPress,
                    onSecondaryTap: onLongPress,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      child: Text(
                        e.value.length > 1
                            ? '${e.key} ${e.value.length}'
                            : e.key,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: mine ? scheme.primary : scheme.onSurface,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

/// One entry in a message's actions.
class _Action {
  const _Action(
    this.id,
    this.icon,
    this.label, {
    this.short,
    this.destructive = false,
  });

  final String id;
  final IconData icon;
  final String label;

  /// The label under its icon when it is one of the quick ones.
  final String? short;
  final bool destructive;
}

/// The sheet a long press on a message opens: reactions, the three things
/// most often done as big buttons, and the rest behind «More».
class _ActionSheet extends StatefulWidget {
  const _ActionSheet({required this.choices, required this.reactions});

  final List<_Action> choices;
  final Widget? reactions;

  /// The ones that make the quick row, in this order.
  static const quickOrder = ['reply', 'copy', 'task', 'download'];

  @override
  State<_ActionSheet> createState() => _ActionSheetState();
}

class _ActionSheetState extends State<_ActionSheet> {
  bool _more = false;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final quick = [
      for (final id in _ActionSheet.quickOrder)
        ?widget.choices.where((a) => a.id == id).firstOrNull,
    ].take(3).toList();
    final rest = widget.choices.where((a) => !quick.contains(a)).toList();
    // One left over is shown as it is; more wait behind «More».
    final showRest = _more || rest.length < 2;
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.reactions != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: widget.reactions,
                ),
              ),
            if (quick.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: Row(
                  children: [
                    for (final a in quick)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Material(
                            color: scheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(14),
                            child: InkWell(
                              key: Key('action-${a.id}'),
                              borderRadius: BorderRadius.circular(14),
                              onTap: () => Navigator.pop(context, a.id),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                  horizontal: 4,
                                ),
                                child: Column(
                                  children: [
                                    Icon(a.icon, color: scheme.primary),
                                    const SizedBox(height: 6),
                                    Text(
                                      a.short ?? a.label,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelMedium,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            if (showRest)
              for (final a in rest)
                ListTile(
                  leading: Icon(
                    a.icon,
                    color: a.destructive ? scheme.error : null,
                  ),
                  title: Text(
                    a.label,
                    style: a.destructive
                        ? TextStyle(color: scheme.error)
                        : null,
                  ),
                  onTap: () => Navigator.pop(context, a.id),
                )
            else
              ListTile(
                key: const Key('moreActions'),
                leading: const Icon(LucideIcons.ellipsis),
                title: Text(l.moreActions),
                onTap: () => setState(() => _more = true),
              ),
          ],
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
              Icon(
                drive ? LucideIcons.cloudUpload : LucideIcons.link,
                size: 20,
              ),
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
              const Icon(LucideIcons.externalLink, size: 16),
            ],
          ),
        ),
      ),
    );
  }
}

class _Quote extends StatelessWidget {
  const _Quote({required this.message, this.onTap});

  final ChatMessage message;

  /// Goes to the message quoted.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final file = message.replyFileName;
    final text =
        message.replyBody ??
        (file == null ? null : fileLabel(l, file)) ??
        l.messageDeleted;
    final quote = Container(
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
    if (onTap == null) return quote;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        key: const Key('quote'),
        onTap: onTap,
        child: quote,
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
            maxWidth: math.min(
              MediaQuery.sizeOf(context).width * 0.78,
              _maxBubbleWidth,
            ),
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
                                ? LucideIcons.circleAlert
                                : LucideIcons.clock,
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
                icon: const Icon(LucideIcons.trash2),
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
                  icon: const Icon(LucideIcons.sendHorizontalDir),
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
      LucideIcons.mic,
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
                    LucideIcons.chevronLeftDir,
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
            progress > 0.6 ? LucideIcons.lock : LucideIcons.lockOpen,
            size: 20,
            color: Color.lerp(
              theme.colorScheme.onSurfaceVariant,
              theme.colorScheme.primary,
              progress,
            ),
          ),
          Icon(
            LucideIcons.chevronUp,
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
    required this.focusNode,
    required this.emojiOpen,
    required this.onEmoji,
    required this.onFieldTap,
    required this.replyTo,
    required this.onCancelReply,
    required this.long,
    required this.longAsFile,
    required this.onLongMode,
    required this.onDropLong,
    required this.tagChoices,
    required this.tag,
    required this.onTag,
    required this.onAttach,
    required this.onSend,
    required this.mic,
  });

  final TextEditingController controller;
  final FocusNode focusNode;

  /// The emoji picker is open under the field; [onEmoji] opens or closes it.
  final bool emojiOpen;
  final VoidCallback onEmoji;
  final VoidCallback onFieldTap;
  final ChatMessage? replyTo;
  final VoidCallback onCancelReply;

  /// Text too long for one message, about to go as a file or as several
  /// messages.
  final String? long;
  final bool longAsFile;
  final void Function(bool asFile) onLongMode;
  final VoidCallback onDropLong;

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
    final long = this.long;
    final canSend = controller.text.trim().isNotEmpty || long != null;

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
                      Icon(LucideIcons.replyDir, size: 18, color: muted),
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
                        icon: const Icon(LucideIcons.x, size: 18),
                        onPressed: onCancelReply,
                      ),
                    ],
                  ),
                ),
              if (long != null)
                _LongTextCard(
                  text: long,
                  asFile: longAsFile,
                  onMode: onLongMode,
                  onDrop: onDropLong,
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
                                  LucideIcons.chevronDown,
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
                              Padding(
                                padding: const EdgeInsetsDirectional.only(
                                  start: 3,
                                  bottom: 3,
                                ),
                                child: IconButton(
                                  key: const Key('emojiButton'),
                                  tooltip: emojiOpen ? l.keyboard : l.emoji,
                                  onPressed: onEmoji,
                                  color: emojiOpen
                                      ? theme.colorScheme.primary
                                      : muted,
                                  icon: Icon(
                                    emojiOpen
                                        ? LucideIcons.keyboard
                                        : LucideIcons.smile,
                                    size: 22,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: TextField(
                                  key: const Key('messageField'),
                                  controller: controller,
                                  focusNode: focusNode,
                                  onTap: onFieldTap,
                                  minLines: 1,
                                  maxLines: 5,
                                  textCapitalization:
                                      TextCapitalization.sentences,
                                  decoration: InputDecoration(
                                    hintText: long != null
                                        ? l.captionHint
                                        : l.typeMessage,
                                    isDense: true,
                                    filled: false,
                                    border: InputBorder.none,
                                    enabledBorder: InputBorder.none,
                                    focusedBorder: InputBorder.none,
                                    contentPadding:
                                        const EdgeInsetsDirectional.fromSTEB(
                                          2,
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
              if (emojiOpen)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: EmojiPanel(controller: controller),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Above the text field: a long text waiting to be sent, as a file or as
/// several messages.
class _LongTextCard extends StatelessWidget {
  const _LongTextCard({
    required this.text,
    required this.asFile,
    required this.onMode,
    required this.onDrop,
  });

  final String text;
  final bool asFile;
  final void Function(bool asFile) onMode;
  final VoidCallback onDrop;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final chars = NumberFormat.decimalPattern('en').format(text.runes.length);
    final parts = splitLongText(text, maxMessageLength).length;
    return Container(
      key: const Key('longText'),
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsetsDirectional.fromSTEB(10, 8, 4, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          asFile
              ? FileBadge(name: l.longTextFile, size: 36)
              : Icon(
                  LucideIcons.notebookText,
                  size: 28,
                  color: theme.colorScheme.primary,
                ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  asFile ? l.longTextFile : text.trim().split('\n').first,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  asFile
                      ? l.longTextAsFile(chars)
                      : l.longTextAsMessages(chars, parts),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            key: const Key('longTextMode'),
            onPressed: () => onMode(!asFile),
            child: Text(asFile ? l.sendAsText : l.sendAsFile),
          ),
          IconButton(
            tooltip: l.cancel,
            visualDensity: VisualDensity.compact,
            icon: const Icon(LucideIcons.x, size: 18),
            onPressed: onDrop,
          ),
        ],
      ),
    );
  }
}

/// Far up a chat: back to the newest message, with how many are below.
class _LatestButton extends StatelessWidget {
  const _LatestButton({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.surface,
      elevation: 4,
      borderRadius: BorderRadius.circular(99),
      child: InkWell(
        key: const Key('jumpLatest'),
        borderRadius: BorderRadius.circular(99),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                context.l10n.latest,
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 4),
              Icon(LucideIcons.arrowDown, size: 18, color: scheme.primary),
              if (count > 0) ...[
                const SizedBox(width: 6),
                Badge(
                  key: const Key('latestCount'),
                  backgroundColor: scheme.primary,
                  textColor: scheme.onPrimary,
                  label: Text('$count'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Under a message with replies: how many, and who wrote the latest.
class _ThreadPill extends StatelessWidget {
  const _ThreadPill({
    required this.count,
    required this.people,
    required this.onTap,
  });

  final int count;
  final List<String> people;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = people.where((p) => p.isNotEmpty).take(3).toList();
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Material(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(99),
        child: InkWell(
          key: const Key('threadPill'),
          borderRadius: BorderRadius.circular(99),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(6, 4, 12, 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (shown.isNotEmpty)
                  SizedBox(
                    width: 20.0 + (shown.length - 1) * 13,
                    height: 20,
                    child: Stack(
                      children: [
                        for (final (i, name) in shown.indexed)
                          PositionedDirectional(
                            start: i * 13.0,
                            child: Container(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: theme.colorScheme.surfaceContainerHigh,
                                  width: 1.5,
                                ),
                              ),
                              child: Avatar(name: name, radius: 8.5),
                            ),
                          ),
                      ],
                    ),
                  ),
                const SizedBox(width: 6),
                Text(
                  context.l10n.replyCount(count),
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A month to pick a day from: weeks start on Saturday, days with messages
/// carry a dot, and today a ring.
class _DateSheet extends ConsumerStatefulWidget {
  const _DateSheet({required this.days, this.initial});

  final DaysKey days;
  final DateTime? initial;

  @override
  ConsumerState<_DateSheet> createState() => _DateSheetState();
}

class _DateSheetState extends ConsumerState<_DateSheet> {
  late final DateTime _today = _dateOnly(DateTime.now());
  late DateTime? _picked = widget.initial == null
      ? null
      : _dateOnly(widget.initial!);
  late DateTime _month = DateTime(
    (_picked ?? _today).year,
    (_picked ?? _today).month,
  );

  static DateTime _dateOnly(DateTime t) => DateTime(t.year, t.month, t.day);

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final days = ref.watch(messageDaysProvider(widget.days)).value ?? const {};
    final first = DateTime(_month.year, _month.month);
    // Saturday is the first column.
    final lead = (first.weekday - DateTime.saturday) % 7;
    final inMonth = DateUtils.getDaysInMonth(_month.year, _month.month);
    final isThisMonth =
        _month.year == _today.year && _month.month == _today.month;
    final weekdays = l.weekdaysShort.split(',');
    final picked = _picked;

    return SafeArea(
      child: Padding(
        key: const Key('dateSheet'),
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                IconButton(
                  key: const Key('prevMonth'),
                  tooltip: l.previousMonth,
                  icon: const Icon(LucideIcons.chevronLeftDir),
                  onPressed: () => setState(
                    () => _month = DateTime(_month.year, _month.month - 1),
                  ),
                ),
                Expanded(
                  child: Text(
                    monthLabel(context, _month),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  key: const Key('nextMonth'),
                  tooltip: l.nextMonth,
                  icon: const Icon(LucideIcons.chevronRightDir),
                  onPressed: isThisMonth
                      ? null
                      : () => setState(
                          () =>
                              _month = DateTime(_month.year, _month.month + 1),
                        ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                for (final w in weekdays)
                  Expanded(
                    child: Text(
                      w,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            for (var week = 0; week * 7 < lead + inMonth; week++)
              Row(
                children: [
                  for (var col = 0; col < 7; col++)
                    Expanded(
                      child: Builder(
                        builder: (context) {
                          final n = week * 7 + col - lead + 1;
                          if (n < 1 || n > inMonth) {
                            return const SizedBox(height: 44);
                          }
                          final day = DateTime(_month.year, _month.month, n);
                          final future = day.isAfter(_today);
                          final has = days.contains(
                            DateTime(day.year, day.month, day.day),
                          );
                          final selected = picked == day;
                          final today = day == _today;
                          return InkWell(
                            key: Key('day-$n'),
                            customBorder: const CircleBorder(),
                            onTap: future
                                ? null
                                : () => setState(() => _picked = day),
                            child: SizedBox(
                              height: 44,
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Container(
                                    width: 32,
                                    height: 32,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: selected ? scheme.primary : null,
                                      border: today && !selected
                                          ? Border.all(
                                              color: scheme.primary,
                                              width: 1.5,
                                            )
                                          : null,
                                    ),
                                    child: Text(
                                      '$n',
                                      style: TextStyle(
                                        fontWeight: has || today
                                            ? FontWeight.w700
                                            : FontWeight.w400,
                                        color: selected
                                            ? scheme.onPrimary
                                            : future
                                            ? scheme.onSurfaceVariant
                                                  .withValues(alpha: 0.4)
                                            : null,
                                      ),
                                    ),
                                  ),
                                  Container(
                                    width: 4,
                                    height: 4,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: has
                                          ? scheme.primary
                                          : Colors.transparent,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton(
                  key: const Key('todayButton'),
                  onPressed: () => Navigator.pop(context, _today),
                  child: Text(l.today),
                ),
                const Spacer(),
                FilledButton(
                  key: const Key('goToDay'),
                  onPressed: picked == null
                      ? null
                      : () => Navigator.pop(context, picked),
                  child: Text(
                    picked == null
                        ? l.pickADay
                        : l.goToDay(dayMonth(context, picked)),
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

/// A message and all the replies under it, oldest first. Writing here
/// replies to the message, so it shows in the chat too; tapping a reply
/// shows it in the chat.
class ReplyThreadScreen extends ConsumerStatefulWidget {
  const ReplyThreadScreen({
    super.key,
    required this.membership,
    required this.target,
    required this.chat,
    required this.rootId,
  });

  final Membership membership;
  final ChatTarget target;

  /// The chat it is in, to send replies through.
  final ChatKey chat;
  final String rootId;

  @override
  ConsumerState<ReplyThreadScreen> createState() => _ReplyThreadScreenState();
}

class _ReplyThreadScreenState extends ConsumerState<ReplyThreadScreen> {
  final _text = TextEditingController();
  late final _focus = FocusNode(
    onKeyEvent: _enterSends(_text, () {
      final root = ref.read(replyChainProvider(_key)).value?.firstOrNull;
      if (root != null) _send(root);
    }),
  );
  bool _sending = false;

  ThreadKey get _key => (
    workspaceId: widget.membership.workspaceId,
    conversationId: widget.target.conversationId,
    rootId: widget.rootId,
  );

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _send(ChatMessage root) async {
    final body = _text.text.trim();
    if (body.isEmpty || _sending) return;
    final l = context.l10n;
    setState(() => _sending = true);
    try {
      await ref
          .read(chatProvider(widget.chat).notifier)
          .send(
            body: body,
            replyTo: root,
            projectId: widget.target.isProject ? null : widget.chat.projectId,
          );
      _text.clear();
      ref.invalidate(replyChainProvider(_key));
    } catch (e) {
      if (mounted) showMessage(context, errorText(l, e));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final me = ref.watch(authProvider).value;
    final target = widget.target;
    final ws = widget.membership.workspaceId;
    final chain = ref.watch(replyChainProvider(_key));
    final names = {
      for (final m in ref.watch(membersProvider(ws)).value ?? const <Member>[])
        m.userId: m.fullName,
    };
    final project = (ref.watch(projectsProvider(ws)).value ?? const [])
        .where((p) => p.id == target.projectId)
        .firstOrNull;
    final closed = target.isProject
        ? (project != null && project.status != ProjectStatus.active)
        : !target.otherActive;
    final replies = (chain.value?.length ?? 1) - 1;

    Widget bubble(ChatMessage m, {String? label}) => GestureDetector(
      onTap: () => Navigator.pop(context, m.id),
      child: _Bubble(
        key: Key('thread-${m.id}'),
        message: m,
        mine: m.senderId == me,
        showSender: m.senderId != me,
        tag: null,
        read: false,
        onMenu: null,
        onReply: null,
        onQuoteTap: null,
        me: me,
        mentions: mentionTargets(m.mentions, names, me),
        onProfile: (id, name) => showProfileCard(
          context,
          ref,
          membership: widget.membership,
          userId: id,
          name: name,
          projectId: target.projectId,
        ),
        onReact: null,
        onReactMenu: null,
        onReactions: () {},
        showQuote: false,
        replyLabel: label,
      ),
    );

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l.replyThread,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              '${target.title} · ${l.replyCount(math.max(replies, 0))}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: AsyncView(
              value: chain,
              onRetry: () => ref.invalidate(replyChainProvider(_key)),
              builder: (list) {
                if (list.isEmpty) {
                  return EmptyState(
                    icon: LucideIcons.messagesSquare,
                    title: l.originalNotFound,
                  );
                }
                final root = list.first;
                return ListView(
                  key: const Key('replyThread'),
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
                  children: [
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(
                          alpha: 0.06,
                        ),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          bubble(root),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(8, 2, 8, 4),
                            child: Text(
                              dayLabel(context, root.createdAt),
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Row(
                        children: [
                          Text(
                            l.replyCount(list.length - 1),
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Expanded(child: Divider()),
                        ],
                      ),
                    ),
                    for (final r in list.skip(1))
                      bubble(
                        r,
                        label: r.replyTo == root.id
                            ? null
                            : l.inReplyTo(r.replySenderName ?? ''),
                      ),
                  ],
                );
              },
            ),
          ),
          if (closed)
            _ClosedNote(
              text: target.isProject
                  ? l.chatClosedProject
                  : l.chatClosedPerson(target.title),
            )
          else if (chain.value?.firstOrNull case final root?)
            Material(
              color: theme.appBarTheme.backgroundColor,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: const Key('threadField'),
                          controller: _text,
                          focusNode: _focus,
                          minLines: 1,
                          maxLines: 5,
                          maxLength: maxMessageLength,
                          buildCounter: (
                            _, {
                            required currentLength,
                            required isFocused,
                            required maxLength,
                          }) => null,
                          textInputAction: TextInputAction.newline,
                          decoration: InputDecoration(
                            hintText: l.replyInThread,
                            isDense: true,
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                      const SizedBox(width: 6),
                      IconButton.filled(
                        key: const Key('threadSend'),
                        tooltip: l.send,
                        onPressed: _sending || _text.text.trim().isEmpty
                            ? null
                            : () => _send(root),
                        icon: const Icon(LucideIcons.sendHorizontalDir),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A poll under its question: each option with how many picked it, a tap to
/// pick (again to take it back), and who answered.
class _PollView extends StatelessWidget {
  const _PollView({
    required this.poll,
    required this.me,
    required this.mine,
    required this.onVote,
  });

  final Poll poll;
  final String? me;
  final bool mine;
  final void Function(Set<int> picks)? onVote;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final picks = poll.picksOf(me);
    final voters = poll.voters.length;
    final open = !poll.closed && onVote != null;
    final accent = mine ? Colors.white : theme.colorScheme.primary;
    final muted = mine ? Colors.white70 : theme.colorScheme.onSurfaceVariant;

    void pick(int i) {
      final next = poll.multiple
          ? (picks.contains(i) ? ({...picks}..remove(i)) : {...picks, i})
          : (picks.contains(i) ? <int>{} : {i});
      onVote!(next);
    }

    return Padding(
      key: const Key('poll'),
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            poll.closed
                ? l.pollClosed
                : poll.multiple
                ? l.pollPickMany
                : l.pollPickOne,
            style: theme.textTheme.labelSmall?.copyWith(color: muted),
          ),
          const SizedBox(height: 4),
          for (var i = 0; i < poll.options.length; i++)
            InkWell(
              key: Key('pollOption-$i'),
              borderRadius: BorderRadius.circular(8),
              onTap: open ? () => pick(i) : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(
                          picks.contains(i)
                              ? LucideIcons.circleCheckBig
                              : LucideIcons.circle,
                          size: 18,
                          color: picks.contains(i) ? accent : muted,
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: Text(poll.options[i])),
                        Text(
                          '${poll.votersOf(i).length}',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: muted,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: voters == 0
                            ? 0
                            : poll.votersOf(i).length / voters,
                        minHeight: 5,
                        color: accent,
                        backgroundColor: accent.withValues(alpha: 0.15),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Text(
            l.pollVoters(voters),
            style: theme.textTheme.labelSmall?.copyWith(color: muted),
          ),
        ],
      ),
    );
  }
}

typedef _PollDraft = ({String question, List<String> options, bool multiple});

/// Writes a poll: the question, two to ten options, and whether more than
/// one may be picked.
class _PollComposer extends StatefulWidget {
  const _PollComposer();

  @override
  State<_PollComposer> createState() => _PollComposerState();
}

class _PollComposerState extends State<_PollComposer> {
  final _question = TextEditingController();
  final _options = [TextEditingController(), TextEditingController()];
  bool _multiple = false;

  @override
  void dispose() {
    _question.dispose();
    for (final c in _options) {
      c.dispose();
    }
    super.dispose();
  }

  void _send() {
    final question = _question.text.trim();
    final options = [
      for (final c in _options)
        if (c.text.trim().isNotEmpty) c.text.trim(),
    ];
    if (question.isEmpty || options.length < 2) {
      showMessage(context, context.l10n.pollNeedsTwo);
      return;
    }
    Navigator.pop<_PollDraft>(context, (
      question: question,
      options: options,
      multiple: _multiple,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          0,
          20,
          16 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l.newPoll,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('pollQuestion'),
              controller: _question,
              autofocus: true,
              maxLength: 300,
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(labelText: l.pollQuestion),
            ),
            for (var i = 0; i < _options.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: TextField(
                  key: Key('pollOptionField-$i'),
                  controller: _options[i],
                  maxLength: 100,
                  decoration: InputDecoration(
                    labelText: l.pollOption(i + 1),
                    counterText: '',
                  ),
                ),
              ),
            if (_options.length < 10)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  key: const Key('pollAddOption'),
                  icon: const Icon(LucideIcons.plus, size: 18),
                  label: Text(l.pollAddOption),
                  onPressed: () =>
                      setState(() => _options.add(TextEditingController())),
                ),
              ),
            SwitchListTile(
              key: const Key('pollMultiple'),
              contentPadding: EdgeInsets.zero,
              title: Text(l.pollMultiple),
              value: _multiple,
              onChanged: (v) => setState(() => _multiple = v),
            ),
            const SizedBox(height: 8),
            FilledButton(
              key: const Key('sendPoll'),
              onPressed: _send,
              child: Text(l.pollSend),
            ),
          ],
        ),
      ),
    );
  }
}

/// On top of a chat: its pinned message, a tap from it, and for whoever
/// may, a way to take it down.
class _PinnedBar extends StatelessWidget {
  const _PinnedBar({required this.pin, required this.onTap, this.onUnpin});

  final PinnedMessage pin;
  final VoidCallback onTap;
  final VoidCallback? onUnpin;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    return Material(
      key: const Key('pinnedBar'),
      color: theme.colorScheme.surfaceContainerHigh,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 4, 8),
          child: Row(
            children: [
              Icon(LucideIcons.pin, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l.pinnedMessage,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '${firstName(pin.senderName)}: '
                      '${pin.body ?? pin.fileName ?? ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
              if (onUnpin != null)
                IconButton(
                  key: const Key('unpin'),
                  tooltip: l.unpinMessage,
                  icon: const Icon(LucideIcons.x, size: 18),
                  onPressed: onUnpin,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
