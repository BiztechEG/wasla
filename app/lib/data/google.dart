import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;

/// Wasla's Google Cloud OAuth client (web type). It is public: Google only
/// accepts it from wasla's web address and from the Android app signed with
/// its key. A self-hosted copy can use its own with
/// --dart-define=GOOGLE_CLIENT_ID=...
const googleClientId = String.fromEnvironment(
  'GOOGLE_CLIENT_ID',
  defaultValue: '412515268708-9ab7kg5dk06f13rr5ouc3kh2stcif1cj.apps.googleusercontent.com',
);

/// Files Wasla saves to Drive; it can't see anything else there.
const driveScope = 'https://www.googleapis.com/auth/drive.file';

/// Events in the person's calendars, to add their tasks.
const calendarScope = 'https://www.googleapis.com/auth/calendar.events';

/// What a task looks like as a calendar event.
class CalendarEvent {
  const CalendarEvent({
    required this.title,
    required this.details,
    required this.start,
    required this.end,
  });

  final String title;
  final String details;
  final DateTime start;
  final DateTime end;

  /// Changes when the event needs updating.
  String get stamp =>
      '${title.hashCode}.${details.hashCode}.${end.millisecondsSinceEpoch}';
}

/// The person's own Google account: Drive and Calendar. Tests swap in a fake.
abstract class GoogleAccount {
  /// False on phones where Google sign-in isn't set up yet (iPhone).
  bool get available;

  /// Asks the person to allow [scopes]; false when they say no.
  Future<bool> connect(List<String> scopes);

  /// True when [scopes] are allowed and no prompt is needed.
  Future<bool> hasAccess(List<String> scopes);

  /// Copies the file at [source] to the person's Drive and returns a link to
  /// it there.
  Future<String> saveToDrive({
    required String name,
    required String mime,
    required String source,
  });

  /// Adds or updates an event in the person's main calendar and returns its
  /// id. A [eventId] that was deleted there is added again.
  Future<String> putEvent(CalendarEvent event, {String? eventId});

  /// Removes an event; one already gone is fine.
  Future<void> deleteEvent(String eventId);

  Future<void> disconnect();
}

/// Thrown when the person hasn't allowed (or has taken back) access.
class GoogleNotConnected implements Exception {
  const GoogleNotConnected();
}

class GoogleApiAccount implements GoogleAccount {
  GoogleApiAccount();

  Future<void>? _ready;

  @override
  bool get available =>
      kIsWeb || defaultTargetPlatform == TargetPlatform.android;

  Future<void> _init() => _ready ??= GoogleSignIn.instance.initialize(
    clientId: kIsWeb ? googleClientId : null,
    serverClientId: kIsWeb ? null : googleClientId,
  );

  /// Tokens already given, by scope: the web can't hand them out again
  /// without asking. Google's tokens last an hour.
  final _tokens = <String, (String, DateTime)>{};

  Future<String?> _token(List<String> scopes, {bool prompt = false}) async {
    final key = scopes.join(' ');
    final kept = _tokens[key];
    if (kept != null && DateTime.now().isBefore(kept.$2)) return kept.$1;
    await _init();
    final client = GoogleSignIn.instance.authorizationClient;
    final authz =
        await client.authorizationForScopes(scopes) ??
        (prompt ? await client.authorizeScopes(scopes) : null);
    if (authz == null) return null;
    _tokens[key] = (
      authz.accessToken,
      DateTime.now().add(const Duration(minutes: 50)),
    );
    return authz.accessToken;
  }

