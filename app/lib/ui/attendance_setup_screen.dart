import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/attendance_models.dart';
import '../data/models.dart';
import '../state/attendance_providers.dart';
import '../state/providers.dart';
import 'attendance_screen.dart';
import 'chat_format.dart';
import 'widgets.dart';

void openAttendanceSetup(BuildContext context, Membership membership) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AttendanceSetupScreen(membership: membership),
      ),
    );

/// 9:00 ص, for a time of day.
String clockOf(BuildContext context, TimeOfDay t) =>
    clockTime(context, DateTime(2000, 1, 1, t.hour, t.minute));

/// Saturday first, as weeks start in Egypt and the Gulf; 0 = Sunday.
const _weekOrder = [6, 0, 1, 2, 3, 4, 5];

/// Workspace owners and admins set up attendance: shifts, branches, days off
/// and the rules.
class AttendanceSetupScreen extends ConsumerWidget {
  const AttendanceSetupScreen({super.key, required this.membership});

  final Membership membership;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final ws = membership.workspaceId;
    final setup = ref.watch(attendanceSetupProvider(ws));
    return Scaffold(
      appBar: AppBar(title: Text(l.attendanceSetup)),
      body: AsyncView(
        value: setup,
        onRetry: () => ref.invalidate(attendanceSetupProvider(ws)),
        builder: (s) => s.started
            ? _SetupList(workspaceId: ws, setup: s)
            : _Intro(workspaceId: ws),
      ),
    );
  }
}

void _refresh(WidgetRef ref, String ws) {
  ref.invalidate(attendanceSetupProvider(ws));
  ref.invalidate(attendanceTodayProvider(ws));
}

class _Intro extends ConsumerWidget {
  const _Intro({required this.workspaceId});

  final String workspaceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        EmptyState(
          icon: LucideIcons.clock,
          title: l.attendanceIntroTitle,
          body: l.attendanceIntroBody,
        ),
        BusyButton(
          key: const Key('enableAttendance'),
          label: l.enableAttendance,
          onPressed: () async {
            final ok = await runAction(
              context,
              () => ref
                  .read(apiProvider)
                  .enableAttendance(workspaceId, l.defaultShiftName),
            );
            if (ok) _refresh(ref, workspaceId);
          },
        ),
      ],
    );
  }
}

class _SetupList extends ConsumerWidget {
  const _SetupList({required this.workspaceId, required this.setup});

  final String workspaceId;
  final AttendanceSetup setup;

  Future<void> _save(
    BuildContext context,
    WidgetRef ref,
    AttendanceSetup next,
  ) async {
    final ok = await runAction(
      context,
      () => ref.read(apiProvider).saveAttendanceSettings(workspaceId, next),
    );
    if (ok) _refresh(ref, workspaceId);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final locale = Localizations.localeOf(context).languageCode;
    // 2023-01-01 was a Sunday, so day 0 + d is weekday d.
    String dayName(int d) =>
        DateFormat('EEEE', locale).format(DateTime(2023, 1, 1 + d));
    final s = setup;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
      children: [
        Card(
          child: SwitchListTile(
            key: const Key('attendanceEnabled'),
            secondary: const Icon(LucideIcons.clock),
            title: Text(l.attendanceOn),
            subtitle: Text(l.attendanceOnHint),
            value: s.enabled,
            onChanged: (v) => _save(context, ref, s.copyWith(enabled: v)),
          ),
        ),

        SectionTitle(l.shifts),
        TileGroup(
          children: [
            for (final sh in s.shifts)
              ListTile(
                leading: const Icon(LucideIcons.sunrise),
                title: Row(
                  children: [
                    Flexible(child: Text(sh.name)),
                    if (sh.id == s.defaultShiftId) ...[
                      const SizedBox(width: 8),
                      Tag(l.defaultShift, strong: true),
                    ],
                  ],
                ),
                subtitle: Text(
                  l.shiftDetails(
                    clockOf(context, sh.start),
                    clockOf(context, sh.end),
                    sh.graceMinutes,
                  ),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _editShift(context, ref, sh),
              ),
            ListTile(
              key: const Key('addShift'),
              leading: const Icon(Icons.add),
              title: Text(l.addShift),
              onTap: () => _editShift(context, ref, null),
            ),
          ],
        ),

        SectionTitle(l.sites),
        TileGroup(
          children: [
            for (final site in s.sites)
              ListTile(
                leading: Icon(
                  site.isField ? LucideIcons.globe : LucideIcons.mapPin,
                ),
                title: Text(site.name),
                subtitle: Text(
                  site.isField ? l.fieldSiteHint : l.radiusLine(site.radiusM),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        SiteEditorScreen(workspaceId: workspaceId, site: site),
                  ),
                ),
              ),
            ListTile(
              key: const Key('addSite'),
              leading: const Icon(Icons.add),
              title: Text(l.addSite),
              subtitle: s.sites.isEmpty ? Text(l.noSitesHint) : null,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SiteEditorScreen(workspaceId: workspaceId),
                ),
              ),
            ),
          ],
        ),

