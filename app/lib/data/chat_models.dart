// Data classes for chats, files and announcements (phase 2).

import 'dart:typed_data';

import 'models.dart';

String _text(Object? value) => value as String? ?? '';

DateTime _time(Object? value) => DateTime.parse(value as String);

DateTime? _timeOrNull(Object? value) =>
    value == null ? null : DateTime.parse(value as String);

enum ConversationKind {
  project,
  direct;

  static ConversationKind parse(Object? value) =>
      value == 'project' ? ConversationKind.project : ConversationKind.direct;
}

/// A row in the chat list: a project's group chat or a private chat.
class Conversation {
  const Conversation({
    required this.id,
    required this.kind,
    this.projectId,
    this.projectName,
    this.projectColor,
    this.otherId,
    this.otherName,
    this.otherActive = true,
    this.lastAt,
    this.lastSenderId,
    this.lastSenderName,
    this.lastBody,
    this.lastFileName,
    this.lastDeleted = false,
    this.unread = 0,
    this.unreadMentions = 0,
    this.tagProjectIds = const [],
  });

  final String id;
  final ConversationKind kind;
  final String? projectId;
  final String? projectName;
  final String? projectColor;
  final String? otherId;
  final String? otherName;

  /// False once the other person has left the workspace.
  final bool otherActive;
  final DateTime? lastAt;
  final String? lastSenderId;
  final String? lastSenderName;
  final String? lastBody;
  final String? lastFileName;
  final bool lastDeleted;
  final int unread;

  /// Unread messages that mention the signed-in user.
  final int unreadMentions;

  /// Projects this chat's messages are tagged with.
  final List<String> tagProjectIds;

  bool get isProject => kind == ConversationKind.project;
  String get title => (isProject ? projectName : otherName) ?? '';

  factory Conversation.fromJson(Json json) {
    final kind = ConversationKind.parse(json['kind']);
    return Conversation(
      id: json['id'] as String,
      kind: kind,
      projectId: json['project_id'] as String?,
      projectName: json['project_name'] as String?,
      projectColor: json['project_color'] as String?,
      otherId: json['other_id'] as String?,
      otherName: json['other_name'] as String?,
      // Only a private chat has another person who can leave.
      otherActive:
          kind == ConversationKind.project ||
          (json['other_active'] as bool? ?? true),
      lastAt: _timeOrNull(json['last_at']),
      lastSenderId: json['last_sender_id'] as String?,
      lastSenderName: json['last_sender_name'] as String?,
      lastBody: json['last_body'] as String?,
      lastFileName: json['last_file_name'] as String?,
      lastDeleted: json['last_deleted'] as bool? ?? false,
      unread: json['unread'] as int? ?? 0,
      unreadMentions: json['unread_mentions'] as int? ?? 0,
      tagProjectIds: [
        for (final id in (json['tag_project_ids'] as List? ?? const []))
          if (id != null) id as String,
      ],
    );
  }
}

/// A file stored in the backend.
class ChatFile {
  const ChatFile({
    required this.id,
    required this.name,
    required this.mime,
    required this.size,
    required this.path,
  });

  final String id;
  final String name;
  final String mime;
  final int size;

  /// Where it lives in storage; turned into a short-lived link to open it.
  final String path;

