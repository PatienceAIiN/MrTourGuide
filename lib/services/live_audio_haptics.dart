import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'haptic_service.dart';
import 'settings_service.dart';

/// Set true to stream band values + decisions to logcat for tuning.
const bool _feelDebug = true;

/// First-person "feel" for the in-app YouTube player.
///
/// Goal: feel the scene the camera-person is in — walking through a street,
/// riding, the ambience and motion around them — as a SOFT, living presence
/// that rises and falls with the scene's physical energy, with gentle accents
/// on real jolts (a hard step, a bump). It stays quiet when someone is simply
/// talking to camera. It works on ANY video because it tracks overall
/// physical energy rather than relying on crisp, audible footstep thumps
/// (many walking videos have soft or buried steps).
///
/// Native streams four band energies (0..1) ~18×/sec:
///   low    (30–250 Hz)  — footfall body, vehicle/engine rumble, impacts
///   lowMid (250–500 Hz) — step slap, physical texture, motion
///   vocal  (300–3400 Hz)— human speech (subtracted out)
///   high   (>3400 Hz)   — air / sparkle (light touch)
class LiveAudioHaptics {
  static const _events = EventChannel('mrtouride/audiofeel');

  StreamSubscription? _sub;
  bool _running = false;
  bool get isRunning => _running;

  double _feelSmooth = 0;  // smoothed physical-feel level (scene motion)
  double _physBase = 0;    // slow floor of physical energy (for accents)
  int _nextThumpMs = 0;    // gait scheduler — when the next footfall fires
  int _lastAccentMs = 0;
  int _lastDebugMs = 0;
  final Stopwatch _clock = Stopwatch()..start();

  void Function(String message)? onError;

  void start() {
    if (_running) return;
    _running = true;
    _feelSmooth = _physBase = 0;
    _nextThumpMs = 0;
    _sub = _events.receiveBroadcastStream().listen(
      _onFrame,
      onError: (e) {
        _running = false;
        onError?.call(e is PlatformException
            ? (e.message ?? 'Live feel is unavailable on this device.')
            : 'Live feel is unavailable on this device.');
      },
      cancelOnError: true,
    );
  }

  void stop() {
    _running = false;
    _sub?.cancel();
    _sub = null;
  }

  void _onFrame(dynamic data) {
    if (!_running || !SettingsService.instance.haptics) return;
    if (data is! Map) return;
    final low = (data['low'] as num?)?.toDouble() ?? 0;
    final lowMid = (data['lowMid'] as num?)?.toDouble() ?? 0;
    final vocal = (data['vocal'] as num?)?.toDouble() ?? 0;
    final high = (data['high'] as num?)?.toDouble() ?? 0;
    final now = _clock.elapsedMilliseconds;

    // Physical energy = the parts of the scene you feel in your body
    // (deep + low-mid motion + a little air), NOT the voice band.
    final physical = low + lowMid * 0.7 + high * 0.15;

    // Subtract the voice: whatever the vocal band carries above the physical
    // level is "someone talking" and must not be felt. This keeps narration
    // and conversation quiet while a busy, moving scene still comes through.
    final voiceOver = (vocal - physical * 0.75).clamp(0.0, 1.0);
    final feelRaw = (physical - voiceOver * 0.9).clamp(0.0, 1.0);

    // Smooth it so the presence glides (soft), instead of flickering.
    _feelSmooth += (feelRaw - _feelSmooth) * 0.35;

    // Slow floor for accent detection.
    if (physical > _physBase) {
      _physBase += (physical - _physBase) * 0.05;
    } else {
      _physBase += (physical - _physBase) * 0.2;
    }
    final onset = physical - _physBase;

    final motion = _feelSmooth; // 0 = still/quiet, 1 = very active scene

    if (_feelDebug && now - _lastDebugMs > 150) {
      _lastDebugMs = now;
      debugPrint('FEEL phys=${physical.toStringAsFixed(2)} '
          'vocal=${vocal.toStringAsFixed(2)} '
          'motion=${motion.toStringAsFixed(2)} '
          'onset=${onset.toStringAsFixed(2)}');
    }

    // ── Accent: a real jolt (hard step, bump, impact) punches through ───
    // A clear spike above the slow floor, when it isn't just voice. Fires
    // immediately and re-phases the gait so the rhythm continues from here.
    if (onset > 0.16 && voiceOver < 0.30 && now - _lastAccentMs > 130) {
      _lastAccentMs = now;
      Haptics.recoil((0.45 + onset).clamp(0.0, 0.9));
      _nextThumpMs = now + 300;
      return;
    }

    // ── Gait engine: thump-thump walking → continuous running ───────────
    // Rather than hoping every faint footstep is audible, synthesise a
    // footfall rhythm whose TEMPO follows how active the scene is:
    //   gentle motion → slow "thump … thump" (a walk)
    //   strong motion → fast, near-continuous "thump-thump-thump" (a run)
    // Speech and quiet stand-still produce no motion → the feet go still.
    if (motion < 0.11) { _nextThumpMs = 0; return; } // standing / talking / quiet

    if (now >= _nextThumpMs) {
      // Cadence: 560 ms (slow walk) → 190 ms (running) as motion rises.
      final interval = (560 - motion * 470).clamp(190.0, 560.0).round();
      _nextThumpMs = now + interval;
      // Each footfall is a soft graded thump — light for a stroll, firm for
      // a run — with a quick settle so it reads as a step, not a buzz.
      final strength = (0.3 + motion * 0.5).clamp(0.0, 0.85);
      Haptics.recoil(strength);
    }
  }
}
