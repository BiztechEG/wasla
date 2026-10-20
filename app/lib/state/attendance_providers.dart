import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/attendance_models.dart';
import '../data/location.dart';
import 'providers.dart';

final locatorProvider = Provider<Locator>((ref) => DeviceLocator());

/// The signed-in user's attendance in a workspace: today, this week and the
/// month so far.
final attendanceTodayProvider = FutureProvider.autoDispose
    .family<AttendanceToday, String>((ref, workspaceId) async {
      final api = ref.watch(apiProvider);
      if (await ref.watch(authProvider.future) == null) {
        return const AttendanceToday(enabled: false, isAdmin: false);
      }
      return api.attendanceToday(workspaceId);
    });

/// One month of the signed-in user's days, newest first. [month] is any day
/// in it.
final myAttendanceProvider = FutureProvider.autoDispose
    .family<List<AttendanceRecord>, (String, DateTime)>((ref, key) async {
      final api = ref.watch(apiProvider);
      await ref.watch(authProvider.future);
      final (workspaceId, month) = key;
      final from = DateTime(month.year, month.month);
      final to = DateTime(month.year, month.month + 1, 0);
      return api.myAttendance(workspaceId, from, to);
    });

final attendanceSetupProvider = FutureProvider.autoDispose
    .family<AttendanceSetup, String>((ref, workspaceId) async {
      final api = ref.watch(apiProvider);
      await ref.watch(authProvider.future);
      return api.attendanceSetup(workspaceId);
    });

/// A manager's view of a day: (workspace, day or null for today, project or
/// null for everyone).
final teamAttendanceProvider = FutureProvider.autoDispose
    .family<TeamBoard, (String, DateTime?, String?)>((ref, key) async {
      final api = ref.watch(apiProvider);
      await ref.watch(authProvider.future);
      final (workspaceId, day, projectId) = key;
      return api.teamAttendance(workspaceId, day: day, projectId: projectId);
    });

final personDayProvider = FutureProvider.autoDispose
    .family<PersonDay, (String, DateTime)>((ref, key) async {
      final api = ref.watch(apiProvider);
      await ref.watch(authProvider.future);
      return api.personDay(key.$1, key.$2);
    });

final attendanceRequestsProvider = FutureProvider.autoDispose
    .family<AttendanceRequests, String>((ref, workspaceId) async {
      final api = ref.watch(apiProvider);
      await ref.watch(authProvider.future);
      return api.attendanceRequests(workspaceId);
    });

/// The signed-in user's corrections in a month (any day in it).
final myFixesProvider = FutureProvider.autoDispose
    .family<List<AttendanceFix>, (String, DateTime)>((ref, key) async {
      final api = ref.watch(apiProvider);
      await ref.watch(authProvider.future);
      final (workspaceId, month) = key;
      return api.myAttendanceFixes(
        workspaceId,
        DateTime(month.year, month.month),
        DateTime(month.year, month.month + 1, 0),
      );
    });

/// After a manager changes anything: the boards, days and requests.
void refreshTeamAttendance(WidgetRef ref, String workspaceId) {
  ref.invalidate(teamAttendanceProvider);
  ref.invalidate(personDayProvider);
  ref.invalidate(attendanceRequestsProvider(workspaceId));
  ref.invalidate(attendanceTodayProvider(workspaceId));
}
