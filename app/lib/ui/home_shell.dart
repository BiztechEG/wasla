import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../state/chat_providers.dart';
import '../state/providers.dart';
import 'chats_tab.dart';
import 'more_tab.dart';
import 'projects_tab.dart';
import 'start_screen.dart';
import 'widgets.dart';

/// The four tabs from the design. My tasks arrives in phase 3.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final membership = ref.watch(currentMembershipProvider);
    if (membership == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final unread = ref.watch(chatBadgeProvider(membership.workspaceId));

    return Scaffold(
      appBar: AppBar(title: _WorkspaceTitle(membership: membership)),
      body: IndexedStack(
        index: _tab,
        children: [
          ChatsTab(
            key: ValueKey(membership.workspaceId),
            membership: membership,
          ),
          ProjectsTab(membership: membership),
          _ComingSoon(icon: Icons.task_alt, body: l.tasksComingSoon),
          MoreTab(membership: membership),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          NavigationDestination(
            icon: Badge(
              isLabelVisible: unread > 0,
              label: Text('$unread'),
              child: const Icon(Icons.forum_outlined),
            ),
            selectedIcon: Badge(
              isLabelVisible: unread > 0,
              label: Text('$unread'),
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
            icon: const Icon(Icons.task_alt_outlined),
            selectedIcon: const Icon(Icons.task_alt),
            label: l.tabMyTasks,
          ),
          NavigationDestination(
            icon: const Icon(Icons.more_horiz),
            label: l.tabMore,
          ),
        ],
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
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => const _WorkspaceSwitcher(),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                membership.workspaceName,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.expand_more, size: 22),
          ],
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

class _ComingSoon extends StatelessWidget {
  const _ComingSoon({required this.icon, required this.body});

  final IconData icon;
  final String body;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: icon,
      title: context.l10n.comingSoonTitle,
      body: body,
    );
  }
}
