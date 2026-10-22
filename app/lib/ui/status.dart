import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/models.dart';
import '../l10n/app_localizations.dart';
import '../state/providers.dart';
import 'chat_format.dart';
import 'widgets.dart';

String presenceLabel(AppLocalizations l, StatusKind kind) => switch (kind) {
  StatusKind.meeting => l.statusMeeting,
  StatusKind.busy => l.statusBusy,
  StatusKind.leave => l.statusLeave,
};

IconData presenceIcon(StatusKind? kind) => switch (kind) {
  null => LucideIcons.circleCheck,
  StatusKind.meeting => LucideIcons.video,
  StatusKind.busy => LucideIcons.circleMinus,
  StatusKind.leave => LucideIcons.palmtree,
};

Color presenceColor(BuildContext context, StatusKind? kind) {
  final scheme = Theme.of(context).colorScheme;
  return switch (kind) {
    null => const Color(0xFF2E9E5B),
    StatusKind.meeting => const Color(0xFFC2660A),
    StatusKind.busy => scheme.error,
    StatusKind.leave => const Color(0xFF7247B8),
  };
}

/// "On leave until 5 November", "In a meeting until 3:30 PM", "Busy".
String presenceText(BuildContext context, UserStatus s) {
  final l = context.l10n;
  final label = presenceLabel(l, s.kind);
  final until = s.until?.toLocal();
  if (until == null) return label;
  final now = DateTime.now();
  final sameDay =
      until.year == now.year &&
      until.month == now.month &&
      until.day == now.day;
  return l.statusUntil(
    label,
    sameDay ? clockTime(context, until) : dayMonth(context, until),
  );
}

/// A small dot in the status's color, on someone's picture.
class PresenceDot extends StatelessWidget {
  const PresenceDot({super.key, required this.kind, this.size = 12});

  final StatusKind kind;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: presenceColor(context, kind),
      shape: BoxShape.circle,
      border: Border.all(
        color: Theme.of(context).scaffoldBackgroundColor,
        width: 2,
      ),
    ),
  );
}

/// One's own status in [membership]'s workspace, from the list everyone
/// there sees.
UserStatus? myStatus(WidgetRef ref, String workspaceId) {
  final me = ref.watch(authProvider).value;
  return ref.watch(statusesProvider(workspaceId)).value?[me];
}

/// Picks one's status: available, or busy, in a meeting or on leave, with a
/// note and until when.
Future<void> showStatusSheet(
  BuildContext context,
  WidgetRef ref, {
  required String workspaceId,
}) async {
  final current = myStatus(ref, workspaceId);
  final picked = await showModalBottomSheet<_Picked>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _StatusSheet(current: current),
  );
  if (picked == null || !context.mounted) return;
  final ok = await runAction(
    context,
    () => ref.read(apiProvider).setMyStatus(picked.status),
  );
  if (ok) ref.invalidate(statusesProvider(workspaceId));
}

/// What the sheet hands back; [status] null: available.
class _Picked {
  const _Picked(this.status);

  final UserStatus? status;
}

enum _Until { hour, today, date, none }

class _StatusSheet extends StatefulWidget {
  const _StatusSheet({required this.current});

  final UserStatus? current;

  @override
  State<_StatusSheet> createState() => _StatusSheetState();
}

class _StatusSheetState extends State<_StatusSheet> {
  late StatusKind? _kind = widget.current?.kind;
  late final _note = TextEditingController(text: widget.current?.note);
  late _Until _until = widget.current == null
      ? _Until.today
      : widget.current!.until == null
      ? _Until.none
      : _Until.date;
  late DateTime? _date = widget.current?.until?.toLocal();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  void _pickKind(StatusKind? kind) => setState(() {
    _kind = kind;
    // Leave is counted in days; a meeting in hours.
    _until = switch (kind) {
      StatusKind.leave => _date == null ? _Until.none : _Until.date,
      StatusKind.meeting => _Until.hour,
      _ => _until == _Until.date ? _Until.today : _until,
    };
  });

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final day = await showDatePicker(
      context: context,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
      initialDate: _date ?? now.add(const Duration(days: 1)),
    );
    if (day != null) {
      setState(() {
        _date = day;
        _until = _Until.date;
      });
    }
  }

  DateTime? get _untilTime {
    final now = DateTime.now();
    return switch (_until) {
      _Until.hour => now.add(const Duration(hours: 1)),
      _Until.today => DateTime(now.year, now.month, now.day, 23, 59),
      // Through the whole last day.
      _Until.date when _date != null => DateTime(
        _date!.year,
        _date!.month,
        _date!.day,
        23,
        59,
      ),
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final kind = _kind;
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          0,
          20,
          16 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l.myStatus,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            RadioGroup<StatusKind?>(
              groupValue: kind,
              onChanged: _pickKind,
              child: Column(
                children: [
                  for (final k in <StatusKind?>[null, ...StatusKind.values])
                    RadioListTile<StatusKind?>(
                      key: Key('status-${k?.wire ?? 'available'}'),
                      contentPadding: EdgeInsets.zero,
                      value: k,
                      secondary: Icon(
                        presenceIcon(k),
                        color: presenceColor(context, k),
                      ),
                      title: Text(
                        k == null ? l.statusAvailable : presenceLabel(l, k),
                      ),
                    ),
                ],
              ),
            ),
            if (kind != null) ...[
              const SizedBox(height: 8),
              TextField(
                key: const Key('statusNote'),
                controller: _note,
                maxLength: 200,
                maxLines: 2,
                minLines: 1,
                decoration: InputDecoration(
                  labelText: l.statusNote,
                  hintText: kind == StatusKind.leave
                      ? l.statusNoteLeaveHint
                      : l.statusNoteHint,
                ),
              ),
              Text(l.statusUntilLabel, style: theme.textTheme.labelLarge),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (kind != StatusKind.leave) ...[
                    ChoiceChip(
                      label: Text(l.statusHour),
                      selected: _until == _Until.hour,
                      onSelected: (_) => setState(() => _until = _Until.hour),
                    ),
                    ChoiceChip(
                      label: Text(l.statusToday),
                      selected: _until == _Until.today,
                      onSelected: (_) => setState(() => _until = _Until.today),
                    ),
                  ],
                  ChoiceChip(
                    key: const Key('statusDate'),
                    label: Text(
                      _until == _Until.date && _date != null
                          ? dayMonth(context, _date!)
                          : l.statusPickDate,
                    ),
                    selected: _until == _Until.date,
                    onSelected: (_) => _pickDate(),
                  ),
                  ChoiceChip(
                    label: Text(l.statusNoEnd),
                    selected: _until == _Until.none,
                    onSelected: (_) => setState(() => _until = _Until.none),
                  ),
                ],
              ),
              if (kind == StatusKind.leave) ...[
                const SizedBox(height: 8),
                Text(
                  l.statusLeaveHint,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
            const SizedBox(height: 16),
            FilledButton(
              key: const Key('saveStatus'),
              onPressed: () => Navigator.pop(
                context,
                _Picked(
                  kind == null
                      ? null
                      : UserStatus(
                          kind: kind,
                          note: _note.text.trim().isEmpty
                              ? null
                              : _note.text.trim(),
                          until: _untilTime,
                        ),
                ),
              ),
              child: Text(l.save),
            ),
          ],
        ),
      ),
    );
  }
}
