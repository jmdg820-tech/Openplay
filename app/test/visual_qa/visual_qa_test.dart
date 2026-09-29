// Visual QA harness for the OPENPLAY UI/UX polish pass.
//
// No browser automation tool is available in this environment (Playwright
// MCP failed to connect this session), and screens that construct a real
// `OpenPlayApi`/`SupabaseClient` hang indefinitely under `flutter test`
// (documented in widget_test.dart). So this harness renders the pieces that
// CAN be genuinely rendered without a live backend: every reusable widget in
// lib/widgets/, plus HomeShell's navigation chrome (made public specifically
// for this -- see MobileShellChrome/DesktopShellChrome/NavRail in
// home_shell.dart) driven with placeholder "page" content instead of live
// API-backed screens.
//
// Run with `flutter test --update-goldens test/visual_qa/visual_qa_test.dart`
// to (re)generate the PNGs under test/visual_qa/goldens/, then inspect them
// directly -- this is real rendered pixel output, not a source-code guess.
//
// Tagged 'visual-qa': a manual inspection tool, not a regression gate, so
// `npm run release` runs `flutter test --exclude-tags visual-qa`.
@Tags(['visual-qa'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:openplay_app/main.dart';
import 'package:openplay_app/models/session.dart';
import 'package:openplay_app/screens/home_shell.dart';
import 'package:openplay_app/screens/session_detail_screen.dart' show SessionStat;
import 'package:openplay_app/theme/app_theme.dart';
import 'package:openplay_app/widgets/app_state_views.dart';
import 'package:openplay_app/widgets/countdown_text.dart';
import 'package:openplay_app/widgets/initials_avatar.dart';
import 'package:openplay_app/widgets/session_card.dart';
import 'package:openplay_app/widgets/status_badge.dart';

/// Named viewports pulled directly from the brief: Android small/normal/
/// large phone widths, the three required desktop widths, one narrow
/// resized desktop window, and the exact 699/700, 999/1000, 1399/1400
/// breakpoint-transition pairs.
const _viewports = <String, Size>{
  'android_small_320x690': Size(320, 690),
  'android_normal_375x812': Size(375, 812),
  'android_large_430x932': Size(430, 932),
  'desktop_1366x768': Size(1366, 768),
  'desktop_1440x900': Size(1440, 900),
  'desktop_1920x1080': Size(1920, 1080),
  'desktop_narrow_resized_760x900': Size(760, 900),
  'breakpoint_tablet_699_below': Size(699, 900),
  'breakpoint_tablet_700_at': Size(700, 900),
  'breakpoint_desktop_999_below': Size(999, 900),
  'breakpoint_desktop_1000_at': Size(1000, 900),
  'breakpoint_wide_1399_below': Size(1399, 900),
  'breakpoint_wide_1400_at': Size(1400, 900),
};

Future<void> _pump(WidgetTester tester, Size size, Widget child) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.light,
    debugShowCheckedModeBanner: false,
    home: Material(child: child),
  ));
  // Not pumpAndSettle(): CountdownText runs a Timer.periodic that never
  // goes idle, so pumpAndSettle would time out waiting for it forever.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

/// Stand-in for a real API-backed tab body -- a labeled block so the nav
/// chrome's own layout (rail width, bottom bar, content max-width clamp,
/// header padding) is what's actually under test, not a live screen's
/// internal layout.
class _PlaceholderPage extends StatelessWidget {
  const _PlaceholderPage(this.label);
  final String label;
  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.04),
      alignment: Alignment.topLeft,
      padding: const EdgeInsets.all(16),
      child: Text('[$label content]', style: Theme.of(context).textTheme.bodyLarge),
    );
  }
}

Session _session({
  String type = 'doubles',
  int capacity = 8,
  String status = 'active',
  String? skillInfo = 'Intermediate (3.0-3.5)',
  DateTime? start,
  DateTime? end,
}) {
  final s = start ?? DateTime.now().add(const Duration(hours: 3));
  return Session(
    id: 'session-1',
    venueId: 'venue-1',
    createdBy: 'user-1',
    sessionType: type,
    startTime: s,
    endTime: end ?? s.add(const Duration(hours: 2)),
    capacity: capacity,
    status: status,
    cancellationReason: status == 'cancelled' ? 'Court closed for maintenance' : null,
    skillLevelInfo: skillInfo,
  );
}

