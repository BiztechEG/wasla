import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/chat_models.dart';
import '../data/picker.dart';
import '../data/voice.dart';
import 'providers.dart';

/// Live changes to the workspace's chats.
final chatEventsProvider = StreamProvider.autoDispose.family<ChatEvent, String>(
  (ref, workspaceId) {
    final api = ref.watch(apiProvider);
    // Starts over for whoever signs in next; quiet while signed out.
    if (ref.watch(authProvider).value == null) return const Stream.empty();
    return api.chatEvents(workspaceId);
  },
);

/// Calls [refresh] shortly after the last of a burst of chat changes.
void _refreshOnChatEvents(
  Ref ref,
  String workspaceId,
  void Function() refresh, {
  bool Function(ChatEvent event)? where,
}) {
  Timer? timer;
  ref.listen(chatEventsProvider(workspaceId), (_, next) {
    final event = next.value;
    if (event == null || (where != null && !where(event))) return;
    timer?.cancel();
    timer = Timer(const Duration(milliseconds: 250), refresh);
  });
  ref.onDispose(() => timer?.cancel());
}

final conversationsProvider = FutureProvider.autoDispose
    .family<List<Conversation>, String>((ref, workspaceId) async {
      final api = ref.watch(apiProvider);
      // Others reading a chat changes nothing in this list; reading it here
      // (maybe on another phone) clears its unread count.
      _refreshOnChatEvents(
        ref,
        workspaceId,
        ref.invalidateSelf,
        where: (e) =>
            e.readerId == null || e.readerId == ref.read(authProvider).value,
      );
      // A new, closed or reopened project changes which group chats show.
      ref.listen(projectsProvider(workspaceId).select((p) => p.value), (
        before,
        after,
      ) {
        if (before != null && after != null) ref.invalidateSelf();
      });
      await ref.watch(authProvider.future);
      return api.conversations(workspaceId);
    });

final unreadAnnouncementsProvider = FutureProvider.autoDispose
    .family<List<UnreadAnnouncement>, String>((ref, workspaceId) async {
      final api = ref.watch(apiProvider);
      await ref.watch(authProvider.future);
      return api.unreadAnnouncements(workspaceId);
    });

/// Unread chats plus unread announcements, for the Chats tab badge.
final chatBadgeProvider = Provider.autoDispose.family<int, String>((
  ref,
  workspaceId,
) {
  final chats = ref.watch(conversationsProvider(workspaceId)).value ?? [];
  final notes = ref.watch(unreadAnnouncementsProvider(workspaceId)).value;
  return chats.where((c) => c.unread > 0).length + (notes?.length ?? 0);
});

typedef AnnouncementScope = ({String workspaceId, String? projectId});

final announcementsProvider = FutureProvider.autoDispose
    .family<List<Announcement>, AnnouncementScope>((ref, scope) async {
      final api = ref.watch(apiProvider);
      await ref.watch(authProvider.future);
      return api.announcements(scope.workspaceId, projectId: scope.projectId);
    });

final projectFilesProvider = FutureProvider.autoDispose
    .family<List<ProjectFile>, String>((ref, projectId) async {
      final api = ref.watch(apiProvider);
      await ref.watch(authProvider.future);
      return api.projectFiles(projectId);
    });

/// A link to a stored file, reused for most of its hour of validity.
final fileUrlProvider = FutureProvider.autoDispose.family<String, String>((
  ref,
  path,
) async {
  final link = ref.keepAlive();
  final timer = Timer(const Duration(minutes: 50), link.close);
  ref.onDispose(timer.cancel);
  try {
    return await ref.watch(apiProvider).fileUrl(path);
  } catch (_) {
    // Try again next time rather than keeping the failure.
    link.close();
    rethrow;
  }
});

// ---------------------------------------------------------------------------
// One open chat
// ---------------------------------------------------------------------------

typedef ChatKey = ({
  String workspaceId,
  String conversationId,
  String? projectId,
});

/// A message typed on this phone that the server has not confirmed yet.
class PendingMessage {
  const PendingMessage({
    required this.localId,
    this.body,
    this.file,
    this.replyTo,
    this.projectId,
    this.mentions = const [],
    this.failed = false,
  });

  final int localId;
  final String? body;
  final Upload? file;
  final ChatMessage? replyTo;
  final String? projectId;
  final List<String> mentions;
  final bool failed;

  PendingMessage asFailed() => PendingMessage(
    localId: localId,
    body: body,
    file: file,
    replyTo: replyTo,
    projectId: projectId,
    mentions: mentions,
    failed: true,
  );
}

class ChatState {
  const ChatState({
    this.messages = const [],
    this.reads = const [],
    this.pending = const [],
    this.hasMore = false,
    this.loadingOlder = false,
  });

