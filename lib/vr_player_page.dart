import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import 'services/haptic_service.dart';
import 'services/media_api.dart';

/// Cardboard-style VR mode for 360° captures: fullscreen landscape,
/// side-by-side stereo view — drop the phone into any VR headset.
/// Haptics keep following the video's feel track.
class VrPlayerPage extends StatefulWidget {
  final VideoItem video;
  final VideoPlayerController controller;
  const VrPlayerPage(
      {super.key, required this.video, required this.controller});

  @override
  State<VrPlayerPage> createState() => _VrPlayerPageState();
}

class _VrPlayerPageState extends State<VrPlayerPage> {
  Timer? _hapticTimer;
  bool showHint = true;

  @override
  void initState() {
    super.initState();
    // Immersive landscape — the headset experience.
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    widget.controller.play();
    final track = widget.video.hapticTrack;
    if (track.isNotEmpty) {
      _hapticTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        final v = widget.controller.value;
        if (!v.isPlaying) return;
        final sec = v.position.inSeconds;
        Haptics.level(track[sec.clamp(0, track.length - 1)]);
      });
    }
    Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => showHint = false);
    });
  }

  @override
  void dispose() {
    _hapticTimer?.cancel();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    Widget eye() => ClipRect(
          child: OverflowBox(
            maxWidth: double.infinity,
            child: AspectRatio(
              aspectRatio: c.value.aspectRatio,
              child: VideoPlayer(c),
            ),
          ),
        );
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () {
          Haptics.tick();
          setState(() => c.value.isPlaying ? c.pause() : c.play());
        },
        child: Stack(
          children: [
            Row(
              children: [
                Expanded(child: eye()),
                Container(width: 2, color: Colors.black),
                Expanded(child: eye()),
              ],
            ),
            if (showHint)
              Positioned(
                bottom: 24,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      'Place your phone in a VR headset · tap to pause',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ),
                ),
              ),
            SafeArea(
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white54),
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
