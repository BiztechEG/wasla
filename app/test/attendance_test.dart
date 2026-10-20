import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wasla/data/attendance_models.dart';
import 'package:wasla/data/chat_models.dart';
import 'package:wasla/data/location.dart';
import 'package:wasla/data/models.dart';

import 'fake_api.dart';
import 'harness.dart';

/// Cairo HQ, and a point about 60 m from it.
const hq = AttendanceSite(
  id: 'hq',
  name: 'Maadi',
  lat: 29.9602,
  lng: 31.2569,
  radiusM: 150,
);
const nearHq = LocationFix(29.96074, 31.2569, accuracyM: 8);
const farAway = LocationFix(30.03, 31.40, accuracyM: 15);

FakeApi attendanceApi({
  WorkspaceRole role = WorkspaceRole.member,
  bool selfie = false,
  bool allowOutside = true,
}) {
  final now = DateTime.now();
  return FakeApi(signedInAs: 'me', name: 'Sami')
    ..memberships.add(FakeApi.membership('ws1', 'Build Co', role))
    ..attendance = AttendanceSetup(
      enabled: true,
      weekendDays: const {},
      requireSelfie: selfie,
      allowOutside: allowOutside,
      sites: const [hq],
    )
    ..shiftToday = ShiftToday(
      name: 'Morning',
      // Started an hour ago with 15 minutes' grace: checking in is late.
      startAt: now.subtract(const Duration(hours: 1)),
      endAt: now.add(const Duration(hours: 7)),
      grace: 15,
    );
}

Future<void> openFromTasks(WidgetTester tester) async {
  await tester.tap(find.byTooltip('My tasks'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('attendanceStrip')));
  await tester.pumpAndSettle();
}

