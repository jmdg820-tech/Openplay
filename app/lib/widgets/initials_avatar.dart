import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// A simple initials circle for a real display name -- OpenPlay has no
/// photo/avatar assets wired up, so this uses only real data (the name
/// already shown elsewhere) rather than a placeholder image or fake photo.
class InitialsAvatar extends StatelessWidget {
  const InitialsAvatar(this.name, {super.key, this.size = 36, this.muted = false});

  final String name;
  final double size;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final initials = _initialsFor(name);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: muted ? AppColors.cloudDim : AppColors.courtTealPale,
        shape: BoxShape.circle,
      ),
      child: Text(
        initials,
        style: TextStyle(
          fontSize: size * 0.38,
          fontWeight: FontWeight.w700,
          color: muted ? AppColors.slate : AppColors.courtTealDeep,
        ),
      ),
    );
  }

  static String _initialsFor(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1)).toUpperCase();
  }
}
