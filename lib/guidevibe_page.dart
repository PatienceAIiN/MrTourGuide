import 'dart:async';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import 'constant.dart';
import 'guidevibe_upload.dart';
import 'navpages/community_page.dart' show showUserProfileDialog;
import 'news_webview.dart';
import 'services/auth_api.dart';
import 'services/guidevibe_api.dart';
import 'services/haptic_service.dart';
import 'services/location_service.dart';

/// GuideVibe — a full-screen, vertically-scrolling short-video feed (Reels /
/// YouTube Shorts style). Creator uploads play inline with audio→haptics;
/// blended YouTube Shorts open in the in-app player and wear a subtle chip.
class GuideVibePage extends StatefulWidget {
  final void Function(int index)? onSelectTab;
  const GuideVibePage({super.key, this.onSelectTab});

  @override
  State<GuideVibePage> createState() => _GuideVibePageState();
}

class _GuideVibePageState extends State<GuideVibePage> {
  final PageController _pager = PageController();
  final List<Short> _shorts = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  String? _error;
  String _city = '';
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final (city, _) = await LocationService.current();
      _city = city;
      final (list, more) = await GuideVibeApi.feed(city: city);
      if (!mounted) return;
      setState(() {
        _shorts
          ..clear()
          ..addAll(list);
        _hasMore = more;
        _loading = false;
      });
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    _loadingMore = true;
    try {
      final (list, more) =
          await GuideVibeApi.feed(city: _city, offset: _shorts.length);
      if (!mounted) return;
      setState(() {
        _shorts.addAll(list);
        _hasMore = more;
      });
    } catch (_) {
      // Silent — the current page keeps playing.
    } finally {
      _loadingMore = false;
    }
  }

  Future<void> _openUpload() async {
    final created = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const GuideVibeUploadPage()),
    );
    if (created == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final isCreator = AuthApi.currentUser?.isCreator ?? false;
    return Scaffold(
      backgroundColor: Colors.black,
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Colors.white))
          : _error != null
              ? _errorView()
              : _shorts.isEmpty
                  ? _emptyView(isCreator)
                  : Stack(
                      children: [
                        PageView.builder(
                          controller: _pager,
                          scrollDirection: Axis.vertical,
                          itemCount: _shorts.length,
                          onPageChanged: (i) {
                            Haptics.tick();
                            setState(() => _index = i);
                            if (i >= _shorts.length - 2) _loadMore();
                          },
                          itemBuilder: (context, i) => _ShortView(
                            key: ValueKey(_shorts[i].id),
                            short: _shorts[i],
                            active: i == _index,
                          ),
                        ),
                        // Header label.
                        Positioned(
                          top: MediaQuery.of(context).padding.top + 12,
                          left: 0,
                          right: 0,
                          child: const IgnorePointer(
                            child: Center(
                              child: Text(
                                'GuideVibe · For You',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.4,
                                  shadows: [
                                    Shadow(
                                        color: Colors.black54,
                                        blurRadius: 4,
                                        offset: Offset(0, 1))
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        // Creator "Create" — top-right so it never hides
                        // behind the floating navbar (which the feed extends
                        // under) or collides with the action rail.
                        if (isCreator)
                          Positioned(
                            top: MediaQuery.of(context).padding.top + 6,
                            right: 8,
                            child: Material(
                              color: Colors.black.withValues(alpha: 0.32),
                              shape: const StadiumBorder(),
                              child: InkWell(
                                customBorder: const StadiumBorder(),
                                onTap: _openUpload,
                                child: const Padding(
                                  padding: EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 7),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.add_a_photo_outlined,
                                          color: Colors.white, size: 17),
                                      SizedBox(width: 6),
                                      Text('Create',
                                          style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 12.5,
                                              fontWeight: FontWeight.w800)),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
    );
  }

  Widget _errorView() => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70)),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: _load,
                style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white30)),
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );

  Widget _emptyView(bool isCreator) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.video_library_outlined,
                  color: Colors.white38, size: 54),
              const SizedBox(height: 14),
              const Text('No GuideVibe shorts yet',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text(
                isCreator
                    ? 'Be the first — share a short.'
                    : 'Check back soon — creators are just getting started.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54, fontSize: 13),
              ),
              if (isCreator) ...[
                const SizedBox(height: 18),
                ElevatedButton.icon(
                  onPressed: _openUpload,
                  style: ElevatedButton.styleFrom(
                      backgroundColor: blue, foregroundColor: Colors.white),
                  icon: const Icon(Icons.add_a_photo_outlined, size: 18),
                  label: const Text('Create GuideVibe'),
                ),
              ],
            ],
          ),
        ),
      );
}