  /// Newest first.
  final List<ChatMessage> messages;
  final List<ReadState> reads;
  final List<PendingMessage> pending;
  final bool hasMore;
  final bool loadingOlder;

  ChatState copyWith({
    List<ChatMessage>? messages,
    List<ReadState>? reads,
    List<PendingMessage>? pending,
    bool? hasMore,
    bool? loadingOlder,
  }) => ChatState(
    messages: messages ?? this.messages,
    reads: reads ?? this.reads,
    pending: pending ?? this.pending,
    hasMore: hasMore ?? this.hasMore,
    loadingOlder: loadingOlder ?? this.loadingOlder,
  );

  DateTime? readBy(String userId) {
    for (final r in reads) {
      if (r.userId == userId) return r.lastReadAt;
    }
    return null;
  }
}

class ChatController extends AsyncNotifier<ChatState> {
  ChatController(this.key);

  final ChatKey key;
  static const _page = 50;
  int _nextLocalId = 0;

  /// Refreshes can finish out of order; only the latest one started counts.
  int _refreshes = 0;
  int _applied = 0;

  @override
  Future<ChatState> build() async {
    final api = ref.watch(apiProvider);
    _refreshOnChatEvents(
      ref,
      key.workspaceId,
      () => refresh().catchError((Object _) {}),
      where: (e) =>
          e.conversationId == null || e.conversationId == key.conversationId,
    );
    final messages = await api.messages(
      key.conversationId,
      projectId: key.projectId,
      limit: _page,
    );
    final reads = await api.readStates(key.conversationId);
    if (!ref.mounted) return const ChatState();
    final loaded = ChatState(
      messages: messages,
      reads: reads,
      hasMore: messages.length == _page,
    );
    _markRead(loaded);
    return loaded;
  }

  /// Picks up new, changed and deleted messages and read marks.
  Future<void> refresh({int? dropPending}) async {
    final before = state.value;
    if (before == null) return;
    final run = ++_refreshes;
    final api = ref.read(apiProvider);
    final limit = min(max(before.messages.length, _page), 200);
    final latest = await api.messages(
      key.conversationId,
      projectId: key.projectId,
      limit: limit,
    );
    final reads = await api.readStates(key.conversationId);
    if (!ref.mounted) return;
    if (run < _applied) {
      // A later refresh already landed; this one is older news.
      if (dropPending != null) _drop(dropPending);
      return;
    }
    _applied = run;
    final now = state.value ?? before;
    final oldest = latest.isEmpty ? null : latest.last.createdAt;
    final newestBefore = now.messages.isEmpty
        ? null
        : now.messages.first.createdAt;
    // So many arrived that they do not reach what was on screen: start from
    // the new ones and page back, rather than leave a hole in between.
    final gap =
        latest.length == limit &&
        oldest != null &&
        newestBefore != null &&
        oldest.isAfter(newestBefore);
    final next = now.copyWith(
      messages: [
        ...latest,
        if (oldest != null && !gap)
          ...now.messages.where((m) => m.createdAt.isBefore(oldest)),
      ],
      hasMore: gap ? true : null,
      reads: reads,
      pending: [
        for (final p in now.pending)
          if (p.localId != dropPending) p,
      ],
    );
    state = AsyncData(next);
    _markRead(next);
  }

  Future<void> loadOlder() async {
    final now = state.value;
    if (now == null ||
        now.loadingOlder ||
        !now.hasMore ||
        now.messages.isEmpty) {
      return;
    }
    state = AsyncData(now.copyWith(loadingOlder: true));
    try {
      final older = await ref
          .read(apiProvider)
          .messages(
            key.conversationId,
            projectId: key.projectId,
            before: now.messages.last.createdAt,
            limit: _page,
          );
      if (!ref.mounted) return;
      final current = state.value ?? now;
      state = AsyncData(
        current.copyWith(
          messages: [...current.messages, ...older],
          hasMore: older.length == _page,
          loadingOlder: false,
        ),
      );
    } catch (_) {
      if (!ref.mounted) return;
      final current = state.value ?? now;
      state = AsyncData(current.copyWith(loadingOlder: false));
    }
  }

  /// Shows the message straight away and sends it. Throws if sending
  /// failed; the message then stays on screen, marked, to retry.
  Future<void> send({
    String? body,
    Upload? file,
    ChatMessage? replyTo,
    String? projectId,
    List<String> mentions = const [],
  }) => _send(
    PendingMessage(
      localId: _nextLocalId++,
      body: body,
      file: file,
      replyTo: replyTo,
      projectId: projectId,
      mentions: mentions,
    ),
  );

