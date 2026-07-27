import 'dart:async';

import 'package:flutter/services.dart';

import 'haptic_service.dart';
import 'settings_service.dart';

/// First-person "feel" for the in-app YouTube player.
///
/// The goal is to feel the video the way the person *holding the camera*
/// would feel it in their body — a footstep lands as a distinct thump, a
/// pothole or bump is a jolt, a moving vehicle carries rhythmic road texture —
/// with **stillness in between**. It deliberately does NOT emit a continuous
/// buzz (that reads as meaningless noise) and stays silent for human speech.
///
/// Native streams four frequency-band energies (0..1) ~18×/sec:
///   low    (30–250 Hz)  — footfall body, vehicle/engine rumble, impacts
///   lowMid (250–500 Hz) — the "slap" of a step, physical texture
///   vocal  (300–3400 Hz)— human speech (ignored)
///   high   (>3400 Hz)   — air / sparkle (ignored for body-feel)
///
/// We detect physical EVENTS (onsets) in the low bands and answer each with a
/// single graded recoil — the jolt your body feels. Sustained low rumble
/// (riding a vehicle) becomes paced road-texture taps, not a drone.
class LiveAudioHaptics {
  static const _events = EventChannel('mrtouride/audiofeel');

  StreamSubscription? _sub;
  bool _running = false;
  bool get isRunning => _running;

  // Rolling baselines so we react to CHANGES (events), not steady loudness.
  double _lowAvg = 0;
  double _lowMidAvg = 0;
  double _lowSustain = 0; // slower average → "am I on a moving vehicle?"
  int _lastJoltMs = 0;
  int _lastTextureMs = 0;
  final Stopwatch _clock = Stopwatch()..start();

  void Function(String message)? onError;

  void start() {
    if (_running) return;
    _running = true;
    _lowAvg = _lowMidAvg = _lowSustain = 0;
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
    final now = _clock.elapsedMilliseconds;

    // Baselines: fast (for onsets) and slow (for sustained motion).
    _lowAvg += (low - _lowAvg) * 0.20;
    _lowMidAvg += (lowMid - _lowMidAvg) * 0.20;
    _lowSustain += (low - _lowSustain) * 0.04;

    // ── Speech rejection (hard) ─────────────────────────────────────────
    // Speech always carries strong 300–3400 Hz vocal energy. Plosives
    // ("p","b") also leak a little low-frequency thump that can mimic a
    // footstep — so we don't just check dominance, we suppress ANY frame
    // with meaningful vocal energy. The ONLY exception is a genuine impact
    // whose low-end massively outweighs the voice (a real bump cutting
    // through someone talking). This keeps narration/conversation dead
    // silent — no disturbance.
    final speechPresent = vocal > 0.18;
    final realImpact = low > vocal * 1.9 && low > 0.30;
    if (speechPresent && !realImpact) return;

    // ── Physical EVENT: footstep, bump, impact ──────────────────────────
    // A step/jolt is a sudden rise over the running baseline in the body
    // bands — not steady volume. One crisp recoil per event, then a short
    // refractory silence so distinct steps stay distinct (not a blur).
    final lowJump = low - _lowAvg;
    final midJump = lowMid - _lowMidAvg;
    final onset = (lowJump * 1.25 + midJump * 0.9);
    final strongEnough = low > 0.20 || lowMid > 0.24;
    if (onset > 0.13 && strongEnough && now - _lastJoltMs > 120) {
      _lastJoltMs = now;
      _lastTextureMs = now + 120; // don't stack texture on top of a jolt
      // Body jolt: bigger onset = harder landing. 0.45 floor so every real
      // step is clearly felt; scales up to a full slam for impacts.
      final punch = (0.45 + onset * 1.1).clamp(0.0, 1.0);
      Haptics.recoil(punch);
      return;
    }

    // ── Riding a vehicle: sustained low rumble → paced road texture ─────
    // When there's steady strong low-end (engine/road) but no fresh jolt,
    // emit gentle spaced pulses so it feels like continuous motion through
    // the body — still discrete taps, never a formless drone.
    if (_lowSustain > 0.34 && now - _lastTextureMs > 190) {
      _lastTextureMs = now;
      final texture = (_lowSustain * 0.5).clamp(0.12, 0.45);
      Haptics.level(texture, durationMs: 55);
    }
    // Otherwise: stillness. Quiet scenes and speech produce no vibration.
  }
}
