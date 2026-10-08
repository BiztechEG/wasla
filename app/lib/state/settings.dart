import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

final prefsProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('prefsProvider must be overridden'),
);

class AppSettings {
  const AppSettings({required this.themeMode, required this.locale});

  final ThemeMode themeMode;
  final Locale locale;
}

/// Theme and language, kept on the device so they apply before sign-in.
class SettingsNotifier extends Notifier<AppSettings> {
  static const _themeKey = 'theme';
  static const _localeKey = 'locale';

  SharedPreferences get _prefs => ref.read(prefsProvider);

  @override
  AppSettings build() {
    final prefs = ref.watch(prefsProvider);
    return AppSettings(
      themeMode: ThemeMode.values.firstWhere(
        (m) => m.name == prefs.getString(_themeKey),
        orElse: () => ThemeMode.system,
      ),
      locale: Locale(prefs.getString(_localeKey) ?? 'ar'),
    );
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = AppSettings(themeMode: mode, locale: state.locale);
    await _prefs.setString(_themeKey, mode.name);
  }

  Future<void> setLocale(Locale locale) async {
    state = AppSettings(themeMode: state.themeMode, locale: locale);
    await _prefs.setString(_localeKey, locale.languageCode);
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);
