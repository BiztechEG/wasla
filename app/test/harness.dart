import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wasla/app.dart';
import 'package:wasla/data/chat_models.dart';
import 'package:wasla/data/google.dart';
import 'package:wasla/data/picker.dart';
import 'package:wasla/data/voice.dart';
import 'package:wasla/push/push.dart';
import 'package:wasla/state/chat_providers.dart';
import 'package:wasla/state/google_providers.dart';
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
  VoiceRecorder? recorder,
  GoogleAccount? google,
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
        if (recorder != null) voiceRecorderProvider.overrideWithValue(recorder),
        googleAccountProvider.overrideWithValue(google ?? FakeGoogle()),
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

/// Records nothing; hands over a few bytes as the recording.
class FakeRecorder implements VoiceRecorder {
  FakeRecorder({this.allowed = true});

  final bool allowed;
  int cancelled = 0;

  @override
  Future<bool> start() async => allowed;

  @override
  Future<Upload?> stop(Duration length) async => Upload(
    bytes: Uint8List.fromList([1, 2, 3]),
    name: voiceName(length, 'm4a'),
    mime: 'audio/mp4',
  );

  @override
  Future<void> cancel() async => cancelled++;
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

/// A Google account that keeps Drive files and calendar events in memory.
class FakeGoogle implements GoogleAccount {
  FakeGoogle({this.available = true, this.allows = true});

  @override
  final bool available;

  /// What the person answers when asked for access.
  bool allows;
  final allowed = <String>{};
  final events = <String, CalendarEvent>{};
  final drive = <String>[];
  int _seq = 0;

  @override
  Future<bool> connect(List<String> scopes) async {
    if (allows) allowed.addAll(scopes);
    return allows;
  }

  @override
  Future<bool> hasAccess(List<String> scopes) async =>
      scopes.every(allowed.contains);

  @override
  Future<String> saveToDrive({
    required String name,
    required String mime,
    required String source,
  }) async {
    if (!await connect([driveScope])) throw const GoogleNotConnected();
    drive.add(name);
    return 'https://drive.google.com/file/d/f${drive.length}/view';
  }

  @override
  Future<String> putEvent(CalendarEvent event, {String? eventId}) async {
    final id = eventId != null && events.containsKey(eventId)
        ? eventId
        : 'e${_seq++}';
    events[id] = event;
    return id;
  }

  @override
  Future<void> deleteEvent(String eventId) async => events.remove(eventId);

  @override
  Future<void> disconnect() async => allowed.clear();
}
