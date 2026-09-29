import 'package:flutter/material.dart';

import '../models/my_participation.dart';
import '../services/openplay_api.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../utils/error_messages.dart';
import '../widgets/app_state_views.dart';
import '../widgets/countdown_text.dart';
import 'session_detail_screen.dart';

/// The signed-in user's own upcoming registrations -- confirmed, waitlisted
/// (with FIFO position), and pending promotion offers (with countdown) --
/// read from get_my_participations() (migration 028). Lets a user get back
/// to a session they joined without having to find it again in Discover.
class MySessionsScreen extends StatefulWidget {
  const MySessionsScreen({super.key, required this.api});

  final OpenPlayApi api;

  @override
  State<MySessionsScreen> createState() => _MySessionsScreenState();
}

class _MySessionsScreenState extends State<MySessionsScreen> {
  late Future<List<MyParticipation>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.api.getMyParticipations();
  }

  void _refresh() {
    setState(() {
      _future = widget.api.getMyParticipations();
    });
  }

  Future<void> _open(MyParticipation p) async {
    try {
      final session = await widget.api.getSession(p.sessionId);
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => SessionDetailScreen(api: widget.api, session: session)),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyActionError(e))));
      }
    }
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My sessions')),
      body: RefreshIndicator(
        onRefresh: () async => _refresh(),
        child: FutureBuilder<List<MyParticipation>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const LoadingStateView();
            }
            if (snapshot.hasError) {
              return ListView(children: [
                ErrorStateView(message: friendlyActionError(snapshot.error!), onRetry: _refresh),
              ]);
            }
            final items = snapshot.data!;
            if (items.isEmpty) {
              return ListView(children: const [
                EmptyStateView(
                  icon: Icons.event_note_rounded,
                  title: 'No upcoming sessions',
                  message: 'Sessions you join or waitlist for will show up here.',
                ),
              ]);
            }
            return ListView.builder(
              padding: const EdgeInsets.all(AppSpacing.lg),
              itemCount: items.length,
              itemBuilder: (context, i) => _MySessionTile(item: items[i], onTap: () => _open(items[i])),
            );
          },
        ),
      ),
    );
  }
}

class _MySessionTile extends StatelessWidget {
  const _MySessionTile({required this.item, required this.onTap});
  final MyParticipation item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = item.startTime.toLocal();
    final e = item.endTime.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    final when = '${s.year}-${two(s.month)}-${two(s.day)} ${two(s.hour)}:${two(s.minute)}–${two(e.hour)}:${two(e.minute)}';
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(when, style: theme.textTheme.titleMedium),
                      const SizedBox(height: 2),
                      Text(item.statusLabel, style: theme.textTheme.bodyMedium),
                      if (item.isPendingOffer) CountdownText(seconds: item.secondsUntilExpiry!),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, color: AppColors.slateLight),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
