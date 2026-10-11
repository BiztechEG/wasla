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

  /// Lighter versions of the project colors for the dark theme (teal is the
  /// dark accent from the design).
  static const _dark = {
    '#0F6E6A': Color(0xFF4CC2B7),
    '#C2660A': Color(0xFFF0A35E),
    '#2F5BD3': Color(0xFF8AA7F2),
    '#7247B8': Color(0xFFB79BE6),
  };

  static Color project(String hex, Brightness brightness) {
    if (brightness == Brightness.dark) {
      return _dark[hex.toUpperCase()] ??
          Color.lerp(parse(hex), Colors.white, 0.4)!;
    }
    return parse(hex);
  }

  /// Text drawn on a 16% tint of [color] needs a deeper shade to stay legible.
  static Color onTint(Color color, Brightness brightness) =>
      brightness == Brightness.dark
      ? Color.lerp(color, Colors.white, 0.35)!
      : Color.lerp(color, Colors.black, 0.25)!;
}

const _font = 'IBMPlexSansArabic';

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;

  final scheme = ColorScheme(
    brightness: brightness,
    primary: dark ? WaslaColors.accentDark : WaslaColors.accent,
    onPrimary: dark ? const Color(0xFF00201D) : Colors.white,
    primaryContainer: dark ? const Color(0xFF0F2E2C) : const Color(0xFFDDEFEC),
    onPrimaryContainer: dark ? WaslaColors.accentDark : WaslaColors.accent,
    secondary: dark ? WaslaColors.accentDark : WaslaColors.accent,
    onSecondary: dark ? const Color(0xFF00201D) : Colors.white,
    error: dark ? const Color(0xFFF2957A) : const Color(0xFFB4441C),
    onError: dark ? Colors.black : Colors.white,
    errorContainer: dark ? const Color(0xFF3A211A) : const Color(0xFFFBE9E2),
    onErrorContainer: dark ? const Color(0xFFF2957A) : const Color(0xFFB4441C),
    surface: dark ? const Color(0xFF141414) : Colors.white,
    onSurface: dark ? const Color(0xFFF2F2F2) : const Color(0xFF12201E),
    onSurfaceVariant: dark ? const Color(0xFFA3A3A3) : const Color(0xFF566664),
    // Edges of inputs and switches need 3:1 contrast; dividers use the
    // lighter border (outlineVariant).
    outline: dark ? const Color(0xFF6B6B6B) : const Color(0xFF86948F),
    outlineVariant: dark ? const Color(0xFF262626) : const Color(0xFFE1E7E5),
    secondaryContainer: dark
        ? const Color(0xFF0F2E2C)
        : const Color(0xFFDDEFEC),
    onSecondaryContainer: dark ? WaslaColors.accentDark : WaslaColors.accent,
    surfaceContainerHighest: dark
        ? const Color(0xFF222222)
        : const Color(0xFFE9EEEC),
    surfaceContainerHigh: dark
        ? const Color(0xFF1B1B1B)
        : const Color(0xFFEEF2F1),
    surfaceContainer: dark ? const Color(0xFF141414) : Colors.white,
    surfaceContainerLow: dark ? const Color(0xFF141414) : Colors.white,
    surfaceContainerLowest: dark ? Colors.black : Colors.white,
    shadow: Colors.black,
  );

  final background = dark ? Colors.black : const Color(0xFFF2F5F4);
  final radius = BorderRadius.circular(15);
  const font = TextStyle(fontFamily: _font);

  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: _font,
    scaffoldBackgroundColor: background,
  );

  return base.copyWith(
    appBarTheme: AppBarTheme(
      backgroundColor: background,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: base.textTheme.titleLarge?.copyWith(
        fontFamily: _font,
        fontWeight: FontWeight.w700,
        color: scheme.onSurface,
        fontSize: 19,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: scheme.primaryContainer,
      indicatorShape: const StadiumBorder(),
      elevation: 0,
      height: 68,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontFamily: _font,
          fontSize: 11.5,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w700
              : FontWeight.w500,
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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 50),
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
        minimumSize: const Size(64, 50),
        shape: RoundedRectangleBorder(borderRadius: radius),
        side: BorderSide(color: scheme.outline),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        visualDensity: VisualDensity.standard,
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        side: WidgetStatePropertyAll(
          BorderSide(color: scheme.surfaceContainerHighest, width: 4),
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.surface
              : scheme.surfaceContainerHighest,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.onSurface
              : scheme.onSurfaceVariant,
        ),
        textStyle: WidgetStateProperty.resolveWith(
          (states) => font.copyWith(
            fontSize: 14,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w500,
          ),
        ),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      elevation: 2,
      highlightElevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      extendedTextStyle: const TextStyle(
        fontFamily: _font,
        fontWeight: FontWeight.w600,
        fontSize: 15,
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    chipTheme: ChipThemeData(
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.onSurface
            : scheme.surface,
      ),
      labelStyle: font.copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: WidgetStateColor.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? background
              : scheme.onSurfaceVariant,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
    ),
    listTileTheme: ListTileThemeData(iconColor: scheme.onSurfaceVariant),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    tabBarTheme: TabBarThemeData(
      dividerColor: scheme.outlineVariant,
      labelStyle: font.copyWith(fontWeight: FontWeight.w600, fontSize: 14),
      unselectedLabelStyle: font.copyWith(fontSize: 14),
    ),
  );
}
