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
  );
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

class ProjectFile {
  const ProjectFile({
    required this.file,
    required this.pinned,
    required this.uploadedBy,
    required this.uploaderName,
    required this.createdAt,
    this.conversationId,
    this.privateChat = false,
  });

  final ChatFile file;
  final bool pinned;
  final String uploadedBy;
  final String uploaderName;
  final DateTime createdAt;

  /// The chat it was sent in; null when added to the project directly.
  final String? conversationId;
  final bool privateChat;

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
  });

  final String id;
  final String? projectId;
  final String body;
  final bool pinned;
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
  });

  final String id;
  final String? projectId;
  final String? projectName;
  final String? projectColor;
  final String body;
  final String authorName;
  final DateTime createdAt;

  factory UnreadAnnouncement.fromJson(Json json) => UnreadAnnouncement(
    id: json['id'] as String,
    projectId: json['project_id'] as String?,
    projectName: json['project_name'] as String?,
    projectColor: json['project_color'] as String?,
    body: _text(json['body']),
    authorName: _text(json['author_name']),
    createdAt: _time(json['created_at']),
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
