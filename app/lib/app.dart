import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'l10n/app_localizations.dart';
import 'state/providers.dart';
import 'state/settings.dart';
import 'theme.dart';
import 'ui/home_shell.dart';
import 'ui/profile_setup_screen.dart';
import 'ui/sign_in_screen.dart';
import 'ui/start_screen.dart';
import 'ui/widgets.dart';

class WaslaApp extends ConsumerWidget {
  const WaslaApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    return MaterialApp(
      onGenerateTitle: (context) => context.l10n.appName,
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: settings.themeMode,
      locale: settings.locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: const AppGate(),
    );
  }
}

/// Picks the first screen from where the user is: signed out, no name yet,
/// no workspace yet, or ready.
class AppGate extends ConsumerWidget {
  const AppGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    if (auth.value == null) {
      return auth.isLoading ? const _Splash() : const SignInScreen();
    }

    final profile = ref.watch(profileProvider);
    final memberships = ref.watch(membershipsProvider);
    for (final value in [profile, memberships]) {
      if (value.hasError && !value.hasValue) {
        return Scaffold(
          body: ErrorView(
            error: value.error!,
            onRetry: () {
              ref.invalidate(profileProvider);
              ref.invalidate(membershipsProvider);
            },
          ),
        );
      }
    }
    // Wait while a newly signed-in user's data loads, but keep the current
    // screen when the same user's data is only being refreshed.
    if (!profile.hasValue ||
        !memberships.hasValue ||
        profile.isReloading ||
        memberships.isReloading) {
      return const _Splash();
    }

    if (profile.value?.fullName.trim().isEmpty ?? true) {
      return const ProfileSetupScreen();
    }
    if (memberships.value!.isEmpty) return const StartScreen();
    return const HomeShell();
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}