/// A "kitchen sink" column exercising every reusable widget with realistic
/// AND edge-case data: long venue/organizer names, no-skill-info sessions,
/// cancelled sessions, empty/loading/error states, long and single-word
/// names for the initials avatar, and both a fresh and near-expiring
/// countdown.
class _WidgetKitchenSink extends StatelessWidget {
  const _WidgetKitchenSink();

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Status badges', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: const [
            StatusBadge('confirmed'),
            StatusBadge('waitlisted'),
            StatusBadge('pending_confirmation'),
            StatusBadge('active'),
            StatusBadge('cancelled'),
            StatusBadge('full'),
            StatusBadge('confirmed', dense: true),
            StatusBadge('pending_confirmation', dense: true),
          ]),
          const SizedBox(height: 24),
          Text('Session cards', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          SessionCard(
            session: _session(),
            venueName: 'Riverside Park Courts',
            organizerName: 'Alex Rivera',
            distanceKm: 2.4,
            onTap: () {},
          ),
          const SizedBox(height: 12),
          SessionCard(
            session: _session(
              type: 'singles',
              capacity: 2,
              skillInfo: null,
              status: 'cancelled',
            ),
            venueName: 'The Greater Metropolitan Community Recreation Center & Sports Complex',
            organizerName: 'Christopher Alexander Montgomery-Whitfield',
            onTap: () {},
          ),
          const SizedBox(height: 24),
          Text('State views', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          const EmptyStateView(
            icon: Icons.sports_tennis_outlined,
            title: 'No open sessions nearby',
            message: 'Try widening your search radius or check back later.',
            actionLabel: 'Host a session',
          ),
          const SizedBox(height: 12),
          const LoadingStateView(message: 'Loading sessions...'),
          const SizedBox(height: 12),
          ErrorStateView(
            message: 'Something went wrong. Please try again.',
            onRetry: () {},
          ),
          const SizedBox(height: 24),
          Text('Session stats (session_detail_screen.dart)', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          const Wrap(
            spacing: 24,
            runSpacing: 12,
            children: [
              SessionStat(icon: Icons.schedule_rounded, label: 'When', value: '2026-09-11 18:00 – 20:00'),
              SessionStat(icon: Icons.groups_rounded, label: 'Players', value: '6 / 8 joined · 2 waiting'),
              SessionStat(
                icon: Icons.bar_chart_rounded,
                label: 'Skill level',
                value: 'Intermediate to advanced players only please (3.5+ DUPR or equivalent)',
              ),
            ],
          ),
          const SizedBox(height: 24),
          Text('Initials avatars', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: const [
            InitialsAvatar('Alex Rivera'),
            InitialsAvatar('Madonna'),
            InitialsAvatar('Christopher Alexander Montgomery-Whitfield'),
            InitialsAvatar('  '),
            InitialsAvatar('Jamie Lee', muted: true),
            InitialsAvatar('Small', size: 24),
            InitialsAvatar('Large', size: 56),
          ]),
          const SizedBox(height: 24),
          Text('Countdown text', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          const CountdownText(seconds: 45),
          const SizedBox(height: 4),
          const CountdownText(seconds: 300),
        ],
      ),
    );
  }
}

void main() {
  // flutter_test's TestWidgetsFlutterBinding blocks real network calls, so
  // google_fonts' default runtime font-fetching (from fonts.gstatic.com)
  // always fails under `flutter test` regardless of actual internet access.
  // This is the package's own documented fix for widget/golden tests --
  // see https://github.com/flutter/packages/blob/main/packages/google_fonts/example/test.
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  group('widget kitchen sink', () {
    for (final entry in _viewports.entries) {
      testWidgets('renders at ${entry.key}', (tester) async {
        // Width drives every layout question this harness cares about
        // (card wrapping, meta-chip overflow, breakpoint switches); height
        // is fixed tall so the whole scrollable kitchen sink is captured
        // in one golden instead of being clipped to a real device's
        // viewport height.
        await _pump(tester, Size(entry.value.width, 1700), const _WidgetKitchenSink());
        await expectLater(
          find.byType(_WidgetKitchenSink),
          matchesGoldenFile('goldens/kitchen_sink_${entry.key}.png'),
        );
      });
    }
  });

  group('home shell chrome', () {
    final pages = const [
      _PlaceholderPage('Play'),
      _PlaceholderPage('Venues'),
      _PlaceholderPage('Account'),
    ];

    for (final entry in _viewports.entries) {
      testWidgets('renders at ${entry.key}', (tester) async {
        tester.view.physicalSize = entry.value;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light,
          debugShowCheckedModeBanner: false,
          home: LayoutBuilder(
            builder: (context, constraints) {
              final isDesktop = constraints.maxWidth >= 700;
              return isDesktop
                  ? DesktopShellChrome(index: 0, onSelect: (_) {}, pages: pages)
                  : MobileShellChrome(index: 0, onSelect: (_) {}, pages: pages);
            },
          ),
        ));
        await tester.pumpAndSettle();
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/home_shell_${entry.key}.png'),
        );
      });
    }

    testWidgets('desktop rail shows selected state on Venues (index 1)', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        debugShowCheckedModeBanner: false,
        home: DesktopShellChrome(index: 1, onSelect: (_) {}, pages: pages),
      ));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/home_shell_desktop_selected_venues.png'),
      );
    });
  });

  group('not-configured screen (real app entry point, no backend needed)', () {
    // The only real screen in this app that can be pumped as-is without a
    // live OpenPlayApi/SupabaseClient: AppConfig.isConfigured is false in
    // this test run (no --dart-define passed), so OpenPlayApp genuinely
    // falls back to this screen instead of calling Supabase.initialize.
    for (final size in [const Size(320, 690), const Size(1440, 900)]) {
      testWidgets('renders at ${size.width.toInt()}x${size.height.toInt()}', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(const OpenPlayApp());
        await tester.pumpAndSettle();
        await expectLater(
          find.byType(OpenPlayApp),
          matchesGoldenFile('goldens/not_configured_${size.width.toInt()}x${size.height.toInt()}.png'),
        );
      });
    }
  });
}
