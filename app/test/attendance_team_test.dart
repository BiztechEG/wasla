import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasla/data/attendance_models.dart';
import 'package:wasla/data/models.dart';

import 'attendance_test.dart' show attendanceApi, nearHq;
import 'fake_api.dart';
import 'harness.dart';

/// An owner with Sami (late), Hoda (not in) and Ali (a worker, not in), on a
/// shift that started an hour ago.
FakeApi teamApi({WorkspaceRole role = WorkspaceRole.owner}) {
  final api = attendanceApi(role: role);
  final shift = api.shiftToday;
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  api
    ..teamProjects = [const AttendanceOption('p1', 'Tower')]
    ..teamPeople.addAll([
      TeamPerson(id: 'sami', name: 'Sami', userId: 'u2', shift: shift),
      TeamPerson(id: 'hoda', name: 'Hoda', userId: 'u3', shift: shift),
      TeamPerson(
        id: 'ali',
        name: 'Ali',
        jobTitle: 'Mason',
        projectId: 'p1',
        projectName: 'Tower',
        shift: shift,
      ),
    ])
    ..teamRecords['sami'] = AttendanceRecord(
      id: 'r-sami',
      personId: 'sami',
      day: today,
      inAt: now.subtract(const Duration(minutes: 30)),
      lateMinutes: 30,
      inByName: 'Sami',
    );
  return api;
}

