import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../push/push.dart';
import '../push/web_push.dart';
import '../state/settings.dart';
import 'widgets.dart';

/// Whether this browser shows the app's notifications; null outside a
/// browser that can.
final notifyPermissionProvider =
    NotifierProvider<NotifyPermissionNotifier, NotifyPermission?>(
      NotifyPermissionNotifier.new,
    );

class NotifyPermissionNotifier extends Notifier<NotifyPermission?> {
  BrowserNotifications? get _browser {
    final push = ref.read(pushMessagingProvider);
    return push is BrowserNotifications ? push as BrowserNotifications : null;
  }

  @override
  NotifyPermission? build() {
    ref.watch(pushMessagingProvider);
    return _browser?.permission;
  }

  /// Asks the browser, and once allowed registers it for notifications.
  Future<void> ask() async {
    final browser = _browser;
    if (browser == null) return;
    _set(await browser.ask());
  }

  /// Reads the answer again: it may have changed in the browser's settings.
  void recheck() {
    if (_browser case final browser?) _set(browser.permission);
  }

  void _set(NotifyPermission now) {
    final was = state;
    state = now;
    if (now == NotifyPermission.granted && was != now) {
      ref.invalidate(pushSyncProvider);
    }
  }
}

/// In My account, in a browser: desktop notifications, on or how to.
class DesktopNotificationsCard extends ConsumerStatefulWidget {
  const DesktopNotificationsCard({super.key});

  @override
  ConsumerState<DesktopNotificationsCard> createState() =>
      _DesktopNotificationsCardState();
}

class _DesktopNotificationsCardState
    extends ConsumerState<DesktopNotificationsCard> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(notifyPermissionProvider.notifier).recheck();
    });
  }

  @override
  Widget build(BuildContext context) {
    final permission = ref.watch(notifyPermissionProvider);
    if (permission == null) return const SizedBox.shrink();
    final l = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      key: const Key('desktopNotifications'),
      child: ListTile(
        contentPadding: const EdgeInsetsDirectional.fromSTEB(16, 8, 12, 8),
        leading: Icon(
          switch (permission) {
            NotifyPermission.granted => LucideIcons.bellRing,
            NotifyPermission.denied => LucideIcons.bellOff,
            NotifyPermission.ask => LucideIcons.bell,
          },
          color: permission == NotifyPermission.granted ? scheme.primary : null,
        ),
        title: Text(l.desktopNotifications),
        subtitle: Text(switch (permission) {
          NotifyPermission.granted => l.desktopNotificationsOn,
          NotifyPermission.denied => l.desktopNotificationsBlocked,
          NotifyPermission.ask => l.desktopNotificationsHint,
        }),
        trailing: permission == NotifyPermission.ask
            ? FilledButton.tonal(
                key: const Key('turnOnDesktopNotifications'),
                onPressed: () =>
                    ref.read(notifyPermissionProvider.notifier).ask(),
                child: Text(l.turnOn),
              )
            : null,
      ),
    );
  }
}

/// At the top of the chats, in a browser that hasn't been asked yet: an
/// offer to turn desktop notifications on, until taken or put off.
class DesktopNotificationsBanner extends ConsumerWidget {
  const DesktopNotificationsBanner({super.key});

  static const _laterKey = 'desktop_notifications_later';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(prefsProvider);
    if (ref.watch(notifyPermissionProvider) != NotifyPermission.ask ||
        ref.watch(_laterProvider) ||
        prefs.getBool(_laterKey) == true) {
      return const SizedBox.shrink();
    }
    final l = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      key: const Key('desktopNotificationsBanner'),
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Material(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(16, 10, 8, 10),
          child: Row(
            children: [
              Icon(LucideIcons.bellRing, color: scheme.onPrimaryContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  l.desktopNotificationsOffer,
                  style: TextStyle(color: scheme.onPrimaryContainer),
                ),
              ),
              TextButton(
                onPressed: () async {
                  ref.read(_laterProvider.notifier).set();
                  await prefs.setBool(_laterKey, true);
                },
                child: Text(l.later),
              ),
              FilledButton(
                key: const Key('bannerTurnOn'),
                onPressed: () =>
                    ref.read(notifyPermissionProvider.notifier).ask(),
                child: Text(l.turnOn),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The offer was put off on this device.
final _laterProvider = NotifierProvider<_Later, bool>(_Later.new);

class _Later extends Notifier<bool> {
  @override
  bool build() => false;

  void set() => state = true;
}
