import 'package:flutter/material.dart';

import '../models/venue.dart';
import '../services/location_service.dart';
import '../services/openplay_api.dart';
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

  void _refresh() => setState(() => _venuesFuture = widget.api.listVenues());

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
            children: [
              TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Name')),
              TextField(
                controller: courtsCtrl,
                decoration: const InputDecoration(labelText: 'Number of courts (optional)'),
                keyboardType: TextInputType.number,
              ),
              TextField(
                  controller: addressCtrl, decoration: const InputDecoration(labelText: 'Address')),
              TextField(
                  controller: hoursCtrl,
                  decoration: const InputDecoration(labelText: 'Hours (e.g. "6am-10pm daily")')),
              const SizedBox(height: 8),
              ValueListenableBuilder<bool>(
                valueListenable: locating,
                builder: (context, isLocating, _) => Text(
                  isLocating ? 'Detecting your location…' : 'Location (edit if needed):',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: latCtrl,
                      decoration: const InputDecoration(labelText: 'Latitude'),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                    ),
                  ),
                  const SizedBox(width: 8),
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
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Create')),
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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not create venue: $e')));
      }
    }
    _refresh();
  }

  Widget _list() {
    return FutureBuilder<List<Venue>>(
      future: _venuesFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(child: Text('Failed to load venues: ${snapshot.error}'));
        }
        final venues = snapshot.data!;
        if (venues.isEmpty) {
          return const Center(child: Text('No venues yet. Tap + to add one.'));
        }
        return RefreshIndicator(
          onRefresh: () async => _refresh(),
          child: ListView.separated(
            itemCount: venues.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final v = venues[i];
              return ListTile(
                title: Text(v.name),
                subtitle: Text([
                  if (v.addressText != null) v.addressText!,
                  if (v.numberOfCourts != null) '${v.numberOfCourts} court(s)',
                ].join(' • ')),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => VenueDetailScreen(api: widget.api, venue: v)),
                ).then((_) => _refresh()),
              );
            },
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) {
      return Stack(
        children: [
          _list(),
          Positioned(
            right: 16,
            bottom: 16,
            child: FloatingActionButton(onPressed: _createVenue, child: const Icon(Icons.add)),
          ),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Venues'),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _refresh)],
      ),
      floatingActionButton: FloatingActionButton(onPressed: _createVenue, child: const Icon(Icons.add)),
      body: _list(),
    );
  }
}
