import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import 'constant.dart';
import 'services/haptic_service.dart';
import 'services/media_api.dart';
import 'services/vr_capability.dart';
import 'vr_player_page.dart';
import 'services/settings_service.dart';

/// Immersive experience player.
///
/// Plays a city experience video with:
///  - haptics toggle + intensity (drives phone vibration on device; shown as
///    a synced pulse indicator on web),
///  - sound toggle,
///  - auto-hiding controls (tap to show/hide),
///  - VR mode hand-off.
///
/// Creator config supplies defaults; the viewer's own settings override them
/// (accessibility first) and can be changed live from the overlay.
class ExperiencePlayerPage extends StatefulWidget {
  final VideoItem video;
  const ExperiencePlayerPage({super.key, required this.video});

  @override
  State<ExperiencePlayerPage> createState() => _ExperiencePlayerPageState();
}

class _ExperiencePlayerPageState extends State<ExperiencePlayerPage> {
  VideoPlayerController? controller;
  String? error;
  bool controlsVisible = true;
  Timer? _hideTimer;
  Timer? _hapticTimer;
  int _nextEvent = 0;
  int _recoilUntilMs = 0;

  /// Traveler-tunable feel style: 'adaptive' answers impacts with recoil
  /// pulses on top of the smooth curve; 'smooth' is the curve only.
  String feelStyle = 'adaptive';
  bool _pulse = false;

  late bool haptics;
  late bool sound;
  late double intensity;

  @override
  void initState() {
    super.initState();
    final settings = SettingsService.instance;
    // Viewer settings win over creator defaults.
    haptics = settings.haptics && widget.video.config.haptics;
    sound = settings.sound && widget.video.config.sound;
    intensity = settings.intensity;
    _init();
  }

  Future<void> _init() async {
    try {
      final c =
          VideoPlayerController.networkUrl(Uri.parse(widget.video.absoluteUrl));
      await c.initialize();
      await c.setLooping(true);
      await c.setVolume(sound ? 1 : 0);
      if (SettingsService.instance.autoplay) await c.play();
      if (!mounted) return;
      setState(() => controller = c);
      _startHaptics();
      _scheduleHide();
    } catch (_) {
      if (!mounted) return;
      setState(() => error = 'Could not load this experience video.');
    }
  }

