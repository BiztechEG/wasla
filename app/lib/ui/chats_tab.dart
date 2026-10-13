import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/chat_models.dart';
import '../data/models.dart';
import '../data/search_models.dart';
import '../state/chat_providers.dart';
import '../state/providers.dart';
import '../theme.dart';
import 'announcements_view.dart';
import 'files_common.dart';
import 'chat_format.dart';
import 'chat_screen.dart';
import 'project_screen.dart';
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
                            padding: const EdgeInsets.fromLTRB(4, 4, 4, 96),
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
              showCheckmark: false,
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
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Row(
          children: [
            if (chat.isProject)
              ProjectAvatar(
                name: chat.title,
                hex: chat.projectColor ?? '#0F6E6A',
                size: 52,
              )
            else
              Avatar(name: chat.title, radius: 26),
            const SizedBox(width: 14),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
      child: Material(
        color: color.withValues(
          alpha: brightness == Brightness.dark ? 0.16 : 0.10,
        ),
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(17),
                  ),
                  child: Icon(
                    Icons.campaign_outlined,
                    color: brightness == Brightness.dark
                        ? Colors.black
                        : Colors.white,
                  ),
                ),
                const SizedBox(width: 14),
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
                      Icons.folder_outlined,
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
                  leading: const Icon(Icons.task_alt),
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
                  leading: const Icon(Icons.campaign_outlined),
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
