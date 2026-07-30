import 'dart:async';

import 'package:flutter/services.dart';

import 'haptic_service.dart';
import 'settings_service.dart';

/// Live "Feel the energy" haptics for the in-app YouTube player.
///
/// Honest and reliable: the phone becomes a subwoofer in your hand — it
/// rumbles with the video's bass and energy and punches on beats and big
/// impacts. Strong for action and music, gentle for calm scenes, and silent
/// on speech and quiet moments. (We don't claim literal footstep detection —
/// a video's audio can't reliably separate walking from music/wind/traffic.)
///
/// Native streams four band energies (0..1) ~18×/sec:
///   low    (30–250 Hz)  — bass, kicks, rumble, impacts
///   lowMid (250–500 Hz) — body, texture
///   vocal  (300–3400 Hz)— human speech (subtracted out)
///   high   (>3400 Hz)   — air / sparkle (light touch)
class LiveAudioHaptics {
  static const _events = EventChannel('mrtouride/audiofeel');

  StreamSubscription? _sub;
  bool _running = false;
  bool get isRunning => _running;

  double _energy = 0;   // smoothed physical energy (the rumble level)
  double _base = 0;     // slow floor, for beat/impact detection
  int _lastBeatMs = 0;
  int _lastRumbleMs = 0;
  int _speechHoldMs = 0; // speech hangover — no haptics until this passes
  final Stopwatch _clock = Stopwatch()..start();

  void Function(String message)? onError;

  void start() {
    if (_running) return;
    _running = true;
    _energy = _base = 0;
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

    // ── Speech gate (talk = still, motion = felt) ────────────────────────
    // Talking must produce NO haptics, but walking/riding ambience MUST
    // keep working. The separator is the >3400 Hz air band: a talking head
    // is mid-heavy with weak highs, while movement scenes (wind, steps on
    // gravel, traffic, foliage) always carry broadband high energy. So a
    // frame is SPEECH only when the vocal band is prominent AND clearly
    // beats both the deep end and the air band. A 300 ms hangover keeps
    // syllable gaps from flickering the rumble back mid-sentence.
    final speechNow =
        vocal > 0.22 && vocal > low * 1.4 && vocal > high * 2.2;
    if (speechNow) _speechHoldMs = now + 300;
    final inSpeech = now < _speechHoldMs;

    // Energy you'd feel physically — bass-weighted; the air band counts
    // (wind/movement feel) and the voice band is subtracted.
    final physical = low * 1.0 + lowMid * 0.5 + high * 0.2;
    final voiceOver = (vocal - physical * 0.6).clamp(0.0, 1.0);
    final feel = inSpeech ? 0.0 : (physical - voiceOver).clamp(0.0, 1.0);

    _energy += (feel - _energy) * 0.4; // smooth the rumble

    // Slow floor for beat detection (bass kicks spike above it).
    if (low > _base) {
      _base += (low - _base) * 0.06;
    } else {
      _base += (low - _base) * 0.25;
    }
    final kick = low - _base;

    // ── Beat / impact: a bass spike → a punchy recoil (the "hit") ───────
    // During speech only a MASSIVE bass hit passes (an explosion behind a
    // narrator) — plosives and voice thumps never reach these numbers.
    final beatGate = inSpeech ? 0.30 : 0.13;
    if (kick > beatGate &&
        low > vocal * (inSpeech ? 2.2 : 1.1) &&
        now - _lastBeatMs > 120) {
      _lastBeatMs = now;
      _lastRumbleMs = now + 90; // let the hit breathe
      Haptics.recoil((0.4 + kick * 1.3).clamp(0.0, 0.95));
      return;
    }

    // ── Rumble: graded subwoofer level following the energy ─────────────
    // Low gate so walking/motion ambience is felt; speech and true quiet
    // stay silent through the gate above.
    if (now < _lastRumbleMs) return;
    if (now - _lastRumbleMs < 60) return; // ~16 Hz
    if (_energy < 0.12) return;            // quiet / speech → still
    _lastRumbleMs = now;
    Haptics.level((_energy * 0.65).clamp(0.0, 0.7), durationMs: 70);
  }
}