  /// Haptic engine: follows the per-video ML haptic track — background
  /// sound, music and ambient energy analysed server-side become graded
  /// light→heavy feel, scaled by the creator's and the viewer's intensity.
  void _startHaptics() {
    _hapticTimer?.cancel();
    if (!haptics) return;
    final fine = widget.video.hapticFine;
    final track =
        fine.isNotEmpty ? fine : widget.video.hapticTrack; // 250ms or 1s res
    final perSecond = fine.isEmpty;
    final events = widget.video.hapticEvents;
    if (track.isNotEmpty) {
      _nextEvent = 0;
      _recoilUntilMs = 0;
      // Feel engine: a fast tick glides smoothly along the energy curve
      // (interpolated between the 250ms samples) so sustained sound feels
      // continuous, not a stutter; when the ML marked an impact (gunshot,
      // slam, drum hit) it answers with a recoil — hard hit then a soft
      // settle, like a console controller. Pulses are cut a touch longer
      // than the tick so consecutive ones overlap into one vibration.
      const tickMs = 90;
      _hapticTimer =
          Timer.periodic(const Duration(milliseconds: tickMs), (_) {
        final c = controller;
        if (c == null || !c.value.isPlaying) return;
        final ms = c.value.position.inMilliseconds;
        if (feelStyle == 'adaptive' && events.isNotEmpty) {
          while (_nextEvent < events.length &&
              (events[_nextEvent]['t'] as num) < ms - 400) {
            _nextEvent++; // skip events we seeked past
          }
          if (_nextEvent < events.length) {
            final e = events[_nextEvent];
            final t = (e['t'] as num).toInt();
            if ((ms - t).abs() <= 130) {
              _nextEvent++;
              // Raw power — the global feel-intensity is applied inside
              // Haptics.recoil so one knob scales everything.
              final punch = (e['power'] as num).clamp(0.0, 1.0);
              Haptics.recoil(punch.toDouble());
              // Let the recoil breathe — don't stomp it with level pulses.
              _recoilUntilMs = ms + 230;
              if (mounted) {
                setState(() => _pulse = true);
                Timer(const Duration(milliseconds: 220), () {
                  if (mounted) setState(() => _pulse = false);
                });
              }
              return; // the recoil owns this tick
            }
          }
        }
        if (ms < _recoilUntilMs) return; // still settling from a recoil
        final step = perSecond ? 1000 : 250;
        final idx = ms ~/ step;
        final frac = (ms % step) / step;
        final a = track[idx.clamp(0, track.length - 1)];
        final b = track[(idx + 1).clamp(0, track.length - 1)];
        final energy = a + (b - a) * frac;
        // Raw energy — Haptics.level applies the global feel-intensity.
        final feel = energy.clamp(0.0, 1.0);
        if (feel < 0.04) return; // near-silence: no feel
        // Duration a hair over the tick → overlapping, continuous feel.
        Haptics.level(feel, durationMs: tickMs + 40);
        if (mounted && !_pulse) {
          setState(() => _pulse = true);
          Timer(const Duration(milliseconds: 140), () {
            if (mounted) setState(() => _pulse = false);
          });
        }
      });
      return;
    }
    // No track yet (older uploads): steady cadence scaled by intensity.
    final period = Duration(
        milliseconds: (1400 - 900 * intensity).round().clamp(300, 2000));
    _hapticTimer = Timer.periodic(period, (_) {
      if (!(controller?.value.isPlaying ?? false)) return;
      HapticFeedback.mediumImpact(); // no-op on web, vibrates on device
      if (mounted) {
        setState(() => _pulse = true);
        Timer(const Duration(milliseconds: 180), () {
          if (mounted) setState(() => _pulse = false);
        });
      }
    });
  }

  /// This capture was published as VR/MR — the button opens the real
  /// headset view instead of the coming-soon note.
  bool get _isImmersive =>
      widget.video.config.kind == 'vr' || widget.video.config.kind == 'mr';

