import 'dart:typed_data';

import 'package:excel/excel.dart' as xl;
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../data/attendance_models.dart';
import '../l10n/app_localizations.dart';
import 'chat_format.dart' show westernDigits;

/// How a report's cells read, in the person's language.
class ReportFormat {
  ReportFormat(this.l, this.locale, {DateTime? today})
    : today = _dateOnly(today ?? DateTime.now());

  final AppLocalizations l;
  final String locale;
  final DateTime today;

  bool get rtl => locale == 'ar';

  String date(DateTime d) => westernDigits(DateFormat('d/M/yyyy').format(d));
  String weekday(DateTime d) => DateFormat('EEEE', locale).format(d);
  String time(DateTime? t) => t == null
      ? ''
      : westernDigits(DateFormat('h:mm a', locale).format(t.toLocal()));

  /// "8:30" for eight and a half hours.
  String hours(Duration? d) => d == null
      ? ''
      : '${d.inHours}:${(d.inMinutes % 60).toString().padLeft(2, '0')}';

  String status(ReportRow r) {
    if (r.inAt != null) {
      if (r.outside && r.review == AttendanceReview.rejected) {
        return l.outsideRejected;
      }
      if (r.outside && r.review == AttendanceReview.pending) {
        return l.outsidePending;
      }
      return r.lateMinutes > 0 ? l.lateLabel : l.present;
    }
    if (r.dayOff) return l.dayOff;
    return r.day == today ? l.notYet : l.absent;
  }

  /// Who checked them in and out; "self" when they did it themselves.
  String recordedBy(ReportRow r) {
    String who(String? by) =>
        by == null ? '' : (r.hasApp && by == r.name ? l.recordedSelf : by);
    final inBy = who(r.inBy);
    final outBy = who(r.outBy);
    if (outBy.isEmpty || outBy == inBy) return inBy;
    if (inBy.isEmpty) return outBy;
    return '$inBy / $outBy';
  }

  String title(AttendanceReport r) => '${l.attendanceReport} · ${r.workspace}';

  String period(AttendanceReport r) => l.reportRange(date(r.from), date(r.to));

  /// A safe file name: the report's title and dates.
  String fileName(AttendanceReport r, String extension) {
    String d(DateTime t) => DateFormat('yyyy-MM-dd').format(t);
    final name = r.workspace
        .replaceAll(RegExp(r'[\\/:*?"<>|]+'), ' ')
        .trim()
        .replaceAll(RegExp(r'\s+'), '-');
    return 'attendance${name.isEmpty ? '' : '-$name'}'
        '-${d(r.from)}-${d(r.to)}.$extension';
  }
}

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// One person's totals over the period.
class ReportTotals {
  ReportTotals(this.first);

  final ReportRow first;
  int present = 0;
  int absent = 0;
  int timesLate = 0;
  int lateMinutes = 0;
  Duration worked = Duration.zero;
}

/// Each person's totals, in the report's order. Today without a record
/// isn't counted as absent: the day isn't over.
List<ReportTotals> reportTotals(AttendanceReport report, DateTime today) {
  final byPerson = <String, ReportTotals>{};
  for (final r in report.rows) {
    final t = byPerson.putIfAbsent(r.personId, () => ReportTotals(r));
    if (r.inAt != null) {
      t.present++;
      if (r.lateMinutes > 0) {
        t.timesLate++;
        t.lateMinutes += r.lateMinutes;
      }
      t.worked += r.worked ?? Duration.zero;
    } else if (!r.dayOff && r.day.isBefore(today)) {
      t.absent++;
    }
  }
  return byPerson.values.toList();
}

double _hoursNumber(Duration d) => (d.inMinutes / 60 * 100).round() / 100;