  bool get isImage => mime.startsWith('image/');
  bool get isVideo => mime.startsWith('video/');
  bool get isAudio => mime.startsWith('audio/');
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.senderId,
    required this.senderName,
    required this.createdAt,
    this.body,
    this.projectId,
    this.deleted = false,
    this.replyTo,
    this.replySenderName,
    this.replyBody,
    this.replyFileName,
    this.file,
    this.mentions = const [],
    this.reactions = const {},
    this.fromFiles = false,
    this.replyCount = 0,
    this.repliers = const [],
    this.poll,
  });

  final String id;
  final String senderId;
  final String senderName;
  final DateTime createdAt;
  final String? body;

  /// The project it is about (always set in a project's chat).
  final String? projectId;
  final bool deleted;
  final String? replyTo;
  final String? replySenderName;
  final String? replyBody;
  final String? replyFileName;
  final ChatFile? file;

  /// The people the message mentions.
  final List<String> mentions;

  /// Each emoji people reacted with, and who, in the order they did.
  final Map<String, List<String>> reactions;

  /// Its file was added from the project's Files tab.
  final bool fromFiles;

  /// Replies under it, replies to replies included (only for a message
  /// that is not itself a reply).
  final int replyCount;

  /// Who wrote the latest replies, latest first (up to three).
  final List<String> repliers;

  /// Set when the message asks the chat a question; [body] is the question.
  final Poll? poll;

  /// A copy with [userId]'s [emoji] reaction added, or taken back.
  ChatMessage withReaction(String emoji, String userId) {
    final next = {for (final e in reactions.entries) e.key: List.of(e.value)};
    final users = next.putIfAbsent(emoji, () => []);
    if (!users.remove(userId)) users.add(userId);
    if (users.isEmpty) next.remove(emoji);
    return copyWith(reactions: next);
  }

  ChatMessage copyWith({
    Map<String, List<String>>? reactions,
    int? replyCount,
    List<String>? repliers,
    Poll? poll,
  }) => ChatMessage(
    id: id,
    senderId: senderId,
    senderName: senderName,
    createdAt: createdAt,
    body: body,
    projectId: projectId,
    deleted: deleted,
    replyTo: replyTo,
    replySenderName: replySenderName,
    replyBody: replyBody,
    replyFileName: replyFileName,
    file: file,
    mentions: mentions,
    reactions: reactions ?? this.reactions,
    fromFiles: fromFiles,
    replyCount: replyCount ?? this.replyCount,
    repliers: repliers ?? this.repliers,
    poll: poll ?? this.poll,
  );

  factory ChatMessage.fromJson(Json json) => ChatMessage(
    id: json['id'] as String,
    senderId: json['sender_id'] as String,
    senderName: _text(json['sender_name']),
    createdAt: _time(json['created_at']),
    body: json['body'] as String?,
    projectId: json['project_id'] as String?,
    deleted: json['deleted'] as bool? ?? false,
    replyTo: json['reply_to'] as String?,
    replySenderName: json['reply_sender_name'] as String?,
    replyBody: json['reply_body'] as String?,
    replyFileName: json['reply_file_name'] as String?,
    file: json['file_id'] == null
        ? null
        : ChatFile(
            id: json['file_id'] as String,
            name: _text(json['file_name']),
            mime: _text(json['file_mime']),
            size: json['file_size'] as int? ?? 0,
            path: _text(json['file_path']),
          ),
    mentions: [
      for (final id in (json['mentions'] as List? ?? const []))
        if (id != null) id as String,
    ],
    reactions: {
      for (final e in ((json['reactions'] as Map?) ?? const {}).entries)
        if ((e.value as List).isNotEmpty)
          e.key as String: [for (final id in e.value as List) id as String],
    },
    fromFiles: json['file_from_files'] as bool? ?? false,
    replyCount: json['reply_count'] as int? ?? 0,
    repliers: [
      for (final id in (json['repliers'] as List? ?? const []))
        if (id != null) id as String,
    ],
    poll: json['poll'] is Map
        ? Poll.fromJson(Json.from(json['poll'] as Map))
        : null,
  );
}

/// A question to the chat: its options, and who picked each.
class Poll {
  const Poll({
    required this.options,
    this.multiple = false,
    this.closed = false,
    this.votes = const {},
  });

  final List<String> options;

  /// More than one option may be picked.
  final bool multiple;

  /// No longer taking votes.
  final bool closed;

  /// Who picked each option, by its place.
  final Map<int, List<String>> votes;

  List<String> votersOf(int option) => votes[option] ?? const [];

  /// Everyone who answered.
  Set<String> get voters => {for (final v in votes.values) ...v};

  /// The options [userId] picked.
  Set<int> picksOf(String? userId) => {
    for (final e in votes.entries)
      if (e.value.contains(userId)) e.key,
  };

  /// A copy with [userId]'s answer replaced by [picks].
  Poll withVote(String userId, Set<int> picks) => Poll(
    options: options,
    multiple: multiple,
    closed: closed,
    votes: {
      for (var i = 0; i < options.length; i++)
        if ([
              ...votersOf(i).where((u) => u != userId),
              if (picks.contains(i)) userId,
            ]
            case final users when users.isNotEmpty)
          i: users,
    },
  );

  Poll closedCopy() =>
      Poll(options: options, multiple: multiple, closed: true, votes: votes);

  factory Poll.fromJson(Json json) => Poll(
    options: [for (final o in json['options'] as List? ?? const []) '$o'],
    multiple: json['multiple'] as bool? ?? false,
    closed: json['closed'] as bool? ?? false,
    votes: {
      for (final e in ((json['votes'] as Map?) ?? const {}).entries)
        ?int.tryParse('${e.key}'): [
          for (final id in e.value as List) id as String,
        ],
    },
  );
}

/// A chat's pinned message, and whether one may change it.
class PinnedMessage {
  const PinnedMessage({
    required this.messageId,
    required this.senderName,
    this.body,
    this.fileName,
  });