  Future<void> _enterVr() async {
    final c = controller;
    if (c == null || !c.value.isInitialized) return;
    final cap = await VrCapability.check();
    if (!mounted) return;
    if (!cap.eligible) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          icon: const Icon(Icons.vrpano, color: red, size: 36),
          title: const Text('Your device is ineligible for VR/MR'),
          content: Text(
            '${cap.reason}\n\nSupported: Android 7.0+ phones with a '
            'gyroscope, used with Google Cardboard or any phone-holder VR '
            'headset. Standalone headsets (Meta Quest, Pico) can open '
            'experiences via their built-in browser.',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13.5, height: 1.5),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Got it'),
            ),
          ],
        ),
      );
      return;
    }
    final mode = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: cardBg(context),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 18, 20, 6),
              child: Text('Choose your VR device',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text('Detected: ${cap.model} — VR ready ✓',
                  style: const TextStyle(fontSize: 12, color: Colors.green)),
            ),
            ListTile(
              leading: const Icon(Icons.smartphone, color: Colors.purple),
              title: const Text('Phone in headset (Cardboard & similar)'),
              subtitle: const Text(
                  'Split-screen stereo — works with any phone-holder headset'),
              onTap: () => Navigator.pop(context, 'cardboard'),
            ),
            ListTile(
              leading: const Icon(Icons.view_in_ar, color: blue),
              title: const Text('Meta Quest / standalone headset'),
              subtitle:
                  const Text('Open this experience in the headset browser'),
              onTap: () => Navigator.pop(context, 'quest'),
            ),
            const ListTile(
              enabled: false,
              leading: Icon(Icons.visibility, color: Colors.grey),
              title: Text('Smart glasses (AR)'),
              subtitle: Text('Coming soon'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || mode == null) return;
    if (mode == 'quest') {
      newSnackBar(context,
          title: 'Open this experience in your headset browser: '
              '${widget.video.absoluteUrl}');
      return;
    }
    Haptics.string();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => VrPlayerPage(video: widget.video, controller: c),
      ),
    );
  }

  Future<void> _vrNotAvailable() async {
    MediaApi.sendFeedback(
      message: 'VR version requested for "${widget.video.title}" '
          '(${widget.video.city})',
    ).catchError((_) => '');
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        icon: const Icon(Icons.view_in_ar, color: Colors.purple, size: 36),
        title: const Text('VR coming soon'),
        content: const Text(
          'This experience has no VR capture yet. We\'ve let the creator '
          'know you want one.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, height: 1.5),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && (controller?.value.isPlaying ?? false)) {
        setState(() => controlsVisible = false);
      }
    });
  }

  void _toggleControls() {
    setState(() => controlsVisible = !controlsVisible);
    if (controlsVisible) _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _hapticTimer?.cancel();
    controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggleControls,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Video / status
            if (error != null)
              Center(
                  child: Text(error!,
                      style: const TextStyle(color: Colors.white70)))
            else if (c == null)
              const Center(child: CircularProgressIndicator(color: lightBlue))
            else
              Center(
                child: AspectRatio(
                  aspectRatio:
                      c.value.aspectRatio == 0 ? 16 / 9 : c.value.aspectRatio,
                  child: VideoPlayer(c),
                ),
              ),
            // Haptic pulse indicator (the "feel" layer)
            if (haptics)
              Positioned(
                right: 20,
                top: 90,
                child: AnimatedScale(
                  scale: _pulse ? 1.5 : 1.0,
                  duration: const Duration(milliseconds: 160),
                  child: AnimatedOpacity(
                    opacity: _pulse ? 1 : 0.35,
                    duration: const Duration(milliseconds: 160),
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.purple.withValues(alpha: 0.6),
                      ),
                      child: const Icon(Icons.vibration,
                          color: Colors.white, size: 22),
                    ),
                  ),
                ),
              ),
            // Overlay controls
            AnimatedOpacity(
              opacity: controlsVisible ? 1 : 0,
              duration: const Duration(milliseconds: 250),
              child: IgnorePointer(
                ignoring: !controlsVisible,
                child: _overlay(c),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _overlay(VideoPlayerController? c) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0.65),
            Colors.transparent,
            Colors.transparent,
            Colors.black.withValues(alpha: 0.75),
          ],
          stops: const [0, 0.25, 0.65, 1],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            // Top bar
            Row(
              children: [
                IconButton(
                  icon:
                      const Icon(Icons.arrow_back_ios_new, color: Colors.white),
                  onPressed: () => Navigator.pop(context),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.video.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.w600)),
                      Text(
                        widget.video.city[0].toUpperCase() +
                            widget.video.city.substring(1),
                        style: const TextStyle(
                            color: Colors.white60, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                // VR mode hand-off — icon only.
                IconButton(
                  tooltip: 'VR mode',
                  onPressed: _isImmersive ? _enterVr : _vrNotAvailable,
                  icon:
                      const Icon(Icons.view_in_ar, color: lightBlue, size: 26),
                ),
              ],
            ),
            const Spacer(),
            // Center transport: back 10 · play/pause · forward 10.
            if (c != null)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    iconSize: 40,
                    color: Colors.white,
                    tooltip: 'Back 10 seconds',
                    icon: const Icon(Icons.replay_10),
                    onPressed: () {
                      Haptics.tick();
                      c.seekTo(c.value.position - const Duration(seconds: 10));
                      _scheduleHide();
                    },
                  ),
                  const SizedBox(width: 18),
                  IconButton(
                    iconSize: 72,
                    color: Colors.white,
                    icon: Icon(c.value.isPlaying
                        ? Icons.pause_circle_filled
                        : Icons.play_circle_filled),
                    onPressed: () {
                      setState(() {
                        c.value.isPlaying ? c.pause() : c.play();
                      });
                      _scheduleHide();
                    },
                  ),
                  const SizedBox(width: 18),
                  IconButton(
                    iconSize: 40,
                    color: Colors.white,
                    tooltip: 'Forward 10 seconds',
                    icon: const Icon(Icons.forward_10),
                    onPressed: () {
                      Haptics.tick();
                      c.seekTo(c.value.position + const Duration(seconds: 10));
                      _scheduleHide();
                    },
                  ),
                ],
              ),
            const Spacer(),
            // Bottom controls
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (c != null)
                    VideoProgressIndicator(
                      c,
                      allowScrubbing: true,
                      colors: const VideoProgressColors(
                        playedColor: lightBlue,
                        bufferedColor: Colors.white24,
                        backgroundColor: Colors.white12,
                      ),
                    ),
                  const SizedBox(height: 6),
                  // Icon-only controls, evenly arranged — words removed and
                  // the old "Hide" button dropped (tapping the video hides
                  // the overlay). Left→right: feel, mute, feel-style, then
                  // the intensity slider fills the rest.
                  Row(
                    children: [
                      _iconToggle(
                        icon: Icons.vibration,
                        tooltip: haptics ? 'Feel off' : 'Feel on',
                        active: haptics,
                        onTap: () {
                          setState(() => haptics = !haptics);
                          _startHaptics();
                        },
                      ),
                      const SizedBox(width: 10),
                      _iconToggle(
                        icon: sound ? Icons.volume_up : Icons.volume_off,
                        tooltip: sound ? 'Mute' : 'Unmute',
                        active: sound,
                        onTap: () {
                          setState(() => sound = !sound);
                          c?.setVolume(sound ? 1 : 0);
                        },
                      ),
                      if (haptics && widget.video.hapticEvents.isNotEmpty) ...[
                        const SizedBox(width: 10),
                        // One tap flips adaptive (impact pulses) ⇄ smooth.
                        _iconToggle(
                          icon: feelStyle == 'adaptive'
                              ? Icons.auto_awesome
                              : Icons.waves,
                          tooltip: feelStyle == 'adaptive'
                              ? 'Adaptive feel'
                              : 'Smooth feel',
                          active: true,
                          activeColor: Colors.purpleAccent,
                          onTap: () {
                            Haptics.tick();
                            setState(() => feelStyle =
                                feelStyle == 'adaptive' ? 'smooth' : 'adaptive');
                            _startHaptics();
                          },
                        ),
                      ],
                      const SizedBox(width: 6),
                      if (haptics)
                        Expanded(
                          child: Slider(
                            value: intensity,
                            divisions: 10,
                            label: '${(intensity * 100).round()}%',
                            activeColor: Colors.purpleAccent,
                            inactiveColor: Colors.white24,
                            onChanged: (v) {
                              final changed = (v * 10).round() !=
                                  (intensity * 10).round();
                              // Same global knob as Settings → Feel intensity.
                              setState(() => intensity = max(0.05, v));
                              SettingsService.instance.intensity = intensity;
                              SettingsService.instance.save();
                              if (changed) {
                                Haptics.level(1.0); // feel the new level
                              }
                              _startHaptics();
                            },
                          ),
                        )
                      else
                        const Spacer(),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Compact circular icon control — active state fills the circle so the
  /// on/off reading is instant without any words.
  Widget _iconToggle({
    required IconData icon,
    required String tooltip,
    required bool active,
    required VoidCallback onTap,
    Color activeColor = lightBlue,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: active
                ? activeColor.withValues(alpha: 0.28)
                : Colors.white.withValues(alpha: 0.08),
            shape: BoxShape.circle,
            border: Border.all(
                color: active ? activeColor : Colors.white24, width: 1),
          ),
          child: Icon(icon,
              size: 19, color: active ? activeColor : Colors.white54),
        ),
      ),
    );
  }
}
