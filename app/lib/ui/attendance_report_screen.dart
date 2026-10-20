import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pdf/widgets.dart' as pw;

import '../data/attendance_models.dart';
import '../data/models.dart';
import '../data/share.dart';
import '../l10n/app_localizations.dart';
import '../state/chat_providers.dart';
import '../state/providers.dart';
import 'attendance_report_files.dart';
import 'chat_format.dart';
import 'widgets.dart';

enum ReportPeriod { thisWeek, thisMonth, lastMonth, custom }

enum _Who { everyone, project, people }

/// The first and last day of [period] around [today]. Weeks start on the
/// locale's first day (Saturday in Arabic).
DateTimeRange reportRange(
  ReportPeriod period,
  DateTime today, {
  int firstDayOfWeek = 6,
}) {
  final day = DateTime(today.year, today.month, today.day);
  return switch (period) {
    ReportPeriod.thisWeek => DateTimeRange(
      start: DateTime(
        day.year,
        day.month,
        day.day - (day.weekday % 7 - firstDayOfWeek) % 7,
      ),
      end: day,
    ),
    ReportPeriod.thisMonth || ReportPeriod.custom => DateTimeRange(
      start: DateTime(day.year, day.month),
      end: day,
    ),
    ReportPeriod.lastMonth => DateTimeRange(
      start: DateTime(day.year, day.month - 1),
      end: DateTime(day.year, day.month, 0),
    ),
  };
}

/// Makes an Excel or PDF attendance report for a period and the people the
/// manager chooses, then shares or downloads it.
class AttendanceReportScreen extends ConsumerStatefulWidget {
  const AttendanceReportScreen({
    super.key,
    required this.membership,
    required this.board,
  });

  final Membership membership;

  /// For the projects and people to choose from.
  final TeamBoard board;

  @override
  ConsumerState<AttendanceReportScreen> createState() =>
      _AttendanceReportScreenState();
}

