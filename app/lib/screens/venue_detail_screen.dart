import 'package:flutter/material.dart';

import '../models/session.dart';
import '../models/venue.dart';
import '../services/openplay_api.dart';
import '../utils/session_rules.dart';
import 'session_detail_screen.dart';

class VenueDetailScreen extends StatefulWidget {
  const VenueDetailScreen({super.key, required this.api, required this.venue});

  final OpenPlayApi api;
  final Venue venue;

  @override
  State<VenueDetailScreen> createState() => _VenueDetailScreenState();
}

class _VenueDetailScreenState extends State<VenueDetailScreen> {
  late Future<bool> _isManagedFuture;
  late Future<List<Session>> _sessionsFuture;

  @override
  void initState() {
    super.initState();
    _isManagedFuture = widget.api.isVenueManaged(widget.venue.id);
    _sessionsFuture = widget.api.listSessions(venueId: widget.venue.id);
  }

  void _refresh() {
    setState(() {
      _isManagedFuture = widget.api.isVenueManaged(widget.venue.id);
      _sessionsFuture = widget.api.listSessions(venueId: widget.venue.id);
    });
  }

  Future<void> _claim() async {
    try {
      await widget.api.claimVenue(widget.venue.id);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('You are now staff at this venue.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not claim: $e')));
      }
    }
    _refresh();
  }

  Future<void> _createSession() async {
    var type = 'doubles';
    final capacityCtrl = TextEditingController(text: '${minCapacityFor(type)}');
    final skillCtrl = TextEditingController();
    final hoursFromNow = ValueNotifier<int>(2);
    String? capacityError;
    final created = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setStateDialog) => AlertDialog(
          title: const Text('New session'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: type,
                items: const [
                  DropdownMenuItem(value: 'doubles', child: Text('Doubles')),
                  DropdownMenuItem(value: 'singles', child: Text('Singles')),
                ],
                onChanged: (v) => setStateDialog(() {
                  type = v ?? 'doubles';
                  capacityError = null;
                }),
                decoration: const InputDecoration(labelText: 'Type'),
              ),
              TextField(
                controller: capacityCtrl,
                decoration: InputDecoration(
                  labelText: 'Capacity (min ${minCapacityFor(type)} for $type)',
                  errorText: capacityError,
                ),
                keyboardType: TextInputType.number,
              ),
              TextField(
                controller: skillCtrl,
                decoration:
                    const InputDecoration(labelText: 'Skill info (optional, e.g. "Intermediate+")'),
              ),
              Row(
                children: [
                  const Text('Starts in (hours): '),
                  Expanded(
                    child: Slider(
                      value: hoursFromNow.value.toDouble(),
                      min: 1,
                      max: 48,
                      divisions: 47,
                      label: '${hoursFromNow.value}h',
                      onChanged: (v) => setStateDialog(() => hoursFromNow.value = v.round()),
                    ),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final error = validateCapacity(type, int.tryParse(capacityCtrl.text));
                if (error != null) {
                  setStateDialog(() => capacityError = error);
                  return;
                }
                Navigator.pop(context, true);
              },
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
    if (created != true) return;
    final start = DateTime.now().add(Duration(hours: hoursFromNow.value));
    try {
      await widget.api.createSession(
        venueId: widget.venue.id,
        sessionType: type,
        startTime: start,
        endTime: start.add(const Duration(minutes: 90)),
        capacity: int.parse(capacityCtrl.text),
        skillLevelInfo: skillCtrl.text.trim().isEmpty ? null : skillCtrl.text.trim(),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not create session: $e')));
      }
    }
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.venue.name)),
      floatingActionButton:
          FloatingActionButton(onPressed: _createSession, child: const Icon(Icons.add)),
      body: RefreshIndicator(
        onRefresh: () async => _refresh(),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (widget.venue.addressText != null) Text(widget.venue.addressText!),
            if (widget.venue.hoursInfo != null) Text(widget.venue.hoursInfo!),
            const SizedBox(height: 12),
            FutureBuilder<bool>(
              future: _isManagedFuture,
              builder: (context, snapshot) {
                final managed = snapshot.data;
                return Row(
                  children: [
                    Chip(
                      label: Text(managed == null
                          ? 'Checking staff status…'
                          : managed
                              ? 'Staffed venue'
                              : 'No staff yet'),
                    ),
                    const Spacer(),
                    if (managed == false)
                      OutlinedButton(onPressed: _claim, child: const Text('Claim as staff')),
                  ],
                );
              },
            ),
            const Divider(height: 32),
            Text('Sessions', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            FutureBuilder<List<Session>>(
              future: _sessionsFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                if (snapshot.hasError) return Text('Failed to load sessions: ${snapshot.error}');
                final sessions = snapshot.data!;
                if (sessions.isEmpty) return const Text('No sessions yet.');
                return Column(
                  children: sessions
                      .map((s) => Card(
                            child: ListTile(
                              title: Text('${s.sessionType} • ${s.startTime.toLocal()}'),
                              subtitle: Text(s.isCancelled
                                  ? 'Cancelled: ${s.cancellationReason ?? ''}'
                                  : 'Capacity ${s.capacity}'),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => SessionDetailScreen(api: widget.api, session: s),
                                ),
                              ).then((_) => _refresh()),
                            ),
                          ))
                      .toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
