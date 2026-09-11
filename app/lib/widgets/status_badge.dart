import 'package:flutter/material.dart';

/// Consistent, unmistakable JOINED / WAITLISTED / PENDING CONFIRMATION
/// treatment everywhere a participant status is shown.
class StatusBadge extends StatelessWidget {
  const StatusBadge(this.status, {super.key});

  final String status; // confirmed | waitlisted | pending_confirmation

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      'confirmed' => ('JOINED', Colors.green),
      'waitlisted' => ('WAITLISTED', Colors.orange),
      'pending_confirmation' => ('CONFIRM YOUR SPOT', Colors.red),
      _ => (status.toUpperCase(), Colors.grey),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 11),
      ),
    );
  }
}
