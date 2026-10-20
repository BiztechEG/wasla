import 'dart:convert';
import 'dart:io';

import 'package:excel/excel.dart' as xl;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:wasla/data/attendance_models.dart';
import 'package:wasla/l10n/app_localizations.dart';
import 'package:wasla/ui/attendance_report_files.dart';
import 'package:wasla/ui/attendance_report_screen.dart';

import 'attendance_team_test.dart' show openTeam, teamApi;
import 'harness.dart';

final _today = DateTime(2026, 10, 20);

AttendanceReport _report() => AttendanceReport(
  workspace: 'Acme',
  from: DateTime(2026, 10, 18),
  to: _today,
  rows: [
    ReportRow(
      personId: 'sami',
      name: 'سامي',
      day: DateTime(2026, 10, 18),
      inAt: DateTime(2026, 10, 18, 9, 20),
      outAt: DateTime(2026, 10, 18, 17, 50),
      lateMinutes: 20,
      inBy: 'سامي',
      outBy: 'ليلى',
    ),
    ReportRow(personId: 'sami', name: 'سامي', day: DateTime(2026, 10, 19)),
    ReportRow(personId: 'sami', name: 'سامي', day: _today),
    ReportRow(
      personId: 'ali',
      name: 'Ali',
      hasApp: false,
      code: '17',
      day: DateTime(2026, 10, 18),
      dayOff: true,
    ),
  ],
);

void main() {
  setUpAll(() => initializeDateFormatting('ar'));

  test('periods: weeks start on Saturday, last month is whole', () {
    // Tuesday 20 October.
    final week = reportRange(ReportPeriod.thisWeek, _today);
    expect(week.start, DateTime(2026, 10, 17));
    expect(week.end, _today);
    final sunday = reportRange(
      ReportPeriod.thisWeek,
      _today,
      firstDayOfWeek: 0,
    );
    expect(sunday.start, DateTime(2026, 10, 18));
    final last = reportRange(ReportPeriod.lastMonth, DateTime(2026, 1, 5));
    expect(last.start, DateTime(2025, 12, 1));
    expect(last.end, DateTime(2025, 12, 31));
  });

  test('totals count presence, absence, lateness and hours', () {
    final totals = reportTotals(_report(), _today);
    final sami = totals.first;
    expect(sami.present, 1);
    // Today isn't over, so only the 19th is an absence.
    expect(sami.absent, 1);
    expect(sami.timesLate, 1);
    expect(sami.lateMinutes, 20);
    expect(sami.worked, const Duration(hours: 8, minutes: 30));
    expect(totals.last.absent, 0); // a day off
  });

  test('the Excel file lists every day and each person\'s totals', () {
    final l = lookupAppLocalizations(const Locale('ar'));
    final f = ReportFormat(l, 'ar', today: _today);
    final book = xl.Excel.decodeBytes(reportExcel(_report(), f));
    final days = book.tables[l.reportDays]!;
    expect(days.isRTL, isTrue);
    // A title, the period and the headers, then a row a day.
    expect(days.maxRows, 3 + 4);
    expect(days.row(2).first?.value.toString(), l.colName);
    final first = days.row(3).map((c) => c?.value?.toString()).toList();
    expect(first, contains('سامي'));
    expect(first, contains('20'));
    expect(first, contains('8.5'));
    expect(first, contains('${l.recordedSelf} / ليلى'));
    expect(days.row(4).map((c) => c?.value?.toString()), contains(l.absent));
    expect(days.row(5).map((c) => c?.value?.toString()), contains(l.notYet));
    expect(days.row(6).map((c) => c?.value?.toString()), contains(l.dayOff));

    final summary = book.tables[l.reportSummary]!;
    expect(summary.maxRows, 3 + 2);
    expect(
      f.fileName(_report(), 'xlsx'),
      'attendance-Acme-2026-10-18-2026-10-20.xlsx',
    );
  });

  test('the PDF is made with the Arabic font', () async {
    final l = lookupAppLocalizations(const Locale('ar'));
    final f = ReportFormat(l, 'ar', today: _today);
    pw.Font font(String weight) => pw.Font.ttf(
      File('assets/fonts/IBMPlexSansArabic-$weight.ttf')
          .readAsBytesSync()
          .buffer
          .asByteData(),
    );
    final bytes = await reportPdf(
      _report(),
      f,
      regular: font('Regular'),
      bold: font('SemiBold'),
    );
    expect(latin1.decode(bytes.sublist(0, 5)), '%PDF-');
    expect(bytes.length, greaterThan(10000));
  });

  testWidgets('a manager makes a report for chosen people', (tester) async {
    final api = teamApi();
    final sharer = FakeSharer();
    await startApp(tester, api, prefs: {'locale': 'en'}, sharer: sharer);
    await openTeam(tester);
    await tester.tap(find.byKey(const Key('attendanceReport')));
    await tester.pumpAndSettle();

    expect(find.text('Attendance report'), findsOneWidget);
    await tester.tap(find.byKey(const Key('who-people')));
    await tester.pumpAndSettle();
    // Nobody chosen yet.
    await tester.tap(find.byKey(const Key('reportExcel')));
    await tester.pumpAndSettle();
    expect(find.text('Choose at least one person'), findsOneWidget);

    await tester.tap(find.byKey(const Key('pick-sami')));
    await tester.pumpAndSettle();
    expect(find.text('1 chosen'), findsOneWidget);
    await tester.tap(find.byKey(const Key('reportExcel')));
    await tester.pumpAndSettle();

    final now = DateTime.now();
    expect(
      api.attendanceCalls.last,
      'report ${now.month}/1-${now.month}/${now.day} - sami',
    );
    expect(sharer.shared.single.$2, endsWith('.xlsx'));
  });

  testWidgets('a project report', (tester) async {
    final api = teamApi();
    final sharer = FakeSharer();
    await startApp(tester, api, prefs: {'locale': 'en'}, sharer: sharer);
    await openTeam(tester);
    await tester.tap(find.byKey(const Key('attendanceReport')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('period-lastMonth')));
    await tester.tap(find.byKey(const Key('who-project')));
    await tester.pumpAndSettle();
    // The only project is chosen for them.
    await tester.tap(find.byKey(const Key('reportExcel')));
    await tester.pumpAndSettle();
    expect(api.attendanceCalls.last, endsWith(' p1 -'));
    expect(sharer.shared.single.$2, contains('Acme'));
  });
}