Future<void> openSetup(WidgetTester tester) async {
  final tile = find.byKey(const Key('attendanceSetupTile'));
  await tester.scrollUntilVisible(tile, 200);
  // Clear of the floating navigation bar.
  await Scrollable.ensureVisible(tester.element(tile), alignment: 0.5);
  await tester.pumpAndSettle();
  await tester.tap(tile);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('checking in at the branch, then out', (tester) async {
    final api = attendanceApi();
    await startApp(
      tester,
      api,
      prefs: {'locale': 'en'},
      locator: FakeLocator(fix: nearHq),
    );
    await openFromTasks(tester);

    expect(find.textContaining('Morning ·'), findsOneWidget);
    expect(find.textContaining("You're at Maadi"), findsOneWidget);
    await tester.tap(find.byKey(const Key('attendanceButton')));
    await tester.pumpAndSettle();

    expect(api.attendanceCalls.last, startsWith('in 29.96074,31.2569 -'));
    final record = api.attendanceRecords.single;
    expect(record.outside, isFalse);
    expect(record.lateMinutes, inInclusiveRange(59, 61));
    expect(find.textContaining('1 h 0 min late'), findsWidgets);
    expect(find.text('Check out'), findsOneWidget);

    await tester.tap(find.byKey(const Key('attendanceButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Check out'));
    await tester.pumpAndSettle();
    expect(api.attendanceRecords.single.outAt, isNotNull);
    expect(find.text('Done for today'), findsOneWidget);
  });

  testWidgets('away from the branch asks why and waits for review', (
    tester,
  ) async {
    final api = attendanceApi();
    await startApp(
      tester,
      api,
      prefs: {'locale': 'en'},
      locator: FakeLocator(fix: farAway),
    );
    await openFromTasks(tester);
    expect(find.textContaining('Away from Maadi'), findsOneWidget);

    await tester.tap(find.byKey(const Key('attendanceButton')));
    await tester.pumpAndSettle();
    expect(find.text("You're away from Maadi"), findsOneWidget);
    await tester.tap(find.text('Client visit'));
    await tester.enterText(find.byType(TextField), 'At Al Noor');
    await tester.tap(find.text('Check in with this reason'));
    await tester.pumpAndSettle();

    final record = api.attendanceRecords.single;
    expect(record.outside, isTrue);
    expect(record.reason, OutsideReason.client);
    expect(record.reasonNote, 'At Al Noor');
    expect(find.text('Waiting for manager review'), findsOneWidget);
  });

  testWidgets('outside check-ins can be turned off', (tester) async {
    final api = attendanceApi(allowOutside: false);
    await startApp(
      tester,
      api,
      prefs: {'locale': 'en'},
      locator: FakeLocator(fix: farAway),
    );
    await openFromTasks(tester);
    await tester.tap(find.byKey(const Key('attendanceButton')));
    await tester.pumpAndSettle();
    expect(find.textContaining('only allowed at the branch'), findsOneWidget);
    expect(api.attendanceRecords, isEmpty);
  });

  testWidgets('a selfie is taken when the company asks', (tester) async {
    final api = attendanceApi(selfie: true);
    await startApp(
      tester,
      api,
      prefs: {'locale': 'en'},
      locator: FakeLocator(fix: nearHq),
      picker: FakePicker(
        Upload(
          bytes: Uint8List.fromList([1, 2, 3]),
          name: 'selfie.jpg',
          mime: 'image/jpeg',
        ),
      ),
    );
    await openFromTasks(tester);
    expect(find.textContaining('asks for a selfie'), findsOneWidget);
    await tester.tap(find.byKey(const Key('attendanceButton')));
    await tester.pumpAndSettle();
    expect(api.attendanceCalls.last, endsWith('selfie.jpg'));
  });

  testWidgets('no location: says why and offers the settings', (tester) async {
    final api = attendanceApi();
    final locator = FakeLocator()..error = const LocationDenied(forever: true);
    await startApp(tester, api, prefs: {'locale': 'en'}, locator: locator);
    await openFromTasks(tester);

    await tester.tap(find.byKey(const Key('attendanceButton')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Allow it in the phone'), findsWidgets);
    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();
    expect(locator.settingsOpened, 1);
    expect(api.attendanceRecords, isEmpty);
  });

  testWidgets('the history lists the month', (tester) async {
    final api = attendanceApi();
    final today = DateTime.now();
    final yesterday = DateTime(today.year, today.month, today.day - 1);
    api.attendanceRecords.add(
      AttendanceRecord(
        id: 'old',
        day: yesterday,
        inAt: yesterday.add(const Duration(hours: 9, minutes: 20)),
        outAt: yesterday.add(const Duration(hours: 17)),
        lateMinutes: 20,
        inSite: 'Maadi',
      ),
    );
    await startApp(
      tester,
      api,
      prefs: {'locale': 'en'},
      locator: FakeLocator(fix: nearHq),
    );
    await openFromTasks(tester);
    await tester.tap(find.text('Full history'));
    await tester.pumpAndSettle();
    if (yesterday.month == today.month) {
      expect(find.text('20 min late'), findsOneWidget);
      expect(find.textContaining('Maadi · 7 h 40 min'), findsOneWidget);
    }
  });

  testWidgets('members do not see attendance while it is off', (tester) async {
    final api = FakeApi(signedInAs: 'me', name: 'Sami')
      ..memberships.add(
        FakeApi.membership('ws1', 'Build Co', WorkspaceRole.member),
      );
    await startApp(tester, api, prefs: {'locale': 'en'});
    await tester.tap(find.byTooltip('My tasks'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('attendanceStrip')), findsNothing);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('attendanceTile')), findsNothing);
    expect(find.byKey(const Key('attendanceSetupTile')), findsNothing);
  });

  testWidgets('an admin turns attendance on and adds a branch', (tester) async {
    final api = FakeApi(signedInAs: 'me', name: 'Omar')
      ..memberships.add(
        FakeApi.membership('ws1', 'Build Co', WorkspaceRole.owner),
      );
    await startApp(
      tester,
      api,
      prefs: {'locale': 'en'},
      locator: FakeLocator(fix: nearHq),
    );
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await openSetup(tester);

    await tester.tap(find.byKey(const Key('enableAttendance')));
    await tester.pumpAndSettle();
    expect(api.attendanceCalls, ['enable Morning shift']);
    expect(find.text('Morning shift'), findsOneWidget);
    expect(find.text('Default'), findsOneWidget);

    await tester.tap(find.byKey(const Key('addSite')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('siteName')), 'Maadi');
    await tester.tap(find.byKey(const Key('useMyLocation')));
    await tester.pumpAndSettle();
    expect(find.textContaining('29.960740'), findsOneWidget);
    await tester.tap(find.byKey(const Key('saveSite')));
    await tester.pumpAndSettle();
    expect(api.attendanceCalls.last, 'site Maadi 29.96074,31.2569 150');
    expect(find.text('Maadi'), findsOneWidget);

    final selfie = find.byKey(const Key('requireSelfie'));
    await tester.scrollUntilVisible(selfie, 200);
    await Scrollable.ensureVisible(tester.element(selfie), alignment: 0.5);
    await tester.pumpAndSettle();
    await tester.tap(selfie);
    await tester.pumpAndSettle();
    expect(api.attendance!.requireSelfie, isTrue);
  });

  testWidgets('an admin adds a shift', (tester) async {
    final api = attendanceApi(role: WorkspaceRole.admin);
    api.attendance = api.attendance!.copyWith();
    await startApp(tester, api, prefs: {'locale': 'en'});
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await openSetup(tester);

    await tester.tap(find.byKey(const Key('addShift')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('shiftName')), 'Evening');
    await tester.pump();
    await tester.tap(find.byKey(const Key('saveShift')));
    await tester.pumpAndSettle();
    expect(api.attendanceCalls.last, 'shift Evening 09:00-17:00 15');
    expect(find.text('Evening'), findsOneWidget);
  });

  test('a place inside the radius allows for GPS error', () {
    const edge = LocationFix(29.9616, 31.2569, accuracyM: 40);
    final check = PlaceCheck.of(edge, sites: const [hq]);
    expect(check.distanceM, inInclusiveRange(150, 170));
    expect(check.inside, isTrue);
    expect(PlaceCheck.of(farAway, sites: const [hq]).inside, isFalse);
    expect(
      PlaceCheck.of(
        farAway,
        sites: const [AttendanceSite(id: 'f', name: 'Field')],
      ).inside,
      isTrue,
    );
  });
}
