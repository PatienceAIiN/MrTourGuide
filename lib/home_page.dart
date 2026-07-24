import 'dart:async';

import 'package:flutter/material.dart';

import 'package:mrtouride/constant.dart';
import 'package:mrtouride/detail.dart';
import 'package:mrtouride/experience_player.dart';
import 'package:mrtouride/models/place.dart';
import 'package:mrtouride/news_webview.dart';
import 'package:mrtouride/services/auth_api.dart';
import 'package:mrtouride/services/location_service.dart';
import 'package:mrtouride/services/media_api.dart';
import 'package:mrtouride/services/notification_service.dart';
import 'package:mrtouride/services/tab_events.dart';
import 'package:mrtouride/widgets/notifications_sheet.dart';
import 'package:mrtouride/widgets/youtube_player_page.dart';
import 'package:mrtouride/widgets/news_section.dart';
import 'package:mrtouride/widgets/ux.dart';

class HomeScreen extends StatefulWidget {
  final void Function(int index)? onSelectTab;
  HomeScreen({super.key, this.onSelectTab});

  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomeScreen>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  @override
  bool get wantKeepAlive => true;

  // Live catalog: city covers (internet / creator-uploaded) + latest videos.
  List<Place> places = [];
  List<VideoItem> trending = [];
  bool loading = true;
  String? error;
  bool hasUnseen = false;
  List<NewsItem> news = [];
  // Playable "Picked for you" experience videos (city/activity-seeded).
  List<YtSuggestion> picks = [];

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
  Timer? _rotateTimer;
  int _coverPolls = 0;
  bool _coverPollScheduled = false;

