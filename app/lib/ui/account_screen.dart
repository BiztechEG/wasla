import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/google.dart';
import '../push/push.dart';
import '../state/google_providers.dart';
import '../state/providers.dart';
import '../state/settings.dart';
import '../state/task_providers.dart';
import 'widgets.dart';
import 'status.dart';

void openAccount(BuildContext context) =>
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const AccountScreen()));

/// The signed-in person's own things, apart from any workspace: their name,
/// when their phone stays quiet, how the app looks, Google, and signing out.
class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final profile = ref.watch(profileProvider).value;
    final settings = ref.watch(settingsProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l.myAccount)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
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
              subtitle: LtrLine(profile?.email ?? profile?.phone ?? ''),
              trailing: IconButton(
                tooltip: l.editName,
                icon: const Icon(LucideIcons.pencil),
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

          if (ref.watch(currentMembershipProvider) case final m?) ...[
            SectionTitle(l.myStatus),
            _StatusCard(workspaceId: m.workspaceId),
          ],
          SectionTitle(l.notificationsTitle),
          const _QuietHoursCard(),
          if (ref.watch(currentMembershipProvider) case final m?
              when m.role.canManage ||
                  m.isCompanyOwner ||
                  (ref
                          .watch(myDepartmentsProvider(m.workspaceId))
                          .value
                          ?.isNotEmpty ??
                      false))
            const _WeeklyReportCard(),
          if (ref.watch(googleAccountProvider).available) ...[
            SectionTitle(l.googleSection),
            const _GoogleCard(),
          ],
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
                        ref
                            .read(settingsProvider.notifier)
                            .setThemeMode(s.first);
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
              leading: Icon(LucideIcons.logOut, color: theme.colorScheme.error),
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
                if (yes) await signOut(ref);
              },
            ),
          ),
        ],
      ),
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

/// The person's own Google account: tasks in their calendar. Saving files to
/// Drive is offered on each file.
class _GoogleCard extends ConsumerWidget {
  const _GoogleCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final calendar = ref.watch(calendarProvider);
    final notifier = ref.read(calendarProvider.notifier);
    return Card(
      child: Column(
        children: [
          SwitchListTile(
            key: const Key('calendarAuto'),
            secondary: const Icon(LucideIcons.calendarDays),
            title: Text(l.googleCalendarAuto),
            subtitle: Text(l.googleCalendarAutoHint),
            value: calendar.auto,
            onChanged: (on) => runAction(context, () async {
              final tasks = on
                  ? await ref.read(myTasksProvider.future)
                  : const <Never>[];
              if (!await notifier.setAuto(on, tasks)) {
                throw const GoogleNotConnected();
              }
            }),
          ),
          ListTile(
            key: const Key('googleDisconnect'),
            leading: const Icon(LucideIcons.unlink),
            title: Text(l.googleDisconnect),
            onTap: () => runAction(context, () async {
              await notifier.forget();
              await ref.read(googleAccountProvider).disconnect();
            }, done: l.googleDisconnected),
          ),
        ],
      ),
    );
  }
}

/// Quiet hours: on or off, and from when to when.
class _QuietHoursCard extends ConsumerWidget {
  const _QuietHoursCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final quiet = ref.watch(quietHoursProvider).value;
    final offset = DateTime.now().timeZoneOffset.inMinutes;

    Future<void> save(TimeOfDay? from, TimeOfDay? to) async {
      final ok = await runAction(
        context,
        () => ref.read(apiProvider).setQuietHours(from, to, offset),
      );
      if (ok) ref.invalidate(quietHoursProvider);
    }

    Future<void> pick({required bool start}) async {
      final q = quiet!;
      final picked = await showTimePicker(
        context: context,
        initialTime: start ? q.from : q.to,
      );
      if (picked == null || !context.mounted) return;
      final from = start ? picked : q.from;
      final to = start ? q.to : picked;
      if (from == to) return;
      await save(from, to);
    }

    return Card(
      child: Column(
        children: [
          SwitchListTile(
            key: const Key('quietHours'),
            secondary: const Icon(LucideIcons.moon),
            title: Text(l.quietHours),
            subtitle: Text(l.quietHoursHint),
            value: quiet != null,
            onChanged: (on) => on
                ? save(
                    const TimeOfDay(hour: 22, minute: 0),
                    const TimeOfDay(hour: 7, minute: 0),
                  )
                : save(null, null),
          ),
          if (quiet != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      key: const Key('quietFrom'),
                      onPressed: () => pick(start: true),
                      child: Text(
                        '${l.quietFrom} ${quiet.from.format(context)}',
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton(
                      key: const Key('quietTo'),
                      onPressed: () => pick(start: false),
                      child: Text('${l.quietTo} ${quiet.to.format(context)}'),
                    ),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
            child: Row(
              children: [
                Icon(
                  LucideIcons.bellOff,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l.mutedChatsHint,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One's status, a tap from changing it.
class _StatusCard extends ConsumerWidget {
  const _StatusCard({required this.workspaceId});

  final String workspaceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final status = myStatus(ref, workspaceId);
    return Card(
      child: ListTile(
        key: const Key('statusTile'),
        leading: Icon(
          presenceIcon(status?.kind),
          color: presenceColor(context, status?.kind),
        ),
        title: Text(
          status == null ? l.statusAvailable : presenceText(context, status),
        ),
        subtitle: status?.note == null ? null : Text(status!.note!),
        trailing: const Icon(LucideIcons.chevronRightDir),
        onTap: () => showStatusSheet(context, ref, workspaceId: workspaceId),
      ),
    );
  }
}

/// For whoever runs a team: the Sunday report, on or off.
class _WeeklyReportCard extends ConsumerWidget {
  const _WeeklyReportCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final on = ref.watch(weeklyReportProvider).value;
    return Card(
      child: SwitchListTile(
        key: const Key('weeklyReport'),
        secondary: const Icon(LucideIcons.chartLine),
        title: Text(l.weeklyReportTitle),
        subtitle: Text(l.weeklyReportHint),
        value: on ?? true,
        onChanged: on == null
            ? null
            : (value) async {
                final ok = await runAction(
                  context,
                  () => ref.read(apiProvider).setWeeklyReport(value),
                );
                if (ok) ref.invalidate(weeklyReportProvider);
              },
      ),
    );
  }
}
