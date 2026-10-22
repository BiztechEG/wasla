import 'models.dart';

int _int(Object? v) => (v as num?)?.toInt() ?? 0;

/// How one workspace is doing, for those who run it: counts only.
class WorkspaceOverview {
  const WorkspaceOverview({
    required this.workspaceId,
    required this.workspaceName,
    required this.companyName,
    this.members = 0,
    this.projects = 0,
    this.open = 0,
    this.late = 0,
    this.review = 0,
    this.doneWeek = 0,
    this.doneWeekBefore = 0,
    this.messagesWeek = 0,
    this.activePeopleWeek = 0,
    this.attendance,
    this.projectList = const [],
  });

  final String workspaceId;
  final String workspaceName;
  final String companyName;
  final int members;
  final int projects;

  /// Tasks not done yet, those past their due time, and those in review.
  final int open;
  final int late;
  final int review;

  /// Tasks done in the last seven days, and in the seven before.
  final int doneWeek;
  final int doneWeekBefore;

  /// Messages in project chats this week, and how many people wrote.
  final int messagesWeek;
  final int activePeopleWeek;

  /// Today's attendance; null where it is off.
  final AttendanceOverview? attendance;
  final List<ProjectOverview> projectList;

  factory WorkspaceOverview.fromJson(Json json) => WorkspaceOverview(
    workspaceId: json['workspace_id'] as String,
    workspaceName: json['workspace_name'] as String? ?? '',
    companyName: json['company_name'] as String? ?? '',
    members: _int(json['members']),
    projects: _int(json['projects']),
    open: _int(json['open']),
    late: _int(json['late']),
    review: _int(json['review']),
    doneWeek: _int(json['done_week']),
    doneWeekBefore: _int(json['done_week_before']),
    messagesWeek: _int(json['messages_week']),
    activePeopleWeek: _int(json['active_people_week']),
    attendance: json['attendance'] is Map
        ? AttendanceOverview.fromJson(Json.from(json['attendance'] as Map))
        : null,
    projectList: [
      for (final p in json['project_list'] as List? ?? const [])
        ProjectOverview.fromJson(Json.from(p as Map)),
    ],
  );
}

class AttendanceOverview {
  const AttendanceOverview({
    this.dayOff = false,
    this.people = 0,
    this.present = 0,
    this.late = 0,
  });

  final bool dayOff;
  final int people;
  final int present;
  final int late;

  factory AttendanceOverview.fromJson(Json json) => AttendanceOverview(
    dayOff: json['day_off'] as bool? ?? false,
    people: _int(json['people']),
    present: _int(json['present']),
    late: _int(json['late']),
  );
}

class ProjectOverview {
  const ProjectOverview({
    required this.id,
    required this.name,
    required this.color,
    this.total = 0,
    this.open = 0,
    this.late = 0,
    this.done = 0,
  });

  final String id;
  final String name;
  final String color;
  final int total;
  final int open;
  final int late;
  final int done;

  double get fraction => total == 0 ? 0 : done / total;

  factory ProjectOverview.fromJson(Json json) => ProjectOverview(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    color: json['color'] as String? ?? '#0F6E6A',
    total: _int(json['total']),
    open: _int(json['open']),
    late: _int(json['late']),
    done: _int(json['done']),
  );
}
