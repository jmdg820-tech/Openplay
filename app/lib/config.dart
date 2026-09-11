/// OPENPLAY runtime configuration.
///
/// Never hardcode real project credentials here. Both values are read from
/// `--dart-define` at build/run time so the same code works against any
/// environment (a local Supabase stack, a dev project, production) without
/// editing source:
///
///   flutter run -d chrome \
///     --dart-define=SUPABASE_URL=http://127.0.0.1:54321 \
///     --dart-define=SUPABASE_ANON_KEY=`local-anon-key`
///
/// The defaults below point at the conventional local Supabase CLI stack
/// addresses (`supabase start`) purely so `flutter analyze`/`flutter build`
/// succeed without extra flags; they are not a live, reachable backend by
/// themselves and must be overridden for any real run. See
/// docs/openplay-v3-architecture.md and the final implementation report for
/// this session's environment limitations (no Docker available locally).
class AppConfig {
  static const supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'http://127.0.0.1:54321',
  );

  static const supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: '',
  );

  static bool get isConfigured => supabaseAnonKey.isNotEmpty;
}