  @override
  Future<bool> connect(List<String> scopes) async {
    try {
      return await _token(scopes, prompt: true) != null;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) return false;
      rethrow;
    }
  }

  @override
  Future<bool> hasAccess(List<String> scopes) async {
    try {
      return await _token(scopes) != null;
    } catch (_) {
      return false;
    }
  }

  /// Sends a request with a token for [scopes], asking for access first if
  /// needed. A token Google no longer accepts is dropped and asked for again.
  Future<http.Response> _send(
    List<String> scopes,
    Future<http.Response> Function(Map<String, String> headers) request, {
    bool prompt = true,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final token = await _token(scopes, prompt: prompt);
      if (token == null) throw const GoogleNotConnected();
      final res = await request({'Authorization': 'Bearer $token'});
      if (res.statusCode != 401) return res;
      _tokens.remove(scopes.join(' '));
      await GoogleSignIn.instance.authorizationClient.clearAuthorizationToken(
        accessToken: token,
      );
    }
    throw const GoogleNotConnected();
  }

  Never _fail(http.Response res) =>
      throw Exception('Google ${res.statusCode}: ${res.body}');

  @override
  Future<String> saveToDrive({
    required String name,
    required String mime,
    required String source,
  }) async {
    // Access first, so a "no" doesn't cost a download.
    if (await _token([driveScope], prompt: true) == null) {
      throw const GoogleNotConnected();
    }
    final file = await http.get(Uri.parse(source));
    if (file.statusCode != 200) _fail(file);
    final bytes = file.bodyBytes;
    const boundary = 'wasla-upload-boundary';
    final body = BytesBuilder()
      ..add(
        utf8.encode(
          '--$boundary\r\n'
          'Content-Type: application/json; charset=UTF-8\r\n\r\n'
          '${jsonEncode({'name': name})}\r\n'
          '--$boundary\r\n'
          'Content-Type: $mime\r\n\r\n',
        ),
      )
      ..add(bytes)
      ..add(utf8.encode('\r\n--$boundary--'));
    final res = await _send(
      [driveScope],
      (headers) => http.post(
        Uri.https('www.googleapis.com', '/upload/drive/v3/files', {
          'uploadType': 'multipart',
          'fields': 'webViewLink',
        }),
        headers: {
          ...headers,
          'Content-Type': 'multipart/related; boundary=$boundary',
        },
        body: body.takeBytes(),
      ),
    );
    if (res.statusCode != 200) _fail(res);
    return (jsonDecode(res.body) as Map<String, dynamic>)['webViewLink']
        as String;
  }

  static final _events = Uri.https(
    'www.googleapis.com',
    '/calendar/v3/calendars/primary/events',
  );

  @override
  Future<String> putEvent(CalendarEvent event, {String? eventId}) async {
    final body = jsonEncode({
      'summary': event.title,
      'description': event.details,
      'start': {'dateTime': event.start.toUtc().toIso8601String()},
      'end': {'dateTime': event.end.toUtc().toIso8601String()},
      // A Wasla task brings its own reminders; Google's default would add
      // a second set.
      'reminders': {'useDefault': false},
    });
    Future<http.Response> send(Map<String, String> headers, String? id) {
      final h = {...headers, 'Content-Type': 'application/json'};
      return id == null
          ? http.post(_events, headers: h, body: body)
          : http.put(
              _events.replace(path: '${_events.path}/$id'),
              headers: h,
              body: body,
            );
    }

    var res = await _send([calendarScope], (h) => send(h, eventId));
    // Deleted in Google Calendar: add it again.
    if (eventId != null && (res.statusCode == 404 || res.statusCode == 410)) {
      res = await _send([calendarScope], (h) => send(h, null));
    }
    if (res.statusCode != 200) _fail(res);
    final saved = jsonDecode(res.body) as Map<String, dynamic>;
    // An event someone deleted stays readable as "cancelled"; put it back.
    if (saved['status'] == 'cancelled') {
      return putEvent(event);
    }
    return saved['id'] as String;
  }

  @override
  Future<void> deleteEvent(String eventId) async {
    final res = await _send(
      [calendarScope],
      (h) => http.delete(
        _events.replace(path: '${_events.path}/$eventId'),
        headers: h,
      ),
    );
    if (res.statusCode >= 300 &&
        res.statusCode != 404 &&
        res.statusCode != 410) {
      _fail(res);
    }
  }

  @override
  Future<void> disconnect() async {
    // Taking back the access Wasla was given, not just forgetting it: one
    // token revokes the whole grant.
    var token = _tokens.values.firstOrNull?.$1;
    for (final scope in [calendarScope, driveScope]) {
      token ??= await _token([scope]).catchError((_) => null);
    }
    _tokens.clear();
    if (token != null) {
      await http.post(
        Uri.https('oauth2.googleapis.com', '/revoke', {'token': token}),
      );
    }
    try {
      await GoogleSignIn.instance.disconnect();
    } catch (_) {}
  }
}
