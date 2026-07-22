import 'dart:async';

import 'package:flutter/material.dart';

import 'package:mrtouride/constant.dart';
import 'package:mrtouride/detail.dart';
import 'package:mrtouride/experience_player.dart';
import 'package:mrtouride/models/place.dart';
import 'package:mrtouride/services/auth_api.dart';
import 'package:mrtouride/services/location_service.dart';
import 'package:mrtouride/services/media_api.dart';
import 'package:mrtouride/widgets/news_section.dart';
import 'package:mrtouride/widgets/ux.dart';

class HomeScreen extends StatefulWidget {
  final void Function(int index)? onSelectTab;
  HomeScreen({super.key, this.onSelectTab});

  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomeScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  // Live catalog: city covers (internet / creator-uploaded) + latest videos.
  List<Place> places = [];
  List<VideoItem> trending = [];
  bool loading = true;
  String? error;
  List<NewsItem> news = [];

  // Rotating headline below the greeting.
  static const _phrases = [
    'Where do you want\nto feel today?',
    'Sunrise at the monuments —\nfrom your couch.',
    'Wind, waves, footsteps.\nIn your hands.',
    'Travel with your senses.\nFrom home.',
  ];
  int _phrase = 0;
  Timer? _phraseTimer;
  Timer? _syncTimer;

  @override
  void initState() {
    super.initState();
    _load();
    _loadNews();
    _phraseTimer = Timer.periodic(const Duration(milliseconds: 3500), (_) {
      if (mounted) setState(() => _phrase = (_phrase + 1) % _phrases.length);
    });
    // Quiet resync: fresh places and trending with no manual refresh.
    _syncTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _phraseTimer?.cancel();
    _syncTimer?.cancel();
    super.dispose();
  }

