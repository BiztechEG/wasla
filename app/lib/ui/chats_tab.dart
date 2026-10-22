import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/chat_models.dart';
import '../data/models.dart';
import '../data/search_models.dart';
import '../data/voice.dart';
import '../state/chat_providers.dart';
import '../state/providers.dart';
import '../theme.dart';
import 'announcements_view.dart';
import 'chat_format.dart';
import 'chat_screen.dart';
import 'files_common.dart';
import 'modern.dart';
import 'project_screen.dart';
import 'projects_tab.dart';
import 'task_format.dart';
import 'task_screen.dart';
import 'widgets.dart';

/// Every chat in one list, as in the design: announcements on top, then
/// project and private chats, latest first, filterable by project.
class ChatsTab extends ConsumerStatefulWidget {
  const ChatsTab({super.key, required this.membership});

  final Membership membership;

  @override
  ConsumerState<ChatsTab> createState() => _ChatsTabState();
}

enum _Kind { all, unread, people }

final _searchBorder = OutlineInputBorder(
  borderRadius: BorderRadius.circular(14),
  borderSide: BorderSide.none,
);

class _ChatsTabState extends ConsumerState<ChatsTab> {
  final _search = TextEditingController();
  String? _project;
  _Kind _kind = _Kind.all;
  String _query = '';
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onQuery(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _query = value.trim());
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final ws = widget.membership.workspaceId;
    final chats = ref.watch(conversationsProvider(ws));
    final notes = ref.watch(unreadAnnouncementsProvider(ws)).value ?? const [];
    final me = ref.watch(authProvider).value;
    final projects = ref.watch(projectsProvider(ws)).value ?? const <Project>[];
    final mutedChats =
        ref.watch(mutedChatsProvider(ws)).value ?? const <String, DateTime?>{};

    Future<void> refresh() {
      ref.invalidate(unreadAnnouncementsProvider(ws));
      return ref.refresh(conversationsProvider(ws).future);
    }

