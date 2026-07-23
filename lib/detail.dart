import 'package:flutter/material.dart';

import 'ar_view.dart';
import 'constant.dart';
import 'experience_player.dart';
import 'models/place.dart';
import 'news_webview.dart';
import 'services/auth_api.dart';
import 'services/haptic_service.dart';
import 'services/media_api.dart';
import 'widgets/hashtag_text.dart';
import 'widgets/ux.dart';

/// Place detail page — fully dynamic: hero, about and live experience videos
/// all come from the tapped [Place] and its city's backend catalog.
class DetailScreen extends StatefulWidget {
  final Place place;
  const DetailScreen({super.key, required this.place});

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  List<VideoItem> videos = [];
  List<YtSuggestion> ytPicks = [];
  late double rating = place.rating;
  late int ratingCount = place.ratingCount;
  int myStars = 0;
  bool ratingBusy = false;
  List<VideoItem> suggestions = [];
  List<Place> morePlaces = [];
  CityWeather? weather;
  bool loadingVideos = true;
  String? videosError;

  List<PlaceComment> comments = [];
  final _commentCtl = TextEditingController();
  int? _replyingTo;
  String? _replyingToName;
  bool _postingComment = false;
  int _commentsShown = 5; // paginate: reveal 10 more each tap

  Place get place => widget.place;

  @override
  void dispose() {
    _commentCtl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadVideos();
    _loadRating();
    _loadComments();
    // Live temperature + ML suggestions load independently — never block
    // the page on them.
    MediaApi.fetchWeather(place.citySlug).then((w) {
      if (mounted) setState(() => weather = w);
    }).catchError((_) {});
    MediaApi.fetchSuggestions(place.citySlug).then((s) {
      if (mounted) setState(() => suggestions = s);
    }).catchError((_) {});
    // Real, playable picks for THIS place (server-cached 30 min).
    MediaApi.searchMedia('${place.title} ${place.location}').then((m) {
      if (mounted) setState(() => ytPicks = m.youtube);
    }).catchError((_) {});
  }

  /// Authoritative rating so it never shows stale/blank and remembers the
  /// user's own stars across visits.
  Future<void> _loadRating() async {
    try {
      final (avg, count, mine) = await MediaApi.placeRating(place.citySlug);
      if (!mounted) return;
      setState(() {
        rating = avg;
        ratingCount = count;
        myStars = mine;
      });
    } catch (_) {}
  }

  Future<void> _loadComments() async {
    try {
      final list = await MediaApi.placeComments(place.citySlug);
      if (mounted) setState(() => comments = list);
    } catch (_) {}
  }

