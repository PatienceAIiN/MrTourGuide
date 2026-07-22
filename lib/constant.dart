import 'package:flutter/material.dart';

const blue = Color.fromARGB(255, 30, 49, 157);
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