Future<void> openTeam(WidgetTester tester) async {
  await tester.tap(find.byTooltip('More'));
  await tester.pumpAndSettle();
  final tile = find.byKey(const Key('teamAttendanceTile'));
  await tester.scrollUntilVisible(tile, 200);
  await Scrollable.ensureVisible(tester.element(tile), alignment: 0.5);
  await tester.pumpAndSettle();
  await tester.tap(tile);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a manager sees who is in, late and absent', (tester) async {
    final api = teamApi();
    await startApp(tester, api, prefs: {'locale': 'en'});
    await openTeam(tester);

    expect(find.text('Team attendance'), findsOneWidget);
    expect(find.text('30 min late'), findsOneWidget);
    expect(find.text('Absent'), findsNWidgets(2));
    expect(find.text('No app'), findsOneWidget);
    expect(find.text('Late 1'), findsOneWidget);
    expect(find.text('Absent 2'), findsOneWidget);

    await tester.tap(find.text('Late 1'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('person-sami')), findsOneWidget);
    expect(find.byKey(const Key('person-hoda')), findsNothing);
  });

  testWidgets('roll call checks people in at their own times', (tester) async {
    final api = teamApi();
    await startApp(
      tester,
      api,
      prefs: {'locale': 'en'},
      locator: FakeLocator(fix: nearHq),
    );
    await openTeam(tester);
    await tester.tap(find.byKey(const Key('rollCall')));
    await tester.pumpAndSettle();

    // Sami is already in, so only Hoda and Ali are listed.
    expect(find.byKey(const Key('roll-sami')), findsNothing);
    expect(find.byKey(const Key('roll-hoda')), findsOneWidget);
    await tester.tap(find.byKey(const Key('selectAll')));
    await tester.pumpAndSettle();
    expect(find.text('Check in 2 people'), findsOneWidget);

    // Hoda came just now: late, in orange.
    await tester.tap(find.byKey(const Key('time-hoda')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('timeNow')));
    await tester.pumpAndSettle();
    expect(find.textContaining('1 h 0 min late'), findsOneWidget);

    await tester.tap(find.byKey(const Key('saveRollCall')));
    await tester.pumpAndSettle();
    final call = api.attendanceCalls.last;
    expect(call, startsWith('roll in '));
    expect(call, contains('hoda@'));
    expect(call, contains('ali@'));
    expect(api.teamRecords['ali']!.lateMinutes, 0);
    expect(api.teamRecords['hoda']!.lateMinutes, inInclusiveRange(59, 61));
    expect(find.text('Recorded 2 people'), findsOneWidget);
  });

  testWidgets('adding a worker without the app', (tester) async {
    final api = teamApi()..workersFree = 20;
    await startApp(tester, api, prefs: {'locale': 'en'});
    await openTeam(tester);
    await tester.tap(find.byKey(const Key('workers')));
    await tester.pumpAndSettle();
    expect(find.text('1 of 20 free workers'), findsOneWidget);

    await tester.tap(find.byKey(const Key('addWorker')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('workerName')), 'Kamal');
    await tester.enterText(find.byKey(const Key('workerJob')), 'Driver');
    await tester.pump();
    await tester.tap(find.byKey(const Key('saveWorker')));
    await tester.pumpAndSettle();
    expect(api.attendanceCalls.last, 'worker Kamal Driver - -');
    expect(find.byKey(const Key('worker-w0')), findsOneWidget);
  });

  testWidgets('past the free workers, adding stops', (tester) async {
    final api = teamApi()..workersFree = 1;
    await startApp(tester, api, prefs: {'locale': 'en'});
    await openTeam(tester);
    await tester.tap(find.byKey(const Key('workers')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('addWorker')));
    await tester.pumpAndSettle();
    expect(find.textContaining('free workers are used up'), findsOneWidget);
    expect(find.byKey(const Key('workerName')), findsNothing);
  });

  testWidgets('a lead must put a worker in one of their projects', (
    tester,
  ) async {
    final api = teamApi(role: WorkspaceRole.member)..attendanceManager = true;
    await startApp(tester, api, prefs: {'locale': 'en'});
    await openTeam(tester);
    await tester.tap(find.byKey(const Key('workers')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('addWorker')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('workerName')), 'Kamal');
    await tester.pump();
    // The lead's only project is chosen for them.
    await tester.tap(find.byKey(const Key('saveWorker')));
    await tester.pumpAndSettle();
    expect(api.attendanceCalls.last, 'worker Kamal - p1 -');
  });

  testWidgets('reviewing a check-in from outside and a correction', (
    tester,
  ) async {
    final api = teamApi();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    api.teamReviews.add((
      AttendanceRecord(
        id: 'r9',
        day: today,
        inAt: now,
        outside: true,
        inSite: 'Maadi',
        inDistanceM: 900,
        reason: OutsideReason.client,
        reasonNote: 'At Al Noor',
        review: AttendanceReview.pending,
      ),
      'Hoda',
    ));
    api.teamFixes.add(
      AttendanceFix(
        id: 'f1',
        personId: 'sami',
        name: 'Sami',
        day: today.subtract(const Duration(days: 1)),
        inAt: today.subtract(const Duration(hours: 15)),
        note: 'Forgot my phone',
      ),
    );
    await startApp(tester, api, prefs: {'locale': 'en'});
    await openTeam(tester);
    expect(find.text('2 requests waiting for you'), findsOneWidget);
    await tester.tap(find.byKey(const Key('attendanceRequests')));
    await tester.pumpAndSettle();

    expect(find.text('Away from Maadi · 900 m'), findsOneWidget);
    expect(find.textContaining('At Al Noor'), findsOneWidget);
    await tester.tap(find.byKey(const Key('accept-r9')));
    await tester.pumpAndSettle();
    expect(api.attendanceCalls.last, 'review r9 true');

    expect(find.textContaining('Forgot my phone'), findsOneWidget);
    await tester.tap(find.byKey(const Key('rejectFix-f1')));
    await tester.pumpAndSettle();
    expect(api.attendanceCalls.last, 'decide f1 false');
    expect(find.text('Nothing waiting'), findsOneWidget);
  });

  testWidgets('a manager changes times and sees who did what', (tester) async {
    final api = teamApi();
    api.teamEdits['sami'] = [
      AttendanceEdit(
        field: 'in',
        at: DateTime.now(),
        oldAt: DateTime(2026, 10, 20, 9, 30),
        newAt: DateTime(2026, 10, 20, 9, 10),
        detail: 'Was at the gate',
        byName: 'Laila',
      ),
    ];
    await startApp(tester, api, prefs: {'locale': 'en'});
    await openTeam(tester);
    await tester.tap(find.byKey(const Key('person-sami')));
    await tester.pumpAndSettle();

    final change = find.text('Check-in changed 9:30 AM → 9:10 AM');
    await tester.scrollUntilVisible(change, 200);
    expect(change, findsOneWidget);
    expect(find.textContaining('Laila'), findsOneWidget);
    final edit = find.byKey(const Key('editTimes'));
    await tester.scrollUntilVisible(edit, -100);
    await tester.tap(edit);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('editNote')), 'Gate');
    await tester.tap(find.byKey(const Key('saveTimes')));
    await tester.pumpAndSettle();
    expect(api.attendanceCalls.last, startsWith('times r-sami '));
    expect(api.attendanceCalls.last, endsWith(' Gate'));
  });

  testWidgets('people ask to correct a day', (tester) async {
    final api = attendanceApi();
    await startApp(
      tester,
      api,
      prefs: {'locale': 'en'},
      locator: FakeLocator(fix: nearHq),
    );
    await tester.tap(find.byTooltip('My tasks'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('attendanceStrip')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Full history'));
    await tester.pumpAndSettle();

    final today = DateTime.now();
    final day = DateTime(today.year, today.month, today.day - 1);
    if (day.month != today.month) return;
    await tester.tap(find.byKey(Key('day-${day.day}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('fixIn')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('fixNote')), 'Forgot');
    await tester.pump();
    await tester.tap(find.byKey(const Key('sendFix')));
    await tester.pumpAndSettle();
    expect(api.attendanceCalls.last, 'fix ${day.day} 09:00 - Forgot');
    expect(find.text('Correction asked'), findsOneWidget);
  });

  testWidgets('members who manage nobody see no team', (tester) async {
    final api = attendanceApi();
    await startApp(tester, api, prefs: {'locale': 'en'});
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('teamAttendanceTile')), findsNothing);
  });
}