        SectionTitle(l.weeklyDaysOff),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final d in _weekOrder)
                  FilterChip(
                    label: Text(dayName(d)),
                    selected: s.weekendDays.contains(d),
                    onSelected: (on) => _save(
                      context,
                      ref,
                      s.copyWith(
                        weekendDays: on
                            ? {...s.weekendDays, d}
                            : ({...s.weekendDays}..remove(d)),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),

        SectionTitle(l.attendanceRules),
        TileGroup(
          children: [
            SwitchListTile(
              key: const Key('ramadan'),
              secondary: const Icon(LucideIcons.moon),
              title: Text(l.ramadanHours),
              subtitle: Text(
                s.ramadan
                    ? l.ramadanLine(
                        dayMonth(context, s.ramadanFrom!),
                        dayMonth(context, s.ramadanTo!),
                        clockOf(context, s.ramadanStart!),
                        clockOf(context, s.ramadanEnd!),
                      )
                    : l.ramadanHint,
              ),
              value: s.ramadan,
              onChanged: (on) async {
                if (!on) {
                  return _save(context, ref, s.copyWith(clearRamadan: true));
                }
                final r = await _pickRamadan(context, s);
                if (r != null && context.mounted) {
                  await _save(context, ref, s.copyWith(ramadan: r));
                }
              },
            ),
            if (s.ramadan)
              ListTile(
                leading: const SizedBox(width: 24),
                title: Text(l.changeRamadan),
                onTap: () async {
                  final r = await _pickRamadan(context, s);
                  if (r != null && context.mounted) {
                    await _save(context, ref, s.copyWith(ramadan: r));
                  }
                },
              ),
            SwitchListTile(
              key: const Key('requireSelfie'),
              secondary: const Icon(LucideIcons.camera),
              title: Text(l.requireSelfie),
              subtitle: Text(l.requireSelfieHint),
              value: s.requireSelfie,
              onChanged: (v) =>
                  _save(context, ref, s.copyWith(requireSelfie: v)),
            ),
            SwitchListTile(
              key: const Key('allowOutside'),
              secondary: const Icon(LucideIcons.mapPinned),
              title: Text(l.allowOutside),
              subtitle: Text(l.allowOutsideHint),
              value: s.allowOutside,
              onChanged: (v) =>
                  _save(context, ref, s.copyWith(allowOutside: v)),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
          child: Text(
            l.attendancePrivacyNote,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _editShift(
    BuildContext context,
    WidgetRef ref,
    AttendanceShift? shift,
  ) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) =>
          _ShiftDialog(workspaceId: workspaceId, shift: shift, setup: setup),
    );
    if (saved == true) _refresh(ref, workspaceId);
  }

  /// Ramadan's first and last days, then its hours.
  Future<(DateTime, DateTime, TimeOfDay, TimeOfDay)?> _pickRamadan(
    BuildContext context,
    AttendanceSetup s,
  ) async {
    final l = context.l10n;
    final now = DateTime.now();
    final range = await showDateRangePicker(
      context: context,
      helpText: l.ramadanDays,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 2),
      initialDateRange: s.ramadan
          ? DateTimeRange(start: s.ramadanFrom!, end: s.ramadanTo!)
          : null,
    );
    if (range == null || !context.mounted) return null;
    final start = await showTimePicker(
      context: context,
      helpText: l.ramadanStart,
      initialTime: s.ramadanStart ?? const TimeOfDay(hour: 10, minute: 0),
    );
    if (start == null || !context.mounted) return null;
    final end = await showTimePicker(
      context: context,
      helpText: l.ramadanEnd,
      initialTime: s.ramadanEnd ?? const TimeOfDay(hour: 15, minute: 0),
    );
    if (end == null) return null;
    return (range.start, range.end, start, end);
  }
}

class _ShiftDialog extends ConsumerStatefulWidget {
  const _ShiftDialog({
    required this.workspaceId,
    required this.shift,
    required this.setup,
  });

  final String workspaceId;
  final AttendanceShift? shift;
  final AttendanceSetup setup;

  @override
  ConsumerState<_ShiftDialog> createState() => _ShiftDialogState();
}

class _ShiftDialogState extends ConsumerState<_ShiftDialog> {
  late final _name = TextEditingController(text: widget.shift?.name ?? '');
  late TimeOfDay _start =
      widget.shift?.start ?? const TimeOfDay(hour: 9, minute: 0);
  late TimeOfDay _end =
      widget.shift?.end ?? const TimeOfDay(hour: 17, minute: 0);
  late int _grace = widget.shift?.graceMinutes ?? 15;
  late bool _default =
      widget.shift != null && widget.shift!.id == widget.setup.defaultShiftId;

  static const _graces = [0, 5, 10, 15, 20, 30, 45, 60];

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final api = ref.read(apiProvider);
    final navigator = Navigator.of(context);
    final ok = await runAction(context, () async {
      final id = await api.saveShift(
        widget.workspaceId,
        id: widget.shift?.id,
        name: _name.text.trim(),
        start: _start,
        end: _end,
        graceMinutes: _grace,
      );
      final wasDefault =
          widget.shift != null &&
          widget.shift!.id == widget.setup.defaultShiftId;
      if (_default != wasDefault) {
        await api.saveAttendanceSettings(
          widget.workspaceId,
          _default
              ? widget.setup.copyWith(defaultShiftId: id)
              : AttendanceSetup(
                  enabled: widget.setup.enabled,
                  weekendDays: widget.setup.weekendDays,
                  requireSelfie: widget.setup.requireSelfie,
                  allowOutside: widget.setup.allowOutside,
                  reminders: widget.setup.reminders,
                  ramadanFrom: widget.setup.ramadanFrom,
                  ramadanTo: widget.setup.ramadanTo,
                  ramadanStart: widget.setup.ramadanStart,
                  ramadanEnd: widget.setup.ramadanEnd,
                ),
        );
      }
    });
    if (ok) navigator.pop(true);
  }

  Future<void> _delete() async {
    final l = context.l10n;
    final navigator = Navigator.of(context);
    if (!await confirm(
      context,
      message: l.deleteShiftConfirm(widget.shift!.name),
      action: l.delete,
      destructive: true,
    )) {
      return;
    }
    if (!mounted) return;
    final ok = await runAction(
      context,
      () => ref
          .read(apiProvider)
          .deleteShift(widget.workspaceId, widget.shift!.id),
    );
    if (ok) navigator.pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    Future<void> pick(bool start) async {
      final t = await showTimePicker(
        context: context,
        initialTime: start ? _start : _end,
      );
      if (t != null) setState(() => start ? _start = t : _end = t);
    }

    return AlertDialog(
      title: Text(widget.shift == null ? l.addShift : l.editShift),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const Key('shiftName'),
              controller: _name,
              autofocus: widget.shift == null,
              maxLength: 60,
              decoration: InputDecoration(labelText: l.shiftName),
              onChanged: (_) => setState(() {}),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l.shiftStart),
              trailing: Text(clockOf(context, _start)),
              onTap: () => pick(true),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l.shiftEnd),
              trailing: Text(clockOf(context, _end)),
              onTap: () => pick(false),
            ),
            DropdownButtonFormField<int>(
              initialValue: _graces.contains(_grace) ? _grace : 15,
              decoration: InputDecoration(labelText: l.graceMinutes),
              items: [
                for (final g in _graces)
                  DropdownMenuItem(value: g, child: Text(l.minutesLong(g))),
              ],
              onChanged: (g) => setState(() => _grace = g ?? 15),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _default,
              title: Text(l.makeDefaultShift),
              subtitle: Text(l.defaultShiftHint),
              onChanged: (v) => setState(() => _default = v ?? false),
            ),
          ],
        ),
      ),
      actions: [
        if (widget.shift != null)
          TextButton(
            onPressed: _delete,
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(l.delete),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l.cancel),
        ),
        TextButton(
          key: const Key('saveShift'),
          onPressed: _name.text.trim().isEmpty || _start == _end ? null : _save,
          child: Text(l.save),
        ),
      ],
    );
  }
}

