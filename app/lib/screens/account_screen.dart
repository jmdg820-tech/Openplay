import 'package:flutter/material.dart';

import '../services/openplay_api.dart';
import 'blocked_users_screen.dart';

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
    return ListView(
      children: [
        if (api.isSignedIn) ...[
          ListTile(
            leading: const Icon(Icons.block),
            title: const Text('Blocked users'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => BlockedUsersScreen(api: api)),
            ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Sign out'),
            onTap: api.signOut,
          ),
        ] else ...[
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text("You're browsing without an account"),
            subtitle: Text(
              'Sign in to join sessions as yourself, create venues/sessions, '
              'and report or block other players. Joining as a guest still works either way.',
            ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.login),
            title: const Text('Sign in / Create account'),
            onTap: onSignInRequested,
          ),
        ],
      ],
    );
  }
}
