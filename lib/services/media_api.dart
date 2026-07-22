import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'api_base.dart';
import 'auth_api.dart' show AuthApi, AuthException;

class City {
  final String slug;
  final String name;
  final int videoCount;

  /// High-res cover (internet URL or creator-uploaded /files/... path).
  final String? coverUrl;
  final String location;
  final String description;
  final double rating;

  /// 3D model (.glb URL) for the MR/VR view, when a creator has provided one.
  final String? modelUrl;

  /// How many users have rated this place (0 = show no stars yet).
  final int ratingCount;

  const City({
    required this.slug,
    required this.name,
    required this.videoCount,
    this.coverUrl,
    this.location = '',
    this.description = '',
    this.rating = 0,
    this.modelUrl,
    this.ratingCount = 0,
  });

  /// Absolute cover URL (creator uploads are backend-relative).
  String? get absoluteCoverUrl {
    final c = coverUrl;
    if (c == null) return null;
    return c.startsWith('http') ? c : '$apiBase$c';
  }

  factory City.fromJson(Map<String, dynamic> json) => City(
        ratingCount: json['ratingCount'] as int? ?? 0,
        slug: json['slug'] as String,
        name: json['name'] as String,
        videoCount: json['videoCount'] as int,
        coverUrl: json['coverUrl'] as String?,
        location: json['location'] as String? ?? '',
        description: json['description'] as String? ?? '',
        rating: (json['rating'] as num?)?.toDouble() ?? 0,
        modelUrl: json['modelUrl'] as String?,
      );
}

/// Creator-set experience configuration for a video.
class ExperienceConfig {
  final bool haptics;
  final bool sound;
  final double intensity;

  /// 'normal' | 'vr' (360°) | 'mr' — set by the creator at upload.
  final String kind;
  final bool autoplay;

  /// 'auto' — ML builds the haptic track; 'perframe' — creator fine-tunes
  /// the feel frame by frame after processing.
  final String feelMode;

  /// Creator-set location — makes state/country searches find this video.
  final String country;
  final String state;
  final String cityName;

  const ExperienceConfig({
    this.haptics = true,
    this.sound = true,
    this.intensity = 0.7,
    this.kind = 'normal',
    this.autoplay = true,
    this.feelMode = 'auto',
    this.country = '',
    this.state = '',
    this.cityName = '',
  });

  ExperienceConfig copyWith({
    bool? haptics,
    bool? sound,
    double? intensity,
    String? kind,
    bool? autoplay,
    String? feelMode,
    String? country,
    String? state,
    String? cityName,
  }) =>
      ExperienceConfig(
        haptics: haptics ?? this.haptics,
        sound: sound ?? this.sound,
        intensity: intensity ?? this.intensity,
        kind: kind ?? this.kind,
        autoplay: autoplay ?? this.autoplay,
        feelMode: feelMode ?? this.feelMode,
        country: country ?? this.country,
        state: state ?? this.state,
        cityName: cityName ?? this.cityName,
      );

  factory ExperienceConfig.fromJson(Map<String, dynamic>? json) =>
      ExperienceConfig(
        haptics: json?['haptics'] as bool? ?? true,
        sound: json?['sound'] as bool? ?? true,
        intensity: (json?['intensity'] as num?)?.toDouble() ?? 0.7,
        kind: json?['kind'] as String? ?? 'normal',
        autoplay: json?['autoplay'] as bool? ?? true,
        feelMode: json?['feelMode'] as String? ?? 'auto',
        country: json?['country'] as String? ?? '',
        state: json?['state'] as String? ?? '',
        cityName: json?['cityName'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'haptics': haptics,
        'sound': sound,
        'intensity': intensity,
        'kind': kind,
        'autoplay': autoplay,
        'feelMode': feelMode,
        'country': country,
        'state': state,
        'cityName': cityName,
      };
}

class VideoItem {
  final int id;
  final String city;
  final String title;
  final String filename;
  final String mime;
  final int sizeBytes;

  /// Whether the ML pipeline has produced a haptic track for this video yet.
  /// (Haptics adapt phone vibration to the video's sound/touch content in
  /// the MR/VR experience — processing happens server-side.)
  final bool hapticsReady;

  /// 'processing' while the ML pipeline trims/enhances, then 'ready'.
  final String status;
  final ExperienceConfig config;

  /// Poster frame extracted by the pipeline (backend-relative), if any.
  final String? thumbUrl;
  final DateTime uploadedAt;
  final String url;

  /// Per-second feel intensities (0..1) from the ML audio-energy analysis —
  /// background sound, music and ambience drive light→heavy haptics.
  final List<double> hapticTrack;

