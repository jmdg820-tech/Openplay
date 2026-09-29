import 'package:flutter/material.dart';

import '../models/venue.dart';
import '../services/location_service.dart';
import '../services/openplay_api.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../utils/error_messages.dart';
import '../widgets/app_state_views.dart';
import 'venue_detail_screen.dart';

class VenueListScreen extends StatefulWidget {
  const VenueListScreen({super.key, required this.api, this.embedded = false});

  final OpenPlayApi api;

  /// When true, renders without its own Scaffold/AppBar (it's a tab inside
  /// [HomeShell]'s Scaffold) but keeps its own floating "add venue" button
  /// via a Stack instead of Scaffold.floatingActionButton.
  final bool embedded;

  @override
  State<VenueListScreen> createState() => _VenueListScreenState();
}

class _VenueListScreenState extends State<VenueListScreen> {
  late Future<List<Venue>> _venuesFuture;

  @override
  void initState() {
    super.initState();
    _venuesFuture = widget.api.listVenues();
  }

  void _refresh() {
    setState(() {
      _venuesFuture = widget.api.listVenues();
    });
  }

  Future<void> _createVenue() async {
    final nameCtrl = TextEditingController();
    final courtsCtrl = TextEditingController();
    final addressCtrl = TextEditingController();
    final hoursCtrl = TextEditingController();
    final latCtrl = TextEditingController();
    final lngCtrl = TextEditingController();

    final locating = ValueNotifier<bool>(true);
    LocationService().currentPosition().then((pos) {
      locating.value = false;
      if (pos != null) {
        latCtrl.text = pos.lat.toStringAsFixed(6);
        lngCtrl.text = pos.lng.toStringAsFixed(6);
      }
    });

    final created = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New venue'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Name')),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: courtsCtrl,
                decoration: const InputDecoration(labelText: 'Number of courts (optional)'),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                  controller: addressCtrl, decoration: const InputDecoration(labelText: 'Address')),
              const SizedBox(height: AppSpacing.md),
              TextField(
                  controller: hoursCtrl,
                  decoration: const InputDecoration(labelText: 'Hours (e.g. "6am-10pm daily")')),
              const SizedBox(height: AppSpacing.lg),
              ValueListenableBuilder<bool>(
                valueListenable: locating,
                builder: (context, isLocating, _) => Row(
                  children: [
                    if (isLocating) ...[
                      const SizedBox(
                          width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: AppSpacing.sm),
                    ],
                    Text(
                      isLocating ? 'Detecting your location…' : 'Location (edit if needed)',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: latCtrl,
                      decoration: const InputDecoration(labelText: 'Latitude'),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: TextField(
                      controller: lngCtrl,
                      decoration: const InputDecoration(labelText: 'Longitude'),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Create venue')),
        ],
      ),
    );
    if (created != true || nameCtrl.text.trim().isEmpty) return;

    final lat = double.tryParse(latCtrl.text.trim());
    final lng = double.tryParse(lngCtrl.text.trim());
    if (lat == null || lng == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('A venue needs a location -- enter latitude/longitude.')),
        );
      }
      return;
    }

    try {
      await widget.api.createVenue(
        name: nameCtrl.text.trim(),
        latitude: lat,
        longitude: lng,
        numberOfCourts: int.tryParse(courtsCtrl.text),
        addressText: addressCtrl.text.trim().isEmpty ? null : addressCtrl.text.trim(),
        hoursInfo: hoursCtrl.text.trim().isEmpty ? null : hoursCtrl.text.trim(),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not create venue: ${friendlyActionError(e)}')));
      }
    }
    _refresh();
  }

  Widget _list() {
    return FutureBuilder<List<Venue>>(
      future: _venuesFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const LoadingStateView(message: 'Loading venues…');
        }
        if (snapshot.hasError) {
          return ErrorStateView(
            message: friendlyActionError(snapshot.error!),
            onRetry: _refresh,
          );
        }
        final venues = snapshot.data!;
        if (venues.isEmpty) {
          return const EmptyStateView(
            icon: Icons.stadium_rounded,
            title: 'No venues yet',
            message: 'Tap + to add the first place to play.',
          );
        }
        final isDesktop = MediaQuery.sizeOf(context).width >= AppBreakpoints.tablet;
        return RefreshIndicator(
          onRefresh: () async => _refresh(),
          child: isDesktop
              ? GridView.builder(
                  padding: const EdgeInsets.only(bottom: AppSpacing.xxxl),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 360,
                    mainAxisExtent: 108,
                    crossAxisSpacing: AppSpacing.lg,
                    mainAxisSpacing: AppSpacing.lg,
                  ),
                  itemCount: venues.length,
                  itemBuilder: (context, i) => _VenueCard(
                    venue: venues[i],
                    onTap: () => _open(venues[i]),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(
                      AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xxxl + 64),
                  itemCount: venues.length,
                  itemBuilder: (context, i) => Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.md),
                    child: _VenueCard(venue: venues[i], onTap: () => _open(venues[i])),
                  ),
                ),
        );
      },
    );
  }

  void _open(Venue v) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => VenueDetailScreen(api: widget.api, venue: v)),
    ).then((_) => _refresh());
  }

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) {
      return Stack(
        children: [
          _list(),
          Positioned(
            right: AppSpacing.lg,
            bottom: AppSpacing.lg,
            child: FloatingActionButton(onPressed: _createVenue, child: const Icon(Icons.add)),
          ),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Venues'),
        actions: [IconButton(icon: const Icon(Icons.refresh_rounded), onPressed: _refresh)],
      ),
      floatingActionButton: FloatingActionButton(onPressed: _createVenue, child: const Icon(Icons.add)),
      body: _list(),
    );
  }
}

class _VenueCard extends StatelessWidget {
  const _VenueCard({required this.venue, required this.onTap});
  final Venue venue;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.courtTealPale,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: const Icon(Icons.stadium_rounded, color: AppColors.courtTealDeep, size: 22),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(venue.name, style: theme.textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(
                      [
                        if (venue.addressText != null) venue.addressText!,
                        if (venue.numberOfCourts != null) '${venue.numberOfCourts} court(s)',
                      ].join(' · '),
                      style: theme.textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: AppColors.slateLight),
            ],
          ),
        ),
      ),
    );
  }
}