/// The report as an Excel workbook: every day, then each person's totals.
Uint8List reportExcel(AttendanceReport report, ReportFormat f) {
  final l = f.l;
  final book = xl.Excel.createExcel();
  final defaultSheet = book.getDefaultSheet() ?? 'Sheet1';
  book.rename(defaultSheet, l.reportDays);
  final days = book[l.reportDays];
  final summary = book[l.reportSummary];

  final titleStyle = xl.CellStyle(bold: true, fontSize: 14);
  final headStyle = xl.CellStyle(
    bold: true,
    backgroundColorHex: xl.ExcelColor.fromHexString('#D7EFE9'),
    horizontalAlign: xl.HorizontalAlign.Center,
  );

  void heading(xl.Sheet sheet, List<String> headers) {
    sheet.appendRow([xl.TextCellValue(f.title(report))]);
    sheet.appendRow([xl.TextCellValue(f.period(report))]);
    sheet.appendRow([for (final h in headers) xl.TextCellValue(h)]);
    sheet
            .cell(xl.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0))
            .cellStyle =
        titleStyle;
    for (var c = 0; c < headers.length; c++) {
      sheet
              .cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 2))
              .cellStyle =
          headStyle;
    }
  }

  xl.TextCellValue? text(String? s) =>
      s == null || s.isEmpty ? null : xl.TextCellValue(s);

  heading(days, [
    l.colName,
    l.colCode,
    l.colJob,
    l.project,
    l.colDate,
    l.colWeekday,
    l.colIn,
    l.colOut,
    l.colLate,
    l.colHours,
    l.colStatus,
    l.colSite,
    l.colRecordedBy,
  ]);
  for (final r in report.rows) {
    final worked = r.worked;
    days.appendRow([
      xl.TextCellValue(r.name),
      text(r.code),
      text(r.jobTitle),
      text(r.project),
      xl.DateCellValue(year: r.day.year, month: r.day.month, day: r.day.day),
      xl.TextCellValue(f.weekday(r.day)),
      text(f.time(r.inAt)),
      text(f.time(r.outAt)),
      r.inAt == null ? null : xl.IntCellValue(r.lateMinutes),
      worked == null ? null : xl.DoubleCellValue(_hoursNumber(worked)),
      xl.TextCellValue(f.status(r)),
      text(r.site),
      text(f.recordedBy(r)),
    ]);
  }
  const dayWidths = [
    22.0,
    10.0,
    16.0,
    16.0,
    12.0,
    12.0,
    11.0,
    11.0,
    14.0,
    10.0,
    22.0,
    16.0,
    22.0,
  ];
  for (var c = 0; c < dayWidths.length; c++) {
    days.setColumnWidth(c, dayWidths[c]);
  }

  heading(summary, [
    l.colName,
    l.colCode,
    l.colJob,
    l.project,
    l.colDaysPresent,
    l.colDaysAbsent,
    l.colTimesLate,
    l.colLateTotal,
    l.colHoursTotal,
  ]);
  for (final t in reportTotals(report, f.today)) {
    summary.appendRow([
      xl.TextCellValue(t.first.name),
      text(t.first.code),
      text(t.first.jobTitle),
      text(t.first.project),
      xl.IntCellValue(t.present),
      xl.IntCellValue(t.absent),
      xl.IntCellValue(t.timesLate),
      xl.IntCellValue(t.lateMinutes),
      xl.DoubleCellValue(_hoursNumber(t.worked)),
    ]);
  }
  const summaryWidths = [22.0, 10.0, 16.0, 16.0, 14.0, 14.0, 14.0, 20.0, 16.0];
  for (var c = 0; c < summaryWidths.length; c++) {
    summary.setColumnWidth(c, summaryWidths[c]);
  }

  book.setDefaultSheet(l.reportDays);
  if (!f.rtl) return Uint8List.fromList(book.encode()!);
  // The package only writes right-to-left for sheets it read from a file.
  final read = xl.Excel.decodeBytes(book.encode()!);
  for (final sheet in read.tables.values) {
    sheet.isRTL = true;
  }
  return Uint8List.fromList(read.encode()!);
}

