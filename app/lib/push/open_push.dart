import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../state/providers.dart';
import '../ui/admin_screen.dart';
import '../ui/announcements_view.dart';
import '../ui/attendance_screen.dart';
import '../ui/attendance_team_screen.dart';
import '../ui/billing_screen.dart';
import '../ui/chat_screen.dart';
import '../ui/join_requests_screen.dart';
import '../ui/members_screen.dart';
import '../ui/my_tasks_tab.dart';
import '../ui/notifications_screen.dart';
import '../ui/project_screen.dart';
import '../ui/start_screen.dart';

/// Opens what a tapped notification is about: the chat, the task, the
/// announcements, the billing page, or the invitation or request to answer,
/// in the workspace it came from.
Future<void> openFromPush(
  BuildContext context,
  WidgetRef ref,
  Map<String, String> data,
) async {
  final type = data['type'];
  var memberships = ref.read(membershipsProvider).value ?? const [];
  Membership? find() =>
      memberships.where((m) => m.workspaceId == data['workspace']).firstOrNull;
  final navigator = Navigator.of(context);
  void push(Widget screen) =>
      navigator.push(MaterialPageRoute<void>(builder: (_) => screen));

  if (type == 'admin') return push(const AdminScreen());
  if (type == 'workspace' && find() == null) {
    // Just let in: the list of workspaces may not have it yet.
    ref.invalidate(membershipsProvider);
    memberships = await ref.read(membershipsProvider.future);
    if (!context.mounted) return;
  }
  final m = find();
  if (m == null) {
    // An invitation to a workspace one is not in yet: answer it on the start
    // page (already on screen for someone with no workspace).
    if (type == 'invites') {
      if (memberships.isNotEmpty) push(const StartScreen(asPage: true));
      return;
    }
    // No longer in that workspace: the bell still says what happened.
    return push(const NotificationsScreen());
  }
  await ref.read(currentWorkspaceIdProvider.notifier).select(m.workspaceId);
  if (!context.mounted) return;
  final api = ref.read(apiProvider);

  try {
    switch (type) {
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
      case 'join_requests':
        push(JoinRequestsScreen(membership: m));
      case 'members':
        push(MembersScreen(membership: m));
      case 'workspace':
        // Opening the workspace is all there is to it.
        break;
      default:
        push(const NotificationsScreen());
    }
  } catch (_) {
    // Offline or gone: the app is open on the home screen, which is enough.
  }
}
