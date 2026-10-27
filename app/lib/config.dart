/// Where the agent lives. The URL and the publishable key are public by design (every app user needs them);
/// the Meta key never leaves Supabase. Build with:
///   flutter build apk --dart-define=SUPA_KEY=sb_publishable_...
class AppConfig {
  static const supabaseUrl = String.fromEnvironment(
    'SUPA_URL',
    defaultValue: 'https://vldudnzlnkxqjnhwepqq.supabase.co',
  );
  static const supabaseKey = String.fromEnvironment('SUPA_KEY');
}
