import 'dart:async';

import 'package:flutter/material.dart';

import '../models/my_participation.dart';
import '../services/openplay_api.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import 'countdown_text.dart';

/// In-app delivery of the `waitlist_promoted` event: while the app is open,
/// polls the signed-in user's own registrations (get_my_participations(),
/// migration 028) and, if a waitlist promotion is waiting for confirmation,
/// shows "You've been offered a spot" with the live countdown.
///
/// Renders NOTHING otherwise -- including when signed out, when the request
/// fails, or against a backend that doesn't have migration 028 yet -- so it
/// never adds an error state to the screen that hosts it.
///
/// This is not off-app push: a user who has the app closed is still not
/// told. That needs a push/email provider (see docs).
class PendingOfferBanner extends StatefulWidget {
  const PendingOfferBanner({super.key, required this.api, required this.onOpenSession});

  final OpenPlayApi api;
  final Future<void> Function(String sessionId) onOpenSession;

  static const pollInterval = Duration(seconds: 20);

  @override
  State<PendingOfferBanner> createState() => PendingOfferBannerState();
}

class PendingOfferBannerState extends State<PendingOfferBanner> {
  List<MyParticipation> _offers = const [];
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    refresh();
    _timer = Timer.periodic(PendingOfferBanner.pollInterval, (_) => refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> refresh() async {
    if (!widget.api.isSignedIn) {
      if (mounted && _offers.isNotEmpty) setState(() => _offers = const []);
      return;
    }
    try {
      final mine = await widget.api.getMyParticipations();
      if (!mounted) return;
      setState(() => _offers = mine.where((p) => p.isPendingOffer).toList());
    } catch (_) {
      // Deliberately silent: the banner is an enhancement, never a new
      // failure surface. The session screen still shows the offer itself.
      if (mounted && _offers.isNotEmpty) setState(() => _offers = const []);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_offers.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final offer = _offers.first;
    return Card(
      color: AppColors.courtTealPale,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () async {
          await widget.onOpenSession(offer.sessionId);
          refresh();
        },
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            children: [
              const Icon(Icons.notifications_active_rounded, color: AppColors.courtTealDeep),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _offers.length == 1
                          ? "You've been offered a spot!"
                          : "You've been offered ${_offers.length} spots!",
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 2),
                    CountdownText(seconds: offer.secondsUntilExpiry ?? 0),
                    Text('Tap to open the session and confirm.', style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: AppColors.courtTealDeep),
            ],
          ),
        ),
      ),
    );
  }
}
