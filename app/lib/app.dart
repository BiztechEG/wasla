import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'l10n/app_localizations.dart';
import 'push/push.dart';
import 'state/billing_providers.dart';
import 'state/providers.dart';
import 'state/settings.dart';
import 'theme.dart';
import 'ui/admin_screen.dart';
import 'ui/home_shell.dart';
import 'ui/join_link.dart';
import 'ui/profile_setup_screen.dart';
import 'ui/sign_in_screen.dart';
import 'ui/start_screen.dart';
import 'ui/widgets.dart';

final _navigatorKey = GlobalKey<NavigatorState>();

class WaslaApp extends ConsumerWidget {
  const WaslaApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    ref.watch(pushSyncProvider);

    // Signing out (or the session ending) must not leave a members or
    // project screen open on top of the sign-in screen.
    ref.listen(authProvider, (previous, next) {
      if (previous?.value != next.value) {
        _navigatorKey.currentState?.popUntil((route) => route.isFirst);
      }
    });

    return MaterialApp(
      navigatorKey: _navigatorKey,
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
    if (!ref.watch(welcomeShownProvider).hasValue) return const _Splash();
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
    final hasWorkspace = memberships.value!.isNotEmpty;
    // In a browser, the platform admins' first page is their dashboard.
    if (kIsWeb) {
      final admin = ref.watch(platformAdminProvider);
      if (!admin.hasValue && !admin.hasError) return const _Splash();
      if (admin.value ?? false) {
        return AdminScreen(
          app: JoinFromLink(
            child: hasWorkspace
                ? const HomeShell()
                : const StartScreen(asPage: true),
          ),
        );
      }
    }
    return JoinFromLink(
      child: hasWorkspace ? const HomeShell() : const StartScreen(),
    );
  }
}

/// The welcome screen: Wasla's logo and name on the brand color. It shows
/// for a moment when the app opens, and while the account loads.
class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      backgroundColor: WaslaColors.accent,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(30),
                  ),
                  child: const BrandLogo(size: 72),
                ),
                const SizedBox(height: 20),
                Text(
                  l.appName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 32,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  l.tagline,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.85),
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 36),
                const SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Keeps the welcome screen up for a moment when the app opens, so it reads
/// as a welcome rather than a flash.
final welcomeShownProvider = FutureProvider<void>(
  (ref) => Future.delayed(const Duration(milliseconds: 1400)),
);