  const VideoItem({
    required this.id,
    required this.city,
    required this.title,
    required this.filename,
    required this.mime,
    required this.sizeBytes,
    required this.hapticsReady,
    required this.status,
    required this.config,
    this.thumbUrl,
    required this.uploadedAt,
    required this.url,
    this.hapticTrack = const [],
  });

  bool get isProcessing => status == 'processing';

  String? get absoluteThumbUrl => thumbUrl == null ? null : '$apiBase$thumbUrl';

  factory VideoItem.fromJson(Map<String, dynamic> json) => VideoItem(
        hapticTrack: [
          for (final v in ((json['haptics'] as Map<String, dynamic>?)?['track']
                  as List? ??
              const []))
            (v as num).toDouble()
        ],
        id: json['id'] as int,
        city: json['city'] as String,
        title: json['title'] as String,
        filename: json['filename'] as String,
        mime: json['mime'] as String,
        sizeBytes: json['sizeBytes'] as int,
        hapticsReady: json['hapticsReady'] as bool,
        status: json['status'] as String? ?? 'ready',
        config:
            ExperienceConfig.fromJson(json['config'] as Map<String, dynamic>?),
        thumbUrl: json['thumbUrl'] as String?,
        uploadedAt: DateTime.parse(json['uploadedAt'] as String),
        url: json['url'] as String,
      );

  /// Absolute URL the video can be streamed from.
  String get absoluteUrl => '$apiBase$url';
}

class VideoPage {
  final List<VideoItem> videos;
  final bool hasMore;
  const VideoPage({required this.videos, required this.hasMore});
}

class CityWeather {
  final double temperatureC;
  final String description;
  const CityWeather({required this.temperatureC, required this.description});
}

class AiOverview {
  final String overview;
  final String model;

  /// Places available on the platform that match the query — shown as
  /// suggestion cards with a redirect into the experience.
  final List<City> places;
  const AiOverview(
      {required this.overview, required this.model, this.places = const []});
}

/// AI plan + matching on-platform places.
class ItineraryResult {
  final String plan;
  final List<City> places;
  const ItineraryResult({required this.plan, this.places = const []});
}

/// An AI plan saved under the user's account.
class SavedItinerary {
  final int id;
  final String title;
  final String query;
  final String plan;
  final DateTime createdAt;
  const SavedItinerary({
    required this.id,
    required this.title,
    required this.query,
    required this.plan,
    required this.createdAt,
  });

  factory SavedItinerary.fromJson(Map<String, dynamic> json) => SavedItinerary(
        id: json['id'] as int,
        title: json['title'] as String,
        query: json['query'] as String? ?? '',
        plan: json['plan'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
      );
}

/// Travel news headline (advisories, precautions, new destinations).
class NewsItem {
  final String title;
  final String url;
  final String source;
  final String published;

  /// Article cover (og:image), when the source provides one.
  final String? image;
  const NewsItem({
    required this.title,
    required this.url,
    required this.source,
    required this.published,
    this.image,
  });

  factory NewsItem.fromJson(Map<String, dynamic> json) => NewsItem(
        title: json['title'] as String? ?? '',
        url: json['url'] as String? ?? '',
        source: json['source'] as String? ?? '',
        published: json['published'] as String? ?? '',
        image: json['image'] as String?,
      );
}

/// Shared travel-news card: cover image + headline, opens the ad-blocked
/// in-app reader.

class YtSuggestion {
  final String title;
  final String thumbnail;
  final String url;
  const YtSuggestion(
      {required this.title, required this.thumbnail, required this.url});
}

/// Photos + YouTube suggestions for a search query.
class MediaSuggestions {
  final List<String> images;
  final List<YtSuggestion> youtube;
  const MediaSuggestions({required this.images, required this.youtube});

  bool get isEmpty => images.isEmpty && youtube.isEmpty;
}

class SearchResult {
  final List<City> cities;
  final List<VideoItem> videos;
  const SearchResult({required this.cities, required this.videos});

  bool get isEmpty => cities.isEmpty && videos.isEmpty;
}

class MediaApi {
  static Future<SearchResult> search(String query) async {
    final decoded = await _get('/search?q=${Uri.encodeQueryComponent(query)}');
    return SearchResult(
      cities: [
        for (final c in decoded['cities'] as List)
          City.fromJson(c as Map<String, dynamic>)
      ],
      videos: [
        for (final v in decoded['videos'] as List)
          VideoItem.fromJson(v as Map<String, dynamic>)
      ],
    );
  }

