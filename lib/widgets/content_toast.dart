import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../services/haptic_service.dart';

/// Minimal "new content" notification: a floating glass capsule that slides
/// down from the top with a pulsing dot, auto-dismisses, and opens Explore
/// on tap. Island-style — small, dark, quiet.
class ContentToast {
  static OverlayEntry? _entry;

  static void show(
    BuildContext context, {
    required String message,
    required VoidCallback onOpen,
  }) {
    dismiss();
    Haptics.tick();
    final overlay = Overlay.of(context);
    _entry = OverlayEntry(
      builder: (context) => _ToastBody(
        message: message,
        onOpen: () {
          dismiss();
          onOpen();
        },
        onClose: dismiss,
      ),
    );
    overlay.insert(_entry!);
    Timer(const Duration(seconds: 7), dismiss);
  }

  static void dismiss() {
    _entry?.remove();
    _entry = null;
  }
}

class _ToastBody extends StatefulWidget {
  final String message;
  final VoidCallback onOpen;
  final VoidCallback onClose;

  const _ToastBody({
    required this.message,
    required this.onOpen,
    required this.onClose,
  });

  @override
  State<_ToastBody> createState() => _ToastBodyState();
}

class _ToastBodyState extends State<_ToastBody>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOutBack,
          builder: (context, t, child) => Transform.translate(
            offset: Offset(0, -64 * (1 - t)),
            child: Opacity(opacity: t.clamp(0, 1), child: child),
          ),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.only(top: 10),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                  child: Material(
                    color: Colors.black.withValues(alpha: 0.78),
                    child: InkWell(
                      onTap: widget.onOpen,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Pulsing "live" dot
                            FadeTransition(
                              opacity:
                                  Tween(begin: 0.35, end: 1.0).animate(_pulse),
                              child: Container(
                                width: 8,
                                height: 8,
                                decoration: const BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Color(0xFF3CEBFF),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 260),
                              child: Text(
                                widget.message,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            InkWell(
                              onTap: widget.onClose,
                              customBorder: const CircleBorder(),
                              child: const Padding(
                                padding: EdgeInsets.all(6),
                                child: Icon(Icons.close,
                                    size: 14, color: Colors.white38),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
