/// Where the app finds its backend.
///
/// The defaults point at the hosted Supabase project. Both values are public
/// (the publishable key only allows what Row Level Security allows), and a
/// self-hosted server can be used with:
///   flutter run --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_KEY=...
class AppConfig {
  static const supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://qbefpiuglhsgcgwsaocn.supabase.co',
  );

  static const supabaseKey = String.fromEnvironment(
    'SUPABASE_KEY',
    defaultValue: 'sb_publishable_f0s_ZGnr-fOq-OPCG1-bsA_isXiRQma',
  );

  /// The website people download the app from, put in invitations sent
  /// outside the app (--dart-define=SITE_URL=https://...). In a browser the
  /// app's own site is used when this is empty.
  static const siteUrl = String.fromEnvironment('SITE_URL');

  /// This build's number (--dart-define=BUILD_NUMBER=...), the same as the
  /// Android version code; 0 for builds without one, which don't look for
  /// updates.
  static const buildNumber = int.fromEnvironment('BUILD_NUMBER');
}
