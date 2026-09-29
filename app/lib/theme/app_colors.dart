import 'package:flutter/material.dart';

/// OpenPlay's palette, drawn from the sport itself rather than a generic
/// "sports app green": `courtTeal` is a pickleball court surface color,
/// `ballChartreuse` is the optic-yellow-green of the ball. The ball color
/// is spent in exactly one place -- primary calls to action -- so it always
/// reads as "act here" instead of decorating the whole app.
class AppColors {
  AppColors._();

  // Brand
  static const courtTeal = Color(0xFF0E6E63);
  static const courtTealDeep = Color(0xFF0A4F47);
  static const courtTealPale = Color(0xFFDCEEEA);
  static const ballChartreuse = Color(0xFFD6E44A);
  static const ballChartreuseDeep = Color(0xFF9FB01E);

  // Neutrals
  static const ink = Color(0xFF0E1E1B);
  static const slate = Color(0xFF5B6B68);
  static const slateLight = Color(0xFF8B9997);
  static const cloud = Color(0xFFF5F7F4);
  static const cloudDim = Color(0xFFE9EDEA);
  static const line = Color(0xFFDCE3E0);
  static const white = Color(0xFFFFFFFF);

  // Dark-surface variants (used for the desktop nav rail / dark accents)
  static const inkSurface = Color(0xFF122622);
  static const inkSurfaceRaised = Color(0xFF183530);

  // Status -- muted so they stay part of the same family rather than
  // reading as stoplight colors dropped onto an unrelated palette.
  static const statusConfirmed = Color(0xFF2E9E6B);
  static const statusConfirmedBg = Color(0xFFE1F3E8);
  static const statusWaitlisted = Color(0xFFC77D1D);
  static const statusWaitlistedBg = Color(0xFFFBEDDA);
  static const statusPending = Color(0xFFB2461F);
  static const statusPendingBg = Color(0xFFFBE4DA);
  static const statusCancelled = Color(0xFF9A3B32);
  static const statusCancelledBg = Color(0xFFF6E1DE);
  static const statusFull = Color(0xFF5B6B68);
  static const statusFullBg = Color(0xFFE9EDEA);

  static const error = Color(0xFFC0392B);
  static const errorBg = Color(0xFFFBE4E1);

  static ColorScheme get lightScheme => const ColorScheme.light(
        brightness: Brightness.light,
        primary: courtTeal,
        onPrimary: white,
        primaryContainer: courtTealPale,
        onPrimaryContainer: courtTealDeep,
        secondary: ballChartreuseDeep,
        onSecondary: ink,
        secondaryContainer: ballChartreuse,
        onSecondaryContainer: ink,
        surface: white,
        onSurface: ink,
        surfaceContainerHighest: cloudDim,
        surfaceContainerHigh: cloud,
        surfaceContainer: cloud,
        onSurfaceVariant: slate,
        outline: line,
        outlineVariant: line,
        error: error,
        onError: white,
        errorContainer: errorBg,
        onErrorContainer: error,
        inverseSurface: inkSurface,
        onInverseSurface: white,
      );
}
