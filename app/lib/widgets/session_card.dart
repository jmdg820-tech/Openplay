import 'package:flutter/material.dart';

import '../models/session.dart';

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
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${session.sessionType[0].toUpperCase()}${session.sessionType.substring(1)} at $venueName',
                      style: theme.textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (session.isCancelled)
                    Chip(
                      label: const Text('Cancelled'),
                      backgroundColor: theme.colorScheme.errorContainer,
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  const Icon(Icons.schedule, size: 16),
                  const SizedBox(width: 4),
                  Text(_formatRange(session.startTime, session.endTime)),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  const Icon(Icons.groups, size: 16),
                  const SizedBox(width: 4),
                  Text('Capacity ${session.capacity}'),
                  const SizedBox(width: 12),
                  const Icon(Icons.person_pin, size: 16),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text('Hosted by $organizerName',
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
              if (session.skillLevelInfo != null) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Icon(Icons.bar_chart, size: 16),
                    const SizedBox(width: 4),
                    Text(session.skillLevelInfo!),
                  ],
                ),
              ],
              if (distanceKm != null) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Icon(Icons.place, size: 16),
                    const SizedBox(width: 4),
                    Text('${distanceKm!.toStringAsFixed(1)} km away'),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static String _twoDigits(int n) => n.toString().padLeft(2, '0');

  static String _formatRange(DateTime start, DateTime end) {
    final s = start.toLocal();
    final e = end.toLocal();
    final date = '${s.year}-${_twoDigits(s.month)}-${_twoDigits(s.day)}';
    return '$date  ${_twoDigits(s.hour)}:${_twoDigits(s.minute)}–${_twoDigits(e.hour)}:${_twoDigits(e.minute)}';
  }
}
