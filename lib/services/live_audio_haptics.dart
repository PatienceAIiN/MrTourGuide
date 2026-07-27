import 'dart:async';

import 'package:flutter/services.dart';

import 'haptic_service.dart';
import 'settings_service.dart';

/// Live audio → **physical-feel** haptics for the in-app YouTube player.
///
/// The aim is to feel the SCENE, not the narration: footsteps while walking,
/// the rumble of a vehicle, impacts, and ambience — while staying silent when
/// a person is simply talking.
///
/// The native side streams four frequency-band energies (0..1) ~18×/sec:
///   low    (30–250 Hz)  — vehicle rumble, footfall body, thumps, bass
///   lowMid (250–500 Hz) — footstep slap, physical texture
///   vocal  (300–3400 Hz)— human speech (we suppress this)
///   high   (>3400 Hz)   — sibilance / air / sparkle
///
/// Speech is dominated by the vocal band with little low-end; physical events
/// (steps, wheels, hits) always carry low / low-mid energy. So we drive the
/// feel from the physical bands and gate it down hard when the vocal band
/// dominates.
class LiveAudioHaptics {
  static const _events = EventChannel('mrtouride/audiofeel');

  StreamSubscription? _sub;
  bool _running = false;
  bool get isRunning => _running;

  // Rolling references for transient (footstep / impact) detection.
  double _lowAvg = 0;      // slow average of low-band energy
  double _lowMidAvg = 0;
  int _lastStepMs = 0;
  int _lastLevelMs = 0;
  final Stopwatch _clock = Stopwatch()..start();

  void Function(String message)? onError;

  void start() {
    if (_running) return;
    _running = true;
    _lowAvg = 0;
    _lowMidAvg = 0;
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

    // Physical energy = the parts of the scene you'd feel with your body.
    final physical = low * 1.0 + lowMid * 0.6 + high * 0.12;

    // ── Speech gate ────────────────────────────────────────────────────
    // Talking = vocal band dominant with weak low end. When that's the case,
    // scale the feel right down so narration/conversation doesn't buzz.
    final voiceDominant = vocal > (low + lowMid) * 1.4 && low < 0.22;
    final gate = voiceDominant ? 0.12 : 1.0;

    // Update rolling averages (for onset detection).
    _lowAvg += (low - _lowAvg) * 0.18;
    _lowMidAvg += (lowMid - _lowMidAvg) * 0.18;

    // ── Footstep / impact — a fast rise in the low / low-mid bands ──────
    // A step is a short transient: current well above its running average.
    final lowJump = low - _lowAvg;
    final midJump = lowMid - _lowMidAvg;
    final onset = (lowJump * 1.2 + midJump).clamp(0.0, 1.0);
    if (!voiceDominant &&
        onset > 0.14 &&
        (low > 0.18 || lowMid > 0.22) &&
        now - _lastStepMs > 130) {
      _lastStepMs = now;
      _lastLevelMs = now + 130; // let the punch breathe
      // Footfall / impact → crisp recoil, strength from the transient size.
      Haptics.recoil((0.4 + onset * 0.9).clamp(0.0, 1.0));
      return;
    }

    // ── Sustained rumble / ambience → smooth graded level ───────────────
    if (now < _lastLevelMs) return;
    if (now - _lastLevelMs < 55) return; // ~18 Hz cap
    final feel = (physical * gate).clamp(0.0, 1.0);
    if (feel < 0.08) return; // quiet / pure speech: stay still
    _lastLevelMs = now;
    Haptics.level(feel, durationMs: 75);
  }
}
