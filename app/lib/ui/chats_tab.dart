import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/chat_models.dart';
import '../data/models.dart';
import '../state/chat_providers.dart';
import '../state/providers.dart';
import '../theme.dart';
import 'announcements_view.dart';
import 'chat_format.dart';
import 'chat_screen.dart';
import 'widgets.dart';

/// Every chat in one list, as in the design: announcements on top, then
/// project and private chats, latest first, filterable by project.
class ChatsTab extends ConsumerStatefulWidget {
  const ChatsTab({super.key, required this.membership});

  final Membership membership;

  @override
  ConsumerState<ChatsTab> createState() => _ChatsTabState();
}

class _ChatsTabState extends ConsumerState<ChatsTab> {
  final _search = TextEditingController();
  String? _project;
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
    final ws = widget.membership.workspaceId;
    final chats = ref.watch(conversationsProvider(ws));
    final notes = ref.watch(unreadAnnouncementsProvider(ws)).value ?? const [];
    final me = ref.watch(authProvider).value;
    final projects = ref.watch(projectsProvider(ws)).value ?? const <Project>[];

    Future<void> refresh() {
      ref.invalidate(unreadAnnouncementsProvider(ws));
      return ref.refresh(conversationsProvider(ws).future);
    }

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'newMessage',
        onPressed: () => _newChat(context),
        icon: const Icon(Icons.edit_outlined),
        label: Text(l.newMessage),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              key: const Key('chatSearch'),
              controller: _search,
              onChanged: _onQuery,
              decoration: InputDecoration(
                hintText: l.chatsSearchHint,
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: l.cancel,
                        icon: const Icon(Icons.close),
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
                membership: widget.membership,
                query: _query,
                chats: chats.value ?? const [],
              ),
            )
          else ...[
            _ProjectFilter(
              chats: chats.value ?? const [],
              selected: _project,
              onSelected: (id) => setState(() => _project = id),
            ),
            Expanded(
              child: AsyncView(
                value: chats,
                onRetry: () => ref.invalidate(conversationsProvider(ws)),
                builder: (all) {
                  final shown = _project == null
                      ? all
                      : all
                            .where((c) => c.tagProjectIds.contains(_project))
                            .toList();
                  final shownNotes = _project == null
                      ? notes
                      : notes.where((n) => n.projectId == _project).toList();
                  return RefreshIndicator(
                    onRefresh: refresh,
                    child: shown.isEmpty && shownNotes.isEmpty
                        ? ListView(
                            children: [
                              const SizedBox(height: 60),
                              EmptyState(
                                icon: Icons.forum_outlined,
                                title: _project == null
                                    ? l.chatsEmptyTitle
                                    : l.chatsFilterEmpty,
                                body: _project == null
                                    ? l.chatsEmptyBody
                                    : null,
                              ),
                            ],
                          )
                        : ListView(
                            padding: const EdgeInsets.only(bottom: 96),
                            children: [
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
                                  filter: _project,
                                  projects: projects,
                                  onTap: () => Navigator.of(context).push(
                                    MaterialPageRoute<void>(
                                      builder: (_) => ChatScreen(
                                        membership: widget.membership,
                                        target: ChatTarget.of(c),
                                        projectFilter: c.isProject
                                            ? null
                                            : _project,
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

class _ProjectFilter extends StatelessWidget {
  const _ProjectFilter({
    required this.chats,
    required this.selected,
    required this.onSelected,
  });

  final List<Conversation> chats;
  final String? selected;
  final void Function(String?) onSelected;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final projects = [
      for (final c in chats)
        if (c.isProject) c,
    ];
    if (projects.isEmpty) return const SizedBox(height: 4);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 8),
            child: ChoiceChip(
              label: Text(l.filterAll),
              selected: selected == null,
              onSelected: (_) => onSelected(null),
            ),
          ),
          for (final c in projects)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: ChoiceChip(
                avatar: ColorDot(hex: c.projectColor ?? '#0F6E6A', size: 10),
                showCheckmark: false,
                label: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 160),
                  child: Text(c.title, overflow: TextOverflow.ellipsis),
                ),
                selected: selected == c.projectId,
                onSelected: (_) =>
                    onSelected(selected == c.projectId ? null : c.projectId),
              ),
            ),
        ],
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
  });

  final Conversation chat;
  final String? me;
  final String? filter;
  final List<Project> projects;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final unread = chat.unread > 0;
    final lastAt = chat.lastAt;

    // A private chat shows a project it is about (the filtered one first).
    final want = filter ?? chat.tagProjectIds.firstOrNull;
    final tag = chat.isProject || want == null
        ? null
        : projects.where((p) => p.id == want).firstOrNull;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            if (chat.isProject)
              ProjectAvatar(
                name: chat.title,
                hex: chat.projectColor ?? '#0F6E6A',
              )
            else
              Avatar(name: chat.title, radius: 24),
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
                            color: chat.otherActive ? null : muted,
                          ),
                        ),
                      ),
                      if (lastAt != null) ...[
                        const SizedBox(width: 8),
                        Text(
                          listTime(context, lastAt),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: unread ? theme.colorScheme.primary : muted,
                            fontWeight: unread ? FontWeight.w700 : null,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      if (chat.lastFileName != null && !chat.lastDeleted) ...[
                        Icon(Icons.attach_file, size: 15, color: muted),
                        const SizedBox(width: 2),
                      ],
                      Expanded(
                        child: Text(
                          preview(l, chat, me),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: unread ? theme.colorScheme.onSurface : muted,
                          ),
                        ),
                      ),
                      if (unread) ...[
                        const SizedBox(width: 8),
                        Badge(
                          label: Text('${chat.unread}'),
                          backgroundColor: theme.colorScheme.primary,
                          textColor: theme.colorScheme.onPrimary,
                        ),
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

class _SmallTag extends StatelessWidget {
  const _SmallTag({required this.project});

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
    return Material(
      color: color.withValues(alpha: 0.10),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: color,
                foregroundColor: brightness == Brightness.dark
                    ? const Color(0xFF0F1419)
                    : Colors.white,
                child: const Icon(Icons.campaign_outlined),
              ),
              const SizedBox(width: 12),
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
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
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
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
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
                  prefixIcon: const Icon(Icons.search),
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
                      icon: Icons.group_outlined,
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

class _SearchResultsState extends ConsumerState<_SearchResults> {
  late Future<List<MessageHit>> _hits = _load();

  Future<List<MessageHit>> _load() => ref
      .read(apiProvider)
      .searchMessages(widget.membership.workspaceId, widget.query);

  @override
  void didUpdateWidget(_SearchResults old) {
    super.didUpdateWidget(old);
    if (old.query != widget.query) _hits = _load();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final me = ref.watch(authProvider).value;
    final q = widget.query.toLowerCase();
    final people =
        (ref.watch(membersProvider(widget.membership.workspaceId)).value ??
                const <Member>[])
            .where(
              (m) => m.userId != me && m.fullName.toLowerCase().contains(q),
            )
            .toList();

    return FutureBuilder<List<MessageHit>>(
      future: _hits,
      builder: (context, snap) {
        final hits = snap.data ?? const <MessageHit>[];
        final loading = snap.connectionState != ConnectionState.done;
        return ListView(
          padding: const EdgeInsets.only(bottom: 96),
          children: [
            if (people.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: SectionTitle(l.searchPeople),
              ),
              for (final m in people)
                PersonTile(
                  name: m.fullName,
                  contact: m.contact,
                  onTap: () =>
                      openPrivateChat(context, ref, widget.membership, m),
                ),
            ],
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SectionTitle(l.searchMessages),
            ),
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
            else if (hits.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  l.searchNoResults,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              for (final h in hits)
                ListTile(
                  leading: h.fileName != null
                      ? FileBadge(name: h.fileName!)
                      : Avatar(name: h.senderName),
                  title: Text(
                    h.body ?? h.fileName ?? '',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${_chatTitle(h.conversationId)} · '
                    '${h.senderName} · ${listTime(context, h.createdAt)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () {
                    final chat = widget.chats
                        .where((c) => c.id == h.conversationId)
                        .firstOrNull;
                    if (chat == null) return;
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => ChatScreen(
                          membership: widget.membership,
                          target: ChatTarget.of(chat),
                        ),
                      ),
                    );
                  },
                ),
          ],
        );
      },
    );
  }

  String _chatTitle(String id) =>
      widget.chats.where((c) => c.id == id).firstOrNull?.title ?? '';
}