/// The report as a printable PDF: everyone's totals, then each person's
/// days. [regular] and [bold] must cover Arabic.
Future<Uint8List> reportPdf(
  AttendanceReport report,
  ReportFormat f, {
  required pw.Font regular,
  required pw.Font bold,
}) {
  final l = f.l;
  const accent = PdfColor.fromInt(0xFF0F766E);
  const headFill = PdfColor.fromInt(0xFFD7EFE9);
  const zebra = PdfColor.fromInt(0xFFF4F7F6);
  final direction = f.rtl ? pw.TextDirection.rtl : pw.TextDirection.ltr;

  // Tables lay columns out left to right, so Arabic reads them reversed.
  List<T> ordered<T>(List<T> cells) => f.rtl ? cells.reversed.toList() : cells;

  pw.Widget table(List<String> headers, List<List<String>> rows) =>
      pw.TableHelper.fromTextArray(
        headers: ordered(headers),
        data: [for (final r in rows) ordered(r)],
        headerStyle: pw.TextStyle(font: bold, fontSize: 9),
        cellStyle: const pw.TextStyle(fontSize: 9),
        headerDecoration: const pw.BoxDecoration(color: headFill),
        oddRowDecoration: const pw.BoxDecoration(color: zebra),
        cellAlignment: pw.Alignment.center,
        headerAlignment: pw.Alignment.center,
        cellPadding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
        border: const pw.TableBorder(
          horizontalInside: pw.BorderSide(
            color: PdfColor.fromInt(0xFFDDE3E1),
            width: 0.5,
          ),
        ),
        headerDirection: direction,
        tableDirection: direction,
      );

  final totals = reportTotals(report, f.today);
  final byPerson = <String, List<ReportRow>>{};
  for (final r in report.rows) {
    byPerson.putIfAbsent(r.personId, () => []).add(r);
  }

  String who(ReportRow r) => [
    r.name,
    if (r.jobTitle?.isNotEmpty ?? false) r.jobTitle!,
    if (r.code?.isNotEmpty ?? false) '#${r.code}',
    if (r.project?.isNotEmpty ?? false) r.project!,
  ].join(' · ');

  final doc = pw.Document(
    title: f.title(report),
    theme: pw.ThemeData.withFont(base: regular, bold: bold),
  );
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4.landscape,
      margin: const pw.EdgeInsets.all(28),
      textDirection: direction,
      header: (context) => pw.Container(
        padding: const pw.EdgeInsets.only(bottom: 8),
        margin: const pw.EdgeInsets.only(bottom: 10),
        decoration: const pw.BoxDecoration(
          border: pw.Border(bottom: pw.BorderSide(color: accent, width: 1.5)),
        ),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
              f.title(report),
              style: pw.TextStyle(font: bold, fontSize: 14, color: accent),
            ),
            pw.Text(f.period(report), style: const pw.TextStyle(fontSize: 10)),
          ],
        ),
      ),
      footer: (context) => pw.Align(
        alignment: pw.Alignment.center,
        child: pw.Text(
          '${context.pageNumber} / ${context.pagesCount}',
          style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
        ),
      ),
      build: (context) => [
        pw.Text(l.reportSummary, style: pw.TextStyle(font: bold, fontSize: 12)),
        pw.SizedBox(height: 6),
        table(
          [
            l.colName,
            l.colDaysPresent,
            l.colDaysAbsent,
            l.colTimesLate,
            l.colLateTotal,
            l.colHoursTotal,
          ],
          [
            for (final t in totals)
              [
                who(t.first),
                '${t.present}',
                '${t.absent}',
                '${t.timesLate}',
                '${t.lateMinutes}',
                f.hours(t.worked),
              ],
          ],
        ),
        for (final t in totals) ...[
          pw.SizedBox(height: 16),
          pw.Text(
            who(t.first),
            style: pw.TextStyle(font: bold, fontSize: 11, color: accent),
          ),
          pw.SizedBox(height: 4),
          table(
            [
              l.colDate,
              l.colWeekday,
              l.colIn,
              l.colOut,
              l.colLate,
              l.colHours,
              l.colStatus,
              l.colSite,
              l.colRecordedBy,
            ],
            [
              for (final r in byPerson[t.first.personId]!)
                [
                  f.date(r.day),
                  f.weekday(r.day),
                  f.time(r.inAt),
                  f.time(r.outAt),
                  r.inAt == null || r.lateMinutes == 0
                      ? ''
                      : '${r.lateMinutes}',
                  f.hours(r.worked),
                  f.status(r),
                  r.site ?? '',
                  f.recordedBy(r),
                ],
              [
                l.reportTotal,
                '',
                '',
                '',
                '${t.lateMinutes}',
                f.hours(t.worked),
                '${l.present} ${t.present} · ${l.absent} ${t.absent}',
                '',
                '',
              ],
            ],
          ),
        ],
      ],
    ),
  );
  return doc.save();
}