  final String messageId;
  final String senderName;
  final String? body;
  final String? fileName;
}

/// What is pinned in a chat ([message] null: nothing), and whether one may
/// pin or take it down.
class ChatPin {
  const ChatPin({this.message, this.canPin = false});

  final PinnedMessage? message;
  final bool canPin;
}

/// How far someone has read a chat.
class ReadState {
  const ReadState({required this.userId, required this.lastReadAt});

  final String userId;
  final DateTime lastReadAt;

  factory ReadState.fromJson(Json json) => ReadState(
    userId: json['user_id'] as String,
    lastReadAt: _time(json['last_read_at']),
  );
}

/// A file picked on the phone, ready to send.
class Upload {
  const Upload({required this.bytes, required this.name, required this.mime});

  final Uint8List bytes;
  final String name;
  final String mime;
}

/// Where a project's file came from.
enum FileSource {
  /// The project's chat.
  project,

  /// A private chat tagged with the project.
  direct,

  /// The project's Files tab.
  files,

  /// A task's attachments.
  task;

  static FileSource parse(Object? value) => switch (value) {
    'project' => FileSource.project,
    'direct' => FileSource.direct,
    'task' => FileSource.task,
    _ => FileSource.files,
  };
}

class ProjectFile {
  const ProjectFile({
    required this.file,
    required this.pinned,
    required this.uploadedBy,
    required this.uploaderName,
    required this.createdAt,
    this.conversationId,
    this.privateChat = false,
    this.source = FileSource.files,
    this.otherId,
    this.otherName,
    this.messageId,
  });

  final ChatFile file;
  final bool pinned;
  final String uploadedBy;
  final String uploaderName;
  final DateTime createdAt;

  /// The chat it was sent in; null when added to the project directly.
  final String? conversationId;
  final bool privateChat;
  final FileSource source;

  /// For a private chat's file: the other person in it.
  final String? otherId;
  final String? otherName;

  /// The chat message it was sent in, to open the chat at it.
  final String? messageId;

  /// Removed from the Files tab (others go with their message).
  bool get removable => source == FileSource.files || source == FileSource.task;

  factory ProjectFile.fromJson(Json json) => ProjectFile(
    file: ChatFile(
      id: json['id'] as String,
      name: _text(json['name']),
      mime: _text(json['mime']),
      size: json['size_bytes'] as int? ?? 0,
      path: _text(json['storage_path']),
    ),
    pinned: json['pinned'] as bool? ?? false,
    uploadedBy: json['uploaded_by'] as String,
    uploaderName: _text(json['uploader_name']),
    createdAt: _time(json['created_at']),
    conversationId: json['conversation_id'] as String?,
    privateChat: json['private_chat'] as bool? ?? false,
    source: FileSource.parse(json['source']),
    otherId: json['other_id'] as String?,
    otherName: json['other_name'] as String?,
    messageId: json['message_id'] as String?,
  );
}

class Announcement {
  const Announcement({
    required this.id,
    required this.body,
    required this.authorId,
    required this.authorName,
    required this.createdAt,
    this.projectId,
    this.pinned = false,
    this.readByMe = false,
    this.readCount = 0,
    this.audience = 0,
    this.needsAck = false,
    this.ackedByMe = false,
    this.ackCount = 0,
    this.broadcastId,
  });

  final String id;
  final String? projectId;
  final String body;
  final bool pinned;

  /// Set when it went to several workspaces at once.
  final String? broadcastId;

  /// Its readers are asked to confirm they have read it.
  final bool needsAck;
  final bool ackedByMe;
  final int ackCount;
  final String authorId;
  final String authorName;
  final DateTime createdAt;
  final bool readByMe;
  final int readCount;
  final int audience;

  factory Announcement.fromJson(Json json) => Announcement(
    id: json['id'] as String,
    projectId: json['project_id'] as String?,
    body: _text(json['body']),
    pinned: json['pinned'] as bool? ?? false,
    authorId: json['author_id'] as String,
    authorName: _text(json['author_name']),
    createdAt: _time(json['created_at']),
    readByMe: json['read_by_me'] as bool? ?? false,
    readCount: json['read_count'] as int? ?? 0,
    audience: json['audience'] as int? ?? 0,
    needsAck: json['needs_ack'] as bool? ?? false,
    ackedByMe: json['acked_by_me'] as bool? ?? false,
    ackCount: json['ack_count'] as int? ?? 0,
    broadcastId: json['broadcast_id'] as String?,
  );
}

/// How an announcement sent to several workspaces is doing in one of them.
class BroadcastReach {
  const BroadcastReach({
    required this.workspaceId,
    required this.workspaceName,
    this.audience = 0,
    this.readCount = 0,
    this.ackCount = 0,
  });

