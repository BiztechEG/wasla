import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/models.dart';
import '../data/task_models.dart';
import '../push/open_push.dart';
import '../push/push.dart';
import '../state/chat_providers.dart';
import '../state/google_providers.dart';
import '../state/providers.dart';
import '../state/settings.dart';
import '../state/task_providers.dart';
import 'account_screen.dart';
import 'approvals_screen.dart';
import 'chats_tab.dart';
import 'inbox.dart';
import 'modern.dart';
import 'more_tab.dart';
import 'my_tasks_tab.dart';
import 'notifications_screen.dart';
import 'phone_view.dart';
import 'projects_tab.dart';
import 'start_screen.dart';
import 'widgets.dart';
import 'workspaces_screen.dart';
import 'status.dart';

/// The four tabs from the design, with notifications in the top bar.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    // A notification tapped before this screen was ready, then the one the
    // app was opened from.
    WidgetsBinding.instance.addPostFrameCallback((_) => _openPending());
    ref.read(pushMessagingProvider).openedAtStart().then((data) {
      if (data != null) ref.read(pendingPushProvider.notifier).set(data);
    });
  }

  void _openPending() {
    final data = ref.read(pendingPushProvider);
    if (data == null || !mounted) return;
    ref.read(pendingPushProvider.notifier).set(null);
    openFromPush(context, ref, data);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    ref.listen(pendingPushProvider, (_, _) => _openPending());
    // Keeps tasks in Google Calendar in step with their changes.
    ref.listen(myTasksProvider, (_, next) {
      final tasks = next.value;
      if (tasks != null) ref.read(calendarProvider.notifier).sync(tasks);
    });
    // Quiet hours follow the phone's time zone (travel, summer time).
    ref.listen(quietHoursProvider, (_, next) {
      final q = next.value;
      final offset = DateTime.now().timeZoneOffset.inMinutes;
      if (q != null && q.utcOffset != offset) {
        ref
            .read(apiProvider)
            .setQuietHours(q.from, q.to, offset)
            .catchError((_) {});
      }
    });
    // Let into another workspace: it joins the switcher right away.
    ref.listen(notificationsProvider, (_, next) {
      final mine = {
        for (final m in ref.read(membershipsProvider).value ?? <Membership>[])
          m.workspaceId,
      };
      final joined = (next.value ?? const <AppNotification>[]).any(
        (n) =>
            n.unread &&
            n.kind == NotificationKind.requestAccepted &&
            !mine.contains(n.workspaceId),
      );
      if (joined) ref.invalidate(membershipsProvider);
    });
    final membership = ref.watch(currentMembershipProvider);
    if (membership == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final unread = ref.watch(chatBadgeProvider(membership.workspaceId));
    final notes = ref.watch(unreadNotificationsProvider);
    final me = ref.watch(authProvider).value;
    final now = DateTime.now();
    final late = (ref.watch(myTasksProvider).value ?? const [])
        .where((t) => t.isAssignedTo(me) && t.isLate(now))
        .length;

    // What waits for my answer in the "more" tab: invitations to other
    // workspaces, and what waits for my approval in this one.
    final waiting =
        (ref.watch(myInvitesProvider).value?.length ?? 0) +
        ref.watch(approvalsProvider(membership.workspaceId)).count;

    final theme = Theme.of(context);
    final titles = [l.tabChats, l.tabProjects, l.tabMyTasks, l.tabMore];
    final name = ref.watch(profileProvider).value?.fullName ?? '';

    return PopScope(
      // Back on the main screen goes to the first tab, then asks before
      // closing the app. Browsers keep their own back button.
      canPop: kIsWeb,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_tab != 0) {
          setState(() => _tab = 0);
        } else {
          _confirmExit();
        }
      },
      child: Scaffold(
        // The nav bar floats over the lists, which scroll underneath it.
        extendBody: true,
        body: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 16, 0),
                child: Row(
                  children: [
                    // Not Flexible plus Spacer: those split the free space
                    // and left a gap past the bell.
                    Expanded(
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: _WorkspaceTitle(membership: membership),
                      ),
                    ),
                    // In a wide browser window: the phone view, a click away.
                    if (ref.watch(isWebProvider) &&
                        phoneViewFits(MediaQuery.sizeOf(context))) ...[
                      SoftIconButton(
                        key: const Key('phoneViewButton'),
                        tooltip: l.phoneViewTitle,
                        onPressed: () => ref
                            .read(settingsProvider.notifier)
                            .setPhoneView(true),
                        icon: const Icon(LucideIcons.smartphone, size: 20),
                      ),
                      const SizedBox(width: 8),
                    ],
                    _BellButton(count: notes),
                    const SizedBox(width: 8),
                    _MeButton(
                      name: name,
                      status: myStatus(ref, membership.workspaceId)?.kind,
                      onTap: () => openAccount(context),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 16, 8),
                child: Semantics(
                  header: true,
                  child: ExcludeSemantics(
                    // The nav bar already reads out the tab's name.
                    child: Text(
                      titles[_tab],
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        fontSize: 30,
                        height: 1.2,
                      ),
                    ),
                  ),
                ),
              ),
              PendingBanner(membership: membership),
              Expanded(
                child: IndexedStack(
                  index: _tab,
                  children: [
                    ChatsTab(
                      key: ValueKey(membership.workspaceId),
                      membership: membership,
                      onOpenTasks: () => setState(() => _tab = 2),
                    ),
                    ProjectsTab(membership: membership),
                    MyTasksTab(membership: membership),
                    MoreTab(membership: membership),
                  ],
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: FloatingNavBar(
          selected: _tab,
          onSelected: (i) => setState(() => _tab = i),
          items: [
            NavItem(
              icon: LucideIcons.messageCircle,
              label: l.tabChats,
              count: unread,
            ),
            NavItem(icon: LucideIcons.folder, label: l.tabProjects),
            NavItem(
              icon: LucideIcons.circleCheck,
              label: l.tabMyTasks,
              count: late,
            ),
            NavItem(
              icon: LucideIcons.layoutGrid,
              label: l.tabMore,
              count: waiting,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmExit() async {
    final l = context.l10n;
    final close = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.exitAppTitle),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l.exitApp),
          ),
        ],
      ),
    );
    if (close ?? false) await SystemNavigator.pop();
  }
}