    return FabScaffold(
      fab: WaslaFab(
        icon: LucideIcons.squarePen,
        tooltip: l.newMessage,
        onPressed: () => _newChat(context),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: TextField(
              key: const Key('chatSearch'),
              controller: _search,
              onChanged: _onQuery,
              decoration: InputDecoration(
                hintText: l.chatsSearchHint,
                prefixIcon: const Icon(LucideIcons.search, size: 19),
                isDense: true,
                filled: true,
                fillColor: theme.colorScheme.surfaceContainerHigh,
                border: _searchBorder,
                enabledBorder: _searchBorder,
                focusedBorder: _searchBorder.copyWith(
                  borderSide: BorderSide(
                    color: theme.colorScheme.primary,
                    width: 1.5,
                  ),
                ),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: l.cancel,
                        icon: const Icon(LucideIcons.x, size: 19),
                        onPressed: () {
                          _search.clear();
                          setState(() => _query = '');
                        },
                      ),
              ),
            ),
          ),
          if (_query.length >= 2)
            Expanded(
              child: _SearchResults(
                // A new search starts from the top of its results.
                key: ValueKey(_query),
                membership: widget.membership,
                query: _query,
                chats: chats.value ?? const [],
              ),
            )
          else
            Expanded(
              child: AsyncView(
                value: chats,
                onRetry: () => ref.invalidate(conversationsProvider(ws)),
                builder: (all) {
                  final shown = [
                    for (final c in all)
                      if ((_project == null ||
                              c.tagProjectIds.contains(_project)) &&
                          switch (_kind) {
                            _Kind.all => true,
                            _Kind.unread => c.unread > 0,
                            _Kind.people => !c.isProject,
                          })
                        c,
                  ];
                  final shownNotes = _kind == _Kind.people
                      ? const <UnreadAnnouncement>[]
                      : _project == null
                      ? notes
                      : notes.where((n) => n.projectId == _project).toList();
                  final unreadChats = all.where((c) => c.unread > 0).length;
                  return RefreshIndicator(
                    onRefresh: refresh,
                    child: ListView(
                      padding: EdgeInsets.fromLTRB(
                        8,
                        0,
                        8,
                        navClearance(context) + 80,
                      ),
                      children: [
                        _ProjectStrip(
                          chats: all,
                          selected: _project,
                          onSelected: (id) => setState(() => _project = id),
                        ),
                        // Filters only once there is something to filter.
                        if (all.length >= 5 || _kind != _Kind.all)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
                            child: Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                for (final k in _Kind.values)
                                  FilterPill(
                                    label: switch (k) {
                                      _Kind.all => l.filterAll,
                                      _Kind.unread => l.filterUnread,
                                      _Kind.people => l.filterPeople,
                                    },
                                    count: k == _Kind.unread
                                        ? unreadChats
                                        : null,
                                    selected: _kind == k,
                                    onTap: () => setState(() => _kind = k),
                                  ),
                              ],
                            ),
                          ),
                        if (shown.isEmpty && shownNotes.isEmpty) ...[
                          const SizedBox(height: 40),
                          EmptyState(
                            icon: LucideIcons.messageCircle,
                            title: _project == null && _kind == _Kind.all
                                ? l.chatsEmptyTitle
                                : l.chatsFilterEmpty,
                            body: _project == null && _kind == _Kind.all
                                ? l.chatsEmptyBody
                                : null,
                          ),
                          // An admin's first step in a new workspace.
                          if (projects.isEmpty &&
                              widget.membership.role.canManage)
                            Center(
                              child: FilledButton.tonalIcon(
                                key: const Key('firstProject'),
                                icon: const Icon(LucideIcons.plus, size: 18),
                                label: Text(l.newProject),
                                onPressed: () => showModalBottomSheet<void>(
                                  context: context,
                                  isScrollControlled: true,
                                  builder: (_) =>
                                      NewProjectSheet(workspaceId: ws),
                                ),
                              ),
                            ),
                        ],
                        for (final n in shownNotes.take(3))
                          _AnnouncementRow(
                            note: n,
                            onTap: () => showAnnouncement(
                              context,
                              ref,
                              workspaceId: ws,
                              note: n,
                            ),
                          ),
                        for (final c in shown)
                          _ChatRow(
                            chat: c,
                            me: me,
                            silenced: mutedChats.containsKey(c.id),
                            filter: _project,
                            projects: projects,
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => ChatScreen(
                                  membership: widget.membership,
                                  target: ChatTarget.of(c),
                                  projectFilter: c.isProject ? null : _project,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _newChat(BuildContext context) async {
    final ws = widget.membership.workspaceId;
    final person = await showModalBottomSheet<Member>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _PeopleSheet(workspaceId: ws),
    );
    if (person == null || !context.mounted) return;
    await openPrivateChat(context, ref, widget.membership, person);
  }
}

/// Opens (creating if needed) the private chat with [person].
Future<void> openPrivateChat(
  BuildContext context,
  WidgetRef ref,
  Membership membership,
  Member person,
) async {
  String? id;
  final ok = await runAction(context, () async {
    id = await ref
        .read(apiProvider)
        .openDirect(membership.workspaceId, person.userId);
  });
  if (!ok || !context.mounted) return;
  final existing = ref
      .read(conversationsProvider(membership.workspaceId))
      .value
      ?.where((c) => c.id == id)
      .firstOrNull;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ChatScreen(
        membership: membership,
        target: existing != null
            ? ChatTarget.of(existing)
            : ChatTarget(
                conversationId: id!,
                title: person.fullName,
                otherId: person.userId,
              ),
      ),
    ),
  );
}

/// The projects as a row of tiles over the chats: a ring and a count when
/// there is something new, and a tap filters the list by that project.
class _ProjectStrip extends StatelessWidget {
  const _ProjectStrip({
    required this.chats,
    required this.selected,
    required this.onSelected,
  });

  final List<Conversation> chats;
  final String? selected;
  final void Function(String?) onSelected;

  @override
  Widget build(BuildContext context) {
    final projects = [
      for (final c in chats)
        if (c.isProject) c,
    ];
    // A new project starts from the projects tab, or from the empty list.
    if (projects.isEmpty) return const SizedBox(height: 4);
    return SizedBox(
      height: 92,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
        children: [
          for (final c in projects)
            _StripTile(
              chat: c,
              selected: selected == c.projectId,
              onTap: () =>
                  onSelected(selected == c.projectId ? null : c.projectId),
            ),
        ],
      ),
    );
  }
}

class _StripTile extends StatelessWidget {
  const _StripTile({
    required this.chat,
    required this.selected,
    required this.onTap,
  });

