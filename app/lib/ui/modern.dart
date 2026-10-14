import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Room the floating nav bar takes at the bottom of a tab, so the last item
/// of a list can scroll clear of it.
double navClearance(BuildContext context) =>
    MediaQuery.paddingOf(context).bottom + 24;

/// A tab with a "new" button that slides away while the list scrolls down
/// and comes back on the first pull down, so it never hides the last rows.
class FabScaffold extends StatefulWidget {
  const FabScaffold({super.key, required this.body, this.fab});

  final Widget body;
  final Widget? fab;

  @override
  State<FabScaffold> createState() => _FabScaffoldState();
}

class _FabScaffoldState extends State<FabScaffold> {
  bool _shown = true;

  bool _onScroll(UserScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    final shown = switch (n.direction) {
      ScrollDirection.reverse => n.metrics.pixels <= n.metrics.minScrollExtent,
      ScrollDirection.forward => true,
      ScrollDirection.idle => _shown,
    };
    if (shown != _shown) setState(() => _shown = shown);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final fab = widget.fab;
    return Scaffold(
      floatingActionButton: fab == null
          ? null
          : AnimatedSlide(
              offset: _shown ? Offset.zero : const Offset(0, 0.6),
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              child: AnimatedScale(
                scale: _shown ? 1 : 0.8,
                duration: const Duration(milliseconds: 220),
                child: AnimatedOpacity(
                  opacity: _shown ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: IgnorePointer(
                    ignoring: !_shown,
                    // Above the floating nav bar, which the tab runs under.
                    child: Padding(
                      padding: EdgeInsets.only(
                        bottom: MediaQuery.paddingOf(context).bottom,
                      ),
                      child: fab,
                    ),
                  ),
                ),
              ),
            ),
      body: NotificationListener<UserScrollNotification>(
        onNotification: _onScroll,
        child: widget.body,
      ),
    );
  }
}

/// The square "new" button with a soft brand-colored shadow.
class WaslaFab extends StatelessWidget {
  const WaslaFab({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final light = Color.lerp(scheme.primary, Colors.white, dark ? 0.2 : 0.12)!;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        excludeSemantics: true,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(19),
            gradient: LinearGradient(
              begin: AlignmentDirectional.topStart,
              end: AlignmentDirectional.bottomEnd,
              colors: [light, scheme.primary],
            ),
            boxShadow: [
              BoxShadow(
                color: scheme.primary.withValues(alpha: dark ? 0.25 : 0.3),
                blurRadius: 22,
                spreadRadius: -6,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(19),
              onTap: onPressed,
              child: SizedBox.square(
                dimension: 56,
                child: Icon(icon, color: scheme.onPrimary, size: 23),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One tab of [FloatingNavBar].
class NavItem {
  const NavItem({required this.icon, required this.label, this.count = 0});

  final IconData icon;
  final String label;
  final int count;
}

/// The rounded bar that floats over the content. Only the chosen tab shows
/// its name; the others carry it as a tooltip.
class FloatingNavBar extends StatelessWidget {
  const FloatingNavBar({
    super.key,
    required this.items,
    required this.selected,
    required this.onSelected,
  });

  final List<NavItem> items;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final background = dark ? const Color(0xFF1C1F1E) : Colors.white;
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: dark ? 0.5 : 0.12),
                blurRadius: 30,
                spreadRadius: -10,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: Container(
                height: 64,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: background.withValues(alpha: 0.86),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    for (var i = 0; i < items.length; i++)
                      if (i == selected)
                        Flexible(
                          child: _NavButton(
                            item: items[i],
                            selected: true,
                            onTap: () => onSelected(i),
                          ),
                        )
                      else
                        _NavButton(
                          item: items[i],
                          selected: false,
                          onTap: () => onSelected(i),
                        ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final NavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
    final icon = Badge(
      isLabelVisible: item.count > 0,
      backgroundColor: scheme.error,
      textColor: scheme.onError,
      label: Text(item.count > 99 ? '99+' : '${item.count}'),
      child: Icon(item.icon, color: color, size: 22),
    );
    return Tooltip(
      message: item.label,
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        selected: selected,
        label: item.label,
        excludeSemantics: true,
        child: Material(
          color: selected ? scheme.primaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onTap,
            child: AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              child: Container(
                height: 44,
                padding: EdgeInsets.symmetric(horizontal: selected ? 14 : 12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    icon,
                    if (selected) ...[
                      const SizedBox(width: 7),
                      Flexible(
                        child: Text(
                          item.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: color,
                            fontWeight: FontWeight.w600,
                            fontSize: 13.5,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A rounded filter button; the chosen one is filled.
class FilterPill extends StatelessWidget {
  const FilterPill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.count,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fg = selected ? scheme.surface : scheme.onSurfaceVariant;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? scheme.onSurface : scheme.surfaceContainerHigh,
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: fg,
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
                if (count != null && count! > 0) ...[
                  const SizedBox(width: 5),
                  Text(
                    '$count',
                    style: TextStyle(
                      color: fg.withValues(alpha: 0.75),
                      fontSize: 11.5,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A round button on a light fill, for the top bars.
class SoftIconButton extends StatelessWidget {
  const SoftIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.size = 40,
  });

  final Widget icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: size,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        style: IconButton.styleFrom(
          backgroundColor: scheme.surfaceContainerHigh,
          foregroundColor: scheme.onSurface,
        ),
        icon: icon,
      ),
    );
  }
}

/// Bars for a voice message: one per couple of seconds, so a long message
/// looks long. [progress] (0 to 1) darkens what has been played.
class VoiceWave extends StatelessWidget {
  const VoiceWave({
    super.key,
    required this.seconds,
    required this.color,
    this.progress = 0,
    this.height = 20,
    this.minBars = 5,
    this.maxBars = 18,
    this.seed = 0,
  });

  final int seconds;
  final Color color;
  final double progress;
  final double height;
  final int minBars;
  final int maxBars;
  final int seed;

  static const barWidth = 3.0;
  static const gap = 2.0;

  int get bars => (seconds / 2.5).round().clamp(minBars, maxBars);

  double get width => bars * barWidth + (bars - 1) * gap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: CustomPaint(
        painter: _WavePainter(
          bars: bars,
          color: color,
          progress: progress,
          seed: seed,
          rtl: Directionality.of(context) == TextDirection.rtl,
        ),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter({
    required this.bars,
    required this.color,
    required this.progress,
    required this.seed,
    required this.rtl,
  });

  final int bars;
  final Color color;
  final double progress;
  final int seed;
  final bool rtl;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..strokeCap = StrokeCap.round;
    for (var i = 0; i < bars; i++) {
      final level = (math.sin(i * 1.9 + seed) + 1) / 2;
      final h = size.height * (0.28 + 0.72 * level);
      final x =
          (rtl ? bars - 1 - i : i) * (VoiceWave.barWidth + VoiceWave.gap) +
          VoiceWave.barWidth / 2;
      final played = progress > 0 && (i + 0.5) / bars <= progress;
      paint
        ..color = color.withValues(alpha: progress == 0 || played ? 0.85 : 0.3)
        ..strokeWidth = VoiceWave.barWidth;
      canvas.drawLine(
        Offset(x, (size.height - h) / 2 + 1.5),
        Offset(x, (size.height + h) / 2 - 1.5),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.progress != progress || old.color != color || old.bars != bars;
}
