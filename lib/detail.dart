import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'ar_view.dart';
import 'constant.dart';
import 'experience_player.dart';
import 'models/place.dart';
import 'services/auth_api.dart' show AuthException;
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
                            Row(
                              children: [
                                const Icon(Icons.location_on,
                                    color: blue, size: 18),
                                const SizedBox(width: 4),
                                Text(place.location,
                                    style: const TextStyle(
                                        color: Colors.grey, fontSize: 13)),
                                if (weather != null) ...[
                                  const SizedBox(width: 10),
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
                                ],
                                const Spacer(),
                                Row(children: [
                                  for (var i = 0; i < 5; i++)
                                    Icon(
                                        i < place.rating.round()
                                            ? Icons.star
                                            : Icons.star_border,
                                        color: Colors.amber,
                                        size: 16),
                                  const SizedBox(width: 4),
                                  Text(place.rating.toStringAsFixed(1),
                                      style: const TextStyle(
                                          color: Colors.grey, fontSize: 12)),
                                ]),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Text(
                              place.description,
                              textAlign: TextAlign.justify,
                              style: const TextStyle(
                                  fontSize: 14,
                                  height: 1.5,
                                  color: Colors.black87),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Actions
                  Entrance(
                    index: 1,
                    child: Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: Colors.purple,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14)),
                            ),
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => ArViewPage(
                                      title: '${place.title} — MR/VR'),
                                ),
                              );
                            },
                            icon: const Icon(Icons.view_in_ar),
                            label: const Text('MR/VR'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.purple,
                              side: const BorderSide(color: Colors.purple),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14)),
                            ),
                            onPressed: () {
                              launchUrl(Uri.parse(
                                  'https://developer.bhaptics.com/application/upSOC6r1v4rRJgcFauTL'));
                            },
                            icon: const Icon(Icons.vibration),
                            label: const Text('Feel It'),
                          ),
                        ),
                      ],
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