/// One full-screen short. Owns its video controller (created only while
/// active, disposed when scrolled away) and runs the audio→haptics engine.
class _ShortView extends StatefulWidget {
  final Short short;
  final bool active;
  const _ShortView({super.key, required this.short, required this.active});

  @override
  State<_ShortView> createState() => _ShortViewState();
}

class _ShortViewState extends State<_ShortView> {
  VideoPlayerController? _controller;
  bool _initialized = false;
  bool _paused = false;
  bool _showHeart = false;
  bool _viewCounted = false;

  // Haptics engine state.
  Timer? _haptics;
  int _nextEvent = 0;
  int _recoilUntilMs = 0;

  // Local like state (optimistic).
  late bool _liked = widget.short.liked;
  late int _likes = widget.short.likes;

  @override
  void initState() {
    super.initState();
    if (widget.active) _activate();
  }

  @override
  void didUpdateWidget(_ShortView old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) _activate();
    if (!widget.active && old.active) _deactivate();
  }

  @override
  void dispose() {
    _haptics?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  void _activate() {
    if (widget.short.isYouTube) return; // YT plays in the webview on tap
    if (!_viewCounted) {
      _viewCounted = true;
      GuideVibeApi.view(widget.short.id);
    }
    _ensureController();
  }

  void _deactivate() {
    _haptics?.cancel();
    _controller?.pause();
    _controller?.seekTo(Duration.zero);
  }

  Future<void> _ensureController() async {
    if (_controller != null) {
      await _controller!.play();
      _startHaptics();
      return;
    }
    final url = widget.short.absoluteUrl;
    if (url == null) return;
    final c = VideoPlayerController.networkUrl(Uri.parse(url));
    try {
      await c.initialize();
      c.setLooping(true);
      await c.play();
      if (!mounted) {
        c.dispose();
        return;
      }
      setState(() {
        _controller = c;
        _initialized = true;
      });
      _startHaptics();
    } catch (_) {
      c.dispose();
    }
  }

  /// Audio→haptics: fast tick, smooth interpolation, recoil on impacts —
  /// the same engine as the full experience player.
  void _startHaptics() {
    _haptics?.cancel();
    final fine = widget.short.hapticFine;
    final events = widget.short.hapticEvents;
    if (fine.isEmpty) return;
    _nextEvent = 0;
    _recoilUntilMs = 0;
    const tickMs = 90;
    _haptics = Timer.periodic(const Duration(milliseconds: tickMs), (_) {
      final c = _controller;
      if (c == null || !c.value.isPlaying) return;
      final ms = c.value.position.inMilliseconds;
      if (events.isNotEmpty) {
        while (_nextEvent < events.length &&
            (events[_nextEvent]['t'] as num) < ms - 400) {
          _nextEvent++;
        }
        if (_nextEvent < events.length) {
          final e = events[_nextEvent];
          final t = (e['t'] as num).toInt();
          if ((ms - t).abs() <= 130) {
            _nextEvent++;
            Haptics.recoil((e['power'] as num).clamp(0.0, 1.0).toDouble());
            _recoilUntilMs = ms + 230;
            return;
          }
        }
      }
      if (ms < _recoilUntilMs) return;
      const step = 250;
      final idx = ms ~/ step;
      final frac = (ms % step) / step;
      final a = fine[idx.clamp(0, fine.length - 1)];
      final b = fine[(idx + 1).clamp(0, fine.length - 1)];
      final feel = (a + (b - a) * frac).clamp(0.0, 1.0);
      if (feel < 0.06) return;
      Haptics.level(feel, durationMs: tickMs + 40);
    });
  }

  void _togglePlay() {
    final c = _controller;
    if (c == null) return;
    setState(() {
      if (c.value.isPlaying) {
        c.pause();
        _paused = true;
      } else {
        c.play();
        _paused = false;
      }
    });
  }

  void _doubleTapLike() {
    if (!_liked) _toggleLike();
    setState(() => _showHeart = true);
    Timer(const Duration(milliseconds: 850), () {
      if (mounted) setState(() => _showHeart = false);
    });
  }

  Future<void> _toggleLike() async {
    if (AuthApi.currentUser == null) {
      newSnackBar(context, title: 'Sign in to like.');
      return;
    }
    if (widget.short.isYouTube) {
      _openYouTube();
      return;
    }
    Haptics.tick();
    setState(() {
      _liked = !_liked;
      _likes += _liked ? 1 : -1;
    });
    try {
      final liked = await GuideVibeApi.toggleLike(widget.short.id);
      if (mounted && liked != _liked) {
        setState(() {
          _liked = liked;
          _likes = widget.short.likes + (liked ? 1 : 0);
        });
      }
    } catch (_) {}
  }

  void _openYouTube() {
    final id = widget.short.ytId;
    if (id == null) return;
    _controller?.pause();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => NewsWebViewPage(
          title: 'YouTube Shorts',
          url: 'https://www.youtube.com/shorts/$id',
        ),
      ),
    );
  }

  Future<void> _share() async {
    Haptics.tick();
    final s = widget.short;
    final text = s.isYouTube
        ? 'https://www.youtube.com/shorts/${s.ytId}'
        : 'Watch "${s.caption.isEmpty ? 'this GuideVibe' : s.caption}" on '
            'Mr.Tour Guide\nhttps://mrtourguide.patienceai.in/';
    await SharePlus.instance.share(ShareParams(text: text));
  }

  void _openComments() {
    if (widget.short.isYouTube) {
      _openYouTube();
      return;
    }
    _controller?.pause();
    setState(() => _paused = true);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CommentsSheet(shortId: widget.short.id),
    ).whenComplete(() {
      if (mounted && widget.active) {
        _controller?.play();
        setState(() => _paused = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.short;
    return GestureDetector(
      onTap: s.isYouTube ? _openYouTube : _togglePlay,
      onDoubleTap: s.isYouTube ? null : _doubleTapLike,
      child: Container(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _videoLayer(s),
            // Legibility gradient.
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x66000000),
                    Colors.transparent,
                    Colors.transparent,
                    Color(0x99000000),
                  ],
                  stops: [0, 0.22, 0.55, 1],
                ),
              ),
            ),
            if (s.isImmersive) _immersiveOverlay(s),
            _topChips(s),
            _rightRail(s),
            _bottomInfo(s),
            if (_paused && !s.isYouTube) _pauseGlyph(),
            if (_showHeart) _heartBurst(),
          ],
        ),
      ),
    );
  }

  Widget _videoLayer(Short s) {
    if (s.isYouTube) {
      return Stack(
        fit: StackFit.expand,
        children: [
          if (s.absoluteThumbUrl != null)
            Image.network(s.absoluteThumbUrl!,
                fit: BoxFit.cover,
                errorBuilder: (c, e, st) => Container(color: Colors.black))
          else
            Container(color: Colors.black),
          Center(
            child: Container(
              decoration: const BoxDecoration(
                  color: Colors.black45, shape: BoxShape.circle),
              padding: const EdgeInsets.all(14),
              child:
                  const Icon(Icons.play_arrow, color: Colors.white, size: 44),
            ),
          ),
        ],
      );
    }
    final c = _controller;
    if (c != null && _initialized) {
      return FittedBox(
        fit: BoxFit.cover,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: c.value.size.width,
          height: c.value.size.height,
          child: VideoPlayer(c),
        ),
      );
    }
    // Loading: poster + spinner.
    return Stack(
      fit: StackFit.expand,
      children: [
        if (s.absoluteThumbUrl != null)
          Image.network(s.absoluteThumbUrl!,
              fit: BoxFit.cover,
              errorBuilder: (c, e, st) => Container(color: Colors.black))
        else
          Container(color: Colors.black),
        if (widget.active)
          const Center(
              child: CircularProgressIndicator(color: Colors.white70)),
      ],
    );
  }

  Widget _immersiveOverlay(Short s) => IgnorePointer(
        child: s.isVr
            ? const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment(-0.4, 0),
                    radius: 0.7,
                    colors: [Colors.transparent, Colors.black87],
                    stops: [0.55, 1],
                  ),
                ),
                child: Center(
                  child: SizedBox(
                    width: 1,
                    height: double.infinity,
                    child: ColoredBox(color: Colors.white24),
                  ),
                ),
              )
            : CustomPaint(painter: _MrGridPainter(), child: Container()),
      );

  Widget _topChips(Short s) => Positioned(
        top: MediaQuery.of(context).padding.top + 44,
        left: 14,
        right: 14,
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                s.city != null && s.city!.isNotEmpty
                    ? 'video · ${s.city}'
                    : 'video',
                style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 10.5,
                    fontFamily: 'monospace'),
              ),
            ),
            const SizedBox(width: 8),
            if (s.isImmersive)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.32),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: Colors.white38),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.view_in_ar,
                        color: Colors.white, size: 13),
                    const SizedBox(width: 4),
                    Text(s.kind.toUpperCase(),
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w800)),
                  ],
                ),
              ),
            const Spacer(),
            if (s.isYouTube) _youtubeChip(),
          ],
        ),
      );

  Widget _youtubeChip() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.38),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.white24),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.play_circle_fill, color: Color(0xFFFF0000), size: 14),
            SizedBox(width: 5),
            Text('YouTube Shorts',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700)),
          ],
        ),
      );

  Widget _rightRail(Short s) => Positioned(
        right: 8,
        bottom: 96,
        child: Column(
          children: [
            _railButton(
              icon: _liked ? Icons.favorite : Icons.favorite_border,
              color: _liked ? const Color(0xFFFF4D5E) : Colors.white,
              label: _fmt(_likes),
              onTap: _toggleLike,
            ),
            const SizedBox(height: 18),
            _railButton(
              icon: Icons.mode_comment_outlined,
              color: Colors.white,
              label: 'Comment',
              onTap: _openComments,
            ),
            const SizedBox(height: 18),
            _railButton(
              icon: Icons.reply,
              color: Colors.white,
              label: 'Share',
              onTap: _share,
            ),
          ],
        ),
      );

  Widget _railButton({
    required IconData icon,
    required Color color,
    required String label,
    required VoidCallback onTap,
  }) =>
      GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Column(
          children: [
            Icon(icon, color: color, size: 30, shadows: const [
              Shadow(color: Colors.black45, blurRadius: 4, offset: Offset(0, 1))
            ]),
            const SizedBox(height: 3),
            Text(label,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    shadows: [
                      Shadow(color: Colors.black45, blurRadius: 3)
                    ])),
          ],
        ),
      );

  Widget _bottomInfo(Short s) => Positioned(
        left: 14,
        right: 76,
        bottom: 24,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                GestureDetector(
                  onTap: () => s.ownerId != null
                      ? showUserProfileDialog(context, s.ownerId!)
                      : null,
                  child: CircleAvatar(
                    radius: 17,
                    backgroundColor: s.isYouTube
                        ? const Color(0xFFFF0000)
                        : (s.byCreator ? Colors.purple : blue),
                    child: Text(
                      s.ownerName.isNotEmpty
                          ? s.ownerName[0].toUpperCase()
                          : '?',
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 15),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: GestureDetector(
                    onTap: () => s.ownerId != null
                        ? showUserProfileDialog(context, s.ownerId!)
                        : null,
                    child: Text(
                      s.ownerName,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                          shadows: [
                            Shadow(color: Colors.black45, blurRadius: 3)
                          ]),
                    ),
                  ),
                ),
              ],
            ),
            if (s.caption.isNotEmpty) ...[
              const SizedBox(height: 9),
              Text(
                s.caption,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13.5,
                    height: 1.4,
                    shadows: [Shadow(color: Colors.black45, blurRadius: 3)]),
              ),
            ],
            const SizedBox(height: 9),
            Row(
              children: [
                const Icon(Icons.graphic_eq, color: Colors.white70, size: 14),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    s.isImmersive
                        ? 'Immersive · haptics on'
                        : 'Original audio · haptics on',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 12),
                  ),
                ),
              ],
            ),
          ],
        ),
      );

  Widget _pauseGlyph() => const IgnorePointer(
        child: Center(
          child: Icon(Icons.play_arrow, color: Colors.white70, size: 72),
        ),
      );

  Widget _heartBurst() => IgnorePointer(
        child: Center(
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 700),
            curve: Curves.easeOutBack,
            builder: (context, v, child) => Opacity(
              opacity: (1 - v).clamp(0.0, 1.0) * 0.5 + 0.5,
              child: Transform.scale(scale: 0.6 + v * 0.6, child: child),
            ),
            child: const Icon(Icons.favorite,
                color: Color(0xFFFF4D5E), size: 110),
          ),
        ),
      );

  String _fmt(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}m';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '$n';
  }
}