/// The notifications bell, with the unread count.
class _BellButton extends StatelessWidget {
  const _BellButton({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SoftIconButton(
      tooltip: context.l10n.notificationsTitle,
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const NotificationsScreen()),
      ),
      icon: Badge(
        isLabelVisible: count > 0,
        backgroundColor: scheme.error,
        textColor: scheme.onError,
        label: Text('$count'),
        child: const Icon(LucideIcons.bell, size: 20),
      ),
    );
  }
}

/// My initials in the top bar; opens my account.
class _MeButton extends StatelessWidget {
  const _MeButton({required this.name, required this.onTap, this.status});

  final String name;
  final StatusKind? status;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: context.l10n.myAccount,
      excludeSemantics: true,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Avatar(key: const Key('meButton'), name: name, radius: 20),
            if (status case final kind?)
              PositionedDirectional(
                end: -1,
                bottom: -1,
                child: PresenceDot(kind: kind),
              ),
          ],
        ),
      ),
    );
  }
}

/// The workspace name in the top bar; tapping it switches workspace.
class _WorkspaceTitle extends ConsumerWidget {
  const _WorkspaceTitle({required this.membership});

  final Membership membership;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final name = membership.workspaceName.trim();
    return Material(
      color: scheme.surfaceContainerHigh,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: () => showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (_) => const _WorkspaceSwitcher(),
        ),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(5, 5, 10, 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: scheme.primary,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  name.isEmpty ? '?' : name.characters.first,
                  style: TextStyle(
                    color: scheme.onPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  membership.workspaceName,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontSize: 13.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                LucideIcons.chevronDown,
                size: 15,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WorkspaceSwitcher extends ConsumerWidget {
  const _WorkspaceSwitcher();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final list = ref.watch(membershipsProvider).value ?? const <Membership>[];
    final current = ref.watch(currentMembershipProvider);
    final invites = ref.watch(myInvitesProvider).value ?? const <MyInvite>[];
    final theme = Theme.of(context);

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              l.switchWorkspace,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final m in list)
                  ListTile(
                    leading: Avatar(name: m.workspaceName),
                    title: Text(m.workspaceName),
                    subtitle: Text(
                      '${m.companyName} · ${roleLabel(l, m.role)}',
                    ),
                    trailing: m.workspaceId == current?.workspaceId
                        ? Icon(
                            LucideIcons.circleCheckBig,
                            color: theme.colorScheme.primary,
                          )
                        : null,
                    onTap: () {
                      ref
                          .read(currentWorkspaceIdProvider.notifier)
                          .select(m.workspaceId);
                      Navigator.pop(context);
                    },
                  ),
                if (invites.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                    child: Text(
                      l.invitesSection,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  for (final invite in invites)
                    ListTile(
                      leading: Avatar(name: invite.workspaceName),
                      title: Text(invite.workspaceName),
                      subtitle: Text(
                        l.invitedBy(
                          invite.invitedByName,
                          roleLabel(l, invite.role),
                        ),
                      ),
                      trailing: FilledButton.tonal(
                        onPressed: () => acceptInvite(context, ref, invite),
                        child: Text(l.accept),
                      ),
                    ),
                ],
              ],
            ),
          ),
          const Divider(),
          ListTile(
            leading: CircleAvatar(
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Icon(LucideIcons.plus, color: theme.colorScheme.primary),
            ),
            title: Text(l.addWorkspace),
            onTap: () {
              final navigator = Navigator.of(context);
              navigator.pop();
              navigator.push(
                MaterialPageRoute<void>(
                  builder: (_) => const StartScreen(asPage: true),
                ),
              );
            },
          ),
          ListTile(
            leading: CircleAvatar(
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              child: Icon(
                LucideIcons.settings2,
                size: 20,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            title: Text(l.manageWorkspaces),
            onTap: () {
              final navigator = Navigator.of(context);
              navigator.pop();
              navigator.push(
                MaterialPageRoute<void>(
                  builder: (_) => const WorkspacesScreen(),
                ),
              );
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
