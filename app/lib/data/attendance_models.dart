import 'package:flutter/material.dart' show TimeOfDay;

import 'models.dart';

DateTime? _time(Object? value) =>
    value == null ? null : DateTime.parse(value as String);

DateTime _day(Object? value) {
  final d = DateTime.parse(value as String);
  return DateTime(d.year, d.month, d.day);
}

/// "09:30:00" from the server.
TimeOfDay parseClock(Object? value) {
  final parts = (value as String).split(':');
  return TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
}

/// "09:30" for the server.
String clockParam(TimeOfDay t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// Why someone checks in away from their branch.
enum OutsideReason {
  client,
  field,
  home,
  other;

  static OutsideReason? parse(Object? value) {
    for (final r in values) {
      if (r.name == value) return r;
    }
    return null;
  }
}

/// Whether a manager has looked at a check-in from outside.
enum AttendanceReview {
  none,
  pending,
  accepted,
  rejected;

  static AttendanceReview parse(Object? value) => values.firstWhere(
    (r) => r.name == value,
    orElse: () => AttendanceReview.none,
  );
}

/// A branch: a point and a radius, or a field branch with no fixed place.
class AttendanceSite {
  const AttendanceSite({
    required this.id,
    required this.name,
    this.lat,
    this.lng,
    this.radiusM = 150,
    this.people = 0,
  });

  final String id;
  final String name;
  final double? lat;
  final double? lng;
  final int radiusM;
  final int people;

  bool get isField => lat == null;

  factory AttendanceSite.fromJson(Json json) => AttendanceSite(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    lat: (json['lat'] as num?)?.toDouble(),
    lng: (json['lng'] as num?)?.toDouble(),
    radiusM: (json['radius_m'] as num?)?.toInt() ?? 150,
    people: (json['people'] as num?)?.toInt() ?? 0,
  );
}

class AttendanceShift {
  const AttendanceShift({
    required this.id,
    required this.name,
    required this.start,
    required this.end,
    this.graceMinutes = 15,
    this.people = 0,
  });

  final String id;
  final String name;
  final TimeOfDay start;
  final TimeOfDay end;
  final int graceMinutes;
  final int people;

  factory AttendanceShift.fromJson(Json json) => AttendanceShift(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    start: parseClock(json['start_time']),
    end: parseClock(json['end_time']),
    graceMinutes: (json['grace_minutes'] as num?)?.toInt() ?? 15,
    people: (json['people'] as num?)?.toInt() ?? 0,
  );
}

/// One person's day: when they came and left, and from where.
class AttendanceRecord {
  const AttendanceRecord({
    required this.id,
    required this.day,
    required this.inAt,
    this.outAt,
    this.lateMinutes = 0,
    this.inSite,
    this.inDistanceM,
    this.outSite,
    this.outside = false,
    this.reason,
    this.reasonNote,
    this.review = AttendanceReview.none,
    this.inPhotoPath,
    this.inByName,
    this.outByName,
    this.personId,
  });

  final String id;
  final DateTime day;
  final DateTime inAt;
  final DateTime? outAt;
  final int lateMinutes;
  final String? inSite;
  final int? inDistanceM;
  final String? outSite;
  final bool outside;
  final OutsideReason? reason;
  final String? reasonNote;
  final AttendanceReview review;
  final String? inPhotoPath;
  final String? inByName;
  final String? outByName;
  final String? personId;

  bool get open => outAt == null;

  /// Time at work, up to now while still checked in.
  Duration worked([DateTime? now]) =>
      (outAt ?? now ?? DateTime.now()).difference(inAt);

  factory AttendanceRecord.fromJson(Json json) => AttendanceRecord(
    id: json['id'] as String,
    day: _day(json['day']),
    inAt: _time(json['in_at'])!,
    outAt: _time(json['out_at']),
    lateMinutes: (json['late_minutes'] as num?)?.toInt() ?? 0,
    inSite: json['in_site'] as String?,
    inDistanceM: (json['in_distance_m'] as num?)?.toInt(),
    outSite: json['out_site'] as String?,
    outside: json['outside'] as bool? ?? false,
    reason: OutsideReason.parse(json['reason_kind']),
    reasonNote: json['reason_note'] as String?,
    review: AttendanceReview.parse(json['review']),
    inPhotoPath: json['in_photo_path'] as String?,
    inByName: json['in_by_name'] as String?,
    outByName: json['out_by_name'] as String?,
    personId: json['person_id'] as String?,
  );
}

/// The shift's hours today.
class ShiftToday {
  const ShiftToday({
    required this.name,
    required this.startAt,
    required this.endAt,
    required this.grace,
  });

  final String name;
  final DateTime startAt;
  final DateTime endAt;
  final int grace;

  factory ShiftToday.fromJson(Json json) => ShiftToday(
    name: json['name'] as String? ?? '',
    startAt: _time(json['start_at'])!,
    endAt: _time(json['end_at'])!,
    grace: (json['grace'] as num?)?.toInt() ?? 0,
  );
}

/// Everything the attendance screen shows for the signed-in user.
class AttendanceToday {
  const AttendanceToday({
    required this.enabled,
    required this.isAdmin,
    this.isManager = false,
    this.today,
    this.weekendDays = const {5, 6},
    this.requireSelfie = false,
    this.allowOutside = true,
    this.shift,
    this.site,
    this.sites = const [],
    this.record,
    this.recent = const [],
    this.monthPresent = 0,
    this.monthLate = 0,
    this.monthLateMinutes = 0,
  });

  final bool enabled;
  final bool isAdmin;

  /// Owners, admins and project leads see their team's attendance.
  final bool isManager;
  final DateTime? today;

  /// 0 = Sunday ... 6 = Saturday.
  final Set<int> weekendDays;
  final bool requireSelfie;
  final bool allowOutside;
  final ShiftToday? shift;

  /// The person's own branch, when they have one.
  final AttendanceSite? site;
  final List<AttendanceSite> sites;

  /// Today's record, or a check-in still open from last night.
  final AttendanceRecord? record;

  /// The last seven days, newest first.
  final List<AttendanceRecord> recent;
  final int monthPresent;
  final int monthLate;
  final int monthLateMinutes;

  bool get checkedIn => record != null && record!.open;
  bool get done => record != null && !record!.open;

  factory AttendanceToday.fromJson(Json json) {
    final month = json['month'] is Map
        ? Json.from(json['month'] as Map)
        : const <String, dynamic>{};
    List<Json> list(Object? v) =>
        v is List ? v.map((e) => Json.from(e as Map)).toList() : const [];
    return AttendanceToday(
      enabled: json['enabled'] as bool? ?? false,
      isAdmin: json['is_admin'] as bool? ?? false,
      isManager: json['is_manager'] as bool? ?? false,
      today: json['today'] == null ? null : _day(json['today']),
      weekendDays: {
        for (final d in (json['weekend_days'] as List? ?? const [5, 6]))
          (d as num).toInt(),
      },
      requireSelfie: json['require_selfie'] as bool? ?? false,
      allowOutside: json['allow_outside'] as bool? ?? true,
      shift: json['shift'] is Map
          ? ShiftToday.fromJson(Json.from(json['shift'] as Map))
          : null,
      site: json['site'] is Map
          ? AttendanceSite.fromJson(Json.from(json['site'] as Map))
          : null,
      sites: list(json['sites']).map(AttendanceSite.fromJson).toList(),
      record: json['record'] is Map
          ? AttendanceRecord.fromJson(Json.from(json['record'] as Map))
          : null,
      recent: list(json['recent']).map(AttendanceRecord.fromJson).toList(),
      monthPresent: (month['present'] as num?)?.toInt() ?? 0,
      monthLate: (month['late'] as num?)?.toInt() ?? 0,
      monthLateMinutes: (month['late_minutes'] as num?)?.toInt() ?? 0,
    );
  }
}

/// The admin's setup: switches, shifts and branches.
class AttendanceSetup {
  const AttendanceSetup({
    required this.enabled,
    this.weekendDays = const {5, 6},
    this.requireSelfie = false,
    this.allowOutside = true,
    this.reminders = true,
    this.defaultShiftId,
    this.ramadanFrom,
    this.ramadanTo,
    this.ramadanStart,
    this.ramadanEnd,
    this.shifts = const [],
    this.sites = const [],
  });

  /// False also before attendance was ever turned on.
  final bool enabled;
  final Set<int> weekendDays;
  final bool requireSelfie;
  final bool allowOutside;
  final bool reminders;
  final String? defaultShiftId;
  final DateTime? ramadanFrom;
  final DateTime? ramadanTo;
  final TimeOfDay? ramadanStart;
  final TimeOfDay? ramadanEnd;
  final List<AttendanceShift> shifts;
  final List<AttendanceSite> sites;

  bool get ramadan => ramadanFrom != null;

  /// Whether attendance was ever set up (it has a first shift then).
  bool get started => shifts.isNotEmpty || sites.isNotEmpty || enabled;

  AttendanceSetup copyWith({
    bool? enabled,
    Set<int>? weekendDays,
    bool? requireSelfie,
    bool? allowOutside,
    bool? reminders,
    String? defaultShiftId,
    (DateTime, DateTime, TimeOfDay, TimeOfDay)? ramadan,
    bool clearRamadan = false,
  }) => AttendanceSetup(
    enabled: enabled ?? this.enabled,
    weekendDays: weekendDays ?? this.weekendDays,
    requireSelfie: requireSelfie ?? this.requireSelfie,
    allowOutside: allowOutside ?? this.allowOutside,
    reminders: reminders ?? this.reminders,
    defaultShiftId: defaultShiftId ?? this.defaultShiftId,
    ramadanFrom: clearRamadan ? null : ramadan?.$1 ?? ramadanFrom,
    ramadanTo: clearRamadan ? null : ramadan?.$2 ?? ramadanTo,
    ramadanStart: clearRamadan ? null : ramadan?.$3 ?? ramadanStart,
    ramadanEnd: clearRamadan ? null : ramadan?.$4 ?? ramadanEnd,
    shifts: shifts,
    sites: sites,
  );

  factory AttendanceSetup.fromJson(Json json) {
    List<Json> list(Object? v) =>
        v is List ? v.map((e) => Json.from(e as Map)).toList() : const [];
    return AttendanceSetup(
      enabled: json['enabled'] as bool? ?? false,
      weekendDays: {
        for (final d in (json['weekend_days'] as List? ?? const [5, 6]))
          (d as num).toInt(),
      },
      requireSelfie: json['require_selfie'] as bool? ?? false,
      allowOutside: json['allow_outside'] as bool? ?? true,
      reminders: json['reminders'] as bool? ?? true,
      defaultShiftId: json['default_shift_id'] as String?,
      ramadanFrom: json['ramadan_from'] == null
          ? null
          : _day(json['ramadan_from']),
      ramadanTo: json['ramadan_to'] == null ? null : _day(json['ramadan_to']),
      ramadanStart: json['ramadan_start'] == null
          ? null
          : parseClock(json['ramadan_start']),
      ramadanEnd: json['ramadan_end'] == null
          ? null
          : parseClock(json['ramadan_end']),
      shifts: list(json['shifts']).map(AttendanceShift.fromJson).toList(),
      sites: list(json['sites']).map(AttendanceSite.fromJson).toList(),
    );
  }
}

List<Json> _list(Object? v) =>
    v is List ? v.map((e) => Json.from(e as Map)).toList() : const [];

Json? _map(Object? v) => v is Map ? Json.from(v) : null;

/// A project, branch or shift to pick from.
class AttendanceOption {
  const AttendanceOption(this.id, this.name);

  final String id;
  final String name;

  factory AttendanceOption.fromJson(Json json) =>
      AttendanceOption(json['id'] as String, json['name'] as String? ?? '');
}

/// Where someone stands on a day, for their manager.
enum TeamStatus {
  /// Checked in from outside, waiting for review.
  pending,
  late,
  present,

  /// Their shift has not started yet.
  notYet,
  absent,
  dayOff,
}

/// Someone on a manager's list: with the app, or a worker without it.
class TeamPerson {
  const TeamPerson({
    required this.id,
    required this.name,
    this.userId,
    this.jobTitle,
    this.phone,
    this.code,
    this.projectId,
    this.projectName,
    this.siteId,
    this.siteName,
    this.shiftId,
    this.shift,
    this.dayOff = false,
    this.record,
  });

  final String id;
  final String name;

  /// Null for a worker without the app.
  final String? userId;
  final String? jobTitle;
  final String? phone;
  final String? code;
  final String? projectId;
  final String? projectName;
  final String? siteId;
  final String? siteName;
  final String? shiftId;
  final ShiftToday? shift;
  final bool dayOff;
  final AttendanceRecord? record;

  bool get hasApp => userId != null;

  TeamStatus status([DateTime? now]) {
    final r = record;
    if (r != null) {
      if (r.review == AttendanceReview.pending) return TeamStatus.pending;
      return r.lateMinutes > 0 ? TeamStatus.late : TeamStatus.present;
    }
    if (dayOff) return TeamStatus.dayOff;
    final s = shift;
    if (s != null &&
        (now ?? DateTime.now()).isBefore(
          s.startAt.add(Duration(minutes: s.grace)),
        )) {
      return TeamStatus.notYet;
    }
    return TeamStatus.absent;
  }

  factory TeamPerson.fromJson(Json json) => TeamPerson(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    userId: json['user_id'] as String?,
    jobTitle: json['job_title'] as String?,
    phone: json['phone'] as String?,
    code: json['code'] as String?,
    projectId: json['project_id'] as String?,
    projectName: json['project_name'] as String?,
    siteId: json['site_id'] as String?,
    siteName: json['site_name'] as String?,
    shiftId: json['shift_id'] as String?,
    shift: _map(json['shift']) == null
        ? null
        : ShiftToday.fromJson(_map(json['shift'])!),
    dayOff: json['day_off'] as bool? ?? false,
    record: _map(json['record']) == null
        ? null
        : AttendanceRecord.fromJson(_map(json['record'])!),
  );
}

/// A manager's view of one day.
class TeamBoard {
  const TeamBoard({
    required this.day,
    required this.today,
    this.isAdmin = false,
    this.projects = const [],
    this.sites = const [],
    this.shifts = const [],
    this.workersUsed = 0,
    this.workersFree,
    this.extraWorkerUsd = 0,
    this.requests = 0,
    this.people = const [],
  });

  final DateTime day;
  final DateTime today;
  final bool isAdmin;

  /// The projects the manager leads (all of them for owners and admins).
  final List<AttendanceOption> projects;
  final List<AttendanceOption> sites;
  final List<AttendanceOption> shifts;
  final int workersUsed;

  /// Null means no limit.
  final int? workersFree;
  final double extraWorkerUsd;

  /// Check-ins to review and corrections to decide.
  final int requests;
  final List<TeamPerson> people;

  bool get isToday => day == today;

  /// Whether one more worker can be added, and whether it is billed.
  bool get canAddWorker =>
      workersFree == null || workersUsed < workersFree! || extraWorkerUsd > 0;
  bool get nextWorkerBilled =>
      workersFree != null && workersUsed >= workersFree!;

  factory TeamBoard.fromJson(Json json) {
    final workers = _map(json['workers']) ?? const <String, dynamic>{};
    return TeamBoard(
      day: _day(json['day']),
      today: _day(json['today']),
      isAdmin: json['is_admin'] as bool? ?? false,
      projects: _list(json['projects']).map(AttendanceOption.fromJson).toList(),
      sites: _list(json['sites']).map(AttendanceOption.fromJson).toList(),
      shifts: _list(json['shifts']).map(AttendanceOption.fromJson).toList(),
      workersUsed: (workers['used'] as num?)?.toInt() ?? 0,
      workersFree: (workers['free'] as num?)?.toInt(),
      extraWorkerUsd: (workers['extra_usd'] as num?)?.toDouble() ?? 0,
      requests: (json['requests'] as num?)?.toInt() ?? 0,
      people: _list(json['people']).map(TeamPerson.fromJson).toList(),
    );
  }
}

/// A change to someone's record, and who made it.
class AttendanceEdit {
  const AttendanceEdit({
    required this.field,
    required this.at,
    this.oldAt,
    this.newAt,
    this.detail,
    this.byName,
  });

  /// in, out, review or deleted.
  final String field;
  final DateTime at;
  final DateTime? oldAt;
  final DateTime? newAt;
  final String? detail;
  final String? byName;

  factory AttendanceEdit.fromJson(Json json) => AttendanceEdit(
    field: json['field'] as String,
    at: _time(json['at'])!,
    oldAt: _time(json['old_at']),
    newAt: _time(json['new_at']),
    detail: json['detail'] as String?,
    byName: json['by'] as String?,
  );
}

enum FixStatus {
  pending,
  accepted,
  rejected,
  cancelled;

  static FixStatus parse(Object? value) =>
      values.firstWhere((s) => s.name == value, orElse: () => pending);
}

/// Someone's request to correct a day.
class AttendanceFix {
  const AttendanceFix({
    required this.id,
    required this.day,
    required this.note,
    this.status = FixStatus.pending,
    this.inAt,
    this.outAt,
    this.personId,
    this.name,
    this.decisionNote,
    this.decidedBy,
    this.record,
  });

  final String id;
  final DateTime day;
  final DateTime? inAt;
  final DateTime? outAt;
  final String note;
  final FixStatus status;
  final String? personId;
  final String? name;
  final String? decisionNote;
  final String? decidedBy;

  /// The day as it stands, for the manager to compare.
  final AttendanceRecord? record;

  factory AttendanceFix.fromJson(Json json) => AttendanceFix(
    id: json['id'] as String,
    day: _day(json['day']),
    inAt: _time(json['in_at']),
    outAt: _time(json['out_at']),
    note: json['note'] as String? ?? '',
    status: FixStatus.parse(json['status']),
    personId: json['person_id'] as String?,
    name: json['name'] as String?,
    decisionNote: json['decision_note'] as String?,
    decidedBy: json['decided_by'] as String?,
    record: _map(json['record']) == null
        ? null
        : AttendanceRecord.fromJson(_map(json['record'])!),
  );
}

/// One person's day, opened by their manager.
class PersonDay {
  const PersonDay({
    required this.person,
    this.canEdit = false,
    this.edits = const [],
    this.fix,
  });

  final TeamPerson person;
  final bool canEdit;
  final List<AttendanceEdit> edits;
  final AttendanceFix? fix;

  factory PersonDay.fromJson(Json json) => PersonDay(
    person: TeamPerson.fromJson(json),
    canEdit: json['can_edit'] as bool? ?? false,
    edits: _list(json['edits']).map(AttendanceEdit.fromJson).toList(),
    fix: _map(json['fix']) == null
        ? null
        : AttendanceFix.fromJson(_map(json['fix'])!),
  );
}

/// What waits on a manager.
class AttendanceRequests {
  const AttendanceRequests({this.reviews = const [], this.fixes = const []});

  /// Check-ins from outside, with the person's name.
  final List<(AttendanceRecord, String)> reviews;
  final List<AttendanceFix> fixes;

  bool get isEmpty => reviews.isEmpty && fixes.isEmpty;

  factory AttendanceRequests.fromJson(Json json) => AttendanceRequests(
    reviews: [
      for (final r in _list(json['reviews']))
        (AttendanceRecord.fromJson(r), r['name'] as String? ?? ''),
    ],
    fixes: _list(json['fixes']).map(AttendanceFix.fromJson).toList(),
  );
}

/// What a roll call did.
class RollCallResult {
  const RollCallResult({required this.recorded, this.skipped = const []});

  final int recorded;
  final List<String> skipped;

  factory RollCallResult.fromJson(Json json) => RollCallResult(
    recorded: (json['recorded'] as num?)?.toInt() ?? 0,
    skipped: [for (final s in (json['skipped'] as List? ?? const [])) '$s'],
  );
}

/// Where the phone is.
class LocationFix {
  const LocationFix(this.lat, this.lng, {this.accuracyM});

  final double lat;
  final double lng;
  final int? accuracyM;
}

/// One person's day in an attendance report.
class ReportRow {
  const ReportRow({
    required this.personId,
    required this.name,
    required this.day,
    this.jobTitle,
    this.code,
    this.hasApp = true,
    this.project,
    this.dayOff = false,
    this.inAt,
    this.outAt,
    this.lateMinutes = 0,
    this.site,
    this.outside = false,
    this.review = AttendanceReview.none,
    this.inBy,
    this.outBy,
  });

  final String personId;
  final String name;
  final DateTime day;
  final String? jobTitle;
  final String? code;
  final bool hasApp;
  final String? project;
  final bool dayOff;
  final DateTime? inAt;
  final DateTime? outAt;
  final int lateMinutes;
  final String? site;
  final bool outside;
  final AttendanceReview review;
  final String? inBy;
  final String? outBy;

  /// Time between checking in and out, when both are known.
  Duration? get worked => inAt != null && outAt != null && outAt!.isAfter(inAt!)
      ? outAt!.difference(inAt!)
      : null;

  factory ReportRow.fromJson(Json json) => ReportRow(
    personId: json['person_id'] as String,
    name: json['name'] as String? ?? '',
    day: _day(json['day']),
    jobTitle: json['job_title'] as String?,
    code: json['code'] as String?,
    hasApp: json['has_app'] as bool? ?? true,
    project: json['project'] as String?,
    dayOff: json['day_off'] as bool? ?? false,
    inAt: _time(json['in_at']),
    outAt: _time(json['out_at']),
    lateMinutes: (json['late_minutes'] as num?)?.toInt() ?? 0,
    site: json['site'] as String?,
    outside: json['outside'] as bool? ?? false,
    review: AttendanceReview.parse(json['review']),
    inBy: json['in_by'] as String?,
    outBy: json['out_by'] as String?,
  );
}

/// Every day of a period for the people a manager chose.
class AttendanceReport {
  const AttendanceReport({
    required this.workspace,
    required this.from,
    required this.to,
    this.rows = const [],
  });

  final String workspace;
  final DateTime from;

  /// Never past today.
  final DateTime to;

  /// By name, then day.
  final List<ReportRow> rows;

  factory AttendanceReport.fromJson(Json json) => AttendanceReport(
    workspace: json['workspace'] as String? ?? '',
    from: _day(json['from']),
    to: _day(json['to']),
    rows: _list(json['rows']).map(ReportRow.fromJson).toList(),
  );
}
