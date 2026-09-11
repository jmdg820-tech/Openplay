import 'package:flutter/material.dart';

import '../services/openplay_api.dart';
import 'account_screen.dart';
import 'discover_screen.dart';
import 'venue_list_screen.dart';

/// App shell: mobile-first bottom navigation between the primary
/// "play today" discovery flow, venues, and account -- deliberately simple,
/// not an admin-dashboard-style layout.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.api, this.onSignInRequested});

  final OpenPlayApi api;

  /// Non-null only when the current viewer is browsing anonymously (see
  /// AuthGate) -- lets the Account tab offer a way back to the sign-in form
  /// instead of a "Sign out" action that wouldn't mean anything for them.
  final VoidCallback? onSignInRequested;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      DiscoverScreen(api: widget.api),
      VenueListScreen(api: widget.api, embedded: true),
      AccountScreen(api: widget.api, onSignInRequested: widget.onSignInRequested),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('OpenPlay')),
      body: SafeArea(child: pages[_index]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.sports_tennis), label: 'Play'),
          NavigationDestination(icon: Icon(Icons.stadium), label: 'Venues'),
          NavigationDestination(icon: Icon(Icons.person), label: 'Account'),
        ],
      ),
    );
  }
}
