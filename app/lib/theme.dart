import 'package:flutter/material.dart';

/// Colors from the approved design (light and dark).
class WaslaColors {
  static const accent = Color(0xFF0F6E6A);
  static const accentDark = Color(0xFF4CC2B7);

  /// Colors a project can pick, in the order shown in the picker.
  static const projectColors = ['#0F6E6A', '#C2660A', '#2F5BD3', '#7247B8'];

  static Color parse(String hex) {
    final value = int.tryParse(hex.replaceFirst('#', ''), radix: 16);
    return value == null ? accent : Color(0xFF000000 | value);
  }

  /// Project colors read better a little lighter on the dark background.
  static Color project(String hex, Brightness brightness) {
    final color = parse(hex);
    return brightness == Brightness.dark
        ? Color.lerp(color, Colors.white, 0.3)!
        : color;
  }
}

const _font = 'IBMPlexSansArabic';

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;

  final scheme = ColorScheme(
    brightness: brightness,
    primary: dark ? WaslaColors.accentDark : WaslaColors.accent,
    onPrimary: dark ? const Color(0xFF0F1419) : Colors.white,
    primaryContainer: dark ? const Color(0xFF17403E) : const Color(0xFFDCEFEE),
    onPrimaryContainer: dark ? WaslaColors.accentDark : WaslaColors.accent,
    secondary: dark ? WaslaColors.accentDark : WaslaColors.accent,
    onSecondary: dark ? const Color(0xFF0F1419) : Colors.white,
    error: dark ? const Color(0xFFF08A6A) : const Color(0xFFB4441C),
    onError: dark ? const Color(0xFF0F1419) : Colors.white,
    surface: dark ? const Color(0xFF1A2129) : Colors.white,
    onSurface: dark ? const Color(0xFFE8ECEF) : const Color(0xFF14202B),
    onSurfaceVariant: dark ? const Color(0xFFA3AEB9) : const Color(0xFF4A5868),
    outline: dark ? const Color(0xFF2E3842) : const Color(0xFFE2E6EA),
    outlineVariant: dark ? const Color(0xFF2E3842) : const Color(0xFFE2E6EA),
    surfaceContainerHighest: dark
        ? const Color(0xFF232C36)
        : const Color(0xFFEEF1F4),
  );

  final background = dark ? const Color(0xFF0F1419) : const Color(0xFFF4F6F8);
  final bar = dark ? const Color(0xFF151B21) : Colors.white;
  final radius = BorderRadius.circular(12);

  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: _font,
    scaffoldBackgroundColor: background,
  );

  return base.copyWith(
    appBarTheme: AppBarTheme(
      backgroundColor: bar,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      shape: Border(bottom: BorderSide(color: scheme.outline)),
      titleTextStyle: base.textTheme.titleLarge?.copyWith(
        fontFamily: _font,
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
        fontSize: 19,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: bar,
      surfaceTintColor: Colors.transparent,
      indicatorColor: scheme.primaryContainer,
      height: 68,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontFamily: _font,
          fontSize: 12,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w600
              : FontWeight.w400,
          color: states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.onSurfaceVariant,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.onSurfaceVariant,
        ),
      ),
    ),
    cardTheme: CardThemeData(
      color: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: scheme.outline),
      ),
    ),
    dividerTheme: DividerThemeData(color: scheme.outline, space: 1),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: scheme.outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: scheme.outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 48),
        shape: RoundedRectangleBorder(borderRadius: radius),
        textStyle: const TextStyle(
          fontFamily: _font,
          fontWeight: FontWeight.w600,
          fontSize: 15,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 48),
        shape: RoundedRectangleBorder(borderRadius: radius),
        side: BorderSide(color: scheme.outline),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      elevation: 1,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
    ),
    chipTheme: ChipThemeData(
      side: BorderSide(color: scheme.outline),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    listTileTheme: ListTileThemeData(iconColor: scheme.onSurfaceVariant),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}
