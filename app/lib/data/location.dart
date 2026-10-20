import 'dart:math';

import 'package:geolocator/geolocator.dart';

import 'attendance_models.dart';

/// Location services are switched off on the phone.
class LocationOff implements Exception {
  const LocationOff();
}

/// The person did not let Wasla use their location.
class LocationDenied implements Exception {
  const LocationDenied({this.forever = false});

  /// Only the phone's settings can allow it now.
  final bool forever;
}

/// Finds where the phone is. Tests swap in a fake.
abstract class Locator {
  /// Asks for permission when needed.
  Future<LocationFix> current();

  /// Opens the phone's settings for Wasla, to allow location there.
  Future<void> openSettings();
}

class DeviceLocator implements Locator {
  @override
  Future<LocationFix> current() async {
    if (!await Geolocator.isLocationServiceEnabled()) throw const LocationOff();
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) {
      throw const LocationDenied(forever: true);
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.unableToDetermine) {
      throw const LocationDenied();
    }
    final p = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 20),
      ),
    );
    return LocationFix(
      p.latitude,
      p.longitude,
      accuracyM: p.accuracy.isFinite ? p.accuracy.round() : null,
    );
  }

  @override
  Future<void> openSettings() async {
    await Geolocator.openAppSettings();
  }
}

/// Metres between two points, as the server measures them.
double distanceMeters(double lat1, double lng1, double lat2, double lng2) {
  double rad(double d) => d * pi / 180;
  final a =
      pow(sin(rad(lat2 - lat1) / 2), 2) +
      cos(rad(lat1)) * cos(rad(lat2)) * pow(sin(rad(lng2 - lng1) / 2), 2);
  return 2 * 6371000 * asin(min(1, sqrt(a)));
}

/// Where a check-in at [fix] lands, as the server decides it: the person's
/// branch, else the nearest branch with a point.
class PlaceCheck {
  const PlaceCheck({this.site, this.distanceM, required this.inside});

  final AttendanceSite? site;
  final int? distanceM;
  final bool inside;

  factory PlaceCheck.of(
    LocationFix fix, {
    AttendanceSite? own,
    required List<AttendanceSite> sites,
  }) {
    AttendanceSite? site = own;
    if (site == null) {
      double? best;
      for (final s in sites) {
        if (s.isField) continue;
        final d = distanceMeters(fix.lat, fix.lng, s.lat!, s.lng!);
        if (best == null || d < best) {
          best = d;
          site = s;
        }
      }
    }
    if (site == null) return const PlaceCheck(inside: true);
    if (site.isField) return PlaceCheck(site: site, inside: true);
    final d = distanceMeters(fix.lat, fix.lng, site.lat!, site.lng!).round();
    final slack = min(max(fix.accuracyM ?? 0, 0), 50);
    return PlaceCheck(
      site: site,
      distanceM: d,
      inside: d - slack <= site.radiusM,
    );
  }
}
