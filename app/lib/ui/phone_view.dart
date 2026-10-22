import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../state/settings.dart';
import 'widgets.dart';

/// How wide the app is in the phone view.
const phoneViewWidth = 420.0;

/// Whether the window is wide enough for the phone view to change anything.
bool phoneViewFits(Size window) => window.width >= phoneViewWidth + 160;

/// In a browser with the phone view on, the app as wide as a phone in the
/// middle of the window (and the rest of the app thinks the screen is that
/// wide), with a button beside it to go back to the full width.
class PhoneView extends ConsumerWidget {
  const PhoneView({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on =
        ref.watch(isWebProvider) &&
        ref.watch(settingsProvider.select((s) => s.phoneView));
    final media = MediaQuery.of(context);
    if (!on || !phoneViewFits(media.size)) return child;

    final scheme = Theme.of(context).colorScheme;
    // On a tall window it stands like a phone, with rounded corners.
    final tall = media.size.height >= 760;
    final height = tall
        ? math.min(media.size.height - 48, 920.0)
        : media.size.height;
    final radius = BorderRadius.circular(tall ? 28 : 0);
    return Material(
      color: scheme.surfaceContainerHighest,
      child: Stack(
        children: [
          Center(
            child: Container(
              key: const Key('phoneView'),
              width: phoneViewWidth,
              height: height,
              decoration: BoxDecoration(
                borderRadius: radius,
                border: Border.all(color: scheme.outlineVariant),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.10),
                    blurRadius: 32,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: radius,
                child: MediaQuery(
                  data: media.copyWith(
                    size: Size(phoneViewWidth, height),
                    padding: EdgeInsets.zero,
                    viewPadding: EdgeInsets.zero,
                  ),
                  child: child,
                ),
              ),
            ),
          ),
          PositionedDirectional(
            top: 16,
            end: 16,
            child: TextButton.icon(
              key: const Key('fullWidth'),
              onPressed: () =>
                  ref.read(settingsProvider.notifier).setPhoneView(false),
              icon: const Icon(LucideIcons.maximize2, size: 18),
              label: Text(context.l10n.fullWidthView),
            ),
          ),
        ],
      ),
    );
  }
}