  static Future<List<City>> fetchCities({bool mine = false}) async {
    final me = AuthApi.currentUser?.id;
    final decoded =
        await _get('/cities${mine && me != null ? '?ownerId=$me' : ''}');
    return [
      for (final c in decoded['cities'] as List)
        City.fromJson(c as Map<String, dynamic>)
    ];
  }

  /// Latest ready videos across all cities (home trending rail).
  static Future<List<VideoItem>> fetchTrending({int limit = 6}) async {
    final decoded = await _get('/videos/trending?limit=$limit');
    return [
      for (final v in decoded['videos'] as List)
        VideoItem.fromJson(v as Map<String, dynamic>)
    ];
  }

  /// Photos (Wikimedia) + YouTube suggestions for a search query.
  static Future<MediaSuggestions> searchMedia(String query) async {
    final decoded =
        await _get('/search/media?q=${Uri.encodeQueryComponent(query)}');
    return MediaSuggestions(
      images: [for (final i in decoded['images'] as List) i as String],
      youtube: [
        for (final y in decoded['youtube'] as List)
          YtSuggestion(
            title: y['title'] as String,
            thumbnail: y['thumbnail'] as String,
            url: y['url'] as String,
          )
      ],
    );
  }

  /// AI itinerary plan (backend → Groq with web search). Pass [history]
  /// (prior {role, content} turns) so follow-ups revise the same plan.
  static Future<ItineraryResult> aiItinerary(String query,
      {List<Map<String, String>> history = const []}) async {
    final decoded = await _postJson('/ai/itinerary', {
      'query': query,
      if (history.isNotEmpty) 'history': history,
    });
    return ItineraryResult(
      plan: decoded['plan'] as String,
      places: _parsePlaces(decoded['places']),
    );
  }

  static List<City> _parsePlaces(Object? raw) => [
        for (final p in (raw as List? ?? const []))
          City.fromJson(p as Map<String, dynamic>)
      ];

  /// Save an AI plan under the user's account ("Save as itinerary").
  static Future<void> saveItinerary({
    required int userId,
    required String title,
    required String query,
    required String plan,
  }) =>
      _postJson('/itineraries',
          {'userId': userId, 'title': title, 'query': query, 'plan': plan});

  /// The user's saved itineraries, newest first.
  static Future<List<SavedItinerary>> fetchItineraries(int userId) async {
    final decoded = await _get('/itineraries?userId=$userId');
    return [
      for (final i in decoded['itineraries'] as List)
        SavedItinerary.fromJson(i as Map<String, dynamic>)
    ];
  }

  /// Edit a saved itinerary's title and/or plan (owner only).
  static Future<void> updateItinerary({
    required int id,
    required int userId,
    String? title,
    String? plan,
  }) =>
      _postJson('/itineraries/$id/update', {
        'userId': userId,
        if (title != null) 'title': title,
        if (plan != null) 'plan': plan,
      });

  /// Permanently deletes the signed-in user's account and data.
  static Future<void> deleteAccount(int userId) =>
      _postJson('/users/delete-account', {'userId': userId});

  static Future<void> deleteItinerary({required int id, required int userId}) =>
      _postJson('/itineraries/$id/delete', {'userId': userId});

  /// Minimal AI overview for a search query (backend → Groq + web search).
  static Future<AiOverview> aiSearch(String query) async {
    final decoded = await _postJson('/ai/search', {'query': query});
    return AiOverview(
      overview: decoded['overview'] as String,
      model: decoded['model'] as String? ?? 'groq',
      places: _parsePlaces(decoded['places']),
    );
  }

  /// Live temperature for a city (backend proxies Open-Meteo).
  static Future<CityWeather> fetchWeather(String city) async {
    final decoded = await _get('/cities/$city/weather');
    return CityWeather(
      temperatureC: (decoded['temperatureC'] as num).toDouble(),
      description: decoded['description'] as String,
    );
  }

  /// ML-based cross-city suggestions ("You may also feel...").
  static Future<List<VideoItem>> fetchSuggestions(String excludeCity,
      {int limit = 4}) async {
    final decoded =
        await _get('/videos/suggest?city=$excludeCity&limit=$limit');
    return [
      for (final v in decoded['videos'] as List)
        VideoItem.fromJson(v as Map<String, dynamic>)
    ];
  }

  static Future<VideoPage> fetchVideos(
    String city, {
    int offset = 0,
    int limit = 5,
    bool mine = false,
  }) async {
    final me = AuthApi.currentUser?.id;
    final decoded = await _get('/videos?city=$city&offset=$offset'
        '&limit=$limit${mine && me != null ? '&mine=1&userId=$me' : ''}');
    return VideoPage(
      videos: [
        for (final v in decoded['videos'] as List)
          VideoItem.fromJson(v as Map<String, dynamic>)
      ],
      hasMore: decoded['hasMore'] as bool,
    );
  }

