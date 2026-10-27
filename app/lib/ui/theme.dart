import 'package:flutter/material.dart';

/// The colours of the sunrise icon: coral on cream by day, deep dusk violet at night.
class Brand {
  static const coral = Color(0xFFFF7452);
  static const cream = Color(0xFFFBF5EF);
  static const peach = Color(0xFFFFC9B3);
  static const dusk = Color(0xFF2B2240);
  static const ink = Color(0xFF2A211C);

  /// A deeper coral for the bottom of gradients and for glows.
  static const ember = Color(0xFFE8553A);
  static const sand = Color(0xFFF3E7DC);

  /// The warm, soft serif for big moments (greetings, slide titles); everything else is in the sans.
  static const display = 'Fraunces';
  static const sans = 'Jakarta';

  static const sunrise = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFFF8A5C), coral, ember],
  );
}

/// One rhythm for the whole app: things arrive fast and settle softly.
class Motion {
  static const fast = Duration(milliseconds: 180);
  static const medium = Duration(milliseconds: 320);
  static const slow = Duration(milliseconds: 600);
  static const curve = Curves.easeOutCubic;
  static const spring = Curves.easeOutBack;
}

ThemeData lifeTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final base = ColorScheme.fromSeed(
    seedColor: Brand.coral,
    brightness: brightness,
  );
  final scheme = base.copyWith(
    primary: Brand.coral,
    onPrimary: Brand.ink, // dark text on coral: white would be too faint
    primaryContainer: dark ? const Color(0xFF4A3550) : Brand.peach,
    onPrimaryContainer: dark ? Brand.cream : Brand.ink,
    secondaryContainer: dark ? const Color(0xFF3A2F54) : Brand.sand,
    onSecondaryContainer: dark ? Brand.cream : Brand.ink,
    surface: dark ? const Color(0xFF1F1830) : Brand.cream,
    onSurface: dark ? Brand.cream : Brand.ink,
    onSurfaceVariant: dark ? const Color(0xFFCFC3D6) : const Color(0xFF6E5F55),
    surfaceContainerHighest: dark
        ? const Color(0xFF342A4A)
        : const Color(0xFFF1E6DC),
    outlineVariant: dark ? const Color(0xFF4A3F5E) : const Color(0xFFEADBCF),
    tertiaryContainer: dark ? const Color(0xFF3A2F54) : const Color(0xFFFFE3D6),
    onTertiaryContainer: dark ? Brand.cream : Brand.ink,
  );
  final text = _textTheme(scheme.onSurface, scheme.onSurfaceVariant);
  const pill = StadiumBorder();
  const buttonPadding = EdgeInsets.symmetric(horizontal: 22, vertical: 14);
  final buttonText = text.labelLarge?.copyWith(
    fontWeight: FontWeight.w700,
    fontSize: 15,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: Brand.sans,
    textTheme: text,
    scaffoldBackgroundColor: scheme.surface,
    splashFactory: InkSparkle.splashFactory,
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: _RiseTransitions(),
        TargetPlatform.iOS: _RiseTransitions(),
      },
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
    ),
    cardTheme: CardThemeData(
      color: dark ? const Color(0xFF2B2240) : Colors.white,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: pill,
        padding: buttonPadding,
        textStyle: buttonText,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: pill,
        padding: buttonPadding,
        textStyle: buttonText,
        side: BorderSide(color: scheme.outlineVariant),
        foregroundColor: scheme.onSurface,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: pill,
        textStyle: buttonText,
        foregroundColor: dark ? Brand.peach : Brand.ember,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? const Color(0xFF2B2240) : Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: const BorderSide(color: Brand.coral, width: 2),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: dark ? Brand.cream : Brand.dusk,
      contentTextStyle: text.bodyMedium?.copyWith(
        color: dark ? Brand.ink : Brand.cream,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      showDragHandle: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
    ),
    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? Colors.white : null,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? Brand.coral : null,
      ),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 32),
    listTileTheme: const ListTileThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(18)),
      ),
    ),
  );
}

TextTheme _textTheme(Color ink, Color soft) {
  TextStyle d(double size, FontWeight w, {double height = 1.1}) => TextStyle(
    fontFamily: Brand.display,
    fontSize: size,
    fontWeight: w,
    height: height,
    letterSpacing: -0.5,
    color: ink,
  );
  TextStyle s(double size, FontWeight w, {Color? color, double height = 1.4}) =>
      TextStyle(
        fontFamily: Brand.sans,
        fontSize: size,
        fontWeight: w,
        height: height,
        color: color ?? ink,
      );
  return TextTheme(
    displayLarge: d(56, FontWeight.w700),
    displayMedium: d(44, FontWeight.w700),
    displaySmall: d(36, FontWeight.w600),
    headlineLarge: d(32, FontWeight.w600, height: 1.15),
    headlineMedium: d(28, FontWeight.w600, height: 1.15),
    headlineSmall: d(24, FontWeight.w600, height: 1.2),
    titleLarge: s(20, FontWeight.w700, height: 1.3),
    titleMedium: s(16, FontWeight.w700, height: 1.3),
    titleSmall: s(14, FontWeight.w700, height: 1.3),
    bodyLarge: s(16, FontWeight.w500, height: 1.5),
    bodyMedium: s(14, FontWeight.w500, height: 1.45),
    bodySmall: s(12.5, FontWeight.w500, color: soft),
    labelLarge: s(14, FontWeight.w600),
    labelMedium: s(12, FontWeight.w600),
    labelSmall: s(11, FontWeight.w700, color: soft),
  );
}

/// New screens rise in gently from below with a fade, the way the sun comes up in the icon.
class _RiseTransitions extends PageTransitionsBuilder {
  const _RiseTransitions();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final enter = CurvedAnimation(
      parent: animation,
      curve: Motion.curve,
      reverseCurve: Curves.easeInCubic,
    );
    final behind = CurvedAnimation(
      parent: secondaryAnimation,
      curve: Motion.curve,
    );
    return FadeTransition(
      opacity: Tween<double>(begin: 1, end: 0.6).animate(behind),
      child: ScaleTransition(
        scale: Tween<double>(begin: 1, end: 0.96).animate(behind),
        child: FadeTransition(
          opacity: enter,
          child: SlideTransition(
            position: Tween(
              begin: const Offset(0, 0.06),
              end: Offset.zero,
            ).animate(enter),
            child: child,
          ),
        ),
      ),
    );
  }
}
