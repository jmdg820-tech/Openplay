import 'package:flutter/material.dart';

import '../models/session.dart';
import '../models/venue.dart';
import '../services/openplay_api.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../utils/error_messages.dart';
import '../utils/session_rules.dart';
import '../widgets/app_state_views.dart';
import '../widgets/status_badge.dart';
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
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not claim: ${friendlyActionError(e)}')));
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
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'doubles', label: Text('Doubles')),
                    ButtonSegment(value: 'singles', label: Text('Singles')),
                  ],
                  selected: {type},
                  onSelectionChanged: (s) => setStateDialog(() {
                    type = s.first;
                    capacityCtrl.text = '${minCapacityFor(type)}';
                    capacityError = null;
                  }),
                ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: capacityCtrl,
                  decoration: InputDecoration(
                    labelText: 'Capacity (min ${minCapacityFor(type)} for $type)',
                    errorText: capacityError,
                  ),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: skillCtrl,
                  decoration:
                      const InputDecoration(labelText: 'Skill info (optional, e.g. "Intermediate+")'),
                ),
                const SizedBox(height: AppSpacing.lg),
                Text('Starts in', style: Theme.of(context).textTheme.labelMedium),
                ValueListenableBuilder<int>(
                  valueListenable: hoursFromNow,
                  builder: (context, hours, _) => Row(
                    children: [
                      Expanded(
                        child: Slider(
                          value: hours.toDouble(),
                          min: 1,
                          max: 48,
                          divisions: 47,
                          label: '${hours}h',
                          onChanged: (v) => hoursFromNow.value = v.round(),
                        ),
                      ),
                      SizedBox(
                        width: 44,
                        child: Text('${hours}h', style: Theme.of(context).textTheme.bodyMedium),
                      ),
                    ],
                  ),
                ),
              ],
            ),
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
              child: const Text('Create session'),
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
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not create session: ${friendlyActionError(e)}')));
      }
    }
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(widget.venue.name)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createSession,
        icon: const Icon(Icons.add),
        label: const Text('New session'),
      ),
      body: RefreshIndicator(
        onRefresh: () async => _refresh(),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xxxl + 64),
          children: [
            if (widget.venue.addressText != null)
              _InfoRow(icon: Icons.place_outlined, text: widget.venue.addressText!),
            if (widget.venue.hoursInfo != null)
              _InfoRow(icon: Icons.schedule_outlined, text: widget.venue.hoursInfo!),
            if (widget.venue.numberOfCourts != null)
              _InfoRow(icon: Icons.grid_view_rounded, text: '${widget.venue.numberOfCourts} courts'),
            const SizedBox(height: AppSpacing.md),
            FutureBuilder<bool>(
              future: _isManagedFuture,
              builder: (context, snapshot) {
                final managed = snapshot.data;
                return Row(
                  children: [
                    if (managed == null)
                      Text('Checking staff status…', style: theme.textTheme.bodySmall)
                    else
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.xs),
                        decoration: BoxDecoration(
                          color: managed ? AppColors.statusConfirmedBg : AppColors.cloudDim,
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              managed ? Icons.verified_rounded : Icons.info_outline_rounded,
                              size: 14,
                              color: managed ? AppColors.statusConfirmed : AppColors.slate,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              managed ? 'Staffed venue' : 'No staff yet',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: managed ? AppColors.statusConfirmed : AppColors.slate,
                              ),
                            ),
                          ],
                        ),
                      ),
                    const Spacer(),
                    if (managed == false)
                      OutlinedButton(onPressed: _claim, child: const Text('Claim as staff')),
                  ],
                );
              },
            ),
            const SizedBox(height: AppSpacing.xl),
            Text('Sessions', style: theme.textTheme.headlineSmall),
            const SizedBox(height: AppSpacing.md),
            FutureBuilder<List<Session>>(
              future: _sessionsFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: AppSpacing.xxl),
                    child: LoadingStateView(),
                  );
                }
                if (snapshot.hasError) {
                  return ErrorStateView(message: friendlyActionError(snapshot.error!), onRetry: _refresh);
                }
                final sessions = snapshot.data!;
                if (sessions.isEmpty) {
                  return const EmptyStateView(
                    icon: Icons.event_available_rounded,
                    title: 'No sessions here yet',
                    message: 'Tap "New session" to host the first game at this venue.',
                  );
                }
                return Column(
                  children: sessions
                      .map((s) => Padding(
                            padding: const EdgeInsets.only(bottom: AppSpacing.md),
                            child: _SessionRow(
                              session: s,
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

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppColors.slate),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Text(text, style: Theme.of(context).textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({required this.session, required this.onTap});
  final Session session;
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
                child: Icon(
                  session.sessionType == 'singles' ? Icons.person_rounded : Icons.groups_2_rounded,
                  color: AppColors.courtTealDeep,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${session.sessionType[0].toUpperCase()}${session.sessionType.substring(1)}',
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      session.isCancelled
                          ? 'Cancelled: ${session.cancellationReason ?? ''}'
                          : '${session.startTime.toLocal()} · up to ${session.capacity}',
                      style: theme.textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              StatusBadge(session.isCancelled ? 'cancelled' : 'active', dense: true),
              const SizedBox(width: AppSpacing.xs),
              const Icon(Icons.chevron_right_rounded, color: AppColors.slateLight),
            ],
          ),
        ),
      ),
    );
  }
}
