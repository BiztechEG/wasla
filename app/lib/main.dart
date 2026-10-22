import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'config.dart';
import 'data/api.dart';
import 'push/firebase_push.dart';
import 'push/push.dart';
import 'push/web_push.dart';
import 'state/providers.dart';
import 'state/settings.dart';
import 'ui/join_link.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) {
    // A right click opens the app's own menu (on a message, a file…), not
    // the browser's on top of it; text fields get Flutter's copy and paste.
    await BrowserContextMenu.disableContextMenu();
  }
  final prefs = await SharedPreferences.getInstance();
  // A join link (…/app/?join=CODE) is kept until someone has signed in.
  final join = kIsWeb ? Uri.base.queryParameters['join'] : null;
  if (join != null && join.trim().isNotEmpty) {
    await prefs.setString(PendingJoinCode.key, join.trim());
  }
  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    publishableKey: AppConfig.supabaseKey,
  );
  final api = SupabaseWaslaApi(Supabase.instance.client);
  // Phones through Firebase; browsers through Web Push.
  final push = await FirebasePush.start() ?? startWebPush(api.webPushKey);

  runApp(
    ProviderScope(
      // Screens show errors with a retry button instead of silently retrying.
      retry: (_, _) => null,
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        apiProvider.overrideWithValue(api),
        if (push != null) pushMessagingProvider.overrideWithValue(push),
      ],
      child: const WaslaApp(),
    ),
  );
}
