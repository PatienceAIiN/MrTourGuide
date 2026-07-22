import 'dart:math' as math;

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
  ///
  /// [durationMs] sets how long the pulse lasts. The video engine passes a
  /// value slightly longer than its tick interval so back-to-back calls
  /// overlap into one continuously-changing vibration instead of a stutter.
  static void level(double v, {int durationMs = 60}) {
    if (!_enabled) return;
    _levelAsync(v.clamp(0.0, 1.0), durationMs);
  }

  static Future<void> _levelAsync(double v, int durationMs) async {
    if (!kIsWeb) {
      try {
        _hasAmplitude ??= await Vibration.hasAmplitudeControl();
        if (_hasAmplitude == true) {
          // Perceptual curve: human vibration sense is roughly logarithmic,
          // so a gamma lift makes low/mid energy actually noticeable instead
          // of everything reading as off-or-max.
          final perceptual = math.pow(v, 0.6).toDouble();
          await Vibration.vibrate(
            duration: durationMs,
            amplitude: (1 + 254 * perceptual).round().clamp(1, 255),
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

  /// Recoil: one hard hit then a soft settle — the gunshot/impact feel.
  /// [punch] 0..1 scales the strength.
  static Future<void> recoil(double punch) async {
    if (!_enabled) return;
    final p = punch.clamp(0.0, 1.0);
    if (!kIsWeb) {
      try {
        _hasAmplitude ??= await Vibration.hasAmplitudeControl();
        if (_hasAmplitude == true) {
          await Vibration.vibrate(
              duration: (35 + 45 * p).round(),
              amplitude: (140 + 115 * p).round());
          await Future.delayed(const Duration(milliseconds: 70));
          await Vibration.vibrate(
              duration: 30, amplitude: (40 + 60 * p).round());
          return;
        }
      } catch (_) {}
    }
    HapticFeedback.heavyImpact();
    await Future.delayed(const Duration(milliseconds: 80));
    HapticFeedback.lightImpact();
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