  Future<void> retry(PendingMessage message) {
    _drop(message.localId);
    return _send(
      PendingMessage(
        localId: _nextLocalId++,
        body: message.body,
        file: message.file,
        replyTo: message.replyTo,
        projectId: message.projectId,
        mentions: message.mentions,
      ),
    );
  }

  void discard(PendingMessage message) => _drop(message.localId);

  Future<void> _send(PendingMessage message) async {
    final now = state.value;
    if (now == null) throw StateError('chat_not_loaded');
    state = AsyncData(now.copyWith(pending: [...now.pending, message]));
    try {
      await ref
          .read(apiProvider)
          .sendMessage(
            key.workspaceId,
            key.conversationId,
            body: message.body,
            file: message.file,
            replyTo: message.replyTo?.id,
            projectId: message.projectId,
            mentions: message.mentions,
          );
    } catch (_) {
      final current = ref.mounted ? state.value : null;
      if (current != null) {
        state = AsyncData(
          current.copyWith(
            pending: [
              for (final p in current.pending)
                p.localId == message.localId ? p.asFailed() : p,
            ],
          ),
        );
      }
      rethrow;
    }
    if (!ref.mounted) return;
    try {
      await refresh(dropPending: message.localId);
    } catch (_) {
      // Sent; it shows up with the next change.
      if (ref.mounted) _drop(message.localId);
    }
  }

  void _drop(int localId) {
    final now = state.value;
    if (now == null) return;
    state = AsyncData(
      now.copyWith(
        pending: [
          for (final p in now.pending)
            if (p.localId != localId) p,
        ],
      ),
    );
  }

  Future<void> delete(ChatMessage message) async {
    final mine = message.senderId == ref.read(authProvider).value;
    await ref
        .read(apiProvider)
        .deleteMessage(message.id, filePath: mine ? message.file?.path : null);
    if (ref.mounted) await refresh();
  }

  /// Adds or takes back the signed-in user's reaction. It shows straight
  /// away; if the server refuses, the chat is reloaded and the error thrown.
  Future<void> react(ChatMessage message, String emoji) async {
    final me = ref.read(authProvider).value;
    final now = state.value;
    if (me == null || now == null) return;
    state = AsyncData(
      now.copyWith(
        messages: [
          for (final m in now.messages)
            m.id == message.id ? m.withReaction(emoji, me) : m,
        ],
      ),
    );
    try {
      await ref.read(apiProvider).toggleReaction(message.id, emoji);
    } finally {
      if (ref.mounted) await refresh().catchError((Object _) {});
    }
  }

  void _markRead(ChatState chat) {
    // Read marks cover everything up to a time, so a chat filtered by
    // project would mark messages that are not on screen.
    if (key.projectId != null) return;
    final me = ref.read(authProvider).value;
    ChatMessage? newest;
    for (final m in chat.messages) {
      if (m.senderId != me) {
        newest = m;
        break;
      }
    }
    if (newest == null || me == null) return;
    final mine = chat.readBy(me);
    if (mine != null && !newest.createdAt.isAfter(mine)) return;
    ref
        .read(apiProvider)
        .markRead(key.conversationId, newest.createdAt)
        .catchError((Object _) {});
  }
}

final chatProvider = AsyncNotifierProvider.autoDispose
    .family<ChatController, ChatState, ChatKey>(ChatController.new);

final announcementReadersProvider = FutureProvider.autoDispose
    .family<List<AnnouncementReader>, String>(
      (ref, id) => ref.watch(apiProvider).announcementReaders(id),
    );

final pickerProvider = Provider<Picker>((ref) => DevicePicker());

final voiceRecorderProvider = Provider<VoiceRecorder>(
  (ref) => DeviceVoiceRecorder(),
);

/// Projects a private chat's messages can be tagged with.
final sharedProjectsProvider = FutureProvider.autoDispose
    .family<List<String>, String>((ref, conversationId) async {
      final api = ref.watch(apiProvider);
      await ref.watch(authProvider.future);
      return api.sharedProjects(conversationId);
    });

final projectConversationProvider = FutureProvider.autoDispose
    .family<String?, String>((ref, projectId) async {
      final api = ref.watch(apiProvider);
      await ref.watch(authProvider.future);
      return api.projectConversation(projectId);
    });

/// Active projects the signed-in user shares with someone, for their card.
final projectsWithProvider = FutureProvider.autoDispose
    .family<List<String>, ({String workspaceId, String userId})>((
      ref,
      key,
    ) async {
      final api = ref.watch(apiProvider);
      await ref.watch(authProvider.future);
      return api.projectsWith(key.workspaceId, key.userId);
    });
