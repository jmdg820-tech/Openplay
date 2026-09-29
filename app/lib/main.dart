import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';
import 'screens/auth_screen.dart';
import 'screens/home_shell.dart';
import 'services/openplay_api.dart';
import 'theme/app_colors.dart';
import 'theme/app_spacing.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (AppConfig.isConfigured) {
    await Supabase.initialize(
      url: AppConfig.supabaseUrl,
      publishableKey: AppConfig.supabaseAnonKey,
    );
  }
  runApp(const OpenPlayApp());
}

class OpenPlayApp extends StatelessWidget {
  const OpenPlayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OpenPlay',
      theme: AppTheme.light,
      home: AppConfig.isConfigured ? const AuthGate() : const _NotConfiguredScreen(),
    );
  }
}

/// Shown instead of crashing on a missing backend config, so `flutter
/// build`/manual smoke checks always produce a usable app shell even when
/// SUPABASE_URL/SUPABASE_ANON_KEY weren't passed via --dart-define.
class _NotConfiguredScreen extends StatelessWidget {
  const _NotConfiguredScreen();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: const BoxDecoration(color: AppColors.courtTealPale, shape: BoxShape.circle),
                child: const Icon(Icons.settings_outlined, size: 28, color: AppColors.courtTealDeep),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text('OpenPlay is not configured', style: theme.textTheme.titleMedium),
              const SizedBox(height: AppSpacing.sm),
              Container(
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: AppColors.ink,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: const Text(
                  '--dart-define=SUPABASE_URL=<url>\n'
                  '--dart-define=SUPABASE_ANON_KEY=<anon key>',
                  style: TextStyle(color: AppColors.white, fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  late final Stream<AuthState> _authStream;

  /// A guest has no OpenPlay account by definition, so "not signed in" must
  /// not mean "stuck on the sign-in form" -- venues/sessions/roster are
  /// already anon-readable per RLS, and join_session()/leave_session()/
  /// confirm_promotion() already accept anon callers for the guest path
  /// (all covered by the executed DB suite). This flag is purely a client
  /// navigation choice, reset back to false on an explicit real sign-in
  /// (the StreamBuilder below fires on that regardless).
  bool _browsingWithoutAccount = false;

  @override
  void initState() {
    super.initState();
    _authStream = Supabase.instance.client.auth.onAuthStateChange;
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: _authStream,
      builder: (context, snapshot) {
        final session = Supabase.instance.client.auth.currentSession;
        final api = OpenPlayApi(Supabase.instance.client);
        if (session == null && !_browsingWithoutAccount) {
          return AuthScreen(
            api: api,
            onContinueWithoutAccount: () => setState(() => _browsingWithoutAccount = true),
          );
        }
        return HomeShell(
          api: api,
          onSignInRequested:
              session == null ? () => setState(() => _browsingWithoutAccount = false) : null,
        );
      },
    );
  }
}
