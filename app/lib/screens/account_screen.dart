import 'package:flutter/material.dart';

import '../services/openplay_api.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import 'blocked_users_screen.dart';
import 'my_sessions_screen.dart';

class AccountScreen extends StatelessWidget {
  const AccountScreen({super.key, required this.api, this.onSignInRequested});

  final OpenPlayApi api;

  /// Non-null only while browsing anonymously (see AuthGate/HomeShell).
  final VoidCallback? onSignInRequested;

  @override
  Widget build(BuildContext context) {
    // No Scaffold/AppBar here -- this is a tab body inside HomeShell's own
    // Scaffold (same "embedded" convention as VenueListScreen). Giving this
    // screen its own Scaffold as well used to render two stacked app bars
    // whenever the Account tab was selected.
    final theme = Theme.of(context);
    final signedIn = api.isSignedIn;
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: signedIn ? AppColors.courtTealPale : AppColors.cloudDim,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    signedIn ? Icons.person_rounded : Icons.person_outline_rounded,
                    color: signedIn ? AppColors.courtTealDeep : AppColors.slate,
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        signedIn ? 'Signed in' : "Browsing without an account",
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        signedIn
                            ? 'You can join, host, and manage your own sessions.'
                            : 'Sign in to join sessions as yourself, host, and report or block '
                                'other players. Joining as a guest still works either way.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        if (signedIn) ...[
          _AccountTile(
            icon: Icons.event_note_rounded,
            title: 'My sessions',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => MySessionsScreen(api: api)),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          _AccountTile(
            icon: Icons.block_rounded,
            title: 'Blocked users',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => BlockedUsersScreen(api: api)),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          _AccountTile(
            icon: Icons.logout_rounded,
            title: 'Sign out',
            destructive: true,
            onTap: api.signOut,
          ),
        ] else
          _AccountTile(
            icon: Icons.login_rounded,
            title: 'Sign in / Create account',
            onTap: onSignInRequested,
          ),
      ],
    );
  }
}

class _AccountTile extends StatelessWidget {
  const _AccountTile({
    required this.icon,
    required this.title,
    required this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final String title;
  final VoidCallback? onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final color = destructive ? AppColors.error : AppColors.ink;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
          child: Row(
            children: [
              Icon(icon, size: 20, color: destructive ? AppColors.error : AppColors.slate),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(title, style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: color)),
              ),
              if (!destructive) const Icon(Icons.chevron_right_rounded, color: AppColors.slateLight),
            ],
          ),
        ),
      ),
    );
  }
}
