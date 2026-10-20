import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/attendance_models.dart';
import '../data/chat_models.dart';
import '../data/models.dart';
import '../l10n/app_localizations.dart';
import '../state/attendance_providers.dart';
import '../state/chat_providers.dart';
import '../state/providers.dart';
import 'attendance_report_screen.dart';
import 'attendance_screen.dart';
import 'billing_format.dart';
import 'chat_format.dart';
import 'widgets.dart';

void openTeamAttendance(BuildContext context, Membership membership) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TeamAttendanceScreen(membership: membership),
      ),
    );

void openAttendanceRequests(BuildContext context, Membership membership) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AttendanceRequestsScreen(membership: membership),
      ),
    );

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// Minutes late for a check-in at [at] on [shift], 0 within the grace.
int lateFor(ShiftToday? shift, DateTime at, {bool dayOff = false}) {
  if (shift == null || dayOff) return 0;
  if (!at.isAfter(shift.startAt.add(Duration(minutes: shift.grace)))) {
    return 0;
  }
  return at.difference(shift.startAt).inMinutes;
}

/// Asks when: on time (the shift's start), now, or another time on [day].
/// Never in the future. Returns null when cancelled.
Future<DateTime?> pickAttendanceTime(
  BuildContext context, {
  required DateTime day,
  DateTime? onTime,
  DateTime? initial,
}) async {
  final l = context.l10n;
  final now = DateTime.now();
  final today = _dateOnly(now) == _dateOnly(day);
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onTime != null && !onTime.isAfter(now))
            ListTile(
              key: const Key('timeOnTime'),
              leading: const Icon(LucideIcons.circleCheck),
              title: Text(l.timeOnTime),
              trailing: Text(clockTime(context, onTime)),
              onTap: () => Navigator.pop(context, 'on'),
            ),
          if (today)
            ListTile(
              key: const Key('timeNow'),
              leading: const Icon(LucideIcons.clock),
              title: Text(l.timeNow),
              trailing: Text(clockTime(context, now)),
              onTap: () => Navigator.pop(context, 'now'),
            ),
          ListTile(
            key: const Key('timeOther'),
            leading: const Icon(LucideIcons.pencil),
            title: Text(l.timeOther),
            onTap: () => Navigator.pop(context, 'other'),
          ),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return null;
  if (choice == 'on') return onTime;
  if (choice == 'now') return DateTime.now();
  final start = initial ?? onTime ?? now;
  final picked = await showTimePicker(
    context: context,
    initialTime: TimeOfDay.fromDateTime(start.isAfter(now) ? now : start),
  );
  if (picked == null || !context.mounted) return null;
  final at = DateTime(day.year, day.month, day.day, picked.hour, picked.minute);
  if (at.isAfter(DateTime.now().add(const Duration(minutes: 1)))) {
    showMessage(context, l.errorFutureTime);
    return null;
  }
  return at;
}

String teamStatusLabel(AppLocalizations l, TeamPerson p, [DateTime? now]) =>
    switch (p.status(now)) {
      TeamStatus.pending => l.toReview,
      TeamStatus.late => lateText(l, p.record!.lateMinutes),
      TeamStatus.present => l.present,
      TeamStatus.notYet => l.notYet,
      TeamStatus.absent => l.absent,
      TeamStatus.dayOff => l.dayOff,
    };

Color teamStatusColor(BuildContext context, TeamStatus s) {
  final scheme = Theme.of(context).colorScheme;
  return switch (s) {
    TeamStatus.pending || TeamStatus.late => lateTint(context),
    TeamStatus.present => scheme.primary,
    TeamStatus.absent => scheme.error,
    TeamStatus.notYet || TeamStatus.dayOff => scheme.outline,
  };
}

/// The day of everyone a manager looks after.
class TeamAttendanceScreen extends ConsumerStatefulWidget {
  const TeamAttendanceScreen({super.key, required this.membership});

  final Membership membership;

  @override
  ConsumerState<TeamAttendanceScreen> createState() =>
      _TeamAttendanceScreenState();
}

class _TeamAttendanceScreenState extends ConsumerState<TeamAttendanceScreen> {
  DateTime? _day;
  String? _project;
  TeamStatus? _filter;
  Timer? _tick;

  String get _ws => widget.membership.workspaceId;