  final Conversation chat;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = WaslaColors.project(
      chat.projectColor ?? '#0F6E6A',
      theme.brightness,
    );
    final ring = selected
        ? scheme.onSurface
        : chat.unread > 0
        ? color
        : null;
    return Tooltip(
      message: chat.title,
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        selected: selected,
        label: chat.title,
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            width: 62,
            child: Column(
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(2.5),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(19),
                        border: Border.all(
                          color: ring ?? Colors.transparent,
                          width: 2,
                        ),
                      ),
                      child: ProjectAvatar(
                        name: chat.title,
                        hex: chat.projectColor ?? '#0F6E6A',
                        size: 44,
                      ),
                    ),
                    if (chat.unread > 0)
                      PositionedDirectional(
                        top: -4,
                        end: -4,
                        child: Container(
                          constraints: const BoxConstraints(minWidth: 18),
                          height: 18,
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: color,
                            borderRadius: BorderRadius.circular(9),
                            border: Border.all(
                              color: theme.scaffoldBackgroundColor,
                              width: 2,
                            ),
                          ),
                          child: Text(
                            chat.unread > 99 ? '99+' : '${chat.unread}',
                            style: TextStyle(
                              color: theme.scaffoldBackgroundColor,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              height: 1,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  chat.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: selected
                        ? scheme.onSurface
                        : scheme.onSurfaceVariant,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
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

class _ChatRow extends StatelessWidget {
  const _ChatRow({
    required this.chat,
    required this.me,
    required this.filter,
    required this.projects,
    required this.onTap,
    this.silenced = false,
  });

  final Conversation chat;
  final String? me;
  final String? filter;
  final List<Project> projects;
  final VoidCallback onTap;

  /// Muted: its messages stay off the phone.
  final bool silenced;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    final unread = chat.unread > 0;
    final lastAt = chat.lastAt;

    // A private chat shows a project it is about (the filtered one first).
    final want = filter ?? chat.tagProjectIds.firstOrNull;
    final tag = chat.isProject || want == null
        ? null
        : projects.where((p) => p.id == want).firstOrNull;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Row(
          children: [
            if (chat.isProject)
              ProjectAvatar(
                name: chat.title,
                hex: chat.projectColor ?? '#0F6E6A',
                size: 50,
              )
            else
              Avatar(name: chat.title, radius: 25),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          chat.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            fontSize: 15.5,
                            color: chat.otherActive ? null : muted,
                          ),
                        ),
                      ),
                      if (silenced) ...[
                        const SizedBox(width: 6),
                        Tooltip(
                          message: l.mutedLabel,
                          child: Icon(
                            LucideIcons.bellOff,
                            key: const Key('mutedMark'),
                            size: 15,
                            color: muted,
                          ),
                        ),
                      ],
                      if (lastAt != null) ...[
                        const SizedBox(width: 8),
                        Text(
                          listTime(context, lastAt),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: unread ? scheme.primary : muted,
                            fontWeight: unread ? FontWeight.w700 : null,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Expanded(
                        child: _Preview(chat: chat, me: me, unread: unread),
                      ),
                      if (chat.unreadMentions > 0) ...[
                        const SizedBox(width: 8),
                        Tooltip(
                          message: l.mentionsYou,
                          child: CircleAvatar(
                            key: const Key('mentionBadge'),
                            radius: 11,
                            backgroundColor: scheme.primary,
                            child: Text(
                              '@',
                              style: TextStyle(
                                color: scheme.onPrimary,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ],
                      if (unread) ...[
                        const SizedBox(width: 6),
                        CountPill(count: chat.unread),
                      ],
                    ],
                  ),
                  if (tag != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: _SmallTag(project: tag),
                    ),
                  if (!chat.otherActive)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        l.leftWorkspace,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: muted,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The last message under a chat's name: who sent it, then the text, a file
/// or a voice message drawn as a short wave as long as the recording.
class _Preview extends StatelessWidget {
  const _Preview({required this.chat, required this.me, required this.unread});

  final Conversation chat;
  final String? me;
  final bool unread;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    final style = theme.textTheme.bodyMedium?.copyWith(
      fontSize: 13.5,
      color: unread ? scheme.onSurface : muted,
    );
    if (chat.lastAt == null || chat.lastDeleted) {
      return Text(
        preview(l, chat, me),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }
    final who = chat.lastSenderId == me
        ? l.you
        : chat.isProject
        ? firstName(chat.lastSenderName ?? '')
        : null;
    final file = chat.lastFileName;
    final body = chat.lastBody;
    final voice = file == null || (body?.isNotEmpty ?? false)
        ? null
        : voiceLength(file);
    final whoSpan = who == null
        ? null
        : TextSpan(
            text: voice == null ? '$who: ' : who,
            style: TextStyle(
              color: scheme.onSurface,
              fontWeight: FontWeight.w500,
            ),
          );

    if (voice != null) {
      return Row(
        children: [
          if (whoSpan != null) ...[
            Text.rich(whoSpan, style: style),
            const SizedBox(width: 8),
          ],
          VoiceWave(
            seconds: voice.inSeconds,
            color: unread ? scheme.primary : muted,
            height: 16,
            seed: chat.id.hashCode % 7,
          ),
          const SizedBox(width: 7),
          Text(
            clockLength(voice),
            style: theme.textTheme.labelSmall?.copyWith(
              color: muted,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      );
    }

    return Row(
      children: [
        if (file != null && !(body?.isNotEmpty ?? false)) ...[
          Icon(LucideIcons.paperclip, size: 14, color: muted),
          const SizedBox(width: 4),
        ],
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                ?whoSpan,
                TextSpan(
                  text: body != null && body.isNotEmpty
                      ? body
                      : fileLabel(l, file ?? ''),
                ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
      ],
    );
  }
}

/// The project a private chat is about: a colored square and its name.
class _SmallTag extends StatelessWidget {
  const _SmallTag({required this.project});

  final Project project;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = WaslaColors.project(project.color, theme.brightness);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            project.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: 11.5,
            ),
          ),
        ),
      ],
    );
  }
}

class _AnnouncementRow extends StatelessWidget {
  const _AnnouncementRow({required this.note, required this.onTap});

  final UnreadAnnouncement note;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final brightness = theme.brightness;
    final color = WaslaColors.project(
      note.projectColor ?? '#C2660A',
      brightness,
    );
    final surface = theme.colorScheme.surface;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Material(
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: Ink(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: AlignmentDirectional.centerStart,
              end: AlignmentDirectional.centerEnd,
              colors: [
                Color.lerp(surface, color, 0.16)!,
                Color.lerp(surface, color, 0.05)!,
              ],
            ),
          ),
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      LucideIcons.megaphone,
                      size: 19,
                      color: brightness == Brightness.dark
                          ? Colors.black
                          : Colors.white,
                    ),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                note.projectName == null
                                    ? l.announcementForAll
                                    : l.announcementFor(note.projectName!),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: WaslaColors.onTint(color, brightness),
                                ),
                              ),
                            ),
                            Text(
                              listTime(context, note.createdAt),
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                        Text(
                          note.body,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w500,
                            fontSize: 13.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    LucideIcons.chevronRightDir,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PeopleSheet extends ConsumerStatefulWidget {
  const _PeopleSheet({required this.workspaceId});

  final String workspaceId;

  @override
  ConsumerState<_PeopleSheet> createState() => _PeopleSheetState();
}

class _PeopleSheetState extends ConsumerState<_PeopleSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final me = ref.watch(authProvider).value;
    final members = ref.watch(membersProvider(widget.workspaceId));

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.75,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                l.newMessage,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                autofocus: false,
                onChanged: (v) => setState(() => _query = v.trim()),
                decoration: InputDecoration(
                  hintText: l.searchMembers,
                  prefixIcon: const Icon(LucideIcons.search),
                  isDense: true,
                ),
              ),
            ),
            Expanded(
              child: AsyncView(
                value: members,
                onRetry: () =>
                    ref.invalidate(membersProvider(widget.workspaceId)),
                builder: (all) {
                  final others = all.where((m) => m.userId != me).toList();
                  if (others.isEmpty) {
                    return EmptyState(
                      icon: LucideIcons.users,
                      title: l.noColleagues,
                    );
                  }
                  final shown = others
                      .where(
                        (m) =>
                            _query.isEmpty ||
                            m.fullName.toLowerCase().contains(
                              _query.toLowerCase(),
                            ),
                      )
                      .toList();
                  return ListView(
                    children: [
                      for (final m in shown)
                        PersonTile(
                          name: m.fullName,
                          contact: m.contact,
                          onTap: () => Navigator.pop(context, m),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchResults extends ConsumerStatefulWidget {
  const _SearchResults({
    super.key,
    required this.membership,
    required this.query,
    required this.chats,
  });

  final Membership membership;
  final String query;
  final List<Conversation> chats;

  @override
  ConsumerState<_SearchResults> createState() => _SearchResultsState();
}

/// Everything a search found: messages, plus files, tasks and announcements.
typedef _Found = (List<MessageHit>, WorkspaceSearch);

class _SearchResultsState extends ConsumerState<_SearchResults> {
  late Future<_Found> _hits = _load();

  Future<_Found> _load() {
    final api = ref.read(apiProvider);
    final ws = widget.membership.workspaceId;
    return (
      api.searchMessages(ws, widget.query),
      api.searchWorkspace(ws, widget.query),
    ).wait;
  }

  @override
  void didUpdateWidget(_SearchResults old) {
    super.didUpdateWidget(old);
    if (old.query != widget.query) _hits = _load();
  }

  void _push(Widget screen) =>
      Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => screen));

  void _openProject(String id, {ProjectTab tab = ProjectTab.status}) {
    final project = ref
        .read(projectsProvider(widget.membership.workspaceId))
        .value
        ?.where((p) => p.id == id)
        .firstOrNull;
    if (project != null) {
      _push(ProjectScreen(project: project, initialTab: tab));
    }
  }

  void _openMessage(MessageHit h) {
    // Chats outside the list (a closed project, or one an admin is not part
    // of) open from the hit itself.
    final chat =
        widget.chats.where((c) => c.id == h.conversationId).firstOrNull ??
        h.chat;
    _push(
      ChatScreen(membership: widget.membership, target: ChatTarget.of(chat)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final me = ref.watch(authProvider).value;
    final ws = widget.membership.workspaceId;
    final q = normalizeSearch(widget.query);
    final people = (ref.watch(membersProvider(ws)).value ?? const <Member>[])
        .where((m) => m.userId != me && normalizeSearch(m.fullName).contains(q))
        .toList();
    final projects =
        (ref.watch(projectsProvider(ws)).value ?? const <Project>[])
            .where((p) => normalizeSearch(p.name).contains(q))
            .toList();

    Widget section(String title) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: SectionTitle(title),
    );
    Widget line(String text) =>
        Text(text, maxLines: 1, overflow: TextOverflow.ellipsis);

    return FutureBuilder<_Found>(
      future: _hits,
      builder: (context, snap) {
        final loading = snap.connectionState != ConnectionState.done;
        final (messages, found) =
            snap.data ?? (const <MessageHit>[], const WorkspaceSearch());
        final nothing =
            people.isEmpty &&
            projects.isEmpty &&
            messages.isEmpty &&
            found.files.isEmpty &&
            found.tasks.isEmpty &&
            found.announcements.isEmpty;
        return ListView(
          padding: const EdgeInsets.only(bottom: 96),
          children: [
            if (people.isNotEmpty) ...[
              section(l.searchPeople),
              for (final m in people)
                PersonTile(
                  name: m.fullName,
                  contact: m.contact,
                  onTap: () =>
                      openPrivateChat(context, ref, widget.membership, m),
                ),
            ],
            if (projects.isNotEmpty) ...[
              section(l.searchProjects),
              for (final p in projects)
                ListTile(
                  leading: CircleAvatar(
                    radius: 18,
                    backgroundColor: WaslaColors.project(
                      p.color,
                      theme.brightness,
                    ).withValues(alpha: 0.14),
                    child: Icon(
                      LucideIcons.folder,
                      size: 20,
                      color: WaslaColors.project(p.color, theme.brightness),
                    ),
                  ),
                  title: line(p.name),
                  onTap: () => _openProject(p.id),
                ),
            ],
            if (found.tasks.isNotEmpty) ...[
              section(l.searchTasks),
              for (final t in found.tasks)
                ListTile(
                  leading: const Icon(LucideIcons.circleCheck),
                  title: line(t.title),
                  subtitle: line(
                    t.dueAt == null
                        ? t.projectName
                        : '${t.projectName} · ${dueText(context, t.dueAt!)}',
                  ),
                  trailing: StatusTag(t.status),
                  onTap: () => _push(TaskScreen(workspaceId: ws, taskId: t.id)),
                ),
            ],
            if (found.files.isNotEmpty) ...[
              section(l.searchFiles),
              for (final f in found.files)
                ListTile(
                  leading: FileBadge(name: f.file.name),
                  title: line(f.file.name),
                  subtitle: line(
                    '${f.projectName} · ${listTime(context, f.createdAt)}',
                  ),
                  onTap: () => openFile(context, ref, f.file),
                ),
            ],
            if (messages.isNotEmpty) ...[
              section(l.searchMessages),
              for (final h in messages)
                ListTile(
                  leading: h.fileName != null
                      ? FileBadge(name: h.fileName!)
                      : Avatar(name: h.senderName),
                  title: Text(
                    h.body ?? h.fileName ?? '',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: line(
                    '${h.chat.title} · '
                    '${h.senderName} · ${listTime(context, h.createdAt)}',
                  ),
                  onTap: () => _openMessage(h),
                ),
            ],
            if (found.announcements.isNotEmpty) ...[
              section(l.searchAnnouncements),
              for (final a in found.announcements)
                ListTile(
                  leading: const Icon(LucideIcons.megaphone),
                  title: Text(
                    a.body,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: line(
                    '${a.projectName ?? l.workspaceAnnouncements} · '
                    '${a.authorName} · ${listTime(context, a.createdAt)}',
                  ),
                  onTap: () => a.projectId == null
                      ? _push(
                          WorkspaceAnnouncementsScreen(
                            membership: widget.membership,
                          ),
                        )
                      : _openProject(
                          a.projectId!,
                          tab: ProjectTab.announcements,
                        ),
                ),
            ],
            if (loading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (snap.hasError)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  errorText(l, snap.error!),
                  textAlign: TextAlign.center,
                ),
              )
            else if (nothing)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  l.searchNoResults,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                ),
              ),
          ],
        );
      },
    );
  }
}
