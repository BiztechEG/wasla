import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/updates.dart';
import '../state/settings.dart';
import 'chat_format.dart';
import 'widgets.dart';

final updateCheckerProvider = Provider<UpdateChecker>(
  (ref) => SiteUpdateChecker(),
);

/// A newer Android app on the website, looked for once a run; null when
/// there is none or no telling.
final appUpdateProvider = FutureProvider<AppRelease?>((ref) async {
  try {
    return await ref.watch(updateCheckerProvider).newer();
  } catch (_) {
    // Offline or the site is down: asked again at the next start.
    return null;
  }
});

/// Downloads the new APK in the browser, and says what to do with it.
Future<void> downloadUpdate(BuildContext context, AppRelease release) async {
  final l = context.l10n;
  await openLink(context, release.url);
  if (context.mounted) showMessage(context, l.updateInstallHint);
}

/// At the top of the chats when a newer app is out, until updated or put
/// off for that version.
class UpdateBanner extends ConsumerWidget {
  const UpdateBanner({super.key});

  static String _laterKey(AppRelease r) => 'update_later_${r.build}';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final release = ref.watch(appUpdateProvider).value;
    final prefs = ref.watch(prefsProvider);
    if (release == null ||
        ref.watch(_putOffProvider) == release.build ||
        prefs.getBool(_laterKey(release)) == true) {
      return const SizedBox.shrink();
    }
    final l = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      key: const Key('updateBanner'),
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Material(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(16, 10, 8, 10),
          child: Row(
            children: [
              Icon(LucideIcons.download, color: scheme.onTertiaryContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  l.updateAvailable(release.version),
                  style: TextStyle(color: scheme.onTertiaryContainer),
                ),
              ),
              TextButton(
                onPressed: () async {
                  ref.read(_putOffProvider.notifier).set(release.build);
                  await prefs.setBool(_laterKey(release), true);
                },
                child: Text(l.later),
              ),
              FilledButton(
                key: const Key('updateNow'),
                onPressed: () => downloadUpdate(context, release),
                child: Text(l.updateApp),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// In My account while a newer app is out, even after the banner was put
/// off.
class UpdateTile extends ConsumerWidget {
  const UpdateTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final release = ref.watch(appUpdateProvider).value;
    if (release == null) return const SizedBox.shrink();
    final l = context.l10n;
    return Card(
      key: const Key('updateTile'),
      child: ListTile(
        leading: const Icon(LucideIcons.download),
        title: Text(l.updateAvailable(release.version)),
        subtitle: release.bytes == null
            ? null
            : Text(fileSize(l, release.bytes!)),
        trailing: FilledButton.tonal(
          onPressed: () => downloadUpdate(context, release),
          child: Text(l.updateApp),
        ),
      ),
    );
  }
}

/// The version whose banner was put off in this run.
final _putOffProvider = NotifierProvider<_PutOff, int?>(_PutOff.new);

class _PutOff extends Notifier<int?> {
  @override
  int? build() => null;

  void set(int build) => state = build;
}
