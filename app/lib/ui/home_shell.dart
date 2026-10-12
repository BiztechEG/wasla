import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../push/open_push.dart';
import '../push/push.dart';
import '../state/chat_providers.dart';
import '../state/providers.dart';
import '../state/task_providers.dart';
import 'chats_tab.dart';
import 'more_tab.dart';
import 'my_tasks_tab.dart';
import 'notifications_screen.dart';
import 'projects_tab.dart';
import 'start_screen.dart';
import 'widgets.dart';

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

    final theme = Theme.of(context);
    final titles = [l.tabChats, l.tabProjects, l.tabMyTasks, l.tabMore];

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
        body: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 4, 0),
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
                    _BellButton(count: notes),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(16, 6, 16, 4),
                child: Semantics(
                  header: true,
                  child: ExcludeSemantics(
                    // The nav bar already reads out the tab's name.
                    child: Text(
                      titles[_tab],
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        fontSize: 26,
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: IndexedStack(
                  index: _tab,
                  children: [
                    ChatsTab(
                      key: ValueKey(membership.workspaceId),
                      membership: membership,
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
        bottomNavigationBar: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: theme.colorScheme.outlineVariant),
            ),
          ),
          child: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: [
              NavigationDestination(
                icon: _Count(
                  count: unread,
                  child: const Icon(Icons.forum_outlined),
                ),
                selectedIcon: _Count(
                  count: unread,
                  child: const Icon(Icons.forum),
                ),
                label: l.tabChats,
              ),
              NavigationDestination(
                icon: const Icon(Icons.folder_outlined),
                selectedIcon: const Icon(Icons.folder),
                label: l.tabProjects,
              ),
              NavigationDestination(
                icon: _Count(
                  count: late,
                  child: const Icon(Icons.task_alt_outlined),
                ),
                selectedIcon: _Count(
                  count: late,
                  child: const Icon(Icons.task_alt),
                ),
                label: l.tabMyTasks,
              ),
              NavigationDestination(
                icon: const Icon(Icons.grid_view_outlined),
                selectedIcon: const Icon(Icons.grid_view_rounded),
                label: l.tabMore,
              ),
            ],
          ),
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

/// A red count on a nav icon.
class _Count extends StatelessWidget {
  const _Count({required this.count, required this.child});

  final int count;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Badge(
      isLabelVisible: count > 0,
      backgroundColor: scheme.error,
      textColor: scheme.onError,
      label: Text('$count'),
      child: child,
    );
  }
}

/// The notifications bell, with the unread count.
class _BellButton extends StatelessWidget {
  const _BellButton({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: context.l10n.notificationsTitle,
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const NotificationsScreen()),
      ),
      icon: Badge(
        isLabelVisible: count > 0,
        backgroundColor: scheme.error,
        textColor: scheme.onError,
        label: Text('$count'),
        child: const Icon(Icons.notifications_none, size: 26),
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
      color: scheme.surface,
      borderRadius: BorderRadius.circular(13),
      child: InkWell(
        borderRadius: BorderRadius.circular(13),
        onTap: () => showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (_) => const _WorkspaceSwitcher(),
        ),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(6, 6, 8, 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: scheme.primary,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(
                  name.isEmpty ? '?' : name.characters.first,
                  style: TextStyle(
                    color: scheme.onPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  membership.workspaceName,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.expand_more, size: 18, color: scheme.onSurfaceVariant),
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
                            Icons.check_circle,
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
              ],
            ),
          ),
          const Divider(),
          ListTile(
            leading: CircleAvatar(
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Icon(Icons.add, color: theme.colorScheme.primary),
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
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
