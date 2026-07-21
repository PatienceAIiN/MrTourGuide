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

  const NavEntry({
    required this.icon,
    required this.label,
    this.tabIndex,
    this.action,
    this.color,
  });
}

/// iOS-style floating, frosted, horizontally scrollable bottom bar.
///
/// Merges tab navigation and global actions (MR/VR, settings, feedback,
/// update, logout) into one bar — no side drawer needed.
class AppBottomNav extends StatelessWidget {
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
            // Centered when everything fits; scrolls horizontally when not.
            child: Center(
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
            Icon(e.icon, size: 24, color: color),
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