/// A branch: its name, and its point and radius, or "field" for no fixed
/// place.
class SiteEditorScreen extends ConsumerStatefulWidget {
  const SiteEditorScreen({super.key, required this.workspaceId, this.site});

  final String workspaceId;
  final AttendanceSite? site;

  @override
  ConsumerState<SiteEditorScreen> createState() => _SiteEditorScreenState();
}

class _SiteEditorScreenState extends ConsumerState<SiteEditorScreen> {
  late final _name = TextEditingController(text: widget.site?.name ?? '');
  late bool _field = widget.site?.isField ?? false;
  late double? _lat = widget.site?.lat;
  late double? _lng = widget.site?.lng;
  late double _radius = (widget.site?.radiusM ?? 150).toDouble().clamp(
    50,
    1000,
  );
  int? _accuracy;
  bool _locating = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _valid =>
      _name.text.trim().isNotEmpty &&
      (_field || (_lat != null && _lng != null));

  Future<void> _here() async {
    final l = context.l10n;
    setState(() => _locating = true);
    try {
      final fix = await ref.read(locatorProvider).current();
      if (!mounted) return;
      setState(() {
        _lat = fix.lat;
        _lng = fix.lng;
        _accuracy = fix.accuracyM;
      });
    } catch (e) {
      if (mounted) showMessage(context, locationError(l, e));
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _save() async {
    final navigator = Navigator.of(context);
    final ok = await runAction(
      context,
      () => ref
          .read(apiProvider)
          .saveSite(
            widget.workspaceId,
            id: widget.site?.id,
            name: _name.text.trim(),
            lat: _field ? null : _lat,
            lng: _field ? null : _lng,
            radiusM: _radius.round(),
          ),
    );
    if (ok) {
      _refresh(ref, widget.workspaceId);
      navigator.pop();
    }
  }

  Future<void> _delete() async {
    final l = context.l10n;
    final navigator = Navigator.of(context);
    if (!await confirm(
      context,
      message: l.deleteSiteConfirm(widget.site!.name),
      action: l.delete,
      destructive: true,
    )) {
      return;
    }
    if (!mounted) return;
    final ok = await runAction(
      context,
      () =>
          ref.read(apiProvider).deleteSite(widget.workspaceId, widget.site!.id),
    );
    if (ok) {
      _refresh(ref, widget.workspaceId);
      navigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.site == null ? l.addSite : l.editSite),
        actions: [
          if (widget.site != null)
            IconButton(
              tooltip: l.delete,
              icon: const Icon(Icons.delete_outline),
              onPressed: _delete,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            key: const Key('siteName'),
            controller: _name,
            maxLength: 80,
            decoration: InputDecoration(labelText: l.siteName),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: false,
                icon: const Icon(LucideIcons.mapPin),
                label: Text(l.fixedPlace),
              ),
              ButtonSegment(
                value: true,
                icon: const Icon(LucideIcons.globe),
                label: Text(l.fieldSite),
              ),
            ],
            selected: {_field},
            onSelectionChanged: (v) => setState(() => _field = v.first),
          ),
          const SizedBox(height: 16),
          if (_field)
            Text(l.fieldSiteHint, style: theme.textTheme.bodyMedium)
          else ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l.sitePlace, style: theme.textTheme.labelLarge),
                    const SizedBox(height: 6),
                    if (_lat == null)
                      Text(
                        l.sitePlaceHint,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      )
                    else ...[
                      LtrLine(
                        '${_lat!.toStringAsFixed(6)}, ${_lng!.toStringAsFixed(6)}',
                      ),
                      if (_accuracy != null)
                        Text(
                          l.accuracyLine(_accuracy!),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.tonalIcon(
                          key: const Key('useMyLocation'),
                          onPressed: _locating ? null : _here,
                          icon: _locating
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(LucideIcons.locateFixed),
                          label: Text(l.useMyLocation),
                        ),
                        if (_lat != null)
                          OutlinedButton.icon(
                            onPressed: () => openLink(
                              context,
                              'https://www.google.com/maps/search/?api=1&query=$_lat,$_lng',
                            ),
                            icon: const Icon(LucideIcons.map),
                            label: Text(l.openInMaps),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Text(
                    l.allowedRadius,
                    style: theme.textTheme.labelLarge,
                  ),
                ),
                Text(
                  l.metres(_radius.round()),
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            Slider(
              value: _radius,
              min: 50,
              max: 1000,
              divisions: 95,
              label: l.metres(_radius.round()),
              onChanged: (v) => setState(() => _radius = v),
            ),
            Text(
              l.radiusHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 24),
          BusyButton(
            key: const Key('saveSite'),
            label: l.save,
            onPressed: _valid ? _save : null,
          ),
        ],
      ),
    );
  }
}
