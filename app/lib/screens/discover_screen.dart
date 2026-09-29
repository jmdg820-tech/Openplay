import 'package:flutter/material.dart';

import '../models/session.dart';
import '../services/location_service.dart';
import '../services/openplay_api.dart';
import '../theme/app_spacing.dart';
import '../utils/error_messages.dart';
import '../utils/geo.dart';
import '../widgets/app_state_views.dart';
import '../widgets/pending_offer_banner.dart';
import '../widgets/session_card.dart';
import 'session_detail_screen.dart';

/// The primary user journey's entry point: "I want to play pickleball
/// today" -> discover nearby open-play sessions.
class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key, required this.api});

  final OpenPlayApi api;

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

enum _DateFilter { today, tomorrow, next7Days, custom }

class _DiscoverScreenState extends State<DiscoverScreen> {
  _DateFilter _dateFilter = _DateFilter.today;
  DateTime? _customDate;
  bool _nearbyOnly = false;
  GeoPoint? _myLocation;
  bool _locating = false;

  List<Session> _sessions = [];
  Map<String, String> _venueNames = {};
  Map<String, GeoPoint?> _venueCoords = {};
  Map<String, String> _organizerNames = {};
  bool _loading = true;
  Object? _error;

  final _offerBannerKey = GlobalKey<PendingOfferBannerState>();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _openSession(Session s) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SessionDetailScreen(api: widget.api, session: s)),
    );
    _load();
    _offerBannerKey.currentState?.refresh();
  }

  Future<void> _openSessionById(String sessionId) async {
    try {
      final s = await widget.api.getSession(sessionId);
      if (mounted) await _openSession(s);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyActionError(e))));
      }
    }
  }

  (DateTime, DateTime) _range() {
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    switch (_dateFilter) {
      case _DateFilter.today:
        return (todayStart, todayStart.add(const Duration(days: 1)));
      case _DateFilter.tomorrow:
        final t = todayStart.add(const Duration(days: 1));
        return (t, t.add(const Duration(days: 1)));
      case _DateFilter.next7Days:
        return (todayStart, todayStart.add(const Duration(days: 7)));
      case _DateFilter.custom:
        final d = _customDate ?? todayStart;
        final dayStart = DateTime(d.year, d.month, d.day);
        return (dayStart, dayStart.add(const Duration(days: 1)));
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final (from, to) = _range();
      final sessions =
          await widget.api.listSessions(onOrAfter: from, before: to, activeOnly: true);

      final venues = await widget.api.getVenuesByIds(sessions.map((s) => s.venueId));
      final organizers = await widget.api.getPublicProfiles(sessions.map((s) => s.createdBy));

      if (!mounted) return;
      setState(() {
        _sessions = sessions;
        _venueNames = {for (final v in venues.values) v.id: v.name};
        _venueCoords = {for (final v in venues.values) v.id: v.coordinates};
        _organizerNames = {for (final p in organizers.values) p.id: p.name};
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _toggleNearby(bool value) async {
    setState(() => _nearbyOnly = value);
    if (!value) return;
    setState(() => _locating = true);
    final pos = await LocationService().currentPosition();
    if (!mounted) return;
    setState(() {
      _myLocation = pos;
      _locating = false;
      if (pos == null) {
        _nearbyOnly = false;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Location unavailable -- showing all sessions instead.'),
        ));
      }
    });
  }

  Future<void> _pickCustomDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _customDate ?? DateTime.now(),
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked == null) return;
    setState(() {
      _dateFilter = _DateFilter.custom;
      _customDate = picked;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    var visible = _sessions;
    final distances = <String, double>{};
    if (_nearbyOnly && _myLocation != null) {
      for (final s in visible) {
        final coords = _venueCoords[s.venueId];
        if (coords != null) distances[s.id] = haversineKm(_myLocation!, coords);
      }
      const radiusKm = 25.0;
      visible = visible.where((s) {
        final d = distances[s.id];
        return d == null ? true : d <= radiusKm; // unknown-location venues stay visible
      }).toList()
        ..sort((a, b) {
          final da = distances[a.id];
          final db = distances[b.id];
          if (da == null && db == null) return 0;
          if (da == null) return 1;
          if (db == null) return -1;
          return da.compareTo(db);
        });
    }

    final isDesktop = MediaQuery.sizeOf(context).width >= AppBreakpoints.tablet;

    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            isDesktop ? 0 : AppSpacing.lg,
            isDesktop ? AppSpacing.lg : AppSpacing.md,
            isDesktop ? 0 : AppSpacing.lg,
            AppSpacing.xs,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PendingOfferBanner(key: _offerBannerKey, api: widget.api, onOpenSession: _openSessionById),
              if (!isDesktop) ...[
                Text('Play today', style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: AppSpacing.md),
              ],
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  ChoiceChip(
                    label: const Text('Today'),
                    selected: _dateFilter == _DateFilter.today,
                    onSelected: (_) {
                      setState(() => _dateFilter = _DateFilter.today);
                      _load();
                    },
                  ),
                  ChoiceChip(
                    label: const Text('Tomorrow'),
                    selected: _dateFilter == _DateFilter.tomorrow,
                    onSelected: (_) {
                      setState(() => _dateFilter = _DateFilter.tomorrow);
                      _load();
                    },
                  ),
                  ChoiceChip(
                    label: const Text('Next 7 days'),
                    selected: _dateFilter == _DateFilter.next7Days,
                    onSelected: (_) {
                      setState(() => _dateFilter = _DateFilter.next7Days);
                      _load();
                    },
                  ),
                  ActionChip(
                    avatar: const Icon(Icons.calendar_month_rounded, size: 16),
                    label: Text(_dateFilter == _DateFilter.custom && _customDate != null
                        ? '${_customDate!.year}-${_customDate!.month}-${_customDate!.day}'
                        : 'Pick date'),
                    onPressed: _pickCustomDate,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  FilterChip(
                    avatar: _locating
                        ? const SizedBox(
                            width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.near_me_rounded, size: 16),
                    label: const Text('Nearby (25 km)'),
                    selected: _nearbyOnly,
                    onSelected: _locating ? null : _toggleNearby,
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        if (!isDesktop) const Divider(height: 1),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: _loading
                ? const LoadingStateView(message: 'Finding sessions…')
                : _error != null
                    ? SingleChildScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        child: ErrorStateView(
                          message: friendlyActionError(_error!),
                          onRetry: _load,
                        ),
                      )
                    : visible.isEmpty
                        ? SingleChildScrollView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            child: EmptyStateView(
                              icon: Icons.sports_tennis_rounded,
                              title: 'No sessions match this filter yet',
                              message: _nearbyOnly
                                  ? 'Try a wider date range, or turn off "Nearby" to see more.'
                                  : 'Try a different date, or check back soon.',
                            ),
                          )
                        : _SessionResults(
                            sessions: visible,
                            venueNames: _venueNames,
                            organizerNames: _organizerNames,
                            distances: distances,
                            isDesktop: isDesktop,
                            onOpen: _openSession,
                          ),
          ),
        ),
      ],
    );
  }
}

class _SessionResults extends StatelessWidget {
  const _SessionResults({
    required this.sessions,
    required this.venueNames,
    required this.organizerNames,
    required this.distances,
    required this.isDesktop,
    required this.onOpen,
  });

  final List<Session> sessions;
  final Map<String, String> venueNames;
  final Map<String, String> organizerNames;
  final Map<String, double> distances;
  final bool isDesktop;
  final ValueChanged<Session> onOpen;

  @override
  Widget build(BuildContext context) {
    if (!isDesktop) {
      return ListView.builder(
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xl),
        itemCount: sessions.length,
        itemBuilder: (context, i) => Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.md),
          child: _card(sessions[i]),
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 420,
        mainAxisExtent: 190,
        crossAxisSpacing: AppSpacing.lg,
        mainAxisSpacing: AppSpacing.lg,
      ),
      itemCount: sessions.length,
      itemBuilder: (context, i) => _card(sessions[i]),
    );
  }

  Widget _card(Session s) => SessionCard(
        session: s,
        venueName: venueNames[s.venueId] ?? 'Unknown venue',
        organizerName: organizerNames[s.createdBy] ?? 'Unknown organizer',
        distanceKm: distances[s.id],
        onTap: () => onOpen(s),
      );
}
