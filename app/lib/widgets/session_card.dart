import 'package:flutter/material.dart';

import '../models/session.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import 'status_badge.dart';

/// OpenPlay's primary content unit: a session someone can discover and
/// join. Every field shown here is real data already fetched by the
/// screen that uses this card (session type/time/capacity from `sessions`,
/// venue name and organizer name resolved via the approved public
/// surfaces) -- nothing invented.
class SessionCard extends StatelessWidget {
  const SessionCard({
    super.key,
    required this.session,
    required this.venueName,
    required this.organizerName,
    this.distanceKm,
    required this.onTap,
  });

  final Session session;
  final String venueName;
  final String organizerName;
  final double? distanceKm;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cancelled = session.isCancelled;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _SportGlyph(sessionType: session.sessionType),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _titleFor(session.sessionType),
                          style: theme.textTheme.titleMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          venueName,
                          style: theme.textTheme.bodySmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  StatusBadge(cancelled ? 'cancelled' : 'active', dense: true),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              const Divider(height: 1),
              const SizedBox(height: AppSpacing.md),
              Wrap(
                spacing: AppSpacing.lg,
                runSpacing: AppSpacing.xs,
                children: [
                  _MetaChip(icon: Icons.schedule_rounded, label: _formatWhen(session.startTime, session.endTime)),
                  _MetaChip(icon: Icons.groups_rounded, label: 'Up to ${session.capacity}'),
                  if (session.skillLevelInfo != null)
                    _MetaChip(icon: Icons.bar_chart_rounded, label: session.skillLevelInfo!),
                  if (distanceKm != null)
                    _MetaChip(icon: Icons.place_rounded, label: '${distanceKm!.toStringAsFixed(1)} km'),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Hosted by $organizerName',
                style: theme.textTheme.labelSmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _titleFor(String sessionType) {
    final label = sessionType.isEmpty ? sessionType : '${sessionType[0].toUpperCase()}${sessionType.substring(1)}';
    return '$label pickleball';
  }

  static String _twoDigits(int n) => n.toString().padLeft(2, '0');

  static String _formatWhen(DateTime start, DateTime end) {
    final s = start.toLocal();
    final e = end.toLocal();
    final now = DateTime.now();
    final isToday = s.year == now.year && s.month == now.month && s.day == now.day;
    final dateLabel = isToday ? 'Today' : '${s.month}/${s.day}';
    return '$dateLabel · ${_twoDigits(s.hour)}:${_twoDigits(s.minute)}–${_twoDigits(e.hour)}:${_twoDigits(e.minute)}';
  }
}

class _SportGlyph extends StatelessWidget {
  const _SportGlyph({required this.sessionType});
  final String sessionType;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: AppColors.courtTealPale,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Icon(
        sessionType == 'singles' ? Icons.person_rounded : Icons.groups_2_rounded,
        color: AppColors.courtTealDeep,
        size: 22,
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: AppColors.slate),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodySmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
