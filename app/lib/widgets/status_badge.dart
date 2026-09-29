import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';

/// Consistent status-pill treatment used everywhere OpenPlay shows a
/// participant or session state, so JOINED / WAITLISTED / CONFIRM YOUR SPOT
/// always look and read the same way regardless of which screen it's on.
class StatusBadge extends StatelessWidget {
  const StatusBadge(this.status, {super.key, this.dense = false});

  /// One of the real backend values (`confirmed`, `waitlisted`,
  /// `pending_confirmation`, `active`, `cancelled`) or a UI-derived label
  /// like `full` (computed from real capacity/roster counts, never fake
  /// data).
  final String status;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final spec = _specFor(status);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? AppSpacing.sm : AppSpacing.md,
        vertical: dense ? 2 : AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: spec.background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            margin: const EdgeInsets.only(right: 6),
            decoration: BoxDecoration(color: spec.dot, shape: BoxShape.circle),
          ),
          Text(
            spec.label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: spec.dot,
                  fontWeight: FontWeight.w700,
                ),
          ),
        ],
      ),
    );
  }

  _StatusSpec _specFor(String status) {
    switch (status) {
      case 'confirmed':
        return const _StatusSpec('Joined', AppColors.statusConfirmed, AppColors.statusConfirmedBg);
      case 'waitlisted':
        return const _StatusSpec('Waitlisted', AppColors.statusWaitlisted, AppColors.statusWaitlistedBg);
      case 'pending_confirmation':
        return const _StatusSpec('Confirm your spot', AppColors.statusPending, AppColors.statusPendingBg);
      case 'active':
        return const _StatusSpec('Open', AppColors.statusConfirmed, AppColors.statusConfirmedBg);
      case 'cancelled':
        return const _StatusSpec('Cancelled', AppColors.statusCancelled, AppColors.statusCancelledBg);
      case 'full':
        return const _StatusSpec('Full', AppColors.statusFull, AppColors.statusFullBg);
      default:
        return _StatusSpec(status, AppColors.statusFull, AppColors.statusFullBg);
    }
  }
}

class _StatusSpec {
  const _StatusSpec(this.label, this.dot, this.background);
  final String label;
  final Color dot;
  final Color background;
}
