import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wasla/app.dart';
import 'package:wasla/data/chat_models.dart';
import 'package:wasla/data/picker.dart';
import 'package:wasla/push/push.dart';
import 'package:wasla/state/chat_providers.dart';
import 'package:wasla/state/providers.dart';
import 'package:wasla/state/settings.dart';

import 'fake_api.dart';

/// Starts the whole app against [api], as on a fresh phone.
Future<void> startApp(
  WidgetTester tester,
  FakeApi api, {
  Map<String, Object> prefs = const {},
  Picker? picker,
  PushMessaging? push,
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final p = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: [
        prefsProvider.overrideWithValue(p),
        apiProvider.overrideWithValue(api),
        welcomeShownProvider.overrideWith((ref) async {}),
        if (picker != null) pickerProvider.overrideWithValue(picker),
        if (push != null) pushMessagingProvider.overrideWithValue(push),
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

/// Hands over [file] whatever one picks.
class FakePicker implements Picker {
  FakePicker(this.file);

  final Upload file;

  @override
  Future<Upload?> pickImage({required bool camera, int maxSide = 2048}) async =>
      file;

  @override
  Future<Upload?> pickVideo({required bool camera}) async => file;

  @override
  Future<Upload?> pickFile() async => file;
}