class _AttendanceReportScreenState
    extends ConsumerState<AttendanceReportScreen> {
  var _period = ReportPeriod.thisMonth;
  DateTimeRange? _custom;
  var _who = _Who.everyone;
  String? _project;
  final _people = <String>{};
  var _search = '';
  String? _busy;

  DateTimeRange get _range {
    if (_period == ReportPeriod.custom && _custom != null) return _custom!;
    return reportRange(
      _period,
      DateTime.now(),
      firstDayOfWeek: MaterialLocalizations.of(context).firstDayOfWeekIndex,
    );
  }

  Future<void> _pickDates() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 1, now.month, now.day + 1),
      lastDate: now,
      initialDateRange: _range,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _period = ReportPeriod.custom;
      _custom = picked;
    });
  }

  String? get _problem {
    final l = context.l10n;
    if (_who == _Who.project && _project == null) return l.reportPickProject;
    if (_who == _Who.people && _people.isEmpty) return l.reportPickPeople;
    return null;
  }

  Future<void> _make({required bool pdf}) async {
    final l = context.l10n;
    final problem = _problem;
    if (problem != null) {
      showMessage(context, problem);
      return;
    }
    final range = _range;
    final format = ReportFormat(
      l,
      Localizations.localeOf(context).languageCode,
    );
    final sharer = ref.read(sharerProvider);
    setState(() => _busy = pdf ? 'pdf' : 'excel');
    try {
      final report = await ref
          .read(apiProvider)
          .attendanceReport(
            widget.membership.workspaceId,
            from: range.start,
            to: range.end,
            projectId: _who == _Who.project ? _project : null,
            personIds: _who == _Who.people ? _people.toList() : null,
          );
      if (!mounted) return;
      if (report.rows.isEmpty) {
        showMessage(context, l.reportEmpty);
        return;
      }
      final SharedFile file;
      if (pdf) {
        final fonts = await Future.wait([
          rootBundle.load('assets/fonts/IBMPlexSansArabic-Regular.ttf'),
          rootBundle.load('assets/fonts/IBMPlexSansArabic-SemiBold.ttf'),
        ]);
        file = SharedFile(
          bytes: await reportPdf(
            report,
            format,
            regular: pw.Font.ttf(fonts[0]),
            bold: pw.Font.ttf(fonts[1]),
          ),
          name: format.fileName(report, 'pdf'),
          mime: 'application/pdf',
        );
      } else {
        file = SharedFile(
          bytes: reportExcel(report, format),
          name: format.fileName(report, 'xlsx'),
          mime: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        );
      }
      final shown = await sharer.share(file: file, download: true);
      if (!shown && mounted) showMessage(context, l.errorGeneric);
    } catch (e) {
      if (mounted) showMessage(context, errorText(l, e));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final b = widget.board;
    final range = _range;
    final query = normalizeSearch(_search.trim());
    final people = [
      for (final p in b.people)
        if (query.isEmpty || normalizeSearch(p.name).contains(query)) p,
    ];
    return Scaffold(
      appBar: AppBar(title: Text(l.attendanceReport)),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  key: const Key('reportExcel'),
                  icon: _busy == 'excel'
                      ? const _Spinner()
                      : const Icon(LucideIcons.sheet),
                  label: const Text('Excel'),
                  onPressed: _busy == null ? () => _make(pdf: false) : null,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.tonalIcon(
                  key: const Key('reportPdf'),
                  icon: _busy == 'pdf'
                      ? const _Spinner()
                      : const Icon(LucideIcons.fileText),
                  label: const Text('PDF'),
                  onPressed: _busy == null ? () => _make(pdf: true) : null,
                ),
              ),
            ],
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              l.reportHint,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          SectionTitle(l.reportPeriod),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (p, label) in [
                (ReportPeriod.thisWeek, l.reportThisWeek),
                (ReportPeriod.thisMonth, l.reportThisMonth),
                (ReportPeriod.lastMonth, l.reportLastMonth),
              ])
                ChoiceChip(
                  key: Key('period-${p.name}'),
                  label: Text(label),
                  selected: _period == p,
                  onSelected: (_) => setState(() => _period = p),
                ),
              ChoiceChip(
                key: const Key('period-custom'),
                avatar: const Icon(LucideIcons.calendarRange, size: 16),
                label: Text(l.reportCustom),
                selected: _period == ReportPeriod.custom,
                onSelected: (_) => _pickDates(),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 4, top: 10),
            child: Text(
              key: const Key('reportRange'),
              l.reportRange(
                _shortDate(context, range.start),
                _shortDate(context, range.end),
              ),
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          SectionTitle(l.reportWho),
          SegmentedButton<_Who>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: _Who.everyone,
                label: Text(l.everyone, key: const Key('who-everyone')),
              ),
              if (b.projects.isNotEmpty)
                ButtonSegment(
                  value: _Who.project,
                  label: Text(
                    l.reportOneProject,
                    key: const Key('who-project'),
                  ),
                ),
              ButtonSegment(
                value: _Who.people,
                label: Text(l.reportChosenPeople, key: const Key('who-people')),
              ),
            ],
            selected: {_who},
            onSelectionChanged: (s) => setState(() {
              _who = s.first;
              if (_who == _Who.project && b.projects.length == 1) {
                _project = b.projects.single.id;
              }
            }),
          ),
          if (_who == _Who.project) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in b.projects)
                  ChoiceChip(
                    key: Key('reportProject-${p.id}'),
                    label: Text(p.name),
                    selected: _project == p.id,
                    onSelected: (_) => setState(() => _project = p.id),
                  ),
              ],
            ),
          ],
          if (_who == _Who.people) ...[
            SectionTitle(
              l.reportPeopleCount(_people.length),
              trailing: TextButton(
                onPressed: () => setState(() {
                  if (_people.length == b.people.length) {
                    _people.clear();
                  } else {
                    _people.addAll(b.people.map((p) => p.id));
                  }
                }),
                child: Text(
                  _people.length == b.people.length
                      ? l.selectNone
                      : l.selectAll,
                ),
              ),
            ),
            if (b.people.length > 8) ...[
              TextField(
                decoration: InputDecoration(
                  prefixIcon: const Icon(LucideIcons.search),
                  hintText: l.searchMembers,
                ),
                onChanged: (v) => setState(() => _search = v),
              ),
              const SizedBox(height: 8),
            ],
            if (people.isEmpty)
              EmptyState(icon: LucideIcons.users, title: l.nobodyHere)
            else
              TileGroup(
                children: [
                  for (final p in people)
                    CheckboxListTile(
                      key: Key('pick-${p.id}'),
                      value: _people.contains(p.id),
                      title: Text(p.name),
                      subtitle: _subtitle(l, p),
                      onChanged: (on) => setState(
                        () => on == true
                            ? _people.add(p.id)
                            : _people.remove(p.id),
                      ),
                    ),
                ],
              ),
          ],
        ],
      ),
    );
  }

  Widget? _subtitle(AppLocalizations l, TeamPerson p) {
    final parts = [
      if (p.jobTitle?.isNotEmpty ?? false) p.jobTitle!,
      if (p.projectName?.isNotEmpty ?? false) p.projectName!,
      if (!p.hasApp) l.noApp,
    ];
    return parts.isEmpty ? null : Text(parts.join(' · '));
  }
}

String _shortDate(BuildContext context, DateTime d) =>
    westernDigits(MaterialLocalizations.of(context).formatMediumDate(d));

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => const SizedBox.square(
    dimension: 18,
    child: CircularProgressIndicator(strokeWidth: 2),
  );
}
