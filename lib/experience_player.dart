import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import 'ar_view.dart';
import 'constant.dart';
import 'services/media_api.dart';
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

  /// Haptic engine: on phones this vibrates in sync with the (ML-generated)
  /// haptic track; on web it renders as the pulsing feel indicator.
  void _startHaptics() {
    _hapticTimer?.cancel();
    if (!haptics) return;
    // Pulse cadence scales with intensity (placeholder for the real
    // per-video ML haptic track).
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
                // VR mode hand-off
                TextButton.icon(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) =>
                            ArViewPage(title: '${widget.video.title} — VR'),
                      ),
                    );
                  },
                  icon: const Icon(Icons.view_in_ar, color: lightBlue),
                  label:
                      const Text('VR mode', style: TextStyle(color: lightBlue)),
                ),
              ],
            ),
            const Spacer(),
            // Center play/pause
            if (c != null)
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
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      _toggle(
                        icon: Icons.vibration,
                        label: 'Feel',
                        active: haptics,
                        onChanged: (v) {
                          setState(() => haptics = v);
                          _startHaptics();
                        },
                      ),
                      const SizedBox(width: 8),
                      _toggle(
                        icon: sound ? Icons.volume_up : Icons.volume_off,
                        label: 'Sound',
                        active: sound,
                        onChanged: (v) {
                          setState(() => sound = v);
                          c?.setVolume(v ? 1 : 0);
                        },
                      ),
                      const SizedBox(width: 12),
                      // Feel intensity
                      if (haptics)
                        Expanded(
                          child: Row(
                            children: [
                              const Icon(Icons.waves,
                                  color: Colors.white54, size: 18),
                              Expanded(
                                child: Slider(
                                  value: intensity,
                                  activeColor: Colors.purpleAccent,
                                  inactiveColor: Colors.white24,
                                  onChanged: (v) {
                                    setState(() => intensity = max(0.05, v));
                                    _startHaptics();
                                  },
                                ),
                              ),
                            ],
                          ),
                        )
                      else
                        const Spacer(),
                      TextButton(
                        onPressed: () =>
                            setState(() => controlsVisible = false),
                        child: const Text('Hide',
                            style: TextStyle(color: Colors.white54)),
                      ),
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

  Widget _toggle({
    required IconData icon,
    required String label,
    required bool active,
    required ValueChanged<bool> onChanged,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => onChanged(!active),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active
              ? lightBlue.withValues(alpha: 0.25)
              : Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(20),
          border:
              Border.all(color: active ? lightBlue : Colors.white24, width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: active ? lightBlue : Colors.white54),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    fontSize: 13, color: active ? lightBlue : Colors.white54)),
          ],
        ),
      ),
    );
  }
}
