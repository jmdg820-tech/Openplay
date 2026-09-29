/// A single spacing scale used everywhere instead of ad hoc numbers, so
/// rhythm stays consistent across every screen and both platforms.
class AppSpacing {
  AppSpacing._();

  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
  static const xxxl = 48.0;
}

/// Corner-radius scale. Cards/sheets/dialogs and buttons/chips/inputs each
/// pick from this one scale rather than inventing their own -- controlled,
/// not uniform-on-everything: bigger surfaces get a bigger radius.
class AppRadius {
  AppRadius._();

  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const pill = 999.0;
}

/// Breakpoints for OpenPlay's adaptive layouts. Below [tablet] the app uses
/// the mobile shell (bottom navigation, single column); at/above [desktop]
/// it uses the desktop shell (nav rail, multi-column content).
class AppBreakpoints {
  AppBreakpoints._();

  static const tablet = 700.0;
  static const desktop = 1000.0;
  static const wideDesktop = 1400.0;
}
