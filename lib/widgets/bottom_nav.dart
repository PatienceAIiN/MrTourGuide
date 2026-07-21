import 'dart:ui';

import 'package:flutter/material.dart';

import '../constant.dart';
import '../services/haptic_service.dart';

class NavEntry {
  final IconData icon;
  final String label;

  /// Tab index to switch to, or null for action entries.
  final int? tabIndex;
  final VoidCallback? action;
  final Color? color;

  /// Show a small "new content" dot on this entry.
  final bool badge;

  const NavEntry({
    required this.icon,
    required this.label,
    this.tabIndex,
    this.action,
    this.color,
    this.badge = false,
  });
}

/// iOS-style floating, frosted, horizontally scrollable bottom bar.
///
/// Merges tab navigation and global actions (MR/VR, settings, feedback,
/// update, logout) into one bar — no side drawer needed.
class AppBottomNav extends StatefulWidget {
  final int currentIndex;
  final List<NavEntry> entries;
  final void Function(int tabIndex) onSelectTab;

  const AppBottomNav({
    super.key,
    required this.currentIndex,
    required this.entries,
    required this.onSelectTab,
  });

  @override
  State<AppBottomNav> createState() => _AppBottomNavState();
}

class _AppBottomNavState extends State<AppBottomNav> {
  int get currentIndex => widget.currentIndex;
  List<NavEntry> get entries => widget.entries;
  void Function(int) get onSelectTab => widget.onSelectTab;

  // Clicky-wheel scrolling: a soft tick roughly every item width.
  double _scrollAccum = 0;

  bool _onScroll(ScrollUpdateNotification n) {
    _scrollAccum += (n.scrollDelta ?? 0).abs();
    if (_scrollAccum >= 48) {
      _scrollAccum = 0;
      Haptics.tick();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            height: 68,
            decoration: BoxDecoration(
              color: (Theme.of(context).brightness == Brightness.dark
                      ? const Color(0xFF1D1D22)
                      : Colors.white)
                  .withValues(alpha: 0.82),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.10),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            // Centered when everything fits; scrolls horizontally when not
            // — with a soft haptic tick as it scrolls.
            child: Center(
              child: NotificationListener<ScrollUpdateNotification>(
                onNotification: _onScroll,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < entries.length; i++) ...[
                        if (i > 0) const SizedBox(width: 2),
                        _item(context, entries[i]),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _item(BuildContext context, NavEntry e) {
    final selected = e.tabIndex != null && e.tabIndex == currentIndex;
    final idle = Theme.of(context).brightness == Brightness.dark
        ? Colors.white54
        : Colors.black45;
    final color = selected ? blue : (e.color ?? idle);
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () {
        Haptics.tick();
        if (e.tabIndex != null) {
          onSelectTab(e.tabIndex!);
        } else {
          e.action?.call();
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: selected ? blue.withValues(alpha: 0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(e.icon, size: 24, color: color),
                if (e.badge)
                  Positioned(
                    right: -3,
                    top: -2,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Color(0xFF3CEBFF),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 3),
            Text(
              e.label,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
