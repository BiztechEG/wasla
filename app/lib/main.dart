import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'config.dart';
import 'data/api.dart';
import 'push/firebase_push.dart';
import 'push/push.dart';
import 'state/providers.dart';
import 'state/settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    publishableKey: AppConfig.supabaseKey,
  );
  final push = await FirebasePush.start();

  runApp(
    ProviderScope(
      // Screens show errors with a retry button instead of silently retrying.
      retry: (_, _) => null,
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        apiProvider.overrideWithValue(
          SupabaseWaslaApi(Supabase.instance.client),
        ),
        if (push != null) pushMessagingProvider.overrideWithValue(push),
      ],
      child: const WaslaApp(),
    ),
  );
}