  static Future<VideoItem> uploadVideo({
    required String city,
    required String title,
    required String filename,
    Uint8List? bytes,
    String? filePath,
  }) async {
    final uri = Uri.parse('$apiBase/upload').replace(queryParameters: {
      'city': city,
      'title': title,
      'filename': filename,
      'userId': '${AuthApi.currentUser?.id ?? ''}',
    });
    late http.Response response;
    try {
      if (filePath != null) {
        // Stream from disk — large phone videos never sit in RAM.
        final file = File(filePath);
        final req = http.StreamedRequest('POST', uri)
          ..headers['Content-Type'] = 'application/octet-stream'
          ..contentLength = await file.length();
        file.openRead().listen(
              req.sink.add,
              onDone: req.sink.close,
              onError: (Object e) => req.sink.close(),
              cancelOnError: true,
            );
        final streamed = await req.send().timeout(const Duration(minutes: 15));
        response = await http.Response.fromStream(streamed);
      } else {
        response = await http
            .post(uri,
                headers: {'Content-Type': 'application/octet-stream'},
                body: bytes)
            .timeout(const Duration(minutes: 15));
      }
    } catch (_) {
      throw const AuthException(
          'Cannot reach the media server. Is the backend running on port 8080?');
    }
    final decoded = _decode(response.body);
    if (response.statusCode == 201) {
      return VideoItem.fromJson(decoded['video'] as Map<String, dynamic>);
    }
    throw AuthException(decoded['error'] as String? ?? 'Upload failed.');
  }

  /// Creator: persist per-video experience settings (owner only).
  static Future<VideoItem> updateConfig(
      int videoId, ExperienceConfig config) async {
    final decoded = await _postJson('/videos/$videoId/config',
        {...config.toJson(), 'userId': AuthApi.currentUser?.id});
    return VideoItem.fromJson(decoded['video'] as Map<String, dynamic>);
  }

  /// Rate a place 1-5 stars (one per user; re-rating updates it).
  /// Returns the fresh average + count.
  static Future<(double, int)> ratePlace(String slug, int stars) async {
    final decoded = await _postJson('/cities/$slug/rate',
        {'userId': AuthApi.currentUser?.id, 'stars': stars});
    return (
      (decoded['rating'] as num).toDouble(),
      decoded['ratingCount'] as int
    );
  }

  /// Travel news: precautions, advisories and fresh ideas (server-cached).
  static Future<List<NewsItem>> fetchNews() async {
    final decoded = await _get('/news');
    return [
      for (final n in decoded['items'] as List)
        NewsItem.fromJson(n as Map<String, dynamic>)
    ];
  }

  /// Reverse geocode device coordinates → country/state/city.
  static Future<(String, String, String)> geoReverse(
      double lat, double lon) async {
    final decoded = await _get('/geo/reverse?lat=$lat&lon=$lon');
    return (
      decoded['country'] as String? ?? '',
      decoded['state'] as String? ?? '',
      decoded['city'] as String? ?? '',
    );
  }

  /// Creator enrolls a new place on the platform.
  static Future<void> addCity({
    required String name,
    required String location,
    String description = '',
  }) =>
      _postJson('/cities', {
        'userId': AuthApi.currentUser?.id,
        'name': name,
        'location': location,
        'description': description,
      });

  /// Creator: set a custom thumbnail for an owned video (compressed
  /// server-side, like YouTube Studio).
  static Future<VideoItem> uploadThumbnail({
    required int videoId,
    required String filename,
    required Uint8List bytes,
  }) async {
    final uri = Uri.parse('$apiBase/videos/$videoId/thumbnail')
        .replace(queryParameters: {
      'filename': filename,
      'userId': '${AuthApi.currentUser?.id ?? ''}',
    });
    late http.Response response;
    try {
      response = await http
          .post(uri,
              headers: {'Content-Type': 'application/octet-stream'},
              body: bytes)
          .timeout(const Duration(minutes: 2));
    } catch (_) {
      throw const AuthException('Could not upload the thumbnail.');
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode != 200) {
      throw AuthException(
          decoded['error'] as String? ?? 'Thumbnail upload failed.');
    }
    return VideoItem.fromJson(decoded['video'] as Map<String, dynamic>);
  }

  /// Creator fine-tunes the per-second feel track (0..1 values).
  static Future<VideoItem> updateHaptics(
      int videoId, List<double> track) async {
    final decoded = await _postJson('/videos/$videoId/haptics',
        {'userId': AuthApi.currentUser?.id, 'track': track});
    return VideoItem.fromJson(decoded['video'] as Map<String, dynamic>);
  }

