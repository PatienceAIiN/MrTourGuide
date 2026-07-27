import 'dart:async';

import 'package:flutter/services.dart';

import 'haptic_service.dart';
import 'settings_service.dart';

/// Live audio→haptics for in-app audio the app can't pre-analyse — chiefly
/// the YouTube video playing inside our WebView player.
///
/// The native side attaches an Android [Visualizer] to the global audio mix
/// (session 0) and streams {bass, energy} ~20×/sec. We turn that into the
/// same graded feel the experience player uses: a smooth energy level plus a
/// recoil "punch" on sudden bass transients (kicks, hits, drops).
class LiveAudioHaptics {
  static const _events = EventChannel('mrtouride/audiofeel');

  StreamSubscription? _sub;
  bool _running = false;
  bool get isRunning => _running;

  // Transient detection: a fast rise in bass over its running average = a hit.
  double _bassAvg = 0;
  int _lastRecoilMs = 0;
  int _lastLevelMs = 0;
  final Stopwatch _clock = Stopwatch()..start();

  /// Called when the native stream reports it couldn't start (permission
  /// denied / device without a visualizer). Lets the UI show a hint.
  void Function(String message)? onError;

  void start() {
    if (_running) return;
    _running = true;
    _bassAvg = 0;
    _sub = _events.receiveBroadcastStream().listen(
      _onFrame,
      onError: (e) {
        _running = false;
        onError?.call(e is PlatformException
            ? (e.message ?? 'Feel unavailable on this device.')
            : 'Feel unavailable on this device.');
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
    final bass = (data['bass'] as num?)?.toDouble() ?? 0;
    final energy = (data['energy'] as num?)?.toDouble() ?? 0;
    final now = _clock.elapsedMilliseconds;

    // Running bass average (slow) to detect sudden jumps against.
    _bassAvg += (bass - _bassAvg) * 0.15;

    // ── Transient / hit → recoil punch (rate-limited so it doesn't buzz) ──
    final jump = bass - _bassAvg;
    if (bass > 0.42 && jump > 0.16 && now - _lastRecoilMs > 140) {
      _lastRecoilMs = now;
      _lastLevelMs = now + 160; // let the recoil breathe
      Haptics.recoil((0.45 + jump).clamp(0.0, 1.0));
      return;
    }

    // ── Sustained energy → smooth graded level ──
    if (now < _lastLevelMs) return;
    if (energy < 0.06) return; // near-silence: stay quiet
    if (now - _lastLevelMs < 55) return; // ~18 Hz cap
    _lastLevelMs = now;
    Haptics.level(energy.clamp(0.0, 1.0), durationMs: 75);
  }
}
