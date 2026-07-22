import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter/material.dart';

import 'package:mrtouride/constant.dart';
import 'package:mrtouride/detail.dart';
import 'package:mrtouride/experience_player.dart';
import 'package:mrtouride/models/place.dart';
import 'package:mrtouride/services/auth_api.dart';
import 'package:mrtouride/services/haptic_service.dart';
import 'package:mrtouride/news_webview.dart';
import 'package:mrtouride/services/media_api.dart';
import 'package:mrtouride/services/notification_service.dart';
import 'package:mrtouride/services/settings_service.dart';
import 'package:mrtouride/services/update_service.dart';
import 'package:mrtouride/widgets/news_section.dart';
import 'package:mrtouride/widgets/update_flow.dart';
import 'package:mrtouride/widgets/ux.dart';

class HomeScreen extends StatefulWidget {
  final void Function(int index)? onSelectTab;
  HomeScreen({super.key, this.onSelectTab});

  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomeScreen> {
  // Live catalog: city covers (internet / creator-uploaded) + latest videos.
  List<Place> places = [];
  List<VideoItem> trending = [];
  bool loading = true;
  String? error;
  bool hasUnseen = false;
  List<NewsItem> news = [];

  /// Personal video picks: real, playable YouTube suggestions seeded by
  /// what this user searched and planned recently.
  List<YtSuggestion> forYou = [];

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
    MediaApi.fetchNews().then((items) {
      if (mounted) setState(() => news = items);
    }).catchError((_) {});
    _loadForYou();
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
      // Bell badge: anything new since this device last looked?
      if (SettingsService.instance.notifications) {
        NotificationService.check().then((n) {
          if (mounted && n != null) setState(() => hasUnseen = true);
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = 'Could not load the catalog. Is the backend running?';
      });
    }
  }

  /// Activity-based seed: last search > last AI chat > general discovery.
  Future<void> _loadForYou() async {
    var seed = 'incredible india travel experience';
    try {
      final prefs = await SharedPreferences.getInstance();
      final recents = prefs.getStringList('search.recent') ?? const [];
      if (recents.isNotEmpty) {
        seed = recents.first;
      } else {
        final chats = prefs.getString('ai.chats');
        if (chats != null) {
          final list = jsonDecode(chats) as List;
          if (list.isNotEmpty) {
            seed = (list.first as Map)['title'] as String? ?? seed;
          }
        }
      }
    } catch (_) {}
    try {
      final m = await MediaApi.searchMedia(seed);
      if (mounted) setState(() => forYou = m.youtube);
    } catch (_) {}
  }