  final String workspaceId;
  final String workspaceName;
  final int audience;
  final int readCount;
  final int ackCount;

  factory BroadcastReach.fromJson(Json json) => BroadcastReach(
    workspaceId: json['workspace_id'] as String,
    workspaceName: _text(json['workspace_name']),
    audience: json['audience'] as int? ?? 0,
    readCount: json['read_count'] as int? ?? 0,
    ackCount: json['ack_count'] as int? ?? 0,
  );
}

/// Someone an announcement is for, and whether they read and confirmed it.
class AnnouncementReader {
  const AnnouncementReader({
    required this.userId,
    required this.name,
    this.readAt,
    this.acknowledgedAt,
  });

  final String userId;
  final String name;
  final DateTime? readAt;
  final DateTime? acknowledgedAt;

  factory AnnouncementReader.fromJson(Json json) => AnnouncementReader(
    userId: json['user_id'] as String,
    name: _text(json['full_name']),
    readAt: _timeOrNull(json['read_at']),
    acknowledgedAt: _timeOrNull(json['acknowledged_at']),
  );
}

/// An announcement the signed-in user has not opened yet.
class UnreadAnnouncement {
  const UnreadAnnouncement({
    required this.id,
    required this.body,
    required this.authorName,
    required this.createdAt,
    this.projectId,
    this.projectName,
    this.projectColor,
    this.needsAck = false,
  });

  final String id;
  final String? projectId;
  final String? projectName;
  final String? projectColor;
  final String body;
  final String authorName;
  final DateTime createdAt;

  /// Waiting for the signed-in user to confirm they have read it.
  final bool needsAck;

  factory UnreadAnnouncement.fromJson(Json json) => UnreadAnnouncement(
    id: json['id'] as String,
    projectId: json['project_id'] as String?,
    projectName: json['project_name'] as String?,
    projectColor: json['project_color'] as String?,
    body: _text(json['body']),
    authorName: _text(json['author_name']),
    createdAt: _time(json['created_at']),
    needsAck: json['needs_ack'] as bool? ?? false,
  );
}

/// A message found by search.
class MessageHit {
  const MessageHit({
    required this.messageId,
    required this.chat,
    required this.createdAt,
    required this.senderName,
    this.body,
    this.fileName,
  });

  final String messageId;

  /// The chat it is in, enough to open it even when it is not in the list.
  final Conversation chat;
  final DateTime createdAt;
  final String senderName;
  final String? body;
  final String? fileName;

  String get conversationId => chat.id;

  factory MessageHit.fromJson(Json json) => MessageHit(
    messageId: json['message_id'] as String,
    chat: Conversation(
      id: json['conversation_id'] as String,
      kind: ConversationKind.parse(json['kind']),
      projectId: json['project_id'] as String?,
      projectName: json['project_name'] as String?,
      projectColor: json['project_color'] as String?,
      otherId: json['other_id'] as String?,
      otherName: json['other_name'] as String?,
    ),
    createdAt: _time(json['created_at']),
    senderName: _text(json['sender_name']),
    body: json['body'] as String?,
    fileName: json['file_name'] as String?,
  );
}

/// Something changed in a chat: a message arrived, changed, or was read.
class ChatEvent {
  const ChatEvent({this.conversationId, this.readerId});

  /// Anything may have changed, for example after being offline.
  const ChatEvent.everything() : conversationId = null, readerId = null;

  /// Null when anything may have changed.
  final String? conversationId;

  /// For read receipts: the person who read.
  final String? readerId;
}

/// The content type for a file name, for the few kinds people share most.
String mimeFor(String name) {
  final dot = name.lastIndexOf('.');
  final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  return switch (ext) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'heic' => 'image/heic',
    'pdf' => 'application/pdf',
    'doc' => 'application/msword',
    'docx' =>
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls' => 'application/vnd.ms-excel',
    'xlsx' =>
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'ppt' => 'application/vnd.ms-powerpoint',
    'pptx' => 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'txt' => 'text/plain',
    'csv' => 'text/csv',
    'zip' => 'application/zip',
    'mp4' => 'video/mp4',
    'mov' => 'video/quicktime',
    'webm' => 'video/webm',
    '3gp' => 'video/3gpp',
    'mkv' => 'video/x-matroska',
    'mp3' => 'audio/mpeg',
    'm4a' => 'audio/mp4',
    'aac' => 'audio/aac',
    'wav' => 'audio/wav',
    'ogg' || 'opus' => 'audio/ogg',
    _ => 'application/octet-stream',
  };
}