  bool _loadedOnce = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Push said new content landed, or the user came back to this tab —
    // refresh WITHOUT waiting for the periodic tick.
    ContentEvents.refresh.addListener(_onContentPing);
    TabEvents.changed.addListener(_onTabReturn);
    _hydrateFromCache(); // paint the last-known data INSTANTLY
    _load(initial: true);
    _loadNews();
    _loadPicks();
    _refreshUnseen();
    // Slower, calmer headline cadence.
    _phraseTimer = Timer.periodic(const Duration(milliseconds: 5500), (_) {
      if (mounted) setState(() => _phrase = (_phrase + 1) % _phrases.length);
    });
    // Quiet resync: fresh places and trending with no manual refresh, and
    // never a failure banner — a background tick that fails just keeps the
    // data we already have.
    _syncTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (mounted) _load();
    });
    // Hourly full rotation: fresh recommendations, news and places keep the
    // dashboard alive even if the user never pulls to refresh.
    _rotateTimer = Timer.periodic(const Duration(hours: 1), (_) {
      if (mounted) _refreshAll();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Screen back on / app foregrounded → quietly refresh so any stale
    // "offline" state clears the moment connectivity is back.
    if (state == AppLifecycleState.resumed && mounted) {
      _load();
      _loadNews();
      _refreshUnseen();
    }
  }

  void _onContentPing() {
    if (!mounted) return;
    _load();
    _loadNews();
    _refreshUnseen();
  }

  void _onTabReturn() {
    if (mounted && TabEvents.changed.value == 0) _load();
  }

  @override
  void dispose() {
    ContentEvents.refresh.removeListener(_onContentPing);
    TabEvents.changed.removeListener(_onTabReturn);
    WidgetsBinding.instance.removeObserver(this);
    _phraseTimer?.cancel();
    _syncTimer?.cancel();
    _rotateTimer?.cancel();
    super.dispose();
  }

  /// Instant first paint: hydrate every home rail from the disk cache while
  /// the real fetches run behind it (stale-while-revalidate). This is what
  /// makes a cold open feel immediate instead of spinner-bound.
  Future<void> _hydrateFromCache() async {
    try {
      final results = await Future.wait([
        MediaApi.cachedCities(),
        MediaApi.cachedTrending(),
        MediaApi.cachedNews(),
        MediaApi.cachedMedia('picks'),
      ]);
      if (!mounted || _loadedOnce) return;
      final cs = results[0] as List<City>?;
      final tr = results[1] as List<VideoItem>?;
      final nw = results[2] as List<NewsItem>?;
      final pk = results[3] as MediaSuggestions?;
      if (cs == null && tr == null && nw == null && pk == null) return;
      setState(() {
        if (cs != null && places.isEmpty) {
          places = [for (final c in cs) Place.fromCity(c)];
          loading = false;
        }
        if (tr != null && trending.isEmpty) trending = tr;
        if (nw != null && news.isEmpty) news = nw;
        if (pk != null && picks.isEmpty) picks = pk.youtube;
      });
    } catch (_) {}
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

  /// Playable experience-video picks for the main feed — seeded by the
  /// reader's city (falls back to a general travel query). Server-cached.
  Future<void> _loadPicks() async {
    try {
      final (_, city) = await LocationService.current();
      final seed = city.isNotEmpty
          ? '$city travel experience'
          : 'India travel experiences';
      final m = await MediaApi.searchMedia(seed, swrKey: 'picks');
      if (mounted) setState(() => picks = m.youtube);
    } catch (_) {}
  }

  /// Light poll: is there anything new (content, GuideVibe, community,
  /// activity) since this device last OPENED the bell? The dot persists
  /// across sessions until the inbox is read, then stays off until
  /// something genuinely newer arrives.
  Future<void> _refreshUnseen() async {
    try {
      final st = await NotificationService.unreadStatus();
      if (mounted) setState(() => hasUnseen = st.bell);
    } catch (_) {}
  }

  Future<void> _openNotifications() async {
    await showNotificationsSheet(context, onSelectTab: widget.onSelectTab);
    if (mounted) setState(() => hasUnseen = false);
  }

  /// Pull-to-refresh + the hourly rotation: EVERYTHING on the dashboard
  /// renews — places, trending, recommended videos, news and the bell.
  Future<void> _refreshAll() async {
    await Future.wait([
      _load(),
      _loadNews(),
      _loadPicks(),
      _refreshUnseen(),
    ]);
  }

  Future<void> _load({bool initial = false}) async {
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
        _loadedOnce = true;
        error = null;
      });
      // A just-added place gets its cover a few seconds later — poll fast
      // (10s, max ~2 min) until every card has a real photo.
      final missing = places.any((p) => !p.isNetworkImage);
      if (!missing) {
        _coverPolls = 0;
      } else if (_coverPolls < 12 && !_coverPollScheduled) {
        _coverPolls++;
        _coverPollScheduled = true;
        Timer(const Duration(seconds: 10), () {
          _coverPollScheduled = false;
          if (mounted) _load();
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        loading = false;
        // Only surface the banner on a cold load with nothing to show —
        // background/resume ticks that fail keep the data already on screen
        // (screen-off, doze, app-switch all just retry quietly).
        if (!_loadedOnce) error = 'Could not sync — check your internet.';
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
          onRefresh: _refreshAll,
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
                  // Stack so the bell can pin to the card's TRUE top-right
                  // corner, independent of the greeting row's layout.
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Column(
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
                            const Spacer(),
                            // Keep the greeting clear of the corner bell.
                            const SizedBox(width: 34),
                          ],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Entrance(
                        index: 1,
                        child: SizedBox(
                          height: 72,
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 650),
                            switchInCurve: Curves.easeOutCubic,
                            switchOutCurve: Curves.easeInCubic,
                            transitionBuilder: (child, animation) =>
                                FadeTransition(
                              opacity: animation,
                              child: SlideTransition(
                                position: Tween<Offset>(
                                  begin: const Offset(0, 0.2),
                                  end: Offset.zero,
                                ).animate(animation),
                                child: child,
                              ),
                            ),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              key: ValueKey(_phrase),
                              child: Text(
                                _phrases[_phrase],
                                style: TextStyle(
                                    color: ink(context),
                                    fontSize: 26,
                                    height: 1.25,
                                    fontWeight: FontWeight.bold),
                              ),
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
                      // Pinned to the card's true top-right corner.
                      Positioned(
                        top: -8,
                        right: -10,
                        child: _bellButton(context),
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
                      // Experience videos — playable "Picked for you" rail,
                      // between trending and the travel/precautions news.
                      if (picks.isNotEmpty) ...[
                        const SizedBox(height: 26),
                        _sectionHeader('Picked for you'),
                        const SizedBox(height: 14),
                        SizedBox(
                          height: 216,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: picks.length,
                            separatorBuilder: (c, i) =>
                                const SizedBox(width: 12),
                            itemBuilder: (context, i) => _pickCard(picks[i]),
                          ),
                        ),
                      ],
                      // Travel news + precautions at the bottom of the feed.
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

  /// Notifications bell — embedded in the header card beside the greeting,
  /// flush with the right content edge (no IconButton slop, so it lines up
  /// with the search field below). The dot stays until the inbox is read.
  Widget _bellButton(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        IconButton(
          tooltip: 'Notifications',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 34, height: 40),
          alignment: Alignment.centerRight,
          icon: Icon(Icons.notifications_none_rounded,
              size: 26, color: ink(context)),
          onPressed: _openNotifications,
        ),
        if (hasUnseen)
          Positioned(
            right: 0,
            top: 7,
            child: Container(
              width: 9,
              height: 9,
              decoration: const BoxDecoration(
                color: Color(0xFF3CEBFF),
                shape: BoxShape.circle,
              ),
            ),
          ),
      ],
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
            place.isNetworkImage ? _cover(place.image) : _fetchingCover(),
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

  /// Playable "Picked for you" experience-video card — opens in-app.
  Widget _pickCard(YtSuggestion pick) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          // YouTube picks play fullscreen-landscape, just that one video;
          // anything else opens in the reader webview.
          builder: (context) => YoutubePlayerPage.videoIdOf(pick.url) != null
              ? YoutubePlayerPage(title: pick.title, url: pick.url)
              : NewsWebViewPage(title: pick.title, url: pick.url),
        ),
      ),
      child: SizedBox(
        width: 300,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              alignment: Alignment.center,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Image.network(
                    pick.thumbnail.replaceFirst('mqdefault', 'hqdefault'),
                    width: 300,
                    height: 170,
                    fit: BoxFit.cover,
                    errorBuilder: (c, e, st) => Container(
                        width: 300, height: 170, color: Colors.black12),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.all(9),
                  decoration: const BoxDecoration(
                      color: Colors.black45, shape: BoxShape.circle),
                  child: const Icon(Icons.play_arrow,
                      color: Colors.white, size: 28),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Flexible(
              child: Text(pick.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 13)),
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
                    colors: [Color(0xFF0F6E84), Color(0xFF3CEBFF)],
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

  /// Cover not ready yet (a new place fetches its photo server-side within
  /// seconds) — show a live loading treatment on THAT card only.
  Widget _fetchingCover() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0F6E84), Color(0xFF3CEBFF)],
        ),
      ),
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                  strokeWidth: 2.2, color: Colors.white70),
            ),
            SizedBox(height: 10),
            Text('Fetching photo…',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
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