/// The MR passthrough grid overlay from the design.
class _MrGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.06)
      ..strokeWidth = 1;
    const gap = 28.0;
    for (var x = 0.0; x < size.width; x += gap) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (var y = 0.0; y < size.height; y += gap) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
    final border = Paint()
      ..color = Colors.white.withValues(alpha: 0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(14, 14, size.width - 28, size.height - 28),
          const Radius.circular(16)),
      border,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Comments bottom-sheet for a short.
class _CommentsSheet extends StatefulWidget {
  final String shortId;
  const _CommentsSheet({required this.shortId});

  @override
  State<_CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends State<_CommentsSheet> {
  final _input = TextEditingController();
  List<ShortComment> _comments = [];
  bool _loading = true;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final list = await GuideVibeApi.comments(widget.shortId);
      if (mounted) {
        setState(() {
          _comments = list;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    if (AuthApi.currentUser == null) {
      newSnackBar(context, title: 'Sign in to comment.');
      return;
    }
    setState(() => _sending = true);
    try {
      await GuideVibeApi.addComment(widget.shortId, text);
      _input.clear();
      await _load();
    } on AuthException catch (e) {
      if (mounted) newSnackBar(context, title: e.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: DraggableScrollableSheet(
        initialChildSize: 0.62,
        minChildSize: 0.4,
        maxChildSize: 0.92,
        expand: false,
        builder: (context, scroll) => Container(
          decoration: BoxDecoration(
            color: cardBg(context),
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                    color: Colors.grey.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2)),
              ),
              Padding(
                padding: const EdgeInsets.all(14),
                child: Text('${_comments.length} comments',
                    style: TextStyle(
                        color: ink(context),
                        fontWeight: FontWeight.w800,
                        fontSize: 15)),
              ),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _comments.isEmpty
                        ? Center(
                            child: Text('No comments yet — say something!',
                                style: TextStyle(color: inkSoft(context))))
                        : ListView.builder(
                            controller: scroll,
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            itemCount: _comments.length,
                            itemBuilder: (context, i) {
                              final c = _comments[i];
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 16),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    CircleAvatar(
                                      radius: 15,
                                      backgroundColor: blue,
                                      child: Text(
                                        c.authorName.isNotEmpty
                                            ? c.authorName[0].toUpperCase()
                                            : '?',
                                        style: const TextStyle(
                                            color: Colors.white, fontSize: 12),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(c.authorName,
                                              style: TextStyle(
                                                  color: inkSoft(context),
                                                  fontWeight: FontWeight.w800,
                                                  fontSize: 12)),
                                          const SizedBox(height: 2),
                                          Text(c.body,
                                              style: TextStyle(
                                                  color: ink(context),
                                                  fontSize: 13.5,
                                                  height: 1.4)),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _input,
                          style: TextStyle(color: ink(context)),
                          decoration: InputDecoration(
                            hintText: 'Add a comment…',
                            filled: true,
                            fillColor: pageBg(context),
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 10),
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(999),
                                borderSide: BorderSide.none),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _sending
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2))
                          : IconButton(
                              icon: Icon(Icons.send_rounded,
                                  color: brandInk(context)),
                              onPressed: _send,
                            ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
