import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import '../state/settings.dart';

/// The phone's notification service (Firebase Cloud Messaging), behind an
/// interface so tests and the web build go without it.
abstract class PushMessaging {
  /// Asks to show notifications (Android 13+ and iOS ask the person) and
  /// returns this phone's address for them, or null when not allowed.
  Future<String?> token();

  /// Fires when the phone's address changes.
  Stream<String> get tokenChanges;

  /// The notification the app was opened from, if it was.
  Future<Map<String, String>?> openedAtStart();

  /// Notifications tapped while the app was running in the background.
  Stream<Map<String, String>> get opened;

  String get platform;
}

/// No notifications: tests, the web, and phones without Firebase set up.
class NoPush implements PushMessaging {
  const NoPush();

  @override
  Future<String?> token() async => null;
  @override
  Stream<String> get tokenChanges => const Stream.empty();
  @override
  Future<Map<String, String>?> openedAtStart() async => null;
  @override
  Stream<Map<String, String>> get opened => const Stream.empty();
  @override
  String get platform => 'android';
}

final pushMessagingProvider = Provider<PushMessaging>((ref) => const NoPush());

/// A tapped notification waiting for the home screen to open it.
class PendingPush extends Notifier<Map<String, String>?> {
  @override
  Map<String, String>? build() => null;

  void set(Map<String, String>? data) => state = data;
}

final pendingPushProvider = NotifierProvider<PendingPush, Map<String, String>?>(
  PendingPush.new,
);

/// Keeps the server told which phone the signed-in person is on, and in
/// which language to write to them, and hands tapped notifications to the
/// home screen. Watched by the app for as long as it runs.
final pushSyncProvider = Provider<void>((ref) {
  final push = ref.watch(pushMessagingProvider);
  if (push is NoPush) return;
  final api = ref.watch(apiProvider);
  final user = ref.watch(authProvider).value;
  final locale = ref.watch(settingsProvider.select((s) => s.locale));

  final subs = <StreamSubscription<Object?>>[
    push.opened.listen(ref.read(pendingPushProvider.notifier).set),
  ];
  ref.onDispose(() {
    for (final s in subs) {
      s.cancel();
    }
  });
  if (user == null) return;

  Future<void> register(String? token) async {
    if (token == null) return;
    await ref.read(prefsProvider).setString(_tokenKey, token);
    try {
      await api.registerPushToken(token, push.platform, locale.languageCode);
    } catch (e) {
      // Tried again at the next start or language change.
      debugPrint('push registration failed: $e');
    }
  }

  push.token().then(register);
  subs.add(push.tokenChanges.listen(register));
});

const _tokenKey = 'push_token';

/// Signs out, first telling the server this phone is no longer theirs.
Future<void> signOut(WidgetRef ref) async {
  final api = ref.read(apiProvider);
  final token = ref.read(prefsProvider).getString(_tokenKey);
  if (token != null) {
    try {
      await api.unregisterPushToken(token);
    } catch (_) {
      // Offline: the server forgets the phone once someone else signs in on
      // it, or after 90 days.
    }
  }
  await api.signOut();
}
