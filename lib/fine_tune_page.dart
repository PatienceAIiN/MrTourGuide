import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'constant.dart';
import 'services/auth_api.dart';
import 'services/haptic_service.dart';
import 'services/media_api.dart';
import 'widgets/ux.dart';

/// Per-frame feel studio: the creator watches the video and sculpts the
/// haptic track second by second — drag a bar up for heavier feel, down
/// for lighter. Opens in its own window from the Creator Studio.
class FineTunePage extends StatefulWidget {
  final VideoItem video;
  const FineTunePage({super.key, required this.video});

  @override
  State<FineTunePage> createState() => _FineTunePageState();
}

class _FineTunePageState extends State<FineTunePage> {
  VideoPlayerController? controller;
  late List<double> track;
  final trackScroll = ScrollController();
  Timer? _ticker;
  int playingSecond = -1;
  bool saving = false;
  bool dirty = false;

  static const double _barWidth = 26;

  @override
  void initState() {
    super.initState();
    // Start from the ML track; an empty one gets a neutral baseline the
    // creator can sculpt.
    track = widget.video.hapticTrack.isNotEmpty
        ? List.of(widget.video.hapticTrack)
        : List.filled(60, 0.5);
    final c =
        VideoPlayerController.networkUrl(Uri.parse(widget.video.absoluteUrl));
    controller = c;
    c.initialize().then((_) {
      if (!mounted) return;
      // Match the track length to the real duration once known.
      final secs = c.value.duration.inSeconds;
      if (secs > 0 && secs != track.length && secs <= 900) {
        setState(() {
          if (track.length < secs) {
            track = [
              ...track,
              ...List.filled(
                  secs - track.length, track.isEmpty ? 0.5 : track.last)
            ];
          } else {
            track = track.sublist(0, secs);
          }
        });
      }
      setState(() {});
    }).catchError((_) {});
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final v = controller?.value;
      if (v == null || !v.isPlaying) return;
      final sec = v.position.inSeconds;
      if (sec != playingSecond && mounted) {
        setState(() => playingSecond = sec);
        // Feel what viewers will feel while previewing.
        if (sec < track.length) Haptics.level(track[sec]);
        // Keep the playing bar in view.
        if (trackScroll.hasClients) {
          final target = (sec * (_barWidth + 4)) - 120.0;
          trackScroll.animateTo(
            target.clamp(0.0, trackScroll.position.maxScrollExtent),
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    controller?.dispose();
    trackScroll.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (saving) return;
    setState(() => saving = true);
    try {
      await showBusyWhile(
          context, MediaApi.updateHaptics(widget.video.id, track),
          label: 'Saving…');
      Haptics.string();
      if (!mounted) return;
      setState(() {
        saving = false;
        dirty = false;
      });
      newSnackBar(context, title: 'Feel track saved — live for viewers.');
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() => saving = false);
      newSnackBar(context, title: e.message);
    }
  }

  void _setBar(int i, double localY, double height) {
    final v = (1 - (localY / height)).clamp(0.0, 1.0);
    setState(() {
      track[i] = double.parse(v.toStringAsFixed(2));
      dirty = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final ready = c != null && c.value.isInitialized;
    return Scaffold(
      backgroundColor: pageBg(context),
      appBar: AppBar(
        backgroundColor: cardBg(context),
        elevation: 0,
        iconTheme: IconThemeData(color: ink(context)),
        title: Text('Fine-tune feel — ${widget.video.title}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: ink(context), fontSize: 15)),
        actions: [
          if (dirty)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: saving
                  ? const Center(
                      child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.purple)))
                  : TextButton.icon(
                      onPressed: _save,
                      icon: const Icon(Icons.save, size: 17),
                      label: const Text('Save'),
                    ),
            ),
        ],
      ),
      body: Column(
        children: [
          // Preview player
          AspectRatio(
            aspectRatio: ready ? c.value.aspectRatio : 16 / 9,
            child: ready
                ? GestureDetector(
                    onTap: () {
                      Haptics.tick();
                      setState(() => c.value.isPlaying ? c.pause() : c.play());
                    },
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        VideoPlayer(c),
                        if (!c.value.isPlaying)
                          Container(
                            decoration: const BoxDecoration(
                                color: Colors.black38, shape: BoxShape.circle),
                            padding: const EdgeInsets.all(10),
                            child: const Icon(Icons.play_arrow,
                                color: Colors.white, size: 42),
                          ),
                      ],
                    ),
                  )
                : Container(
                    color: Colors.black,
                    child: const Center(
                        child:
                            CircularProgressIndicator(color: Colors.white54)),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Row(
              children: [
                const Icon(Icons.waves, size: 16, color: Colors.purple),
                const SizedBox(width: 6),
                Text('Feel timeline — drag bars, second by second',
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                        color: ink(context))),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Up = heavier feel · down = lighter · play to preview the '
                'vibration live',
                style: TextStyle(fontSize: 11.5, color: Colors.grey),
              ),
            ),
          ),
          const SizedBox(height: 8),
          // The sculptable track
          Expanded(
            child: Container(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              padding: const EdgeInsets.fromLTRB(10, 12, 10, 8),
              decoration: BoxDecoration(
                color: cardBg(context),
                borderRadius: BorderRadius.circular(16),
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final h = constraints.maxHeight - 22;
                  return ListView.separated(
                    controller: trackScroll,
                    scrollDirection: Axis.horizontal,
                    itemCount: track.length,
                    separatorBuilder: (c2, i) => const SizedBox(width: 4),
                    itemBuilder: (context, i) => GestureDetector(
                      onVerticalDragUpdate: (d) =>
                          _setBar(i, d.localPosition.dy, h),
                      onTapDown: (d) => _setBar(i, d.localPosition.dy, h),
                      child: SizedBox(
                        width: _barWidth,
                        child: Column(
                          children: [
                            Expanded(
                              child: Align(
                                alignment: Alignment.bottomCenter,
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 80),
                                  width: _barWidth,
                                  height: (h * track[i]).clamp(3.0, h),
                                  decoration: BoxDecoration(
                                    borderRadius: const BorderRadius.vertical(
                                        top: Radius.circular(5)),
                                    gradient: LinearGradient(
                                      begin: Alignment.bottomCenter,
                                      end: Alignment.topCenter,
                                      colors: i == playingSecond
                                          ? [Colors.purple, Colors.purpleAccent]
                                          : [
                                              Colors.purple
                                                  .withValues(alpha: 0.45),
                                              blue.withValues(alpha: 0.55),
                                            ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${i}s',
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: i == playingSecond
                                    ? FontWeight.w800
                                    : FontWeight.w400,
                                color: i == playingSecond
                                    ? Colors.purple
                                    : Colors.grey,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
