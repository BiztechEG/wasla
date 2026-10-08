import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../state/providers.dart';
import '../state/settings.dart';
import 'invite_sheet.dart';
import 'join_requests_screen.dart';
import 'members_screen.dart';
import 'start_screen.dart';
import 'widgets.dart';

class MoreTab extends ConsumerWidget {
  const MoreTab({super.key, required this.membership});

  final Membership membership;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final profile = ref.watch(profileProvider).value;
    final settings = ref.watch(settingsProvider);
    final ws = membership.workspaceId;
    final canManage = membership.role.canManage;
    final members = ref.watch(membersProvider(ws)).value;
    final requests = canManage
        ? ref.watch(joinRequestsProvider(ws)).value
        : null;

    void push(Widget screen) =>
        Navigator.of(context)
            .push(MaterialPageRoute<void>(builder: (_) => screen));

    final seats = members == null
        ? null
        : membership.maxMembers == null
        ? l.seatsUnlimited(members.length, membership.planName)
        : l.seats(members.length, membership.maxMembers!, membership.planName);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        // Who is signed in.
        Card(
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 8,
            ),
            leading: Avatar(name: profile?.fullName ?? '', radius: 24),
            title: Text(
              profile?.fullName ?? '',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: Text(ltr(profile?.email ?? profile?.phone ?? '')),
            trailing: IconButton(
              tooltip: l.editName,
              icon: const Icon(Icons.edit_outlined),
              onPressed: () async {
                final name = await promptText(
                  context,
                  title: l.editName,
                  label: l.fullNameLabel,
                  initial: profile?.fullName ?? '',
                );
                if (name == null || !context.mounted) return;
                final ok = await runAction(
                  context,
                  () => ref.read(apiProvider).updateProfile(fullName: name),
                );
                if (ok && context.mounted) ref.invalidate(profileProvider);
              },
            ),
          ),
        ),

        SectionTitle(l.workspaceSection),
        TileGroup(
          children: [
            ListTile(
              leading: Avatar(name: membership.workspaceName),
              title: Text(
                membership.workspaceName,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: seats == null ? null : Text(seats),
              trailing: Tag(roleLabel(l, membership.role), strong: true),
            ),
            ListTile(
              leading: const Icon(Icons.groups_outlined),
              title: Text(l.members),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => push(MembersScreen(membership: membership)),
            ),
            if (canManage) ...[
              ListTile(
                leading: const Icon(Icons.person_add_alt_1_outlined),
                title: Text(l.inviteMembers),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => showInviteSheet(context, membership),
              ),
              ListTile(
                leading: const Icon(Icons.how_to_reg_outlined),
                title: Text(l.joinRequests),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (requests != null && requests.isNotEmpty)
                      Badge(label: Text('${requests.length}')),
                    const Icon(Icons.chevron_right),
                  ],
                ),
                onTap: () => push(JoinRequestsScreen(membership: membership)),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.travel_explore_outlined),
                title: Text(l.discoverable),
                subtitle: Text(l.discoverableHint),
                value: membership.discoverable,
                onChanged: (value) async {
                  final ok = await runAction(
                    context,
                    () => ref.read(apiProvider).setDiscoverable(ws, value),
                  );
                  if (ok && context.mounted) {
                    ref.invalidate(membershipsProvider);
                  }
                },
              ),
            ],
            if (membership.isCompanyOwner)
              ListTile(
                leading: const Icon(Icons.add_business_outlined),
                title: Text(l.newWorkspaceInCompany(membership.companyName)),
                onTap: () async {
                  final name = await promptText(
                    context,
                    title: l.newWorkspaceTitle,
                    label: l.workspaceNameLabel,
                    action: l.create,
                  );
                  if (name == null || !context.mounted) return;
                  String? id;
                  final ok = await runAction(context, () async {
                    id = await ref
                        .read(apiProvider)
                        .createWorkspace(
                          companyId: membership.companyId,
                          name: name,
                        );
                  });
                  if (ok && context.mounted) {
                    await openWorkspace(context, ref, id!);
                  }
                },
              ),
            ListTile(
              leading: const Icon(Icons.add_circle_outline),
              title: Text(l.addWorkspace),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => push(const StartScreen(asPage: true)),
            ),
          ],
        ),

        SectionTitle(l.settingsSection),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.appearance, style: theme.textTheme.labelLarge),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<ThemeMode>(
                    showSelectedIcon: false,
                    segments: [
                      ButtonSegment(
                        value: ThemeMode.system,
                        label: Text(l.themeSystem),
                      ),
                      ButtonSegment(
                        value: ThemeMode.light,
                        label: Text(l.themeLight),
                      ),
                      ButtonSegment(
                        value: ThemeMode.dark,
                        label: Text(l.themeDark),
                      ),
                    ],
                    selected: {settings.themeMode},
                    onSelectionChanged: (s) {
                      ref.read(settingsProvider.notifier).setThemeMode(s.first);
                      _remember(ref, theme: s.first.name);
                    },
                  ),
                ),
                const SizedBox(height: 16),
                Text(l.language, style: theme.textTheme.labelLarge),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 'ar', label: Text('العربية')),
                      ButtonSegment(value: 'en', label: Text('English')),
                    ],
                    selected: {settings.locale.languageCode},
                    onSelectionChanged: (s) {
                      ref
                          .read(settingsProvider.notifier)
                          .setLocale(Locale(s.first));
                      _remember(ref, locale: s.first);
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: ListTile(
            leading: Icon(Icons.logout, color: theme.colorScheme.error),
            title: Text(
              l.signOut,
              style: TextStyle(color: theme.colorScheme.error),
            ),
            onTap: () async {
              final yes = await confirm(
                context,
                message: l.signOutConfirm,
                action: l.signOut,
                destructive: true,
              );
              if (yes) await ref.read(apiProvider).signOut();
            },
          ),
        ),
      ],
    );
  }

  /// Also keeps the choice on the account; failing that is harmless.
  void _remember(WidgetRef ref, {String? theme, String? locale}) {
    ref
        .read(apiProvider)
        .updateProfile(theme: theme, locale: locale)
        .catchError((_) {});
  }
}
