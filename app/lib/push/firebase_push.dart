import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'firebase_options.dart';
import 'push.dart';

/// Phone notifications through Firebase Cloud Messaging.
class FirebasePush implements PushMessaging {
  FirebasePush._();

  /// Null on the web and on iOS (until the Apple developer account exists),
  /// or when Firebase can't start; the app then runs without phone
  /// notifications.
  static Future<FirebasePush?> start() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      await Firebase.initializeApp(options: androidFirebaseOptions);
      return FirebasePush._();
    } catch (e) {
      debugPrint('phone notifications are off: $e');
      return null;
    }
  }

  FirebaseMessaging get _fcm => FirebaseMessaging.instance;

  @override
  Future<String?> token() async {
    try {
      final settings = await _fcm.requestPermission();
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        return null;
      }
      return await _fcm.getToken();
    } catch (e) {
      // No Google Play services, or offline; tried again at the next start.
      debugPrint('no notification token: $e');
      return null;
    }
  }

  @override
  Stream<String> get tokenChanges => _fcm.onTokenRefresh;

  @override
  Future<Map<String, String>?> openedAtStart() async {
    final m = await _fcm.getInitialMessage();
    return m == null ? null : _strings(m.data);
  }

  @override
  Stream<Map<String, String>> get opened =>
      FirebaseMessaging.onMessageOpenedApp.map((m) => _strings(m.data));

  @override
  String get platform =>
      defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';

  static Map<String, String> _strings(Map<String, dynamic> data) => {
    for (final e in data.entries)
      if (e.value != null) e.key: '${e.value}',
  };
}