  @override
  void initState() {
    super.initState();
    // "Not in yet" turns into "absent" as the grace runs out.
    _tick = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _push(Widget screen) =>
      Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => screen));

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final key = (_ws, _day, _project);
    final board = ref.watch(teamAttendanceProvider(key));
    final b = board.value;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.teamAttendance),
        actions: [
          IconButton(
            key: const Key('attendanceRequests'),
            tooltip: l.attendanceRequests,
            icon: Badge(
              isLabelVisible: (b?.requests ?? 0) > 0,
              label: Text('${b?.requests ?? 0}'),
              child: const Icon(LucideIcons.inbox),
            ),
            onPressed: () =>
                _push(AttendanceRequestsScreen(membership: widget.membership)),
          ),
          if (b != null)
            IconButton(
              key: const Key('attendanceReport'),
              tooltip: l.attendanceReport,
              icon: const Icon(LucideIcons.fileSpreadsheet),
              onPressed: () => _push(
                AttendanceReportScreen(membership: widget.membership, board: b),
              ),
            ),
          IconButton(
            key: const Key('workers'),
            tooltip: l.workersWithoutApp,
            icon: const Icon(LucideIcons.hardHat),
            onPressed: () =>
                _push(WorkersScreen(membership: widget.membership)),
          ),
        ],
      ),
      floatingActionButton: b == null
          ? null
          : FloatingActionButton.extended(
              key: const Key('rollCall'),
              icon: const Icon(LucideIcons.listChecks),
              label: Text(l.rollCall),
              onPressed: () => _push(
                RollCallScreen(membership: widget.membership, board: b),
              ),
            ),
      body: AsyncView(
        value: board,
        onRetry: () => ref.invalidate(teamAttendanceProvider(key)),
        builder: (b) {
          final now = DateTime.now();
          final counts = <TeamStatus, int>{};
          for (final p in b.people) {
            counts.update(p.status(now), (n) => n + 1, ifAbsent: () => 1);
          }
          final shown = _filter == null
              ? b.people
              : b.people.where((p) => p.status(now) == _filter).toList();
          return RefreshIndicator(
            onRefresh: () => ref.refresh(teamAttendanceProvider(key).future),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
              children: [
                _DayBar(
                  day: b.day,
                  today: b.today,
                  onChanged: (d) =>
                      setState(() => _day = d == b.today ? null : d),
                ),
                if (b.projects.length > 1 ||
                    (b.isAdmin && b.projects.isNotEmpty))
                  SizedBox(
                    height: 48,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        ChoiceChip(
                          label: Text(l.everyone),
                          selected: _project == null,
                          onSelected: (_) => setState(() => _project = null),
                        ),
                        for (final p in b.projects) ...[
                          const SizedBox(width: 8),
                          ChoiceChip(
                            key: Key('project-${p.id}'),
                            label: Text(p.name),
                            selected: _project == p.id,
                            onSelected: (_) => setState(() => _project = p.id),
                          ),
                        ],
                      ],
                    ),
                  ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final s in TeamStatus.values)
                      if ((counts[s] ?? 0) > 0)
                        FilterChip(
                          key: Key('filter-${s.name}'),
                          label: Text('${_statusTitle(l, s)} ${counts[s]}'),
                          selected: _filter == s,
                          onSelected: (on) =>
                              setState(() => _filter = on ? s : null),
                        ),
                  ],
                ),
                if (b.requests > 0) ...[
                  const SizedBox(height: 12),
                  Card(
                    child: ListTile(
                      leading: Icon(
                        LucideIcons.inbox,
                        color: lateTint(context),
                      ),
                      title: Text(l.requestsWaiting(b.requests)),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _push(
                        AttendanceRequestsScreen(membership: widget.membership),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                if (shown.isEmpty)
                  EmptyState(icon: LucideIcons.users, title: l.nobodyHere)
                else
                  TileGroup(
                    children: [
                      for (final p in shown)
                        _PersonTile(
                          person: p,
                          now: now,
                          onTap: () => _push(
                            PersonDayScreen(
                              membership: widget.membership,
                              personId: p.id,
                              day: b.day,
                            ),
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

String _statusTitle(AppLocalizations l, TeamStatus s) => switch (s) {
  TeamStatus.pending => l.toReview,
  TeamStatus.late => l.lateLabel,
  TeamStatus.present => l.present,
  TeamStatus.notYet => l.notYet,
  TeamStatus.absent => l.absent,
  TeamStatus.dayOff => l.dayOff,
};

class _DayBar extends StatelessWidget {
  const _DayBar({
    required this.day,
    required this.today,
    required this.onChanged,
  });

  final DateTime day;
  final DateTime today;
  final ValueChanged<DateTime> onChanged;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    return Row(
      children: [
        IconButton(
          tooltip: l.previousDay,
          icon: const Icon(Icons.chevron_left),
          onPressed: () =>
              onChanged(DateTime(day.year, day.month, day.day - 1)),
        ),
        Expanded(
          child: TextButton(
            onPressed: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: day,
                firstDate: DateTime(today.year - 1),
                lastDate: today,
              );
              if (picked != null) onChanged(_dateOnly(picked));
            },
            child: Text(
              dayLabel(context, day),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: l.nextDay,
          icon: const Icon(Icons.chevron_right),
          onPressed: day == today
              ? null
              : () => onChanged(DateTime(day.year, day.month, day.day + 1)),
        ),
      ],
    );
  }
}

class _PersonTile extends StatelessWidget {
  const _PersonTile({required this.person, required this.now, this.onTap});

  final TeamPerson person;
  final DateTime now;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final p = person;
    final r = p.record;
    final status = p.status(now);
    final line = <String>[
      if (r != null)
        r.outAt == null
            ? l.inAt(clockTime(context, r.inAt))
            : l.inOut(clockTime(context, r.inAt), clockTime(context, r.outAt!)),
      if (r == null && status == TeamStatus.notYet && p.shift != null)
        l.shiftStartsAt(clockTime(context, p.shift!.startAt)),
      if (r != null && r.inByName != null && r.inByName != p.name)
        l.recordedBy(r.inByName!),
      if (r == null && p.jobTitle != null) p.jobTitle!,
    ];
    return ListTile(
      key: Key('person-${p.id}'),
      onTap: onTap,
      leading: Avatar(name: p.name),
      title: Row(
        children: [
          Flexible(child: Text(p.name, overflow: TextOverflow.ellipsis)),
          if (!p.hasApp) ...[const SizedBox(width: 6), Tag(l.noApp)],
        ],
      ),
      subtitle: line.isEmpty ? null : Text(line.join(' · ')),
      trailing: AttendanceChip(
        text: teamStatusLabel(l, p, now),
        color: teamStatusColor(context, status),
      ),
    );
  }
}

/// Checking several people in or out at once, each at their own time.
class RollCallScreen extends ConsumerStatefulWidget {
  const RollCallScreen({
    super.key,
    required this.membership,
    required this.board,
  });

  final Membership membership;
  final TeamBoard board;

  @override
  ConsumerState<RollCallScreen> createState() => _RollCallScreenState();
}

class _RollCallScreenState extends ConsumerState<RollCallScreen> {
  bool _checkIn = true;
  final _selected = <String>{};
  final _times = <String, DateTime>{};
  Upload? _photo;

  TeamBoard get _b => widget.board;

  List<TeamPerson> get _people => _checkIn
      ? _b.people.where((p) => p.record == null).toList()
      : _b.people.where((p) => p.record?.open ?? false).toList();

  DateTime _default(TeamPerson p) {
    final now = DateTime.now();
    final day = _b.day;
    final DateTime at;
    if (_checkIn) {
      at =
          p.shift?.startAt ??
          (_b.isToday ? now : DateTime(day.year, day.month, day.day, 9));
    } else {
      at = p.shift?.endAt ?? now;
    }
    return at.isAfter(now) ? now : at;
  }

  DateTime _timeOf(TeamPerson p) => _times[p.id] ?? _default(p);

  Future<void> _pick(TeamPerson p) async {
    final at = await pickAttendanceTime(
      context,
      day: _checkIn ? _b.day : _dateOnly(p.record!.inAt.toLocal()),
      onTime: _checkIn ? p.shift?.startAt : p.shift?.endAt,
      initial: _timeOf(p),
    );
    if (at == null) return;
    setState(() {
      _times[p.id] = at;
      _selected.add(p.id);
    });
  }

  Future<void> _save() async {
    final l = context.l10n;
    final navigator = Navigator.of(context);
    final people = _people.where((p) => _selected.contains(p.id)).toList();
    // The manager's place is kept when the phone gives one.
    LocationFix? at;
    try {
      at = await ref.read(locatorProvider).current();
    } catch (_) {}
    if (!mounted) return;
    RollCallResult? result;
    final ok = await runAction(context, () async {
      result = await ref
          .read(apiProvider)
          .rollCall(
            widget.membership.workspaceId,
            checkIn: _checkIn,
            times: {for (final p in people) p.id: _timeOf(p)},
            at: at,
            photo: _photo,
          );
    });
    if (!ok || !mounted) return;
    showMessage(
      context,
      result!.skipped.isEmpty
          ? l.rollCallDone(result!.recorded)
          : l.rollCallSkipped(result!.recorded, result!.skipped.length),
    );
    refreshTeamAttendance(ref, widget.membership.workspaceId);
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final people = _people;
    final chosen = people.where((p) => _selected.contains(p.id)).length;
    final allChosen = people.isNotEmpty && chosen == people.length;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.rollCall),
        actions: [
          if (people.isNotEmpty)
            TextButton(
              key: const Key('selectAll'),
              onPressed: () => setState(() {
                if (allChosen) {
                  _selected.removeAll(people.map((p) => p.id));
                } else {
                  _selected.addAll(people.map((p) => p.id));
                }
              }),
              child: Text(allChosen ? l.selectNone : l.selectAll),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: true, label: Text(l.checkIn)),
                  ButtonSegment(value: false, label: Text(l.checkOut)),
                ],
                selected: {_checkIn},
                onSelectionChanged: (s) => setState(() {
                  _checkIn = s.first;
                  _selected.clear();
                  _times.clear();
                }),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              _checkIn ? l.rollCallInHint : l.rollCallOutHint,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: people.isEmpty
                ? EmptyState(
                    icon: LucideIcons.users,
                    title: _checkIn ? l.everyoneIsIn : l.nobodyToCheckOut,
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                    children: [
                      TileGroup(
                        children: [for (final p in people) _row(context, p)],
                      ),
                    ],
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  IconButton.filledTonal(
                    key: const Key('groupPhoto'),
                    tooltip: l.groupPhoto,
                    isSelected: _photo != null,
                    icon: Icon(
                      _photo == null ? LucideIcons.camera : LucideIcons.check,
                    ),
                    onPressed: () async {
                      final photo = await ref
                          .read(pickerProvider)
                          .pickImage(camera: true, maxSide: 1280);
                      if (photo != null) setState(() => _photo = photo);
                    },
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: BusyButton(
                      key: const Key('saveRollCall'),
                      label: _checkIn
                          ? l.checkInPeople(chosen)
                          : l.checkOutPeople(chosen),
                      onPressed: chosen == 0 ? null : _save,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, TeamPerson p) {
    final l = context.l10n;
    final at = _timeOf(p);
    final late = _checkIn ? lateFor(p.shift, at, dayOff: p.dayOff) : 0;
    final tint = lateTint(context);
    return ListTile(
      key: Key('roll-${p.id}'),
      onTap: () => setState(() {
        if (!_selected.remove(p.id)) _selected.add(p.id);
      }),
      leading: Checkbox(
        value: _selected.contains(p.id),
        onChanged: (on) => setState(() {
          if (on ?? false) {
            _selected.add(p.id);
          } else {
            _selected.remove(p.id);
          }
        }),
      ),
      title: Text(p.name, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          if (!p.hasApp) l.noApp,
          if (p.jobTitle != null) p.jobTitle!,
          if (late > 0) lateText(l, late),
        ].join(' · '),
        style: late > 0 ? TextStyle(color: tint) : null,
      ),
      trailing: ActionChip(
        key: Key('time-${p.id}'),
        avatar: Icon(
          LucideIcons.clock,
          size: 16,
          color: late > 0 ? tint : null,
        ),
        label: Text(
          clockTime(context, at),
          style: late > 0
              ? TextStyle(color: tint, fontWeight: FontWeight.w600)
              : null,
        ),
        onPressed: () => _pick(p),
      ),
    );
  }
}

/// One person's day, for their manager: the record, changes, and actions.
class PersonDayScreen extends ConsumerWidget {
  const PersonDayScreen({
    super.key,
    required this.membership,
    required this.personId,
    required this.day,
  });

  final Membership membership;
  final String personId;
  final DateTime day;

  String get _ws => membership.workspaceId;

  Future<void> _record(
    BuildContext context,
    WidgetRef ref,
    TeamPerson p, {
    required bool checkIn,
  }) async {
    final l = context.l10n;
    final at = await pickAttendanceTime(
      context,
      day: checkIn ? day : _dateOnly(p.record!.inAt.toLocal()),
      onTime: checkIn ? p.shift?.startAt : p.shift?.endAt,
    );
    if (at == null || !context.mounted) return;
    LocationFix? place;
    try {
      place = await ref.read(locatorProvider).current();
    } catch (_) {}
    if (!context.mounted) return;
    final ok = await runAction(
      context,
      () => ref
          .read(apiProvider)
          .rollCall(_ws, checkIn: checkIn, times: {p.id: at}, at: place),
      done: checkIn
          ? l.checkedInAt(clockTime(context, at))
          : l.checkedOutAt(clockTime(context, at)),
    );
    if (ok) refreshTeamAttendance(ref, _ws);
  }

  Future<void> _editTimes(
    BuildContext context,
    WidgetRef ref,
    AttendanceRecord r,
  ) async {
    final l = context.l10n;
    final answer = await showDialog<(DateTime, DateTime?, String)>(
      context: context,
      builder: (_) => _TimesDialog(record: r),
    );
    if (answer == null || !context.mounted) return;
    final ok = await runAction(
      context,
      () => ref
          .read(apiProvider)
          .setAttendanceTimes(
            r.id,
            inAt: answer.$1,
            outAt: answer.$2,
            note: answer.$3,
          ),
      done: l.saved,
    );
    if (ok) refreshTeamAttendance(ref, _ws);
  }

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    AttendanceRecord r,
  ) async {
    final l = context.l10n;
    final navigator = Navigator.of(context);
    if (!await confirm(
      context,
      message: l.deleteRecordConfirm,
      action: l.delete,
      destructive: true,
    )) {
      return;
    }
    if (!context.mounted) return;
    final ok = await runAction(
      context,
      () => ref.read(apiProvider).deleteAttendanceRecord(r.id),
    );
    if (ok) {
      refreshTeamAttendance(ref, _ws);
      navigator.pop();
    }
  }

  Future<void> _review(
    BuildContext context,
    WidgetRef ref,
    AttendanceRecord r, {
    required bool accept,
  }) async {
    final l = context.l10n;
    final ok = await runAction(
      context,
      () => ref.read(apiProvider).reviewAttendance(r.id, accept: accept),
      done: accept ? l.reviewAcceptedDone : l.reviewRejectedDone,
    );
    if (ok) refreshTeamAttendance(ref, _ws);
  }

  Future<void> _assign(
    BuildContext context,
    WidgetRef ref,
    TeamPerson p,
  ) async {
    final l = context.l10n;
    final board = await ref.read(
      teamAttendanceProvider((_ws, null, null)).future,
    );
    if (!context.mounted) return;
    final answer = await showDialog<(String?, String?)>(
      context: context,
      builder: (_) => _AssignDialog(person: p, board: board),
    );
    if (answer == null || !context.mounted) return;
    final ok = await runAction(
      context,
      () => ref
          .read(apiProvider)
          .assignAttendance(p.id, siteId: answer.$1, shiftId: answer.$2),
      done: l.saved,
    );
    if (ok) refreshTeamAttendance(ref, _ws);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final key = (personId, day);
    final value = ref.watch(personDayProvider(key));
    return Scaffold(
      appBar: AppBar(title: Text(dayLabel(context, day))),
      body: AsyncView(
        value: value,
        onRetry: () => ref.invalidate(personDayProvider(key)),
        builder: (d) {
          final p = d.person;
          final r = p.record;
          final status = p.status();
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
            children: [
              Card(
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  leading: Avatar(name: p.name, radius: 24),
                  title: Text(
                    p.name,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    [
                      if (!p.hasApp) l.noApp,
                      if (p.jobTitle != null) p.jobTitle!,
                      if (p.projectName != null) p.projectName!,
                      if (p.shift != null)
                        '${p.shift!.name} ${clockTime(context, p.shift!.startAt)}',
                    ].join(' · '),
                  ),
                  trailing: AttendanceChip(
                    text: teamStatusLabel(l, p),
                    color: teamStatusColor(context, status),
                  ),
                ),
              ),
              if (r != null) ...[
                SectionTitle(l.theDay),
                TileGroup(
                  children: [
                    ListTile(
                      leading: const Icon(LucideIcons.logIn),
                      title: Text(l.inAt(clockTime(context, r.inAt))),
                      subtitle: Text(
                        [
                          if (r.lateMinutes > 0) lateText(l, r.lateMinutes),
                          if (r.inByName != null) l.recordedBy(r.inByName!),
                        ].join(' · '),
                      ),
                    ),
                    if (r.inSite != null || r.outside)
                      ListTile(
                        leading: Icon(
                          r.outside
                              ? LucideIcons.mapPinOff
                              : LucideIcons.mapPin,
                          color: r.outside ? lateTint(context) : null,
                        ),
                        title: Text(
                          r.outside
                              ? l.awayFromSite(
                                  r.inSite ?? '',
                                  r.inDistanceM ?? 0,
                                )
                              : r.inSite!,
                        ),
                        subtitle: r.reason == null
                            ? null
                            : Text(
                                [
                                  reasonLabel(l, r.reason!),
                                  if (r.reasonNote != null) r.reasonNote!,
                                ].join(' · '),
                              ),
                      ),
                    ListTile(
                      leading: const Icon(LucideIcons.logOut),
                      title: Text(
                        r.outAt == null
                            ? l.stillAtWork
                            : l.outAt(clockTime(context, r.outAt!)),
                      ),
                      subtitle: Text(
                        [
                          workedText(l, r.worked()),
                          if (r.outByName != null && r.outAt != null)
                            l.recordedBy(r.outByName!),
                        ].join(' · '),
                      ),
                    ),
                  ],
                ),
                if (d.canEdit && r.review == AttendanceReview.pending) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          key: const Key('rejectCheckIn'),
                          onPressed: () =>
                              _review(context, ref, r, accept: false),
                          child: Text(l.reject),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          key: const Key('acceptCheckIn'),
                          onPressed: () =>
                              _review(context, ref, r, accept: true),
                          child: Text(l.accept),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
              if (d.fix != null && d.fix!.status == FixStatus.pending) ...[
                SectionTitle(l.correctionRequest),
                _FixCard(
                  membership: membership,
                  fix: d.fix!,
                  canDecide: d.canEdit,
                ),
              ],
              if (d.canEdit) ...[
                SectionTitle(l.actions),
                TileGroup(
                  children: [
                    if (r == null)
                      ListTile(
                        key: const Key('recordCheckIn'),
                        leading: const Icon(LucideIcons.logIn),
                        title: Text(l.recordCheckIn),
                        onTap: () => _record(context, ref, p, checkIn: true),
                      ),
                    if (r != null && r.open)
                      ListTile(
                        key: const Key('recordCheckOut'),
                        leading: const Icon(LucideIcons.logOut),
                        title: Text(l.recordCheckOut),
                        onTap: () => _record(context, ref, p, checkIn: false),
                      ),
                    if (r != null)
                      ListTile(
                        key: const Key('editTimes'),
                        leading: const Icon(LucideIcons.pencil),
                        title: Text(l.editTimes),
                        onTap: () => _editTimes(context, ref, r),
                      ),
                    if (p.hasApp)
                      ListTile(
                        key: const Key('assignAttendance'),
                        leading: const Icon(LucideIcons.mapPinned),
                        title: Text(l.branchAndShift),
                        subtitle: Text(
                          [
                            p.siteName ?? l.anyBranch,
                            p.shift?.name ?? l.workspaceDefaultShift,
                          ].join(' · '),
                        ),
                        onTap: () => _assign(context, ref, p),
                      )
                    else
                      ListTile(
                        key: const Key('editWorker'),
                        leading: const Icon(LucideIcons.userPen),
                        title: Text(l.editWorker),
                        onTap: () async {
                          final board = await ref.read(
                            teamAttendanceProvider((_ws, null, null)).future,
                          );
                          if (!context.mounted) return;
                          await Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => WorkerEditorScreen(
                                membership: membership,
                                board: board,
                                person: p,
                              ),
                            ),
                          );
                        },
                      ),
                    if (r != null)
                      ListTile(
                        key: const Key('deleteRecord'),
                        leading: Icon(
                          LucideIcons.trash2,
                          color: theme.colorScheme.error,
                        ),
                        title: Text(
                          l.deleteRecord,
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                        onTap: () => _delete(context, ref, r),
                      ),
                  ],
                ),
              ],
              if (d.edits.isNotEmpty) ...[
                SectionTitle(l.changes),
                TileGroup(
                  children: [
                    for (final e in d.edits)
                      ListTile(
                        dense: true,
                        leading: const Icon(LucideIcons.history, size: 20),
                        title: Text(_editText(context, e)),
                        subtitle: Text(
                          [
                            if (e.byName != null) e.byName!,
                            fullTime(context, e.at),
                            if (e.detail != null && e.field != 'review')
                              e.detail!,
                          ].join(' · '),
                        ),
                      ),
                  ],
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  String _editText(BuildContext context, AttendanceEdit e) {
    final l = context.l10n;
    String t(DateTime? d) => d == null ? '-' : clockTime(context, d);
    return switch (e.field) {
      'in' => l.editedIn(t(e.oldAt), t(e.newAt)),
      'out' => l.editedOut(t(e.oldAt), t(e.newAt)),
      'review' => e.detail == 'accepted' ? l.reviewAccepted : l.reviewRejected,
      _ => l.recordDeleted(t(e.oldAt)),
    };
  }
}

class _TimesDialog extends StatefulWidget {
  const _TimesDialog({required this.record});

  final AttendanceRecord record;

  @override
  State<_TimesDialog> createState() => _TimesDialogState();
}

class _TimesDialogState extends State<_TimesDialog> {
  late DateTime _in = widget.record.inAt.toLocal();
  late DateTime? _out = widget.record.outAt?.toLocal();
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<DateTime?> _pick(DateTime? current, DateTime base) async {
    final l = context.l10n;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current ?? DateTime.now()),
    );
    if (t == null || !mounted) return null;
    var at = DateTime(base.year, base.month, base.day, t.hour, t.minute);
    // A check-out before the check-in is the next morning (a night shift).
    if (current == _out && !at.isAfter(_in)) {
      at = at.add(const Duration(days: 1));
    }
    if (at.isAfter(DateTime.now().add(const Duration(minutes: 1)))) {
      showMessage(context, l.errorFutureTime);
      return null;
    }
    return at;
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return AlertDialog(
      title: Text(l.editTimes),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            key: const Key('editIn'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(LucideIcons.logIn),
            title: Text(l.checkIn),
            trailing: Text(clockTime(context, _in)),
            onTap: () async {
              final at = await _pick(_in, _in);
              if (at != null) setState(() => _in = at);
            },
          ),
          ListTile(
            key: const Key('editOut'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(LucideIcons.logOut),
            title: Text(l.checkOut),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_out == null ? l.notSet : clockTime(context, _out!)),
                if (_out != null)
                  IconButton(
                    tooltip: l.clear,
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => setState(() => _out = null),
                  ),
              ],
            ),
            onTap: () async {
              final at = await _pick(_out, _in);
              if (at != null) setState(() => _out = at);
            },
          ),
          TextField(
            key: const Key('editNote'),
            controller: _note,
            maxLength: 300,
            decoration: InputDecoration(labelText: l.changeReason),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.cancel),
        ),
        TextButton(
          key: const Key('saveTimes'),
          onPressed: _out != null && !_out!.isAfter(_in)
              ? null
              : () => Navigator.pop(context, (_in, _out, _note.text.trim())),
          child: Text(l.save),
        ),
      ],
    );
  }
}

class _AssignDialog extends StatefulWidget {
  const _AssignDialog({required this.person, required this.board});

  final TeamPerson person;
  final TeamBoard board;

  @override
  State<_AssignDialog> createState() => _AssignDialogState();
}

class _AssignDialogState extends State<_AssignDialog> {
  late String? _site = widget.person.siteId;
  late String? _shift = widget.person.shiftId;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return AlertDialog(
      title: Text(l.branchAndShift),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _OptionField(
            label: l.branch,
            none: l.anyBranch,
            options: widget.board.sites,
            value: _site,
            onChanged: (v) => setState(() => _site = v),
          ),
          const SizedBox(height: 12),
          _OptionField(
            label: l.shift,
            none: l.workspaceDefaultShift,
            options: widget.board.shifts,
            value: _shift,
            onChanged: (v) => setState(() => _shift = v),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, (_site, _shift)),
          child: Text(l.save),
        ),
      ],
    );
  }
}

/// A dropdown of projects, branches or shifts, with a "none" choice when
/// [none] is given.
class _OptionField extends StatelessWidget {
  const _OptionField({
    super.key,
    required this.label,
    required this.options,
    required this.value,
    required this.onChanged,
    this.none,
  });

  final String label;
  final String? none;
  final List<AttendanceOption> options;
  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final known = value == null || options.any((o) => o.id == value);
    return DropdownButtonFormField<String?>(
      initialValue: known ? value : null,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        if (none != null)
          DropdownMenuItem<String?>(value: null, child: Text(none!)),
        for (final o in options)
          DropdownMenuItem<String?>(
            value: o.id,
            child: Text(o.name, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: onChanged,
    );
  }
}

/// A correction someone asked for, with accept and reject for a manager.
class _FixCard extends ConsumerWidget {
  const _FixCard({
    required this.membership,
    required this.fix,
    required this.canDecide,
    this.showName = false,
  });

  final Membership membership;
  final AttendanceFix fix;
  final bool canDecide;
  final bool showName;

  Future<void> _decide(
    BuildContext context,
    WidgetRef ref, {
    required bool accept,
  }) async {
    final l = context.l10n;
    final ok = await runAction(
      context,
      () => ref.read(apiProvider).decideAttendanceFix(fix.id, accept: accept),
      done: accept ? l.fixAcceptedDone : l.fixRejectedDone,
    );
    if (ok) refreshTeamAttendance(ref, membership.workspaceId);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final r = fix.record;
    String t(DateTime? d) => d == null ? '-' : clockTime(context, d);
    return Card(
      key: Key('fix-${fix.id}'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showName)
              Text(
                fix.name ?? '',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            Text(dayLabel(context, fix.day), style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            Text(
              l.fixAsked(
                fix.inAt == null ? t(r?.inAt) : t(fix.inAt),
                fix.outAt == null ? t(r?.outAt) : t(fix.outAt),
              ),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            Text(
              r == null ? l.fixNoRecord : l.fixRecorded(t(r.inAt), t(r.outAt)),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Text('“${fix.note}”'),
            if (canDecide) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      key: Key('rejectFix-${fix.id}'),
                      onPressed: () => _decide(context, ref, accept: false),
                      child: Text(l.reject),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      key: Key('acceptFix-${fix.id}'),
                      onPressed: () => _decide(context, ref, accept: true),
                      child: Text(l.accept),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Check-ins from outside to review, and corrections to decide.
class AttendanceRequestsScreen extends ConsumerWidget {
  const AttendanceRequestsScreen({super.key, required this.membership});

  final Membership membership;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final ws = membership.workspaceId;
    final value = ref.watch(attendanceRequestsProvider(ws));
    return Scaffold(
      appBar: AppBar(title: Text(l.attendanceRequests)),
      body: AsyncView(
        value: value,
        onRetry: () => ref.invalidate(attendanceRequestsProvider(ws)),
        builder: (q) {
          if (q.isEmpty) {
            return EmptyState(
              icon: LucideIcons.inbox,
              title: l.noRequests,
              body: l.noRequestsBody,
            );
          }
          return RefreshIndicator(
            onRefresh: () => ref.refresh(attendanceRequestsProvider(ws).future),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
              children: [
                if (q.reviews.isNotEmpty) ...[
                  SectionTitle(l.checkInsToReview),
                  for (final (r, name) in q.reviews)
                    _ReviewCard(membership: membership, record: r, name: name),
                ],
                if (q.fixes.isNotEmpty) ...[
                  SectionTitle(l.correctionsToDecide),
                  for (final f in q.fixes)
                    _FixCard(
                      membership: membership,
                      fix: f,
                      canDecide: true,
                      showName: true,
                    ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ReviewCard extends ConsumerWidget {
  const _ReviewCard({
    required this.membership,
    required this.record,
    required this.name,
  });

  final Membership membership;
  final AttendanceRecord record;
  final String name;

  Future<void> _review(
    BuildContext context,
    WidgetRef ref, {
    required bool accept,
  }) async {
    final l = context.l10n;
    final ok = await runAction(
      context,
      () => ref.read(apiProvider).reviewAttendance(record.id, accept: accept),
      done: accept ? l.reviewAcceptedDone : l.reviewRejectedDone,
    );
    if (ok) refreshTeamAttendance(ref, membership.workspaceId);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final r = record;
    return Card(
      key: Key('review-${r.id}'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              name,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              '${dayLabel(context, r.day)} · ${l.inAt(clockTime(context, r.inAt))}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(LucideIcons.mapPinOff, size: 16, color: lateTint(context)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    l.awayFromSite(r.inSite ?? '', r.inDistanceM ?? 0),
                  ),
                ),
              ],
            ),
            if (r.reason != null) ...[
              const SizedBox(height: 4),
              Text(
                [
                  reasonLabel(l, r.reason!),
                  if (r.reasonNote != null) '“${r.reasonNote}”',
                ].join(' · '),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    key: Key('reject-${r.id}'),
                    onPressed: () => _review(context, ref, accept: false),
                    child: Text(l.reject),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    key: Key('accept-${r.id}'),
                    onPressed: () => _review(context, ref, accept: true),
                    child: Text(l.accept),
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

/// Workers without the app: added once, then checked in by a manager.
class WorkersScreen extends ConsumerWidget {
  const WorkersScreen({super.key, required this.membership});

  final Membership membership;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final key = (membership.workspaceId, null, null);
    final value = ref.watch(teamAttendanceProvider(key));
    final b = value.value;
    return Scaffold(
      appBar: AppBar(title: Text(l.workersWithoutApp)),
      floatingActionButton: b == null
          ? null
          : FloatingActionButton.extended(
              key: const Key('addWorker'),
              icon: const Icon(LucideIcons.userPlus),
              label: Text(l.addWorker),
              onPressed: () {
                if (!b.canAddWorker) {
                  showMessage(context, l.errorWorkersLimit);
                  return;
                }
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        WorkerEditorScreen(membership: membership, board: b),
                  ),
                );
              },
            ),
      body: AsyncView(
        value: value,
        onRetry: () => ref.invalidate(teamAttendanceProvider(key)),
        builder: (b) {
          final workers = b.people.where((p) => !p.hasApp).toList();
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
            children: [
              Card(
                child: ListTile(
                  leading: const Icon(LucideIcons.info),
                  title: Text(
                    b.workersFree == null
                        ? l.workersCount(b.workersUsed)
                        : l.workersQuota(b.workersUsed, b.workersFree!),
                  ),
                  subtitle: Text(
                    b.workersFree != null && b.extraWorkerUsd > 0
                        ? l.workersExtraPrice(usd(context, b.extraWorkerUsd))
                        : l.workersHint,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (workers.isEmpty)
                EmptyState(
                  icon: LucideIcons.hardHat,
                  title: l.noWorkers,
                  body: l.noWorkersBody,
                )
              else
                TileGroup(
                  children: [
                    for (final p in workers)
                      ListTile(
                        key: Key('worker-${p.id}'),
                        leading: Avatar(name: p.name),
                        title: Text(p.name),
                        subtitle: Text(
                          [
                            if (p.jobTitle != null) p.jobTitle!,
                            if (p.projectName != null) p.projectName!,
                            if (p.code != null) p.code!,
                          ].join(' · '),
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => WorkerEditorScreen(
                              membership: membership,
                              board: b,
                              person: p,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
            ],
          );
        },
      ),
    );
  }
}

class WorkerEditorScreen extends ConsumerStatefulWidget {
  const WorkerEditorScreen({
    super.key,
    required this.membership,
    required this.board,
    this.person,
  });

  final Membership membership;
  final TeamBoard board;
  final TeamPerson? person;

  @override
  ConsumerState<WorkerEditorScreen> createState() => _WorkerEditorState();
}

class _WorkerEditorState extends ConsumerState<WorkerEditorScreen> {
  late final _name = TextEditingController(text: widget.person?.name ?? '');
  late final _job = TextEditingController(text: widget.person?.jobTitle ?? '');
  late final _phone = TextEditingController(text: widget.person?.phone ?? '');
  late final _code = TextEditingController(text: widget.person?.code ?? '');
  late String? _project =
      widget.person?.projectId ??
      (widget.board.isAdmin || widget.board.projects.length != 1
          ? null
          : widget.board.projects.single.id);
  late String? _site = widget.person?.siteId;
  late String? _shift = widget.person?.shiftId;

  bool get _isNew => widget.person == null;

  @override
  void dispose() {
    _name.dispose();
    _job.dispose();
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final l = context.l10n;
    final navigator = Navigator.of(context);
    String? text(TextEditingController c) =>
        c.text.trim().isEmpty ? null : c.text.trim();
    final ok = await runAction(
      context,
      () => ref
          .read(apiProvider)
          .saveWorker(
            widget.membership.workspaceId,
            id: widget.person?.id,
            name: _name.text.trim(),
            jobTitle: text(_job),
            phone: text(_phone),
            code: text(_code),
            projectId: _project,
            siteId: _site,
            shiftId: _shift,
          ),
      done: _isNew ? l.workerAdded : l.saved,
    );
    if (!ok) return;
    refreshTeamAttendance(ref, widget.membership.workspaceId);
    navigator.pop();
  }

  Future<void> _remove() async {
    final l = context.l10n;
    final navigator = Navigator.of(context);
    if (!await confirm(
      context,
      message: l.removeWorkerConfirm(widget.person!.name),
      action: l.remove,
      destructive: true,
    )) {
      return;
    }
    if (!mounted) return;
    final ok = await runAction(
      context,
      () => ref.read(apiProvider).removeWorker(widget.person!.id),
    );
    if (!ok) return;
    refreshTeamAttendance(ref, widget.membership.workspaceId);
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final b = widget.board;
    final needsProject = !b.isAdmin;
    final ready =
        _name.text.trim().isNotEmpty && (!needsProject || _project != null);
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? l.addWorker : l.editWorker),
        actions: [
          if (!_isNew)
            IconButton(
              key: const Key('removeWorker'),
              tooltip: l.remove,
              icon: const Icon(LucideIcons.userMinus),
              onPressed: _remove,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          TextField(
            key: const Key('workerName'),
            controller: _name,
            maxLength: 100,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(labelText: l.fullNameLabel),
            onChanged: (_) => setState(() {}),
          ),
          TextField(
            key: const Key('workerJob'),
            controller: _job,
            maxLength: 60,
            decoration: InputDecoration(labelText: l.jobTitle),
          ),
          TextField(
            key: const Key('workerPhone'),
            controller: _phone,
            maxLength: 30,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(labelText: l.phoneOptional),
          ),
          TextField(
            key: const Key('workerCode'),
            controller: _code,
            maxLength: 30,
            decoration: InputDecoration(labelText: l.employeeCode),
          ),
          const SizedBox(height: 8),
          _OptionField(
            key: const Key('workerProject'),
            label: l.project,
            none: needsProject ? null : l.noProject,
            options: b.projects,
            value: _project,
            onChanged: (v) => setState(() => _project = v),
          ),
          const SizedBox(height: 16),
          _OptionField(
            label: l.branch,
            none: l.anyBranch,
            options: b.sites,
            value: _site,
            onChanged: (v) => setState(() => _site = v),
          ),
          const SizedBox(height: 16),
          _OptionField(
            label: l.shift,
            none: l.workspaceDefaultShift,
            options: b.shifts,
            value: _shift,
            onChanged: (v) => setState(() => _shift = v),
          ),
          if (_isNew && b.nextWorkerBilled) ...[
            const SizedBox(height: 16),
            Card(
              child: ListTile(
                leading: Icon(LucideIcons.receipt, color: lateTint(context)),
                title: Text(l.workerBilled(usd(context, b.extraWorkerUsd))),
              ),
            ),
          ],
          const SizedBox(height: 24),
          BusyButton(
            key: const Key('saveWorker'),
            label: l.save,
            onPressed: ready ? _save : null,
          ),
        ],
      ),
    );
  }
}