  /// News for the reader's current country + city (falls back to the
  /// default feed when location is unknown). Location is cached, so this is
  /// cheap and doesn't re-prompt on every open.
  Future<void> _loadNews() async {
    try {
      final (country, city) = await LocationService.current();
      final items = await MediaApi.fetchNews(country: country, city: city);
      if (mounted) setState(() => news = items);
    } catch (_) {}
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        MediaApi.fetchCities(),
        MediaApi.fetchTrending(limit: 6),
      ]);
      if (!mounted) return;
      setState(() {
        places = [for (final c in results[0] as List<City>) Place.fromCity(c)];
        trending = results[1] as List<VideoItem>;
        loading = false;
        error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = 'Could not sync — check your internet.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // keep this tab alive across switches
    final name = AuthApi.currentUser?.name.split(' ').first ?? 'Explorer';
    return Scaffold(
      backgroundColor: pageBg(context),
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: _load,
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                // Header
                Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: cardBg(context),
                    borderRadius: const BorderRadius.vertical(
                        bottom: Radius.circular(30)),
                  ),
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Entrance(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Text(
                              'Hello ',
                              style: TextStyle(
                                fontFamily: 'Helvetica',
                                color: inkSoft(context),
                                fontSize: 26,
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                            Flexible(
                              child: Text(
                                name,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: 'Helvetica',
                                  color: brandInk(context),
                                  fontWeight: FontWeight.w800,
                                  fontSize: 27,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            const WavingHand(size: 26),
                          ],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Entrance(
                        index: 1,
                        child: SizedBox(
                          height: 72,
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 450),
                            switchInCurve: Curves.easeOutCubic,
                            switchOutCurve: Curves.easeInCubic,
                            transitionBuilder: (child, animation) =>
                                FadeTransition(
                              opacity: animation,
                              child: SlideTransition(
                                position: Tween<Offset>(
                                  begin: const Offset(0, 0.35),
                                  end: Offset.zero,
                                ).animate(animation),
                                child: child,
                              ),
                            ),
                            child: TypewriterText(
                              _phrases[_phrase],
                              key: ValueKey(_phrase),
                              style: TextStyle(
                                  color: ink(context),
                                  fontSize: 28,
                                  height: 1.2,
                                  fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      // Search — jumps to the Search tab.
                      Entrance(
                        index: 2,
                        child: Springy(
                          haptic: 'tick',
                          onTap: () => widget.onSelectTab?.call(5),
                          child: Container(
                            decoration: BoxDecoration(
                              color: pageBg(context),
                              borderRadius: BorderRadius.circular(15),
                            ),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 14),
                            child: Row(
                              children: [
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12),
                                  child:
                                      Icon(Icons.search, color: ink(context)),
                                ),
                                const Text(
                                  'Search cities or experiences',
                                  style: TextStyle(
                                      color: Colors.grey, fontSize: 15),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      if (error != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Text(error!,
                              style: const TextStyle(
                                  color: Colors.redAccent, fontSize: 13)),
                        ),
                      _sectionHeader('Most viewed places',
                          onSeeAll: () => widget.onSelectTab?.call(1)),
                      const SizedBox(height: 14),
                      SizedBox(
                        height: 230,
                        child: loading
                            ? const Center(child: CircularProgressIndicator())
                            : _adaptiveRail(
                                count: places.length,
                                minCardWidth: 170,
                                gap: 14,
                                builder: (i, w) => Entrance(
                                  index: i,
                                  child: _placeCard(places[i], width: w),
                                ),
                              ),
                      ),
                      // Empty platforms skip straight to Picked-for-you —
                      // no dead 'No experiences yet' box.
                      if (trending.isNotEmpty) ...[
                        const SizedBox(height: 26),
                        _sectionHeader('Top trending experiences'),
                        const SizedBox(height: 14),
                        SizedBox(
                          height: 190,
                          child: _adaptiveRail(
                            count: trending.length,
                            minCardWidth: 300,
                            gap: 14,
                            builder: (i, w) => Entrance(
                              index: i,
                              child: _trendingCard(trending[i], width: w),
                            ),
                          ),
                        ),
                      ],
                      // Travel news at the bottom of the main feed.
                      ...newsSection(context, news),
                      // Keep last row clear of the floating navbar.
                      const SizedBox(height: 110),
                    ],
                  ),
                )
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Auto-adapting rail: when all cards fit, they expand equally to fill the
  /// full row (no dead space); when they don't, it scrolls horizontally.
  Widget _adaptiveRail({
    required int count,
    required double minCardWidth,
    required double gap,
    required Widget Function(int index, double? width) builder,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final needed = count * minCardWidth + (count - 1) * gap;
        if (count > 0 && needed <= constraints.maxWidth) {
          // Everything fits: stretch cards evenly across the row.
          return Row(
            children: [
              for (var i = 0; i < count; i++) ...[
                if (i > 0) SizedBox(width: gap),
                Expanded(child: builder(i, null)),
              ],
            ],
          );
        }
        return ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: count,
          separatorBuilder: (_, __) => SizedBox(width: gap),
          itemBuilder: (context, i) => builder(i, minCardWidth),
        );
      },
    );
  }

  Widget _sectionHeader(String title, {VoidCallback? onSeeAll}) {
    return Row(
      children: [
        Text(title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        const Spacer(),
        if (onSeeAll != null)
          TextButton(onPressed: onSeeAll, child: const Text('See all')),
      ],
    );
  }

  /// City cover card — high-res network image, single clean caption.
  Widget _placeCard(Place place, {double? width}) {
    return Springy(
      haptic: 'string',
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => DetailScreen(place: place)),
      ),
      child: Container(
        width: width,
        height: 230,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.12),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _cover(place.image),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.65),
                  ],
                  stops: const [0.55, 1],
                ),
              ),
            ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    place.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700),
                  ),
                  Text(
                    place.location,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Trending experience card — ML-extracted poster, opens the player.
  Widget _trendingCard(VideoItem video, {double? width}) {
    return Springy(
      haptic: 'string',
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
            builder: (context) => ExperiencePlayerPage(video: video)),
      ),
      child: Container(
        width: width,
        height: 190,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.12),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (video.absoluteThumbUrl != null)
              _cover(video.absoluteThumbUrl!)
            else
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFF1E319D), Color(0xFF3CEBFF)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
              ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.7),
                  ],
                  stops: const [0.45, 1],
                ),
              ),
            ),
            Center(
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black.withValues(alpha: 0.45),
                ),
                child:
                    const Icon(Icons.play_arrow, color: Colors.white, size: 30),
              ),
            ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 10,
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          video.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w700),
                        ),
                        Text(
                          '${video.city[0].toUpperCase()}${video.city.substring(1)}'
                          '${video.hapticsReady ? ' · Feel · Sound' : ' · Sound'}',
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  if (video.hapticsReady)
                    const Icon(Icons.vibration,
                        color: Colors.purpleAccent, size: 18),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cover(String src) {
    return Image.network(
      src,
      fit: BoxFit.cover,
      loadingBuilder: (context, child, progress) => progress == null
          ? child
          : Container(
              color: Colors.black12,
              child: const Center(
                  child: CircularProgressIndicator(strokeWidth: 2)),
            ),
      errorBuilder: (context, error, stack) => Container(
        color: Colors.black12,
        child: const Icon(Icons.landscape, color: Colors.black26, size: 48),
      ),
    );
  }
}
