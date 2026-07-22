import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:vibration/vibration.dart';

import 'settings_service.dart';

/// Graded UI haptics. Real vibration on phones; no-op on web/desktop
/// (Flutter routes HapticFeedback to the platform, which ignores it there).
///
/// Levels, softest → strongest:
///   tick  — selection changes, nav taps
///   light — card touches
///   medium — primary buttons
///   heavy — destructive / major moments
///   string — "guitar string" pluck: a strong hit followed by a decaying
///            flutter, used for expressive moments (opening an experience).
class Haptics {
  static bool get _enabled => SettingsService.instance.uiHaptics;

  static void tick() {
    if (_enabled) HapticFeedback.selectionClick();
  }

  static void light() {
    if (_enabled) HapticFeedback.lightImpact();
  }

  static void medium() {
    if (_enabled) HapticFeedback.mediumImpact();
  }

  static void heavy() {
    if (_enabled) HapticFeedback.heavyImpact();
  }

  static bool? _hasAmplitude;

  /// Feel the current intensity: on phones with amplitude control this is a
  /// continuous 1-255 strength (console-controller smooth); otherwise it
  /// falls back to the three graded impacts.
  static void level(double v) {
    if (!_enabled) return;
    _levelAsync(v.clamp(0.0, 1.0));
  }

  static Future<void> _levelAsync(double v) async {
    if (!kIsWeb) {
      try {
        _hasAmplitude ??= await Vibration.hasAmplitudeControl();
        if (_hasAmplitude == true) {
          // Short pulse whose strength tracks the feel value exactly.
          await Vibration.vibrate(
            duration: (30 + 50 * v).round(),
            amplitude: (1 + 254 * v).round(),
          );
          return;
        }
      } catch (_) {}
    }
    if (v < 0.34) {
      HapticFeedback.lightImpact();
    } else if (v < 0.67) {
      HapticFeedback.mediumImpact();
    } else {
      HapticFeedback.heavyImpact();
    }
  }

  /// Decaying pluck — like a struck guitar string settling.
  static Future<void> string() async {
    if (!_enabled) return;
    HapticFeedback.heavyImpact();
    for (final gap in const [60, 80, 110, 150, 200]) {
      await Future.delayed(Duration(milliseconds: gap));
      HapticFeedback.lightImpact();
    }
    await Future.delayed(const Duration(milliseconds: 240));
    HapticFeedback.selectionClick();
  }
}
