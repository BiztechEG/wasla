import 'push.dart';
import 'web_push_none.dart' if (dart.library.js_interop) 'web_push_web.dart';

/// Whether the browser may show the app's notifications.
enum NotifyPermission {
  /// Not asked yet: the browser asks when the person clicks to turn them on.
  ask,
  granted,

  /// Turned down; only the browser's site settings can undo it.
  denied,
}

/// A browser's say over desktop notifications. Browsers only ask after a
/// click, so the app asks from a button.
abstract class BrowserNotifications {
  NotifyPermission get permission;

  /// Asks the person (the browser's own prompt) and returns the answer.
  Future<NotifyPermission> ask();
}

/// Desktop notifications in this browser (Web Push), subscribed with the
/// key from [publicKey]; null outside a browser, or in one without Web
/// Push. What it returns is a [PushMessaging] and a [BrowserNotifications].
PushMessaging? startWebPush(Future<String?> Function() publicKey) =>
    platformWebPush(publicKey);
