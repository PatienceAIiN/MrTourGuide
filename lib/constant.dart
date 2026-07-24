import 'package:flutter/material.dart';

/// Brand colour (deep teal) — pairs with the cyan accent and the
/// dark-teal CTAs; readable on light surfaces and acceptable on dark
/// (adaptive spots use [brandInk] for the bright-cyan dark variant).
const blue = Color(0xFF0F6E84);
const black = Color.fromARGB(255, 0, 0, 0);
const grey = Color.fromARGB(255, 181, 181, 181);
const white = Color.fromARGB(255, 255, 255, 255);
const lightBlue = Color.fromARGB(255, 60, 235, 255);
const red = Color.fromARGB(255, 255, 87, 87);

newSnackBar(BuildContext context, {title}) {
  return ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      backgroundColor: blue,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      // Explicit white — theme defaults made this unreadable in dark mode.
      content: Text(
        '$title',
        style: const TextStyle(color: Colors.white, fontSize: 13.5),
      ),
    ),
  );
}

/// Shows a blocking spinner overlay (e.g. "Deleting…", "Saving…",
/// "Publishing…") while [future] runs, then dismisses it — so every
/// create/update/delete gives immediate feedback. Errors propagate to the
/// caller's own try/catch unchanged.
Future<T> showBusyWhile<T>(
  BuildContext context,
  Future<T> future, {
  String label = 'Working…',
}) async {
  final nav = Navigator.of(context, rootNavigator: true);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black.withOpacity(0.35),
    builder: (ctx) => Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
        decoration: BoxDecoration(
          color: cardBg(ctx),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                  strokeWidth: 2.4, color: brandInk(ctx)),
            ),
            const SizedBox(width: 14),
            Text(label,
                style:
                    TextStyle(color: ink(ctx), fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    ),
  );
  try {
    return await future;
  } finally {
    if (nav.canPop()) nav.pop();
  }
}

/// Theme-aware surfaces (light/dark).
Color pageBg(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF101012)
        : const Color.fromRGBO(244, 243, 243, 1);

Color cardBg(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF1D1D22)
        : Colors.white;

Color ink(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? Colors.white
        : Colors.black87;

Color inkSoft(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? Colors.white60
        : Colors.black54;

/// Brand teal as a *foreground* (text/icon) colour. The deep teal is
/// too dim on the dark scaffold, so dark mode uses a bright cyan that
/// keeps the identity while staying readable.
Color brandInk(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF4DD6EE)
        : blue;