  Future<void> _postComment() async {
    final text = _commentCtl.text.trim();
    if (text.isEmpty) return;
    if (AuthApi.currentUser == null) {
      newSnackBar(context, title: 'Sign in to comment.');
      return;
    }
    setState(() => _postingComment = true);
    try {
      await MediaApi.addPlaceComment(place.citySlug, text,
          parentId: _replyingTo);
      _commentCtl.clear();
      setState(() {
        _replyingTo = null;
        _replyingToName = null;
        _postingComment = false;
      });
      Haptics.medium();
      await _loadComments();
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() => _postingComment = false);
      newSnackBar(context, title: e.message);
    }
  }

  Future<void> _deleteComment(PlaceComment c) async {
    try {
      await MediaApi.deletePlaceComment(c.id);
      if (mounted) setState(() => comments.removeWhere((x) => x.id == c.id));
    } on AuthException catch (e) {
      if (mounted) newSnackBar(context, title: e.message);
    }
  }

  Future<void> _loadVideos() async {
    try {
      final results = await Future.wait([
        MediaApi.fetchVideos(place.citySlug, limit: 10),
        MediaApi.fetchCities(),
      ]);
      if (!mounted) return;
      setState(() {
        videos = (results[0] as VideoPage)
            .videos
            .where((v) => !v.isProcessing)
            .toList();
        morePlaces = [
          for (final c in results[1] as List<City>)
            if (c.slug != place.citySlug) Place.fromCity(c)
        ];
        loadingVideos = false;
      });
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        loadingVideos = false;
        videosError = e.message;
      });
    }
  }

  /// No MR/VR capture exists for this place yet — tell the user kindly and
  /// log the interest so creators get the signal.
  Future<void> _mrvrNotAvailable() async {
    // Fire-and-forget: the request lands in the feedback inbox creators see.
    MediaApi.sendFeedback(
      email: AuthApi.currentUser?.email,
      message: 'MR/VR requested for ${place.title} (${place.citySlug})',
    ).catchError((_) => '');
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        icon: const Icon(Icons.view_in_ar, color: Colors.purple, size: 36),
        title: const Text('MR/VR coming soon'),
        content: Text(
          'No MR/VR experience is available for ${place.title} yet. '
          "We've let our creators know you want one — it will appear here "
          'the moment it lands.',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 14, height: 1.5),
        ),
        actions: [
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.purple),
            onPressed: () => Navigator.pop(context),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  /// Minimal "share your experience" rater — five tappable stars.
  Widget _rateRow() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.amber.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              myStars > 0
                  ? 'Thanks for rating!'
                  : ratingCount == 0
                      ? 'Be the first to rate this place'
                      : 'Share your experience',
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: ink(context)),
            ),
          ),
          if (ratingBusy)
            const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.amber))
          else
            for (var i = 1; i <= 5; i++)
              InkWell(
                customBorder: const CircleBorder(),
                onTap: () => _rate(i),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: AnimatedScale(
                    scale: myStars >= i ? 1.15 : 1,
                    duration: const Duration(milliseconds: 180),
                    child: Icon(
                      myStars >= i ? Icons.star : Icons.star_border,
                      color: Colors.amber,
                      size: 22,
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }

  Future<void> _rate(int stars) async {
    if (AuthApi.currentUser == null) {
      newSnackBar(context, title: 'Sign in to rate this place.');
      return;
    }
    Haptics.level(stars / 5);
    setState(() {
      myStars = stars;
      ratingBusy = true;
    });
    try {
      final (avg, count) = await MediaApi.ratePlace(place.citySlug, stars);
      if (!mounted) return;
      setState(() {
        rating = avg;
        ratingCount = count;
        ratingBusy = false;
      });
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() => ratingBusy = false);
      newSnackBar(context, title: e.message);
    }
  }

  Widget _heroImage() {
    if (!place.isNetworkImage) {
      return Image.asset(place.image, fit: BoxFit.cover);
    }
    // High-res internet / creator-uploaded cover.
    return Image.network(
      place.image,
      fit: BoxFit.cover,
      loadingBuilder: (context, child, progress) => progress == null
          ? child
          : Container(
              color: const Color(0xFF0b2233),
              child: const Center(
                  child: CircularProgressIndicator(color: Colors.white54)),
            ),
      errorBuilder: (context, error, stack) =>
          Container(color: const Color(0xFF0b2233)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: pageBg(context),
      body: CustomScrollView(
        slivers: [
          // Collapsing hero header
          SliverAppBar(
            expandedHeight: 320,
            pinned: true,
            backgroundColor: const Color(0xFF052933),
            foregroundColor: Colors.white,
            flexibleSpace: FlexibleSpaceBar(
              titlePadding:
                  const EdgeInsets.only(left: 52, bottom: 14, right: 16),
              title: Text(place.title,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold)),
              background: Stack(
                fit: StackFit.expand,
                children: [
                  _heroImage(),
                  // Legibility gradient
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.65),
                        ],
                        stops: const [0, 0.55, 1],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // About card
                  Entrance(
                    child: Card(
                      color: cardBg(context),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18)),
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Wrap: rating flows to the next line on narrow
                            // screens instead of overflowing the card.
                            Wrap(
                              spacing: 10,
                              runSpacing: 6,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.location_on,
                                        color: blue, size: 18),
                                    const SizedBox(width: 4),
                                    Text(place.location,
                                        style: const TextStyle(
                                            color: Colors.grey, fontSize: 13)),
                                  ],
                                ),
                                if (weather != null)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: lightBlue.withValues(alpha: 0.18),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Text(
                                      '${weather!.temperatureC.round()}°C'
                                      ' · ${weather!.description}',
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: brandInk(context),
                                          fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                if (ratingCount > 0)
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      for (var i = 0; i < 5; i++)
                                        Icon(
                                            i < rating.round()
                                                ? Icons.star
                                                : Icons.star_border,
                                            color: Colors.amber,
                                            size: 16),
                                      const SizedBox(width: 4),
                                      Text(
                                          '${rating.toStringAsFixed(1)}'
                                          ' ($ratingCount)',
                                          style: const TextStyle(
                                              color: Colors.grey,
                                              fontSize: 12)),
                                    ],
                                  ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Text(
                              place.description,
                              textAlign: TextAlign.justify,
                              style: TextStyle(
                                  fontSize: 14,
                                  height: 1.5,
                                  color: ink(context)),
                            ),
                            const SizedBox(height: 14),
                            _rateRow(),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Single action: MR/VR. Feel controls live inside each
                  // experience (creator-configured in the player).
                  Entrance(
                    index: 1,
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.purple,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                        ),
                        onPressed: place.modelUrl != null
                            ? () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => ArViewPage(
                                      title: '${place.title} — MR/VR',
                                      modelSrc: place.modelUrl,
                                    ),
                                  ),
                                )
                            : _mrvrNotAvailable,
                        icon: const Icon(Icons.view_in_ar),
                        label: const Text('MR/VR'),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  // Live experience videos
                  _sectionTitle('Experience videos'),
                  if (loadingVideos)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child:
                          Center(child: CircularProgressIndicator(color: blue)),
                    )
                  else if (videosError != null)
                    Text(videosError!,
                        style: const TextStyle(color: red, fontSize: 13))
                  else if (videos.isEmpty)
                    const Text('No experiences published yet.',
                        style: TextStyle(color: Colors.grey))
                  else
                    for (var i = 0; i < videos.length; i++)
                      Entrance(index: i + 2, child: _videoCard(videos[i])),
                  const SizedBox(height: 20),
                  // Real, playable picks for this place.
                  if (ytPicks.isNotEmpty) ...[
                    _sectionTitle('Picked for you'),
                    SizedBox(
                      height: 216,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: ytPicks.length,
                        separatorBuilder: (c, i) => const SizedBox(width: 12),
                        itemBuilder: (context, i) => InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => NewsWebViewPage(
                                  title: ytPicks[i].title, url: ytPicks[i].url),
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
                                        ytPicks[i].thumbnail.replaceFirst(
                                            'mqdefault', 'hqdefault'),
                                        width: 300,
                                        height: 170,
                                        fit: BoxFit.cover,
                                        errorBuilder: (c, e, st) => Container(
                                            width: 300,
                                            height: 170,
                                            color: Colors.black12),
                                      ),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.all(9),
                                      decoration: const BoxDecoration(
                                          color: Colors.black45,
                                          shape: BoxShape.circle),
                                      child: const Icon(Icons.play_arrow,
                                          color: Colors.white, size: 28),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Flexible(
                                  child: Text(ytPicks[i].title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 13)),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],
                  // ML-based cross-city recommendations
                  if (suggestions.isNotEmpty) ...[
                    _sectionTitle('You may also feel · ML picks'),
                    for (final s in suggestions) _videoCard(s),
                    const SizedBox(height: 20),
                  ],
                  // Ratings & discussion — community-style threads.
                  const SizedBox(height: 8),
                  _sectionTitle('Ratings & comments'),
                  _commentsSection(),
                  const SizedBox(height: 20),
                  // Other destinations (dynamic — excludes this one)
                  _sectionTitle('View more places'),
                  _morePlaces(),
                  const SizedBox(height: 110),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(text,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
    );
  }

  Widget _videoCard(VideoItem video) {
    return Card(
      color: cardBg(context),
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ListTile(
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF1E319D), Color(0xFF3CEBFF)],
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(Icons.play_arrow, color: white, size: 26),
        ),
        title: Text(video.title,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          video.hapticsReady ? 'Video · Feel · Sound' : 'Video · Sound',
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
        trailing: const Icon(Icons.chevron_right, color: blue),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
              builder: (context) => ExperiencePlayerPage(video: video)),
        ),
      ),
    );
  }

  Widget _morePlaces() {
    if (morePlaces.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 200,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: morePlaces.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, i) {
          final p = morePlaces[i];
          return Springy(
            haptic: 'light',
            onTap: () => Navigator.pushReplacement(
              context,
              MaterialPageRoute(builder: (context) => DetailScreen(place: p)),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: SizedBox(
                width: 150,
                height: 200,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    p.isNetworkImage
                        ? Image.network(p.image,
                            fit: BoxFit.cover,
                            errorBuilder: (c, e, s) =>
                                Container(color: Colors.black12))
                        : Image.asset(p.image, fit: BoxFit.cover),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        color: Colors.black.withValues(alpha: 0.45),
                        child: Text(
                          p.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _commentsSection() {
    final tops = comments.where((c) => c.parentId == null).toList();
    final shown = tops.take(_commentsShown).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (tops.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text('No comments yet — start the conversation.',
                style: TextStyle(color: inkSoft(context), fontSize: 13)),
          )
        else ...[
          for (final c in shown) ...[
            _commentTile(c),
            for (final r in comments.where((x) => x.parentId == c.id))
              Padding(
                padding: const EdgeInsets.only(left: 34),
                child: _commentTile(r, inThread: true),
              ),
          ],
          if (tops.length > shown.length)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () =>
                    setState(() => _commentsShown += 10),
                icon: const Icon(Icons.expand_more, size: 18),
                label: Text(
                    'View ${tops.length - shown.length} more comment'
                    '${tops.length - shown.length == 1 ? '' : 's'}',
                    style: TextStyle(color: brandInk(context))),
              ),
            ),
        ],
        const SizedBox(height: 8),
        if (_replyingToName != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                Text('Replying to $_replyingToName',
                    style: TextStyle(
                        fontSize: 12, color: inkSoft(context))),
                const SizedBox(width: 6),
                InkWell(
                  onTap: () => setState(() {
                    _replyingTo = null;
                    _replyingToName = null;
                  }),
                  child: const Icon(Icons.close, size: 14, color: Colors.grey),
                ),
              ],
            ),
          ),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _commentCtl,
                style: TextStyle(color: ink(context)),
                minLines: 1,
                maxLines: 3,
                decoration: InputDecoration(
                  hintText: _replyingToName != null
                      ? 'Write a reply…'
                      : 'Add a comment…',
                  filled: true,
                  fillColor: cardBg(context),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none),
                ),
              ),
            ),
            const SizedBox(width: 8),
            _postingComment
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : IconButton(
                    icon: Icon(Icons.send_rounded, color: brandInk(context)),
                    onPressed: _postComment,
                  ),
          ],
        ),
      ],
    );
  }

  Widget _commentTile(PlaceComment c, {bool inThread = false}) {
    final mine = c.authorId == AuthApi.currentUser?.id;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: inThread ? 12 : 15,
            backgroundColor: c.byCreator ? Colors.purple : blue,
            child: Text(
              c.authorName.isNotEmpty ? c.authorName[0].toUpperCase() : '?',
              style: TextStyle(
                  color: Colors.white, fontSize: inThread ? 10 : 12),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(c.authorName,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: inkSoft(context),
                              fontWeight: FontWeight.w800,
                              fontSize: 12)),
                    ),
                    if (c.byCreator)
                      const Padding(
                        padding: EdgeInsets.only(left: 4),
                        child: Text('✦',
                            style: TextStyle(
                                color: Colors.purple, fontSize: 11)),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                HashtagText(c.body,
                    style: TextStyle(
                        color: ink(context), fontSize: 13.5, height: 1.4)),
                Row(
                  children: [
                    if (!inThread)
                      TextButton(
                        style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            minimumSize: const Size(0, 30),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                        onPressed: () => setState(() {
                          _replyingTo = c.id;
                          _replyingToName = c.authorName;
                        }),
                        child: Text('Reply',
                            style: TextStyle(
                                fontSize: 12, color: brandInk(context))),
                      ),
                    if (mine)
                      TextButton(
                        style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            minimumSize: const Size(0, 30),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                        onPressed: () => _deleteComment(c),
                        child: const Text('Delete',
                            style: TextStyle(fontSize: 12, color: Colors.grey)),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _horizontalGallery(List<String> images,
      {required double width, required double height}) {
    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: images.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, i) => ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Image.asset(images[i],
              width: width, height: height, fit: BoxFit.cover),
        ),
      ),
    );
  }
}
