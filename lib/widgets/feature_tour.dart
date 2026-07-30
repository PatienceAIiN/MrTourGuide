import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/haptic_service.dart';

/// First-launch feature tour: a full-screen swipeable carousel of what the
/// app can do, shown ONCE after install (skippable any time).
class FeatureTour extends StatefulWidget {
  const FeatureTour({super.key});

  /// Show the tour once per install.
  static Future<void> maybeShow(BuildContext context) async {
    final p = await SharedPreferences.getInstance();
    if (p.getBool('tour.done') == true) return;
    await p.setBool('tour.done', true);
    if (!context.mounted) return;
    await Navigator.of(context).push(PageRouteBuilder(
      opaque: true,
      pageBuilder: (_, __, ___) => const FeatureTour(),
      transitionsBuilder: (_, a, __, child) =>
          FadeTransition(opacity: a, child: child),
    ));
  }

  @override
  State<FeatureTour> createState() => _FeatureTourState();
}

class _Slide {
  final IconData icon;
  final String title, body;
  final Color color;
  const _Slide(this.icon, this.title, this.body, this.color);
}

const _slides = [
  _Slide(Icons.vibration_rounded, 'Feel every destination',
      'Watch travel experiences and feel them — your phone pulses with '
      'waves, wind and footsteps, tuned to each video.',
      Color(0xFF7B2FF7)),
  _Slide(Icons.view_in_ar_rounded, 'MR / VR mode',
      'Step inside monuments and streets in mixed or virtual reality, or '
      'watch in classic video mode.',
      Color(0xFF9D4EDD)),
  _Slide(Icons.play_circle_fill_rounded, 'GuideVibe shorts',
      'A swipe-up feed of short travel videos — every clip is one you can '
      'feel.',
      Color(0xFFFF4D5E)),
  _Slide(Icons.graphic_eq_rounded, 'Feel any YouTube video',
      'Tap the Feel button in the player and the video\'s sound becomes '
      'live haptics — bass, beats and impacts in your hand.',
      Color(0xFF3CBBEB)),
  _Slide(Icons.auto_awesome_rounded, 'AI trip planner',
      'Ask for a day-by-day trip in plain words — honest, '
      'accessibility-aware answers you can save.',
      Color(0xFFF107A3)),
  _Slide(Icons.terrain_rounded, 'Tour Mode',
      'For every trip: offline survival packs, one-tap SOS by SMS, '
      'shake-to-SOS, and a trip beacon that auto-alerts your contact if '
      'you don\'t check in.',
      Color(0xFF26A69A)),
  _Slide(Icons.forum_rounded, 'A warm community',
      'Share moments, follow creators, react and reply — travelers and '
      'creators together.',
      Color(0xFF5B2BE0)),
];

class _FeatureTourState extends State<FeatureTour> {
  final _page = PageController();
  int _i = 0;

  void _next() {
    Haptics.light();
    if (_i >= _slides.length - 1) {
      Navigator.of(context).pop();
      return;
    }
    _page.nextPage(
        duration: const Duration(milliseconds: 350), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    final s = _slides[_i];
    return Scaffold(
      backgroundColor: const Color(0xFF14101C),
      body: SafeArea(
        child: Column(children: [
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Skip',
                  style: TextStyle(color: Colors.white54)),
            ),
          ),
          Expanded(
            child: PageView.builder(
              controller: _page,
              itemCount: _slides.length,
              onPageChanged: (i) {
                Haptics.tick();
                setState(() => _i = i);
              },
              itemBuilder: (_, i) {
                final sl = _slides[i];
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 36),
                  child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 120, height: 120,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(colors: [
                              sl.color.withValues(alpha: .35),
                              sl.color.withValues(alpha: .08),
                            ]),
                          ),
                          child: Icon(sl.icon, size: 58, color: sl.color),
                        ),
                        const SizedBox(height: 34),
                        Text(sl.title,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 26,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.5)),
                        const SizedBox(height: 14),
                        Text(sl.body,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 15,
                                height: 1.5)),
                      ]),
                );
              },
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < _slides.length; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: i == _i ? 22 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                      color: i == _i ? s.color : Colors.white24,
                      borderRadius: BorderRadius.circular(4)),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(36, 26, 36, 30),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: s.color,
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(999))),
                onPressed: _next,
                child: Text(
                    _i >= _slides.length - 1 ? 'Start exploring' : 'Next',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 16)),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }
}
