import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

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
              request.url.contains('about:blank');
          return ok ? NavigationDecision.navigate : NavigationDecision.prevent;
        },
      ))
      ..loadRequest(Uri.parse(
          'https://www.youtube.com/embed/$id?autoplay=1&playsinline=1'
          '&rel=0&modestbranding=1&iv_load_policy=3'));
    // Autoplay needs the no-gesture flag on Android.
    final platform = _web.platform;
    if (platform is AndroidWebViewController) {
      platform.setMediaPlaybackRequiresUserGesture(false);
    }
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
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
        ],
      ),
    );
  }
}
