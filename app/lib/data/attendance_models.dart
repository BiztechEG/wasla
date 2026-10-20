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

/// Where the phone is.
class LocationFix {
  const LocationFix(this.lat, this.lng, {this.accuracyM});

  final double lat;
  final double lng;
  final int? accuracyM;
}
