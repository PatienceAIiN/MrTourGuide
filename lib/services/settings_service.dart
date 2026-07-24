import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:shared_preferences/shared_preferences.dart';

/// User-tailored experience settings, persisted locally.
///
/// These are the viewer's global defaults; each video's creator config can
/// further shape the experience, and the player merges the two (user settings
/// always win — accessibility first).
class SettingsService extends ChangeNotifier {
  static final SettingsService instance = SettingsService._();
  SettingsService._();

  static const _kHaptics = 'settings.haptics';
  static const _kSound = 'settings.sound';
  static const _kIntensity = 'settings.intensity';
  static const _kAutoplay = 'settings.autoplay';
  static const _kReduceMotion = 'settings.reduceMotion';
  static const _kUiHaptics = 'settings.uiHaptics';
  static const _kNotifications = 'settings.notifications';
  static const _kLocationNotifs = 'settings.locationNotifs';
  static const _kDarkMode = 'settings.darkMode';

  bool haptics = true;
  bool sound = true;
  double intensity = 0.7;
  bool autoplay = true;

  /// Touch feedback on UI interactions (buttons, cards, nav).
  bool uiHaptics = true;

  /// New-content notifications (toast + bell badge polling).
  bool notifications = true;

  /// Location-specific pushes only: when ON, "new experience" notifications
  /// arrive only for the user's own city; when OFF, all locations notify.
  bool locationNotifs = false;

  /// Dark theme for the whole app.
  bool darkMode = false;

  ThemeMode get themeMode => darkMode ? ThemeMode.dark : ThemeMode.light;

  /// Accessibility: minimize animations for motion-sensitive users.
  bool reduceMotion = false;

  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      haptics = prefs.getBool(_kHaptics) ?? true;
      sound = prefs.getBool(_kSound) ?? true;
      intensity = prefs.getDouble(_kIntensity) ?? 0.7;
      autoplay = prefs.getBool(_kAutoplay) ?? true;
      reduceMotion = prefs.getBool(_kReduceMotion) ?? false;
      uiHaptics = prefs.getBool(_kUiHaptics) ?? true;
      notifications = prefs.getBool(_kNotifications) ?? true;
      locationNotifs = prefs.getBool(_kLocationNotifs) ?? false;
      darkMode = prefs.getBool(_kDarkMode) ?? false;
    } catch (_) {
      // Defaults are fine if prefs are unavailable (e.g. tests).
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> save() async {
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kHaptics, haptics);
      await prefs.setBool(_kSound, sound);
      await prefs.setDouble(_kIntensity, intensity);
      await prefs.setBool(_kAutoplay, autoplay);
      await prefs.setBool(_kReduceMotion, reduceMotion);
      await prefs.setBool(_kUiHaptics, uiHaptics);
      await prefs.setBool(_kNotifications, notifications);
      await prefs.setBool(_kLocationNotifs, locationNotifs);
      await prefs.setBool(_kDarkMode, darkMode);
    } catch (_) {}
  }

  Duration animation(Duration normal) => reduceMotion ? Duration.zero : normal;
}
