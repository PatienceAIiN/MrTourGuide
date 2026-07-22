import 'package:flutter/material.dart';

import 'ar_view.dart';
import 'constant.dart';
import 'experience_player.dart';
import 'models/place.dart';
import 'services/auth_api.dart';
import 'services/haptic_service.dart';
import 'services/media_api.dart';
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
  late double rating = place.rating;
  late int ratingCount = place.ratingCount;
  int myStars = 0;
  bool ratingBusy = false;
  List<VideoItem> suggestions = [];
  List<Place> morePlaces = [];
  CityWeather? weather;
  bool loadingVideos = true;
  String? videosError;

  Place get place => widget.place;

  @override
  void initState() {
    super.initState();
    _loadVideos();
    // Live temperature + ML suggestions load independently — never block
    // the page on them.
    MediaApi.fetchWeather(place.citySlug).then((w) {
      if (mounted) setState(() => weather = w);
    }).catchError((_) {});
    MediaApi.fetchSuggestions(place.citySlug).then((s) {
      if (mounted) setState(() => suggestions = s);
    }).catchError((_) {});
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
                                      style: const TextStyle(
                                          fontSize: 11,
                                          color: Color(0xFF1E319D),
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
                  // Vlogs
                  _sectionTitle('Top trending vlogs'),
                  _horizontalGallery(const [
                    'assets/image/tajmahalvlog1.png',
                    'assets/image/tajmahalvlog2.png',
                    'assets/image/tajmahalvlog3.png',
                  ], width: 300, height: 170),
                  const SizedBox(height: 20),
                  // ML-based cross-city recommendations
                  if (suggestions.isNotEmpty) ...[
                    _sectionTitle('You may also feel · ML picks'),
                    for (final s in suggestions) _videoCard(s),
                    const SizedBox(height: 20),
                  ],
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
