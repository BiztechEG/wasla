import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/attendance_models.dart';
import '../data/chat_models.dart';
import '../data/location.dart';
import '../data/models.dart';
import '../l10n/app_localizations.dart';
import '../state/attendance_providers.dart';
import '../state/chat_providers.dart';
import '../state/providers.dart';
import '../theme.dart';
import 'attendance_setup_screen.dart';
import 'chat_format.dart';
import 'widgets.dart';

void openAttendance(BuildContext context, Membership membership) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AttendanceScreen(membership: membership),
      ),
    );

/// The orange used for being late.
Color lateTint(BuildContext context) =>
    WaslaColors.project('#C2660A', Theme.of(context).brightness);

String lateText(AppLocalizations l, int minutes) => minutes >= 60
    ? l.lateHours(minutes ~/ 60, minutes % 60)
    : l.lateMinutes(minutes);

String workedText(AppLocalizations l, Duration d) =>
    l.workedTime(d.inHours, d.inMinutes % 60);

String reasonLabel(AppLocalizations l, OutsideReason r) => switch (r) {
  OutsideReason.client => l.reasonClient,
  OutsideReason.field => l.reasonField,
  OutsideReason.home => l.reasonHome,
  OutsideReason.other => l.reasonOther,
};

String locationError(AppLocalizations l, Object e) => switch (e) {
  LocationOff() => l.locationOff,
  LocationDenied(forever: true) => l.locationDeniedForever,
  LocationDenied() => l.locationDenied,
  _ => l.locationFailed,
};

/// Checking in and out, with today's shift, this week and the month so far.
class AttendanceScreen extends ConsumerStatefulWidget {
  const AttendanceScreen({super.key, required this.membership});

  final Membership membership;

