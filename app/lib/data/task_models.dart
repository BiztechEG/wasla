// Data classes for tasks, their updates and notifications (phase 3).

import 'chat_models.dart';
import 'models.dart';

String _text(Object? value) => value as String? ?? '';

DateTime _time(Object? value) => DateTime.parse(value as String);

DateTime? _timeOrNull(Object? value) =>
    value == null ? null : DateTime.parse(value as String);

enum TaskStatus {
  todo('new'),
  inProgress('in_progress'),
  onHold('on_hold'),
  review('review'),
  done('done');

  const TaskStatus(this.wire);

  /// The name the database uses.
  final String wire;

  bool get isOpen => this != done;

  static TaskStatus parse(Object? value) =>
      values.firstWhere((s) => s.wire == value, orElse: () => todo);
}

enum TaskPriority {
  normal,
  high,
  urgent;

  static TaskPriority parse(Object? value) =>
      values.firstWhere((p) => p.name == value, orElse: () => normal);
}

enum TaskVisibility {
  private,
  public;

  static TaskVisibility parse(Object? value) =>
      value == 'public' ? public : private;
}

class TaskPerson {
  const TaskPerson({required this.id, required this.name});

  final String id;
  final String name;

  factory TaskPerson.fromJson(Json json) =>
      TaskPerson(id: json['id'] as String, name: _text(json['name']));
}

/// A task as the lists show it.
class TaskItem {
  const TaskItem({
    required this.id,
    required this.workspaceId,
    required this.workspaceName,
    required this.projectId,
    required this.projectName,
    required this.projectColor,
    required this.title,
    required this.status,
    required this.createdBy,
    required this.creatorName,
    required this.createdAt,
    required this.updatedAt,
    this.priority = TaskPriority.normal,
    this.visibility = TaskVisibility.private,
    this.dueAt,
    this.assignees = const [],
    this.doneAt,
  });

  final String id;
  final String workspaceId;
  final String workspaceName;
  final String projectId;
  final String projectName;
  final String projectColor;
  final String title;
  final TaskStatus status;
  final TaskPriority priority;
  final TaskVisibility visibility;
  final DateTime? dueAt;
  final String createdBy;
  final String creatorName;
  final List<TaskPerson> assignees;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? doneAt;

  bool isAssignedTo(String? userId) => assignees.any((a) => a.id == userId);

  bool isLate(DateTime now) =>
      status.isOpen && dueAt != null && dueAt!.isBefore(now);

  factory TaskItem.fromJson(Json json) => TaskItem(
    id: json['id'] as String,
    workspaceId: json['workspace_id'] as String,
    workspaceName: _text(json['workspace_name']),
    projectId: json['project_id'] as String,
    projectName: _text(json['project_name']),
    projectColor: json['project_color'] as String? ?? '#0F6E6A',
    title: _text(json['title']),
    status: TaskStatus.parse(json['status']),
    priority: TaskPriority.parse(json['priority']),
    visibility: TaskVisibility.parse(json['visibility']),
    dueAt: _timeOrNull(json['due_at']),
    createdBy: json['created_by'] as String,
    creatorName: _text(json['creator_name']),
    assignees: [
      for (final a in (json['assignees'] as List? ?? const []))
        TaskPerson.fromJson(Json.from(a as Map)),
    ],
    createdAt: _time(json['created_at']),
    updatedAt: _time(json['updated_at']),
    doneAt: _timeOrNull(json['done_at']),
  );

  TaskItem copyWith({
    TaskStatus? status,
    List<TaskPerson>? assignees,
    DateTime? updatedAt,
  }) => TaskItem(
    id: id,
    workspaceId: workspaceId,
    workspaceName: workspaceName,
    projectId: projectId,
    projectName: projectName,
    projectColor: projectColor,
    title: title,
    status: status ?? this.status,
    priority: priority,
    visibility: visibility,
    dueAt: dueAt,
    createdBy: createdBy,
    creatorName: creatorName,
    assignees: assignees ?? this.assignees,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    doneAt: doneAt,
  );
}

enum TaskEvent {
  created,
  status,
  due,
  priority,
  title,
  visibility,
  assignees,
  attachment,
  comment;

  static TaskEvent? parse(Object? value) {
    for (final e in values) {
      if (e.name == value) return e;
    }
    return null;
  }
}

