import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

import 'push.dart';
import 'web_push.dart';

PushMessaging? platformWebPush(Future<String?> Function() publicKey) {
  final navigator = web.window.navigator as JSObject;
  if (!globalContext.has('Notification') ||
      !globalContext.has('PushManager') ||
      !navigator.has('serviceWorker')) {
    return null;
  }
  return _WebPush(publicKey);
}

/// The browser's push subscription, through the app's own service worker
/// (web/push_sw.js). Its token is the subscription as JSON: where to send
/// and the keys to encrypt with.
class _WebPush implements PushMessaging, BrowserNotifications {
  _WebPush(this._publicKey) {
    final container = web.window.navigator.serviceWorker;
    container.addEventListener(
      'message',
      (web.MessageEvent e) {
        final data = e.data.dartify();
        if (data is Map && data['waslaPush'] is Map) {
          _opened.add(_strings(data['waslaPush'] as Map));
        }
      }.toJS,
    );
    // Messages from a worker that does not control the page wait for this.
    container.startMessages();
  }

  final Future<String?> Function() _publicKey;
  final _opened = StreamController<Map<String, String>>.broadcast();

  @override
  String get platform => 'web';

  @override
  NotifyPermission get permission => switch (web.Notification.permission) {
    'granted' => NotifyPermission.granted,
    'denied' => NotifyPermission.denied,
    _ => NotifyPermission.ask,
  };

  @override
  Future<NotifyPermission> ask() async {
    try {
      await web.Notification.requestPermission().toDart;
    } catch (e) {
      debugPrint('notification permission: $e');
    }
    return permission;
  }

  @override
  Future<String?> token() async {
    if (permission != NotifyPermission.granted) return null;
    try {
      final key = await _publicKey();
      if (key == null) return null;
      final serverKey = _unbase64(key);
      // Its own scope, apart from the page's (which Flutter's worker uses).
      final reg = await web.window.navigator.serviceWorker
          .register('push_sw.js'.toJS, web.RegistrationOptions(scope: 'push/'))
          .toDart;
      await _activated(reg);
      var sub = await reg.pushManager.getSubscription().toDart;
      if (sub != null &&
          !_same(sub.options.applicationServerKey?.toDart, serverKey)) {
        // Made with an older key: the server could no longer reach it.
        await sub.unsubscribe().toDart;
        sub = null;
      }
      sub ??= await reg.pushManager
          .subscribe(
            web.PushSubscriptionOptionsInit(
              userVisibleOnly: true,
              applicationServerKey: serverKey.toJS,
            ),
          )
          .toDart;
      String key64(String name) =>
          _base64(sub!.getKey(name)!.toDart.asUint8List());
      return jsonEncode({
        'endpoint': sub.endpoint,
        'keys': {'p256dh': key64('p256dh'), 'auth': key64('auth')},
      });
    } catch (e) {
      // Tried again at the next start.
      debugPrint('no desktop notifications: $e');
      return null;
    }
  }

  @override
  Stream<String> get tokenChanges => const Stream.empty();

  /// A notification clicked while the app was closed opens it with
  /// ?push=…; the address is then put back as it was.
  @override
  Future<Map<String, String>?> openedAtStart() async {
    final raw = Uri.base.queryParameters['push'];
    if (raw == null) return null;
    final params = Map.of(Uri.base.queryParameters)..remove('push');
    web.window.history.replaceState(
      null,
      '',
      Uri.base
          .replace(queryParameters: params.isEmpty ? null : params)
          .toString(),
    );
    try {
      final data = jsonDecode(raw);
      return data is Map ? _strings(data) : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Stream<Map<String, String>> get opened => _opened.stream;

  /// Subscribing needs the worker running, not just installed.
  static Future<void> _activated(web.ServiceWorkerRegistration reg) async {
    final worker = reg.installing ?? reg.waiting;
    if (reg.active != null || worker == null) return;
    final done = Completer<void>();
    worker.addEventListener(
      'statechange',
      (web.Event _) {
        if (worker.state == 'activated' && !done.isCompleted) done.complete();
      }.toJS,
    );
    if (worker.state == 'activated') return;
    await done.future.timeout(const Duration(seconds: 20));
  }

  static bool _same(ByteBuffer? a, Uint8List b) {
    if (a == null) return false;
    final x = a.asUint8List();
    return x.length == b.length && listEquals(x, b);
  }

  static Uint8List _unbase64(String s) =>
      base64Url.decode(s.padRight((s.length + 3) ~/ 4 * 4, '='));

  static String _base64(Uint8List b) => base64Url.encode(b).replaceAll('=', '');

  static Map<String, String> _strings(Map<Object?, Object?> data) => {
    for (final e in data.entries)
      if (e.key != null && e.value != null) '${e.key}': '${e.value}',
  };
}
