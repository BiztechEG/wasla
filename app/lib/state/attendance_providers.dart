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