  /// Creator: delete an owned upload.
  static Future<void> deleteVideo(int videoId) async {
    await _postJson(
        '/videos/$videoId/delete', {'userId': AuthApi.currentUser?.id});
  }

  /// Creator: rename an owned upload.
  static Future<VideoItem> renameVideo(int videoId, String title) async {
    final decoded = await _postJson('/videos/$videoId/rename',
        {'userId': AuthApi.currentUser?.id, 'title': title});
    return VideoItem.fromJson(decoded['video'] as Map<String, dynamic>);
  }

  /// Upload a profile picture (server compresses to 512px JPEG).
  static Future<String> uploadAvatar(String filename, Uint8List bytes) async {
    if (bytes.length > 5 * 1024 * 1024) {
      throw const AuthException('Profile pictures are limited to 5 MB.');
    }
    final uri = Uri.parse('$apiBase/users/avatar').replace(queryParameters: {
      'userId': '${AuthApi.currentUser?.id ?? ''}',
      'filename': filename,
    });
    late http.Response response;
    try {
      response = await http
          .post(uri,
              headers: {'Content-Type': 'application/octet-stream'},
              body: bytes)
          .timeout(const Duration(minutes: 2));
    } catch (_) {
      throw const AuthException('Upload failed — is the backend up?');
    }
    final decoded = _decode(response.body);
    if (response.statusCode != 201) {
      throw AuthException(decoded['error'] as String? ?? 'Upload failed.');
    }
    return decoded['avatarUrl'] as String;
  }

  /// Update the short bio.
  static Future<void> updateAbout(String about) async {
    await _postJson(
        '/users/about', {'userId': AuthApi.currentUser?.id, 'about': about});
  }

  /// Public profile card for community username taps.
  static Future<Map<String, dynamic>> publicProfile(int userId) =>
      _get('/users/$userId/profile');

  /// Creator: replace a city's cover image from the app.
  static Future<void> uploadCityCover({
    required String city,
    required String filename,
    required Uint8List bytes,
  }) async {
    final uri = Uri.parse('$apiBase/cities/$city/cover').replace(
        queryParameters: {
          'filename': filename,
          'userId': '${AuthApi.currentUser?.id ?? ''}'
        });
    late http.Response response;
    try {
      response = await http
          .post(uri,
              headers: {'Content-Type': 'application/octet-stream'},
              body: bytes)
          .timeout(const Duration(minutes: 2));
    } catch (_) {
      throw const AuthException('Cover upload failed — is the backend up?');
    }
    if (response.statusCode != 201) {
      final decoded = _decode(response.body);
      throw AuthException(
          decoded['error'] as String? ?? 'Cover upload failed.');
    }
  }

  static Future<String> sendFeedback({
    String? email,
    int? rating,
    required String message,
  }) async {
    final decoded = await _postJson('/feedback', {
      if (email != null) 'email': email,
      if (rating != null) 'rating': rating,
      'message': message,
    });
    return decoded['thanks'] as String? ?? 'Thanks!';
  }

  /// Public JSON POST for auxiliary services (push registration).
  static Future<Map<String, dynamic>> getJsonPost(
          String path, Map<String, dynamic> body) =>
      _postJson(path, body);

  static Future<Map<String, dynamic>> _postJson(
      String path, Map<String, dynamic> body) async {
    late http.Response response;
    try {
      response = await http
          .post(Uri.parse('$apiBase$path'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(body))
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      throw const AuthException(
          'Cannot reach the media server. Is the backend running on port 8080?');
    }
    final decoded = _decode(response.body);
    if (response.statusCode >= 400) {
      throw AuthException(decoded['error'] as String? ?? 'Request failed.');
    }
    return decoded;
  }

  /// Raw GET for lightweight callers (notifications etc.).
  static Future<Map<String, dynamic>> getJson(String path) => _get(path);

  static Future<Map<String, dynamic>> _get(String path) async {
    late http.Response response;
    try {
      response = await http
          .get(Uri.parse('$apiBase$path'))
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      throw const AuthException(
          'Cannot reach the media server. Is the backend running on port 8080?');
    }
    final decoded = _decode(response.body);
    if (response.statusCode != 200) {
      throw AuthException(decoded['error'] as String? ?? 'Request failed.');
    }
    return decoded;
  }

  /// Tolerates empty / non-JSON bodies (proxies, dead server, test env).
  static Map<String, dynamic> _decode(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    throw const AuthException(
        'Cannot reach the media server. Is the backend running on port 8080?');
  }
}
