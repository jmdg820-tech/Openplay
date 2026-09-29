import 'package:flutter/material.dart';

import '../services/openplay_api.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import 'account_screen.dart';
import 'discover_screen.dart';
import 'venue_list_screen.dart';

/// OpenPlay's shell. Same information architecture on every platform
/// (Play / Venues / Account), but the presentation adapts: a thumb-reach
/// bottom bar below [AppBreakpoints.tablet], a persistent dark navigation
/// rail beside the content at and above it -- the one deliberate "deep
/// branding surface" moment in an otherwise light UI, not a mobile layout
/// stretched wide.
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

class _HomeDestination {
  const _HomeDestination(this.icon, this.selectedIcon, this.label);
  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

const _destinations = [
  _HomeDestination(Icons.sports_tennis_outlined, Icons.sports_tennis, 'Play'),
  _HomeDestination(Icons.stadium_outlined, Icons.stadium, 'Venues'),
  _HomeDestination(Icons.person_outline_rounded, Icons.person_rounded, 'Account'),
];

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      DiscoverScreen(api: widget.api),
      VenueListScreen(api: widget.api, embedded: true),
      AccountScreen(api: widget.api, onSignInRequested: widget.onSignInRequested),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final isDesktop = constraints.maxWidth >= AppBreakpoints.tablet;
        return isDesktop
            ? DesktopShellChrome(index: _index, onSelect: (i) => setState(() => _index = i), pages: pages)
            : MobileShellChrome(index: _index, onSelect: (i) => setState(() => _index = i), pages: pages);
      },
    );
  }
}

class MobileShellChrome extends StatelessWidget {
  const MobileShellChrome({super.key, required this.index, required this.onSelect, required this.pages});
  final int index;
  final ValueChanged<int> onSelect;
  final List<Widget> pages;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: _OpenPlayWordmark(dark: false)),
      body: SafeArea(child: pages[index]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: onSelect,
        destinations: [
          for (final d in _destinations)
            NavigationDestination(icon: Icon(d.icon), selectedIcon: Icon(d.selectedIcon), label: d.label),
        ],
      ),
    );
  }
}

class DesktopShellChrome extends StatelessWidget {
  const DesktopShellChrome({super.key, required this.index, required this.onSelect, required this.pages});
  final int index;
  final ValueChanged<int> onSelect;
  final List<Widget> pages;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          NavRail(index: index, onSelect: onSelect),
          const VerticalDivider(width: 1),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.xxl, AppSpacing.xl, AppSpacing.xxl, 0),
                  child: Text(_destinations[index].label, style: Theme.of(context).textTheme.displaySmall),
                ),
                Expanded(
                  // Align first: Expanded hands this a tight width, and
                  // ConstrainedBox's maxWidth has no effect against a tight
                  // incoming constraint -- it needs Align's loose constraint
                  // to actually cap the content's reading width at 1920px+.
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: AppBreakpoints.wideDesktop),
                      child: pages[index],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class NavRail extends StatelessWidget {
  const NavRail({super.key, required this.index, required this.onSelect});
  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 232,
      color: AppColors.inkSurface,
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl, horizontal: AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: AppSpacing.sm, bottom: AppSpacing.xxl),
            child: _OpenPlayWordmark(dark: true),
          ),
          for (var i = 0; i < _destinations.length; i++) _RailItem(
            destination: _destinations[i],
            selected: i == index,
            onTap: () => onSelect(i),
          ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.only(left: AppSpacing.sm),
            child: Text(
              'Play more. Together.',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(color: AppColors.slateLight),
            ),
          ),
        ],
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({required this.destination, required this.selected, required this.onTap});
  final _HomeDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Material(
        color: selected ? AppColors.inkSurfaceRaised : Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.md),
            child: Row(
              children: [
                Icon(
                  selected ? destination.selectedIcon : destination.icon,
                  size: 20,
                  color: selected ? AppColors.ballChartreuse : AppColors.slateLight,
                ),
                const SizedBox(width: AppSpacing.md),
                Text(
                  destination.label,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: selected ? AppColors.white : AppColors.slateLight,
                      ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OpenPlayWordmark extends StatelessWidget {
  const _OpenPlayWordmark({required this.dark});
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme.headlineSmall;
    return RichText(
      text: TextSpan(
        style: theme?.copyWith(color: dark ? AppColors.white : AppColors.ink),
        children: [
          const TextSpan(text: 'Open'),
          TextSpan(
            text: 'Play',
            style: TextStyle(color: dark ? AppColors.ballChartreuse : AppColors.courtTeal),
          ),
        ],
      ),
    );
  }
}
