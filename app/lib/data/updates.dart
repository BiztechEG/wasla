import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config.dart';

/// A newer Android app on the website, to download and install over this
/// one (the app is not in an app store yet).
class AppRelease {
  const AppRelease({
    required this.version,
    required this.build,
    required this.url,
    this.bytes,
  });

  final String version;
  final int build;

  /// Where the APK downloads from.
  final String url;
  final int? bytes;
}

/// Looks for a newer app. Tests swap in a fake.
abstract class UpdateChecker {
  /// The newer release, or null when this one is the latest (or there is
  /// no telling: the web, a build without a number, offline).
  Future<AppRelease?> newer();
}

/// Reads download/version.json from the site the app was built for, which
/// the website workflow writes next to the APK.
class SiteUpdateChecker implements UpdateChecker {
  @override
  Future<AppRelease?> newer() async {
    final site = AppConfig.siteUrl.replaceFirst(RegExp(r'/+$'), '');
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android ||
        AppConfig.buildNumber == 0 ||
        site.isEmpty) {
      return null;
    }
    final res = await http
        .get(Uri.parse('$site/download/version.json'))
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) return null;
    final json = jsonDecode(res.body);
    if (json is! Map) return null;
    final build = json['build'];
    if (build is! int || build <= AppConfig.buildNumber) return null;
    return AppRelease(
      version: '${json['version'] ?? ''}',
      build: build,
      bytes: json['bytes'] is int ? json['bytes'] as int : null,
      url: '$site/download/wasla.apk',
    );
  }
}