  @override
  ConsumerState<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends ConsumerState<AttendanceScreen> {
  LocationFix? _fix;
  Object? _fixError;
  bool _locating = false;
  bool _busy = false;
  Timer? _tick;

  String get _ws => widget.membership.workspaceId;

  @override
  void initState() {
    super.initState();
    _locate();
    // The clock and the time worked move on by themselves.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<LocationFix?> _locate() async {
    setState(() {
      _locating = true;
      _fixError = null;
    });
    try {
      final fix = await ref.read(locatorProvider).current();
      if (mounted) setState(() => _fix = fix);
      return fix;
    } catch (e) {
      if (mounted) setState(() => _fixError = e);
      return null;
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _showLocationProblem(Object error) async {
    final l = context.l10n;
    final forever = error is LocationDenied && error.forever;
    final open = await confirm(
      context,
      message: locationError(l, error),
      action: forever ? l.openSettings : l.retry,
    );
    if (!open || !mounted) return;
    if (forever) {
      await ref.read(locatorProvider).openSettings();
    } else {
      await _locate();
    }
  }

  Future<void> _checkIn(AttendanceToday today) async {
    final l = context.l10n;
    setState(() => _busy = true);
    try {
      final fix = await _locate();
      if (!mounted) return;
      // No spinner while the person answers a question.
      setState(() => _busy = false);
      if (fix == null) {
        if (_fixError != null) await _showLocationProblem(_fixError!);
        return;
      }
      final place = PlaceCheck.of(fix, own: today.site, sites: today.sites);
      OutsideReason? reason;
      String? note;
      if (!place.inside) {
        if (!today.allowOutside) {
          showMessage(
            context,
            l.outsideNotAllowed(place.site?.name ?? '', place.distanceM ?? 0),
          );
          return;
        }
        final answer = await showModalBottomSheet<(OutsideReason, String)>(
          context: context,
          isScrollControlled: true,
          showDragHandle: true,
          builder: (_) => _OutsideSheet(place: place),
        );
        if (answer == null || !mounted) return;
        (reason, note) = answer;
      }
      Upload? photo;
      if (today.requireSelfie) {
        photo = await ref
            .read(pickerProvider)
            .pickImage(camera: true, front: true, maxSide: 800);
        if (photo == null || !mounted) return;
      }
      AttendanceRecord? record;
      setState(() => _busy = true);
      final ok = await runAction(context, () async {
        record = await ref
            .read(apiProvider)
            .checkIn(_ws, fix, photo: photo, reason: reason, note: note);
      });
      if (!mounted) return;
      if (ok) {
        showMessage(context, l.checkedInAt(clockTime(context, record!.inAt)));
      }
      ref.invalidate(attendanceTodayProvider(_ws));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _checkOut() async {
    final l = context.l10n;
    if (!await confirm(
      context,
      message: l.checkOutConfirm,
      action: l.checkOut,
    )) {
      return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      final fix = await _locate();
      if (!mounted) return;
      if (fix == null) {
        setState(() => _busy = false);
        if (_fixError != null) await _showLocationProblem(_fixError!);
        return;
      }
      AttendanceRecord? record;
      final ok = await runAction(context, () async {
        record = await ref.read(apiProvider).checkOut(_ws, fix);
      });
      if (!mounted) return;
      if (ok) {
        showMessage(
          context,
          l.checkedOutAt(clockTime(context, record!.outAt!)),
        );
      }
      ref.invalidate(attendanceTodayProvider(_ws));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final today = ref.watch(attendanceTodayProvider(_ws));
    final isAdmin = widget.membership.role.canManage;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.attendance),
        actions: [
          if (isAdmin)
            IconButton(
              tooltip: l.attendanceSetup,
              icon: const Icon(LucideIcons.settings2),
              onPressed: () => openAttendanceSetup(context, widget.membership),
            ),
        ],
      ),
      body: AsyncView(
        value: today,
        onRetry: () => ref.invalidate(attendanceTodayProvider(_ws)),
        builder: (t) {
          if (!t.enabled) {
            return Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                EmptyState(
                  icon: LucideIcons.clock,
                  title: l.attendanceOff,
                  body: isAdmin ? l.attendanceOffAdmin : l.attendanceOffBody,
                ),
                if (isAdmin)
                  FilledButton(
                    onPressed: () =>
                        openAttendanceSetup(context, widget.membership),
                    child: Text(l.attendanceSetup),
                  ),
              ],
            );
          }
          return RefreshIndicator(
            onRefresh: () {
              unawaited(_locate());
              return ref.refresh(attendanceTodayProvider(_ws).future);
            },
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
              children: [
                _TodayCard(
                  today: t,
                  fix: _fix,
                  fixError: _fixError,
                  locating: _locating,
                  busy: _busy,
                  onRetryLocation: _locate,
                  onCheckIn: () => _checkIn(t),
                  onCheckOut: _checkOut,
                ),
                const SizedBox(height: 12),
                _WeekCard(
                  today: t,
                  onHistory: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          AttendanceHistoryScreen(workspaceId: _ws, today: t),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _Stat(
                        value: l.minutesShort(t.monthLateMinutes),
                        label: l.lateThisMonth,
                        color: t.monthLateMinutes > 0
                            ? lateTint(context)
                            : null,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _Stat(value: '${t.monthLate}', label: l.lateTimes),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _Stat(
                        value: '${t.monthPresent}',
                        label: l.presentDays,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// The shift, the clock, where one is and the big button.
class _TodayCard extends StatelessWidget {
  const _TodayCard({
    required this.today,
    required this.fix,
    required this.fixError,
    required this.locating,
    required this.busy,
    required this.onRetryLocation,
    required this.onCheckIn,
    required this.onCheckOut,
  });

  final AttendanceToday today;
  final LocationFix? fix;
  final Object? fixError;
  final bool locating;
  final bool busy;
  final VoidCallback onRetryLocation;
  final VoidCallback onCheckIn;
  final VoidCallback onCheckOut;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final shift = today.shift;
    final record = today.record;
    final now = DateTime.now();
    final time = clockTime(context, now);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
        child: Column(
          children: [
            if (shift != null)
              _Line(
                icon: LucideIcons.clock,
                text: l.shiftLine(
                  shift.name,
                  clockTime(context, shift.startAt),
                  clockTime(context, shift.endAt),
                ),
              ),
            const SizedBox(height: 10),
            if (record != null && record.open) ...[
              Text(l.atWorkFor, style: _muted(theme)),
              Text(
                _hm(record.worked(now)),
                style: theme.textTheme.displaySmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ] else
              Text(
                time,
                style: theme.textTheme.displaySmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            const SizedBox(height: 10),
            _status(context),
            const SizedBox(height: 18),
            _BigButton(
              busy: busy,
              state: record == null
                  ? _ButtonState.checkIn
                  : record.open
                  ? _ButtonState.checkOut
                  : _ButtonState.done,
              onPressed: record == null
                  ? onCheckIn
                  : record.open
                  ? onCheckOut
                  : null,
            ),
            const SizedBox(height: 14),
            if (record == null && today.requireSelfie)
              _Line(icon: LucideIcons.camera, text: l.selfieNeeded),
            if (record != null && record.open && shift != null)
              _Line(
                icon: LucideIcons.logOut,
                text: l.checkOutBy(clockTime(context, shift.endAt)),
              ),
            if (record != null && !record.open)
              _Line(
                icon: LucideIcons.timer,
                text: workedText(l, record.worked()),
              ),
            if (record != null && record.review == AttendanceReview.pending)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: _Chip(
                  icon: LucideIcons.hourglass,
                  text: l.waitingReview,
                  color: lateTint(context),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _hm(Duration d) =>
      '${d.inHours}:${(d.inMinutes % 60).toString().padLeft(2, '0')}';

  TextStyle? _muted(ThemeData theme) => theme.textTheme.bodyMedium?.copyWith(
    color: theme.colorScheme.onSurfaceVariant,
  );

  /// Where one is before checking in; when one came after.
  Widget _status(BuildContext context) {
    final l = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final record = today.record;
    if (record != null) {
      final at = clockTime(context, record.inAt);
      return _Chip(
        icon: LucideIcons.check,
        text: record.lateMinutes > 0
            ? l.checkedInLate(at, lateText(l, record.lateMinutes))
            : l.checkedInOnTime(at),
        color: record.lateMinutes > 0 ? lateTint(context) : scheme.primary,
      );
    }
    if (locating && fix == null) {
      return _Chip(
        icon: LucideIcons.locateFixed,
        text: l.locating,
        color: scheme.onSurfaceVariant,
      );
    }
    if (fix == null) {
      return ActionChip(
        avatar: Icon(LucideIcons.mapPinOff, size: 16, color: scheme.error),
        label: Text(locationError(l, fixError ?? const LocationOff())),
        onPressed: onRetryLocation,
      );
    }
    final place = PlaceCheck.of(fix!, own: today.site, sites: today.sites);
    if (place.site == null) {
      return _Chip(
        icon: LucideIcons.mapPin,
        text: l.locationFound,
        color: scheme.primary,
      );
    }
    if (place.site!.isField) {
      return _Chip(
        icon: LucideIcons.mapPin,
        text: l.atFieldSite(place.site!.name),
        color: scheme.primary,
      );
    }
    return _Chip(
      icon: LucideIcons.mapPin,
      text: place.inside
          ? l.atSite(place.site!.name, place.distanceM!)
          : l.awayFromSite(place.site!.name, place.distanceM!),
      color: place.inside ? scheme.primary : scheme.error,
    );
  }
}

enum _ButtonState { checkIn, checkOut, done }

class _BigButton extends StatelessWidget {
  const _BigButton({
    required this.state,
    required this.busy,
    required this.onPressed,
  });

  final _ButtonState state;
  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final orange = lateTint(context);
    final (label, icon, fill, fg, ring) = switch (state) {
      _ButtonState.checkIn => (
        l.checkIn,
        LucideIcons.check,
        scheme.primary,
        scheme.onPrimary,
        scheme.primaryContainer,
      ),
      _ButtonState.checkOut => (
        l.checkOut,
        LucideIcons.logOut,
        scheme.surface,
        orange,
        orange.withValues(alpha: 0.25),
      ),
      _ButtonState.done => (
        l.doneForToday,
        LucideIcons.circleCheck,
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
        scheme.surfaceContainerHigh,
      ),
    };
    return Semantics(
      button: true,
      label: label,
      child: Container(
        width: 184,
        height: 184,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: ring, width: 10),
        ),
        child: Material(
          color: fill,
          shape: state == _ButtonState.checkOut
              ? CircleBorder(side: BorderSide(color: orange, width: 2))
              : const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: const Key('attendanceButton'),
            onTap: busy ? null : onPressed,
            child: Center(
              child: busy
                  ? CircularProgressIndicator(color: fg)
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(icon, size: 38, color: fg),
                        const SizedBox(height: 6),
                        Text(
                          label,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: fg,
                            fontSize: 19,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Asks why one checks in away from the branch.
class _OutsideSheet extends StatefulWidget {
  const _OutsideSheet({required this.place});

  final PlaceCheck place;

  @override
  State<_OutsideSheet> createState() => _OutsideSheetState();
}

class _OutsideSheetState extends State<_OutsideSheet> {
  OutsideReason? _reason;
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: scheme.errorContainer,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(LucideIcons.triangleAlert, color: scheme.error),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l.awayTitle(widget.place.site?.name ?? ''),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l.awayBody(
                        widget.place.site?.radiusM ?? 0,
                        widget.place.distanceM ?? 0,
                      ),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final r in OutsideReason.values)
                ChoiceChip(
                  label: Text(reasonLabel(l, r)),
                  selected: _reason == r,
                  onSelected: (_) => setState(() => _reason = r),
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _note,
            maxLength: 300,
            maxLines: 2,
            minLines: 1,
            decoration: InputDecoration(labelText: l.reasonDetails),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _reason == null
                  ? null
                  : () => Navigator.pop(context, (_reason!, _note.text.trim())),
              child: Text(l.checkInWithReason),
            ),
          ),
        ],
      ),
    );
  }
}

/// The last seven days, one small box each.
class _WeekCard extends StatelessWidget {
  const _WeekCard({required this.today, required this.onHistory});

  final AttendanceToday today;
  final VoidCallback onHistory;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final locale = Localizations.localeOf(context).languageCode;
    final last = today.today ?? DateTime.now();
    final byDay = {for (final r in today.recent) r.day: r};
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 14),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    l.lastSevenDays,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                TextButton(onPressed: onHistory, child: Text(l.fullHistory)),
              ],
            ),
            Row(
              children: [
                for (var i = 6; i >= 0; i--)
                  Expanded(
                    child: Builder(
                      builder: (context) {
                        final day = DateTime(
                          last.year,
                          last.month,
                          last.day - i,
                        );
                        final r = byDay[day];
                        final off = today.weekendDays.contains(day.weekday % 7);
                        final isToday = i == 0;
                        final late = (r?.lateMinutes ?? 0) > 0;
                        final color = r == null
                            ? scheme.surfaceContainerHighest
                            : late
                            ? lateTint(context).withValues(alpha: 0.16)
                            : scheme.primaryContainer;
                        final fg = r == null
                            ? scheme.onSurfaceVariant
                            : late
                            ? WaslaColors.onTint(
                                lateTint(context),
                                theme.brightness,
                              )
                            : scheme.onPrimaryContainer;
                        return Column(
                          children: [
                            Text(
                              isToday
                                  ? l.today
                                  : DateFormat('EEE', locale).format(day),
                              maxLines: 1,
                              overflow: TextOverflow.clip,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: isToday
                                    ? scheme.onSurface
                                    : scheme.onSurfaceVariant,
                                fontWeight: isToday ? FontWeight.w700 : null,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Container(
                              height: 36,
                              margin: const EdgeInsets.symmetric(horizontal: 2),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: isToday && r == null ? null : color,
                                borderRadius: BorderRadius.circular(10),
                                border: isToday && r == null
                                    ? Border.all(color: scheme.outline)
                                    : null,
                              ),
                              child: Text(
                                r != null
                                    ? westernDigits(
                                        DateFormat(
                                          'h:mm',
                                          locale,
                                        ).format(r.inAt.toLocal()),
                                      )
                                    : off
                                    ? l.dayOffShort
                                    : '',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                  color: fg,
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// One month of one's days.
class AttendanceHistoryScreen extends ConsumerStatefulWidget {
  const AttendanceHistoryScreen({
    super.key,
    required this.workspaceId,
    required this.today,
  });

  final String workspaceId;
  final AttendanceToday today;

  @override
  ConsumerState<AttendanceHistoryScreen> createState() =>
      _AttendanceHistoryScreenState();
}

class _AttendanceHistoryScreenState
    extends ConsumerState<AttendanceHistoryScreen> {
  late DateTime _month;

  DateTime get _last => widget.today.today ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    _month = DateTime(_last.year, _last.month);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final key = (widget.workspaceId, _month);
    final records = ref.watch(myAttendanceProvider(key));
    final thisMonth = _month.year == _last.year && _month.month == _last.month;
    return Scaffold(
      appBar: AppBar(title: Text(l.attendanceHistory)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                IconButton(
                  tooltip: l.previousMonth,
                  icon: const Icon(Icons.chevron_left),
                  onPressed: () => setState(
                    () => _month = DateTime(_month.year, _month.month - 1),
                  ),
                ),
                Expanded(
                  child: Text(
                    monthLabel(context, _month),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: l.nextMonth,
                  icon: const Icon(Icons.chevron_right),
                  onPressed: thisMonth
                      ? null
                      : () => setState(
                          () =>
                              _month = DateTime(_month.year, _month.month + 1),
                        ),
                ),
              ],
            ),
          ),
          Expanded(
            child: AsyncView(
              value: records,
              onRetry: () => ref.invalidate(myAttendanceProvider(key)),
              builder: (list) => _MonthList(
                month: _month,
                last: _last,
                records: list,
                weekendDays: widget.today.weekendDays,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MonthList extends StatelessWidget {
  const _MonthList({
    required this.month,
    required this.last,
    required this.records,
    required this.weekendDays,
  });

  final DateTime month;
  final DateTime last;
  final List<AttendanceRecord> records;
  final Set<int> weekendDays;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final byDay = {for (final r in records) r.day: r};
    final counted = records.where((r) => r.review != AttendanceReview.rejected);
    final late = counted.where((r) => r.lateMinutes > 0).length;
    final worked = counted.fold(
      Duration.zero,
      (sum, r) => r.outAt == null ? sum : sum + r.worked(),
    );
    final end = DateTime(month.year, month.month + 1, 0);
    final lastDay = end.isAfter(last) ? last : end;
    final days = [
      for (
        var d = lastDay;
        !d.isBefore(month);
        d = DateTime(d.year, d.month, d.day - 1)
      )
        d,
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      children: [
        Row(
          children: [
            Expanded(
              child: _Stat(value: '${counted.length}', label: l.presentDays),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _Stat(
                value: '$late',
                label: l.lateTimes,
                color: late > 0 ? lateTint(context) : null,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _Stat(
                value: l.hoursShort(worked.inHours),
                label: l.hoursWorked,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (days.isEmpty)
          EmptyState(icon: LucideIcons.calendar, title: l.noDaysYet)
        else
          TileGroup(
            children: [
              for (final d in days)
                _DayTile(
                  day: d,
                  record: byDay[d],
                  off: weekendDays.contains(d.weekday % 7),
                ),
            ],
          ),
      ],
    );
  }
}

class _DayTile extends StatelessWidget {
  const _DayTile({required this.day, required this.record, required this.off});

  final DateTime day;
  final AttendanceRecord? record;
  final bool off;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final locale = Localizations.localeOf(context).languageCode;
    final r = record;
    final String title;
    String? subtitle;
    Widget? tag;
    if (r == null) {
      title = off ? l.dayOff : l.noRecord;
    } else {
      final inAt = clockTime(context, r.inAt);
      title = r.outAt == null
          ? l.inStillAtWork(inAt)
          : l.inOut(inAt, clockTime(context, r.outAt!));
      subtitle = [
        if (r.inSite != null) r.inSite!,
        if (r.outAt != null) workedText(l, r.worked()),
        if (r.reason != null) reasonLabel(l, r.reason!),
      ].join(' · ');
      tag = switch (r.review) {
        AttendanceReview.pending => _Chip(
          text: l.waitingReview,
          color: lateTint(context),
        ),
        AttendanceReview.rejected => _Chip(
          text: l.reviewRejected,
          color: scheme.error,
        ),
        _ when r.lateMinutes > 0 => _Chip(
          text: lateText(l, r.lateMinutes),
          color: lateTint(context),
        ),
        _ => _Chip(text: l.present, color: scheme.primary),
      };
    }
    return ListTile(
      leading: SizedBox(
        width: 44,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '${day.day}',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              DateFormat('EEE', locale).format(day),
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      title: Text(
        title,
        style: TextStyle(
          fontWeight: r == null ? null : FontWeight.w600,
          color: r == null ? scheme.onSurfaceVariant : null,
        ),
      ),
      subtitle: subtitle == null || subtitle.isEmpty ? null : Text(subtitle),
      trailing: tag,
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}

/// A rounded label on a tint of [color].
class _Chip extends StatelessWidget {
  const _Chip({required this.text, required this.color, this.icon});

  final String text;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final fg = WaslaColors.onTint(color, Theme.of(context).brightness);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 15, color: fg),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: fg,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A number and what it counts.
class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label, this.color});

  final String value;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            maxLines: 1,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
          Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// A line on the "My tasks" tab: today's check-in, one tap from the
/// attendance screen. Nothing while attendance is off.
class AttendanceStrip extends ConsumerWidget {
  const AttendanceStrip({super.key, required this.membership});

  final Membership membership;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = ref.watch(attendanceTodayProvider(membership.workspaceId)).value;
    if (t == null || !t.enabled) return const SizedBox.shrink();
    final r = t.record;
    final String text;
    final Color color;
    if (r == null) {
      text = t.shift == null
          ? l.notCheckedIn
          : l.notCheckedInShift(clockTime(context, t.shift!.startAt));
      color = scheme.onSurfaceVariant;
    } else if (r.open) {
      text = l.checkedInOnTime(clockTime(context, r.inAt));
      color = scheme.primary;
    } else {
      text = l.inOut(clockTime(context, r.inAt), clockTime(context, r.outAt!));
      color = scheme.onSurfaceVariant;
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Material(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          key: const Key('attendanceStrip'),
          borderRadius: BorderRadius.circular(16),
          onTap: () => openAttendance(context, membership),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                Icon(LucideIcons.clock, size: 20, color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  r == null
                      ? l.checkIn
                      : r.open
                      ? l.checkOut
                      : l.attendance,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w700,
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