  String _timeAgo(DateTime t) {
    final d = DateTime.now().difference(t.toLocal());
    if (d.inMinutes < 60) return '${d.inMinutes.clamp(1, 59)}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }

  /// Bell modal: the last 7 days of new experiences. Tapping one jumps
  /// straight to the place it was published for.
  Future<void> _openNotifications() async {
    Haptics.tick();
    setState(() => hasUnseen = false);
    NotificationService.markSeen();
    final results = await Future.wait([
      NotificationService.recent(),
      UpdateService.check(),
    ]);
    final items =
        List<AppNotification>.from(results[0] as List<AppNotification>);
    final update = results[1] as UpdateInfo?;
    if (update != null && update.isNewer) {
      items.insert(
          0,
          AppNotification(
            type: 'update',
            title: 'App update v${update.version}: ${update.notes}',
            at: DateTime.now(),
          ));
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: cardBg(context),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                    color: Colors.grey.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                const Icon(Icons.notifications, color: blue, size: 19),
                const SizedBox(width: 8),
                Text('Notifications',
                    style: TextStyle(
                        color: ink(context),
                        fontWeight: FontWeight.bold,
                        fontSize: 16)),
              ],
            ),
            const SizedBox(height: 10),
            if (items.isEmpty)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Center(
                  child: Text("You're all caught up — nothing new this week.",
                      style: TextStyle(color: Colors.grey, fontSize: 13)),
                ),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final n in items)
                      Card(
                        color: pageBg(context),
                        margin: const EdgeInsets.only(bottom: 8),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        child: ListTile(
                          dense: true,
                          leading: CircleAvatar(
                            radius: 16,
                            backgroundColor: switch (n.type) {
                              'reaction' => Colors.pink,
                              'reply' => Colors.teal,
                              'city' => Colors.purple,
                              'update' => Colors.indigo,
                              _ => blue,
                            },
                            child: Icon(
                              switch (n.type) {
                                'reaction' => Icons.favorite,
                                'reply' => Icons.chat_bubble,
                                'city' => Icons.location_city,
                                'update' => Icons.system_update,
                                _ => Icons.fiber_new,
                              },
                              color: white,
                              size: 16,
                            ),
                          ),
                          title: Text(n.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600, fontSize: 13)),
                          subtitle: Text(_timeAgo(n.at),
                              style: const TextStyle(
                                  fontSize: 11, color: Colors.grey)),
                          trailing:
                              const Icon(Icons.chevron_right, color: blue),
                          onTap: () {
                            Navigator.pop(context);
                            _openNotificationTarget(n);
                          },
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Redirect to where the notification came from: place page for new
  /// content, Community for social activity, the updater for new builds.
  void _openNotificationTarget(AppNotification n) {
    Haptics.light();
    switch (n.type) {
      case 'reaction':
      case 'reply':
        widget.onSelectTab?.call(3); // Community
      case 'update':
        UpdateService.check().then((info) {
          if (mounted && info != null && info.isNewer) {
            runUpdateFlow(context, info);
          }
        });
      default:
        final match = places.where((p) => p.citySlug == n.city).toList();
        if (match.isNotEmpty) {
          Navigator.push(
            context,
            MaterialPageRoute(
                builder: (context) => DetailScreen(place: match.first)),
          );
        } else {
          widget.onSelectTab?.call(1); // Explore fallback
        }
    }
  }

  @override
  Widget build(BuildContext context) {
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
                          children: [
                            Expanded(
                              child: Text.rich(
                                TextSpan(
                                  text: 'Hello ',
                                  style: TextStyle(
                                      color: inkSoft(context), fontSize: 17),
                                  children: [
                                    TextSpan(
                                      text: name,
                                      style: const TextStyle(
                                        color: Color(0xFF1E319D),
                                        fontWeight: FontWeight.w800,
                                        fontSize: 18,
                                      ),
                                    ),
                                    const TextSpan(text: ' 👋'),
                                  ],
                                ),
                              ),
                            ),
                            // Notifications bell — new-content inbox.
                            Stack(
                              children: [
                                IconButton(
                                  tooltip: 'Notifications',
                                  icon: Icon(Icons.notifications_none,
                                      color: ink(context)),
                                  onPressed: _openNotifications,
                                ),
                                if (hasUnseen)
                                  Positioned(
                                    right: 10,
                                    top: 10,
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
                            ),
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
                            child: Text(
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
                          onTap: () => widget.onSelectTab?.call(4),
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
                      const SizedBox(height: 26),
                      _sectionHeader('Top trending experiences'),
                      const SizedBox(height: 14),
                      SizedBox(
                        height: 190,
                        child: loading
                            ? const SizedBox.shrink()
                            : trending.isEmpty
                                ? const Center(
                                    child: Text('No experiences yet.',
                                        style: TextStyle(color: Colors.grey)))
                                : _adaptiveRail(
                                    count: trending.length,
                                    minCardWidth: 300,
                                    gap: 14,
                                    builder: (i, w) => Entrance(
                                      index: i,
                                      child:
                                          _trendingCard(trending[i], width: w),
                                    ),
                                  ),
                      ),
                      // Picked for you: real, playable travel videos —
                      // seeded by this user's own searches and plans.
                      if (forYou.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
                          child: Row(
                            children: [
                              const Icon(Icons.play_circle_fill,
                                  size: 17, color: Colors.redAccent),
                              const SizedBox(width: 6),
                              Text('Picked for you',
                                  style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14.5,
                                      color: ink(context))),
                            ],
                          ),
                        ),
                        SizedBox(
                          height: 150,
                          child: ListView.separated(
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            scrollDirection: Axis.horizontal,
                            itemCount: forYou.length,
                            separatorBuilder: (c, i) =>
                                const SizedBox(width: 10),
                            itemBuilder: (context, i) => InkWell(
                              borderRadius: BorderRadius.circular(14),
                              onTap: () {
                                Haptics.light();
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => NewsWebViewPage(
                                        title: forYou[i].title,
                                        url: forYou[i].url),
                                  ),
                                );
                              },
                              child: SizedBox(
                                width: 210,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Stack(
                                      alignment: Alignment.center,
                                      children: [
                                        ClipRRect(
                                          borderRadius:
                                              BorderRadius.circular(12),
                                          child: Image.network(
                                            forYou[i].thumbnail,
                                            width: 210,
                                            height: 110,
                                            fit: BoxFit.cover,
                                            errorBuilder: (c, e, s) =>
                                                Container(
                                              width: 210,
                                              height: 110,
                                              color: Colors.black12,
                                            ),
                                          ),
                                        ),
                                        Container(
                                          padding: const EdgeInsets.all(6),
                                          decoration: const BoxDecoration(
                                            color: Colors.black45,
                                            shape: BoxShape.circle,
                                          ),
                                          child: const Icon(Icons.play_arrow,
                                              color: Colors.white, size: 22),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 5),
                                    Text(forYou[i].title,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 12,
                                            height: 1.3)),
                                  ],
                                ),
                              ),
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