/// One line of a task's history: a change, an attachment or a comment.
class TaskActivity {
  const TaskActivity({
    required this.id,
    required this.kind,
    required this.actorId,
    required this.actorName,
    required this.createdAt,
    this.oldValue,
    this.newValue,
    this.body,
  });

  final String id;
  final TaskEvent kind;
  final String actorId;
  final String actorName;
  final String? oldValue;
  final String? newValue;
  final String? body;
  final DateTime createdAt;

  static TaskActivity? fromJson(Json json) {
    final kind = TaskEvent.parse(json['kind']);
    if (kind == null) return null;
    return TaskActivity(
      id: json['id'] as String,
      kind: kind,
      actorId: json['actor_id'] as String,
      actorName: _text(json['actor_name']),
      oldValue: json['old_value'] as String?,
      newValue: json['new_value'] as String?,
      body: json['body'] as String?,
      createdAt: _time(json['created_at']),
    );
  }
}

class TaskReminder {
  const TaskReminder({required this.id, required this.remindAt});

  final String id;
  final DateTime remindAt;

  factory TaskReminder.fromJson(Json json) => TaskReminder(
    id: json['id'] as String,
    remindAt: _time(json['remind_at']),
  );
}

/// One task with everything its screen shows, and what the signed-in user
/// may do with it.
class TaskDetail {
  const TaskDetail({
    required this.task,
    this.description,
    this.holdReason,
    this.remindBefore = const [1440, 60],
    this.projectOpen = true,
    this.isParty = false,
    this.canEdit = false,
    this.canClose = false,
    this.canAssign = false,
    this.isAssignee = false,
    this.sourceConversationId,
    this.files = const [],
    this.activity = const [],
    this.reminders = const [],
  });

  final TaskItem task;
  final String? description;
  final String? holdReason;

  /// Minutes before the due time the assignees are reminded.
  final List<int> remindBefore;
  final bool projectOpen;

  /// Creator, assignee, lead or admin: sees and writes comments.
  final bool isParty;

  /// Creator, lead or admin: changes what the task is.
  final bool canEdit;

  /// Creator, lead or admin: marks it done or reopens it.
  final bool canClose;

  /// Lead or admin: gives it to anyone in the project. Anyone else who edits
  /// it only adds or removes themselves.
  final bool canAssign;
  final bool isAssignee;

  /// The chat of the message it was made from, when one can read it.
  final String? sourceConversationId;
  final List<ProjectFile> files;
  final List<TaskActivity> activity;
  final List<TaskReminder> reminders;

  /// Whether the signed-in user can move the task to [next].
  bool canMoveTo(TaskStatus next) {
    if (!projectOpen || next == task.status) return false;
    if (canClose) return true;
    return isAssignee && next != TaskStatus.done && task.status.isOpen;
  }

  factory TaskDetail.fromJson(Json json) => TaskDetail(
    task: TaskItem.fromJson(Json.from(json['task'] as Map)),
    description: json['description'] as String?,
    holdReason: json['hold_reason'] as String?,
    remindBefore: [
      for (final m in (json['remind_before'] as List? ?? const []))
        (m as num).toInt(),
    ],
    projectOpen: json['project_open'] as bool? ?? true,
    isParty: json['is_party'] as bool? ?? false,
    canEdit: json['can_edit'] as bool? ?? false,
    canClose: json['can_close'] as bool? ?? false,
    canAssign: json['can_assign'] as bool? ?? false,
    isAssignee: json['is_assignee'] as bool? ?? false,
    sourceConversationId: json['source_conversation_id'] as String?,
    files: [
      for (final f in (json['files'] as List? ?? const []))
        ProjectFile.fromJson(Json.from(f as Map)),
    ],
    activity: [
      for (final a in (json['activity'] as List? ?? const []))
        ?TaskActivity.fromJson(Json.from(a as Map)),
    ],
    reminders: [
      for (final r in (json['reminders'] as List? ?? const []))
        TaskReminder.fromJson(Json.from(r as Map)),
    ],
  );
}

/// What a new or changed task holds.
class TaskDraft {
  const TaskDraft({
    required this.workspaceId,
    required this.projectId,
    required this.title,
    this.description,
    this.assigneeIds = const [],
    this.dueAt,
    this.priority = TaskPriority.normal,
    this.visibility = TaskVisibility.private,
    this.remindBefore = const [1440, 60],
    this.sourceMessageId,
  });

