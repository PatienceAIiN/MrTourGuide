import 'dart:async';

import 'package:flutter/material.dart';

import '../constant.dart';
import '../services/haptic_service.dart';
import '../services/media_api.dart';

/// Modern capsule hero: live city covers cross-fade inside a tall
/// capsule, gently floating — the auth pages' visual anchor.
class CapsuleHero extends StatefulWidget {
  const CapsuleHero({super.key});

  @override
  State<CapsuleHero> createState() => _CapsuleHeroState();
}

class _CapsuleHeroState extends State<CapsuleHero> {
  List<String> covers = [];
  int index = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    MediaApi.fetchCities().then((cities) {
      if (!mounted) return;
      setState(() => covers = [
            for (final c in cities)
              if (c.absoluteCoverUrl != null) c.absoluteCoverUrl!
          ]);
      _timer = Timer.periodic(const Duration(seconds: 3), (_) {
        if (mounted && covers.length > 1) {
          setState(() => index = (index + 1) % covers.length);
        }
      });
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Floaty(
      amplitude: 8,
      child: Container(
        width: 168,
        height: 220,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(100),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF1E319D).withValues(alpha: 0.25),
              blurRadius: 30,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(100),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 700),
            switchInCurve: Curves.easeOutCubic,
            child: covers.isEmpty
                ? Container(
                    key: const ValueKey('fallback'),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFF1E319D), Color(0xFF3CEBFF)],
                      ),
                    ),
                    child: const Center(
                        child: Icon(Icons.travel_explore,
                            color: Colors.white70, size: 48)),
                  )
                : Image.network(
                    covers[index],
                    key: ValueKey(index),
                    fit: BoxFit.cover,
                    width: 168,
                    height: 220,
                    errorBuilder: (c, e, s) => Container(color: Colors.black12),
                  ),
          ),
        ),
      ),
    );
  }
}

/// Gentle endless float — breathes life into images and icons.
class Floaty extends StatefulWidget {
  final Widget child;
  final double amplitude;
  const Floaty({super.key, required this.child, this.amplitude = 6});

  @override
  State<Floaty> createState() => _FloatyState();
}

class _FloatyState extends State<Floaty> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 3))
        ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) => Transform.translate(
        offset: Offset(0, -widget.amplitude / 2 + widget.amplitude * _c.value),
        child: child,
      ),
      child: widget.child,
    );
  }
}

/// Consistent confirmation dialog. Returns true when confirmed.
Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  String cancelLabel = 'Cancel',
  bool destructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(cancelLabel),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: destructive ? red : blue,
          ),
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Primary button with a built-in progress spinner while [busy].
class LoadingButton extends StatelessWidget {
  final bool busy;
  final VoidCallback onPressed;
  final String label;
  final IconData? icon;
  final Color color;

  const LoadingButton({
    super.key,
    required this.busy,
    required this.onPressed,
    required this.label,
    this.icon,
    this.color = blue,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: double.infinity,
      child: FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: color,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        onPressed: busy ? null : onPressed,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: busy
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child:
                      CircularProgressIndicator(color: white, strokeWidth: 2.5),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (icon != null) ...[
                      Icon(icon, size: 20),
                      const SizedBox(width: 8),
                    ],
                    Text(label,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600)),
                  ],
                ),
        ),
      ),
    );
  }
}

/// Fade+slide entrance used across lists for a smooth, dynamic feel.
class Entrance extends StatelessWidget {
  final Widget child;
  final int index;

  const Entrance({super.key, required this.child, this.index = 0});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 140 + (index.clamp(0, 8)) * 30),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child:
            Transform.translate(offset: Offset(0, 18 * (1 - t)), child: child),
      ),
      child: child,
    );
  }
}

/// Springy, haptic press wrapper: scales down on touch with graded haptic
/// feedback ('tick' | 'light' | 'medium' | 'string'), springs back on release.
class Springy extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final String haptic;
  final BorderRadius? borderRadius;

  const Springy({
    super.key,
    required this.child,
    this.onTap,
    this.haptic = 'light',
    this.borderRadius,
  });

  @override
  State<Springy> createState() => _SpringyState();
}

class _SpringyState extends State<Springy> {
  bool _pressed = false;

  void _feedback() {
    switch (widget.haptic) {
      case 'tick':
        Haptics.tick();
      case 'medium':
        Haptics.medium();
      case 'string':
        Haptics.string();
      default:
        Haptics.light();
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) {
        setState(() => _pressed = true);
        _feedback();
      },
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.94 : 1.0,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutBack,
        child: widget.child,
      ),
    );
  }
}
