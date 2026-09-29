import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Two typefaces, each with a distinct job: Space Grotesk (a geometric
/// grotesque with real character) carries every headline and display
/// moment -- it's what gives OpenPlay a voice instead of reading as
/// default Roboto. Inter, a quiet, highly-legible workhorse, carries body
/// and label text so long roster names and descriptions stay easy to read.
class AppTypography {
  AppTypography._();

  static TextTheme textTheme(Color onSurface, Color onSurfaceMuted) {
    final display = GoogleFonts.spaceGroteskTextTheme();
    final body = GoogleFonts.interTextTheme();

    TextStyle d(TextStyle? base, {required double size, required FontWeight weight, double? height, double? spacing}) {
      return (base ?? const TextStyle()).copyWith(
        fontSize: size,
        fontWeight: weight,
        height: height,
        letterSpacing: spacing,
        color: onSurface,
      );
    }

    return TextTheme(
      displayLarge: d(display.displayLarge, size: 40, weight: FontWeight.w600, height: 1.1),
      displayMedium: d(display.displayMedium, size: 32, weight: FontWeight.w600, height: 1.15),
      displaySmall: d(display.displaySmall, size: 28, weight: FontWeight.w600, height: 1.2),
      headlineLarge: d(display.headlineLarge, size: 24, weight: FontWeight.w600, height: 1.25),
      headlineMedium: d(display.headlineMedium, size: 20, weight: FontWeight.w600, height: 1.3),
      headlineSmall: d(display.headlineSmall, size: 18, weight: FontWeight.w600, height: 1.3),
      titleLarge: d(display.titleLarge, size: 17, weight: FontWeight.w600, height: 1.3),
      titleMedium: d(body.titleMedium, size: 15, weight: FontWeight.w600, height: 1.35),
      titleSmall: d(body.titleSmall, size: 13, weight: FontWeight.w600, height: 1.35, spacing: 0.1),
      bodyLarge: d(body.bodyLarge, size: 16, weight: FontWeight.w400, height: 1.5),
      bodyMedium: d(body.bodyMedium, size: 14, weight: FontWeight.w400, height: 1.5),
      bodySmall: d(body.bodySmall, size: 13, weight: FontWeight.w400, height: 1.45).copyWith(color: onSurfaceMuted),
      labelLarge: d(body.labelLarge, size: 14, weight: FontWeight.w600, height: 1.2),
      labelMedium: d(body.labelMedium, size: 12, weight: FontWeight.w600, height: 1.2, spacing: 0.2),
      labelSmall: d(body.labelSmall, size: 11, weight: FontWeight.w600, height: 1.2, spacing: 0.2).copyWith(color: onSurfaceMuted),
    );
  }
}
