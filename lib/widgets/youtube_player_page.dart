import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../services/live_audio_haptics.dart';

/// Fullscreen landscape player for recommended YouTube videos.
///
/// Loads the EMBED page for one video id — so only that video plays (no
/// YouTube feed to wander into) — auto-plays, and forces landscape while
/// open. Orientation + system UI are restored on exit.
class YoutubePlayerPage extends StatefulWidget {
  final String title;
  final String url;
  const YoutubePlayerPage({super.key, required this.title, required this.url});

  /// Pulls the video id out of any common YouTube URL shape; null when the
  /// link isn't a YouTube video (callers then fall back to a browser).
  static String? videoIdOf(String url) {
    final u = Uri.tryParse(url);
    if (u == null) return null;
    final host = u.host.toLowerCase();
    if (!host.contains('youtube.com') && !host.contains('youtu.be')) {
      return null;
    }
    String? id;
    if (host.contains('youtu.be')) {
      id = u.pathSegments.isNotEmpty ? u.pathSegments.first : null;
    } else if (u.queryParameters['v'] != null) {
      id = u.queryParameters['v'];
    } else {
      final segs = u.pathSegments;
      final i = segs.indexWhere((s) => s == 'shorts' || s == 'embed' || s == 'v');
      if (i >= 0 && i + 1 < segs.length) id = segs[i + 1];
    }
    if (id == null || !RegExp(r'^[A-Za-z0-9_-]{6,}$').hasMatch(id)) return null;
    return id;
  }

  @override
  State<YoutubePlayerPage> createState() => _YoutubePlayerPageState();
}

class _YoutubePlayerPageState extends State<YoutubePlayerPage> {
  late final WebViewController _web;
  bool _ready = false;

  // Live audio→haptics: feel the YouTube sound as vibration.
  final _feel = LiveAudioHaptics();
  bool _feelOn = false;
  bool _feelBusy = false;

  @override
  void initState() {
    super.initState();
    // Landscape + immersive while the video plays.
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    final id = YoutubePlayerPage.videoIdOf(widget.url) ?? '';
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          if (mounted) setState(() => _ready = true);
        },
        // Keep the session on THIS video: block taps that would navigate
        // out to the YouTube site/app feed.
        onNavigationRequest: (request) {
          final ok = request.url.contains('/embed/') ||
              request.url.contains('about:blank') ||
              request.url.contains('mrtourguide.patienceai.in');
          return ok ? NavigationDecision.navigate : NavigationDecision.prevent;
        },
      ))
      // Loaded as an HTML page from OUR origin so the iframe request carries
      // a Referer — YouTube rejects referer-less embeds with error 153.
      ..loadHtmlString('''
<!DOCTYPE html><html><head>
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
<style>html,body{margin:0;padding:0;background:#000;height:100%;overflow:hidden}
iframe{position:absolute;inset:0;width:100%;height:100%;border:0}</style>
</head><body>
<iframe src="https://www.youtube.com/embed/$id?autoplay=1&playsinline=1&rel=0&modestbranding=1&iv_load_policy=3"
 allow="autoplay; encrypted-media; fullscreen" allowfullscreen></iframe>
</body></html>
''', baseUrl: 'https://mrtourguide.patienceai.in');
    // Autoplay needs the no-gesture flag on Android.
    final platform = _web.platform;
    if (platform is AndroidWebViewController) {
      platform.setMediaPlaybackRequiresUserGesture(false);
    }
  }

  @override
  void dispose() {
    _feel.stop();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  /// Toggle live feel. First time on, explain why the mic permission is
  /// needed (Android gates the audio Visualizer behind it — nothing is
  /// recorded or sent anywhere; it only reads the sound's energy on-device).
  Future<void> _toggleFeel() async {
    if (_feelBusy) return;
    if (_feelOn) {
      _feel.stop();
      setState(() => _feelOn = false);
      return;
    }
    setState(() => _feelBusy = true);
    final granted = await _ensureAudioPermission();
    if (!mounted) { _feelBusy = false; return; }
    if (!granted) {
      setState(() => _feelBusy = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Feel needs audio access to sense the video sound.'),
      ));
      return;
    }
    _feel.onError = (msg) {
      if (!mounted) return;
      setState(() { _feelOn = false; _feelBusy = false; });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
    };
    _feel.start();
    setState(() { _feelOn = true; _feelBusy = false; });
  }

  Future<bool> _ensureAudioPermission() async {
    final rec = AudioRecorder();
    if (await rec.hasPermission(request: false)) return true;
    // One-time friendly explainer before the OS prompt.
    final proceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        icon: const Icon(Icons.vibration, size: 36),
        title: const Text('Feel the video'),
        content: const Text(
          'To turn this video’s sound into real vibrations, the app needs '
          'audio access. Nothing is ever recorded, saved or sent — it only '
          'senses the beat on your device, live.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, height: 1.5),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Not now')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Enable feel')),
        ],
      ),
    );
    if (proceed != true) return false;
    return rec.hasPermission(); // triggers the OS permission prompt
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(child: WebViewWidget(controller: _web)),
          if (!_ready)
            const Center(
                child: CircularProgressIndicator(color: Colors.white)),
          Positioned(
            top: 8,
            left: 8,
            child: Material(
              color: Colors.black45,
              shape: const CircleBorder(),
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ),
          // Feel button — turns the video's audio into live haptics.
          // Right edge, vertically centred: clear of the phone's front
          // camera punch-hole (top-left in landscape) and YouTube's controls.
          Positioned(
            right: 8,
            top: 0,
            bottom: 0,
            child: Center(
              child: Material(
                color: _feelOn
                    ? const Color(0xFF3CEBFF).withValues(alpha: 0.9)
                    : Colors.black.withValues(alpha: 0.55),
                shape: const StadiumBorder(),
                child: InkWell(
                  borderRadius: BorderRadius.circular(24),
                  onTap: _toggleFeel,
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      if (_feelBusy)
                        const SizedBox(
                            width: 18, height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                      else
                        Icon(
                            _feelOn
                                ? Icons.vibration
                                : Icons.vibration_outlined,
                            color: _feelOn ? Colors.black : Colors.white,
                            size: 22),
                      const SizedBox(height: 3),
                      Text(_feelOn ? 'Feel\non' : 'Feel',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: _feelOn ? Colors.black : Colors.white,
                              fontWeight: FontWeight.w800,
                              fontSize: 11,
                              height: 1.1)),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
