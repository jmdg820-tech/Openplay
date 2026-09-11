import 'package:flutter/material.dart';

import '../models/session.dart';
import '../services/location_service.dart';
import '../services/openplay_api.dart';
import '../utils/geo.dart';
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
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
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
        _error = '$e';
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

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Play today', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
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
                    avatar: const Icon(Icons.calendar_month, size: 16),
                    label: Text(_dateFilter == _DateFilter.custom && _customDate != null
                        ? '${_customDate!.year}-${_customDate!.month}-${_customDate!.day}'
                        : 'Pick date'),
                    onPressed: _pickCustomDate,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Switch(
                    value: _nearbyOnly,
                    onChanged: _locating ? null : _toggleNearby,
                  ),
                  const Text('Nearby only (25 km)'),
                  if (_locating) ...[
                    const SizedBox(width: 8),
                    const SizedBox(
                        width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                  ],
                ],
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? ListView(children: [
                        Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text('Could not load sessions: $_error'),
                        )
                      ])
                    : visible.isEmpty
                        ? ListView(children: const [
                            Padding(
                              padding: EdgeInsets.all(32),
                              child: Center(
                                child: Text('No open-play sessions match this filter yet.'),
                              ),
                            ),
                          ])
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            itemCount: visible.length,
                            itemBuilder: (context, i) {
                              final s = visible[i];
                              return SessionCard(
                                session: s,
                                venueName: _venueNames[s.venueId] ?? 'Unknown venue',
                                organizerName: _organizerNames[s.createdBy] ?? 'Unknown organizer',
                                distanceKm: distances[s.id],
                                onTap: () async {
                                  await Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => SessionDetailScreen(api: widget.api, session: s),
                                    ),
                                  );
                                  _load();
                                },
                              );
                            },
                          ),
          ),
        ),
      ],
    );
  }
}
