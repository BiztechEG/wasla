import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wasla/app.dart';
import 'package:wasla/state/providers.dart';
import 'package:wasla/state/settings.dart';

import 'fake_api.dart';

/// Starts the whole app against [api], as on a fresh phone.
Future<void> startApp(
  WidgetTester tester,
  FakeApi api, {
  Map<String, Object> prefs = const {},
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final p = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: [
        prefsProvider.overrideWithValue(p),
        apiProvider.overrideWithValue(api),
      ],
      child: const WaslaApp(),
    ),
  );
  await tester.pumpAndSettle();
}

/// A 360x640 phone, the smallest the app is designed for.
void smallPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(360, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}
