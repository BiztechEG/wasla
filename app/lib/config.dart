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
}
