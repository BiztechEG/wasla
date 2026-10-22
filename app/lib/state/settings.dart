import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

final prefsProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('prefsProvider must be overridden'),
);

class AppSettings {
  const AppSettings({
    required this.themeMode,
    required this.locale,
    this.phoneView = true,
  });

  final ThemeMode themeMode;
  final Locale locale;

  /// In a browser on a wide screen: the app as wide as a phone, in the
  /// middle of the window.
  final bool phoneView;

  AppSettings copyWith({
    ThemeMode? themeMode,
    Locale? locale,
    bool? phoneView,
  }) => AppSettings(
    themeMode: themeMode ?? this.themeMode,
    locale: locale ?? this.locale,
    phoneView: phoneView ?? this.phoneView,
  );
}

/// Whether the app runs in a browser; tests say so to try the web's ways.
final isWebProvider = Provider<bool>((ref) => kIsWeb);

/// Theme, language and the browser's phone view, kept on the device so they apply before sign-in.
class SettingsNotifier extends Notifier<AppSettings> {
  static const _themeKey = 'theme';
  static const _localeKey = 'locale';
  static const _phoneViewKey = 'phone_view';

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
      // In a wide browser window the app starts as wide as a phone.
      phoneView: prefs.getBool(_phoneViewKey) ?? true,
    );
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = state.copyWith(themeMode: mode);
    await _prefs.setString(_themeKey, mode.name);
  }

  Future<void> setLocale(Locale locale) async {
    state = state.copyWith(locale: locale);
    await _prefs.setString(_localeKey, locale.languageCode);
  }

  Future<void> setPhoneView(bool on) async {
    state = state.copyWith(phoneView: on);
    await _prefs.setBool(_phoneViewKey, on);
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);
