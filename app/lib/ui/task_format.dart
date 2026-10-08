import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/task_models.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'chat_format.dart';
import 'widgets.dart';

String statusLabel(AppLocalizations l, TaskStatus status) => switch (status) {
  TaskStatus.todo => l.taskStatusNew,
  TaskStatus.inProgress => l.taskStatusInProgress,
  TaskStatus.onHold => l.taskStatusOnHold,
  TaskStatus.review => l.taskStatusReview,
  TaskStatus.done => l.taskStatusDone,
};

String priorityLabel(AppLocalizations l, TaskPriority priority) =>
    switch (priority) {
      TaskPriority.normal => l.priorityNormal,
      TaskPriority.high => l.priorityHigh,
      TaskPriority.urgent => l.priorityUrgent,
    };

String groupLabel(AppLocalizations l, DueGroup group) => switch (group) {
  DueGroup.late => l.groupLate,
  DueGroup.today => l.today,
  DueGroup.week => l.groupWeek,
  DueGroup.later => l.groupLater,
  DueGroup.noDate => l.groupNoDate,
  DueGroup.done => l.groupDone,
};

String remindersLabel(AppLocalizations l, List<int> minutes) {
  final day = minutes.contains(1440);
  final hour = minutes.contains(60);
  if (day && hour) return l.remindDayAndHour;
  if (day) return l.remindDayBefore;
  if (hour) return l.remindHourBefore;
  return l.remindNone;
}

/// The design's colors for each status; dark mode gets lighter versions.
Color statusColor(TaskStatus status, Brightness brightness) {
  final hex = switch (status) {
    TaskStatus.todo => null,
    TaskStatus.inProgress => '#C2660A',
    TaskStatus.onHold => '#B4441C',
    TaskStatus.review => '#2F5BD3',
    TaskStatus.done => '#0F6E6A',
  };
  if (hex == null) {
    return brightness == Brightness.dark
        ? const Color(0xFFA3AEB9)
        : const Color(0xFF4A5868);
  }
  return WaslaColors.project(hex, brightness);
}

Color lateColor(BuildContext context) => Theme.of(context).colorScheme.error;

/// A status as a small colored label.
class StatusTag extends StatelessWidget {
  const StatusTag(this.status, {super.key});

  final TaskStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brightness = theme.brightness;
    final color = statusColor(status, brightness);
    final plain = status == TaskStatus.todo;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: plain
            ? theme.colorScheme.surfaceContainerHighest
            : color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        statusLabel(context.l10n, status),
        maxLines: 1,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: plain
              ? theme.colorScheme.onSurfaceVariant
              : WaslaColors.onTint(color, brightness),
        ),
      ),
    );
  }
}

String _locale(BuildContext context) =>
    Localizations.localeOf(context).languageCode;

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// When a task is due, as short as the list allows: the time today,
/// "tomorrow", a weekday this week, else a date; "was due …" once late.
String dueText(BuildContext context, DateTime due, {bool late = false}) {
  final l = context.l10n;
  final local = due.toLocal();
  final now = DateTime.now();
  final locale = _locale(context);
  final String when;
  if (_sameDay(local, now)) {
    when = late ? l.today : clockTime(context, local);
  } else if (_sameDay(local, now.add(const Duration(days: 1)))) {
    when = l.tomorrow;
  } else if (_sameDay(local, now.subtract(const Duration(days: 1)))) {
    when = l.yesterday;
  } else if (local.difference(now).inDays.abs() < 7) {
    when = DateFormat('EEEE', locale).format(local);
  } else {
    when = westernDigits(
      DateFormat(
        local.year == now.year ? 'd MMMM' : 'd/M/yyyy',
        locale,
      ).format(local),
    );
  }
  return late ? l.wasDue(when) : when;
}

/// The full due date and time, for the task screen.
String dueFull(BuildContext context, DateTime due) {
  final local = due.toLocal();
  final now = DateTime.now();
  final locale = _locale(context);
  final String day;
  if (_sameDay(local, now)) {
    day = context.l10n.today;
  } else if (_sameDay(local, now.add(const Duration(days: 1)))) {
    day = context.l10n.tomorrow;
  } else {
    day = westernDigits(
      DateFormat(
        local.year == now.year ? 'EEEE d MMMM' : 'd MMMM yyyy',
        locale,
      ).format(local),
    );
  }
  return '$day ${clockTime(context, local)}';
}

/// Asks for a date, then a time (5 pm by default), in the future.
Future<DateTime?> pickDateTime(
  BuildContext context, {
  DateTime? initial,
}) async {
  final now = DateTime.now();
  final start =
      initial?.toLocal() ?? DateTime(now.year, now.month, now.day, 17);
  final date = await showDatePicker(
    context: context,
    initialDate: start.isBefore(now) ? now : start,
    firstDate: DateTime(now.year, now.month, now.day),
    lastDate: now.add(const Duration(days: 365 * 2)),
  );
  if (date == null || !context.mounted) return null;
  final time = await showTimePicker(
    context: context,
    initialTime: TimeOfDay.fromDateTime(start),
  );
  if (time == null) return null;
  return DateTime(date.year, date.month, date.day, time.hour, time.minute);
}
