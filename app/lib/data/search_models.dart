import 'chat_models.dart';
import 'models.dart';
import 'task_models.dart';

/// What a workspace search found besides messages and people.
class WorkspaceSearch {
  const WorkspaceSearch({
    this.files = const [],
    this.tasks = const [],
    this.announcements = const [],
  });

  final List<FileHit> files;
  final List<TaskHit> tasks;
  final List<AnnouncementHit> announcements;

  factory WorkspaceSearch.fromJson(Json json) => WorkspaceSearch(
    files: _list(json['files']).map(FileHit.fromJson).toList(),
    tasks: _list(json['tasks']).map(TaskHit.fromJson).toList(),
    announcements: _list(json['announcements'])
        .map(AnnouncementHit.fromJson)
        .toList(),
  );
}

List<Json> _list(Object? value) => value is List
    ? [for (final e in value) Map<String, dynamic>.from(e as Map)]
    : const [];

/// A project file or a task attachment.
class FileHit {
  const FileHit({
    required this.file,
    required this.createdAt,
    required this.projectId,
    required this.projectName,
    this.taskId,
  });

  final ChatFile file;
  final DateTime createdAt;
  final String projectId;
  final String projectName;

  /// Set when the file is attached to a task.
  final String? taskId;

  factory FileHit.fromJson(Json json) => FileHit(
    file: ChatFile(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      mime: json['mime'] as String? ?? '',
      size: (json['size_bytes'] as num?)?.toInt() ?? 0,
      path: json['storage_path'] as String? ?? '',
    ),
    createdAt: DateTime.parse(json['created_at'] as String),
    projectId: json['project_id'] as String,
    projectName: json['project_name'] as String? ?? '',
    taskId: json['task_id'] as String?,
  );
}

class TaskHit {
  const TaskHit({
    required this.id,
    required this.title,
    required this.status,
    required this.projectName,
    this.dueAt,
  });

  final String id;
  final String title;
  final TaskStatus status;
  final String projectName;
  final DateTime? dueAt;

  factory TaskHit.fromJson(Json json) => TaskHit(
    id: json['id'] as String,
    title: json['title'] as String? ?? '',
    status: TaskStatus.parse(json['status']),
    projectName: json['project_name'] as String? ?? '',
    dueAt: json['due_at'] == null
        ? null
        : DateTime.parse(json['due_at'] as String),
  );
}

class AnnouncementHit {
  const AnnouncementHit({
    required this.id,
    required this.body,
    required this.createdAt,
    required this.authorName,
    this.projectId,
    this.projectName,
  });

  final String id;
  final String body;
  final DateTime createdAt;
  final String authorName;

  /// Null for an announcement to the whole workspace.
  final String? projectId;
  final String? projectName;

  factory AnnouncementHit.fromJson(Json json) => AnnouncementHit(
    id: json['id'] as String,
    body: json['body'] as String? ?? '',
    createdAt: DateTime.parse(json['created_at'] as String),
    authorName: json['author_name'] as String? ?? '',
    projectId: json['project_id'] as String?,
    projectName: json['project_name'] as String?,
  );
}