  final String workspaceId;
  final String projectId;
  final String title;
  final String? description;
  final List<String> assigneeIds;
  final DateTime? dueAt;
  final TaskPriority priority;
  final TaskVisibility visibility;
  final List<int> remindBefore;
  final String? sourceMessageId;
}

enum NotificationKind {
  assigned('assigned'),
  status('status'),
  comment('comment'),
  dueChanged('due_changed'),
  nudge('nudge'),
  dueSoon('due_soon'),
  overdue('overdue'),
  reminder('reminder'),
  unassigned('unassigned'),
  deleted('deleted'),
  // Subscriptions: detail is the plan's name, or the invoice's number.
  planRequest('plan_request'),
  invoice('invoice'),
  planActive('plan_active'),
  planEnding('plan_ending'),
  planExpired('plan_expired');

  const NotificationKind(this.wire);

  final String wire;

  bool get isBilling => index >= planRequest.index;

  static NotificationKind? parse(Object? value) {
    for (final k in values) {
      if (k.wire == value) return k;
    }
    return null;
  }
}

class AppNotification {
  const AppNotification({
    required this.id,
    required this.kind,
    required this.workspaceId,
    required this.workspaceName,
    required this.createdAt,
    this.taskId,
    this.taskTitle,
    this.projectName,
    this.projectColor,
    this.actorName,
    this.detail,
    this.readAt,
  });

  final String id;
  final NotificationKind kind;
  final String? taskId;
  final String? taskTitle;
  final String? projectName;
  final String? projectColor;
  final String workspaceId;
  final String workspaceName;

  /// Who caused it; null for reminders.
  final String? actorName;

  /// For a status change: the new status. For a task one was taken off or
  /// that was deleted: its title then.
  final String? detail;
  final DateTime createdAt;
  final DateTime? readAt;

  bool get unread => readAt == null;

  static AppNotification? fromJson(Json json) {
    final kind = NotificationKind.parse(json['kind']);
    if (kind == null) return null;
    return AppNotification(
      id: json['id'] as String,
      kind: kind,
      taskId: json['task_id'] as String?,
      taskTitle: json['task_title'] as String?,
      projectName: json['project_name'] as String?,
      projectColor: json['project_color'] as String?,
      workspaceId: json['workspace_id'] as String,
      workspaceName: _text(json['workspace_name']),
      actorName: json['actor_name'] as String?,
      detail: json['detail'] as String?,
      createdAt: _time(json['created_at']),
      readAt: _timeOrNull(json['read_at']),
    );
  }
}

/// Where a task falls in a list sorted by when it is due.
enum DueGroup { late, today, week, later, noDate, done }

DueGroup dueGroup(TaskItem task, DateTime now) {
  if (!task.status.isOpen) return DueGroup.done;
  final due = task.dueAt?.toLocal();
  if (due == null) return DueGroup.noDate;
  if (due.isBefore(now)) return DueGroup.late;
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(due.year, due.month, due.day);
  final days = day.difference(today).inDays;
  if (days == 0) return DueGroup.today;
  if (days < 7) return DueGroup.week;
  return DueGroup.later;
}

/// Tasks in the order of [DueGroup], each group sorted by due time (done
/// ones newest first), empty groups left out.
Map<DueGroup, List<TaskItem>> groupByDue(List<TaskItem> tasks, DateTime now) {
  final groups = {for (final g in DueGroup.values) g: <TaskItem>[]};
  for (final t in tasks) {
    groups[dueGroup(t, now)]!.add(t);
  }
  int byDue(TaskItem a, TaskItem b) => a.dueAt!.compareTo(b.dueAt!);
  for (final g in [
    DueGroup.late,
    DueGroup.today,
    DueGroup.week,
    DueGroup.later,
  ]) {
    groups[g]!.sort(byDue);
  }
  groups[DueGroup.noDate]!.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  groups[DueGroup.done]!.sort(
    (a, b) => (b.doneAt ?? b.updatedAt).compareTo(a.doneAt ?? a.updatedAt),
  );
  groups.removeWhere((_, list) => list.isEmpty);
  return groups;
}
