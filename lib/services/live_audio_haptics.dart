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

    // Energy you'd feel physically — bass-weighted, plus a little body/air,
    // with the voice band subtracted so talking doesn't drive the rumble.
    final physical = low * 1.0 + lowMid * 0.55 + high * 0.12;
    final voiceOver = (vocal - physical * 0.8).clamp(0.0, 1.0);
    final feel = (physical - voiceOver * 0.9).clamp(0.0, 1.0);

    _energy += (feel - _energy) * 0.4; // smooth the rumble

    // Slow floor for beat detection (bass kicks spike above it).
    if (low > _base) {
      _base += (low - _base) * 0.06;
    } else {
      _base += (low - _base) * 0.25;
    }
    final kick = low - _base;

    // ── Beat / impact: a bass spike → a punchy recoil (the "hit") ───────
    if (kick > 0.14 && voiceOver < 0.35 && now - _lastBeatMs > 120) {
      _lastBeatMs = now;
      _lastRumbleMs = now + 90; // let the hit breathe
      Haptics.recoil((0.4 + kick * 1.3).clamp(0.0, 0.95));
      return;
    }

    // ── Rumble: graded subwoofer level following the energy ─────────────
    // Gate at 0.16 so calm/ambient/speech stays silent — only genuinely
    // energetic audio (music, action, crowds) produces the rumble.
    if (now < _lastRumbleMs) return;
    if (now - _lastRumbleMs < 60) return; // ~16 Hz
    if (_energy < 0.16) return;            // quiet / speech → still
    _lastRumbleMs = now;
    Haptics.level((_energy * 0.6).clamp(0.0, 0.7), durationMs: 70);
  }
}
