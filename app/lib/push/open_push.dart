import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import '../ui/admin_screen.dart';
import '../ui/announcements_view.dart';
import '../ui/attendance_screen.dart';
import '../ui/attendance_team_screen.dart';
import '../ui/billing_screen.dart';
import '../ui/chat_screen.dart';
import '../ui/my_tasks_tab.dart';
import '../ui/notifications_screen.dart';
import '../ui/project_screen.dart';

/// Opens what a tapped notification is about: the chat, the task, the
/// announcements, or the billing page, in the workspace it came from.
Future<void> openFromPush(
  BuildContext context,
  WidgetRef ref,
  Map<String, String> data,
) async {
  final memberships = ref.read(membershipsProvider).value ?? const [];
  final m = memberships
      .where((m) => m.workspaceId == data['workspace'])
      .firstOrNull;
  final navigator = Navigator.of(context);
  void push(Widget screen) =>
      navigator.push(MaterialPageRoute<void>(builder: (_) => screen));

  if (data['type'] == 'admin') return push(const AdminScreen());
  // No longer in that workspace: the bell still says what happened.
  if (m == null) return push(const NotificationsScreen());
  await ref.read(currentWorkspaceIdProvider.notifier).select(m.workspaceId);
  if (!context.mounted) return;
  final api = ref.read(apiProvider);

  try {
    switch (data['type']) {
      case 'chat':
        final chats = await api.conversations(m.workspaceId);
        final c = chats.where((c) => c.id == data['conversation']).firstOrNull;
        if (c != null) {
          push(ChatScreen(membership: m, target: ChatTarget.of(c)));
        }
      case 'task':
        if (data['task'] != null) {
          openTask(context, m.workspaceId, data['task']!);
        }
      case 'announcement':
        final projectId = data['project'];
        if (projectId == null) {
          push(WorkspaceAnnouncementsScreen(membership: m));
        } else {
          final projects = await api.projects(m.workspaceId);
          final p = projects.where((p) => p.id == projectId).firstOrNull;
          if (p != null) {
            push(
              ProjectScreen(project: p, initialTab: ProjectTab.announcements),
            );
          }
        }
      case 'attendance':
        openAttendance(context, m);
      case 'attendance_team':
        openAttendanceRequests(context, m);
      case 'billing':
        openBilling(context, ref, m.workspaceId);
      default:
        push(const NotificationsScreen());
    }
  } catch (_) {
    // Offline or gone: the app is open on the home screen, which is enough.
  }
}
