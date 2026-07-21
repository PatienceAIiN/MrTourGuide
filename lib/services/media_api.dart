import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'api_base.dart';
import 'auth_api.dart' show AuthException;

class City {
  final String slug;
  final String name;
  final int videoCount;

  /// High-res cover (internet URL or creator-uploaded /files/... path).
  final String? coverUrl;
  final String location;
  final String description;
  final double rating;

  const City({
    required this.slug,
    required this.name,
    required this.videoCount,
    this.coverUrl,
    this.location = '',
    this.description = '',
    this.rating = 4.5,
  });

  /// Absolute cover URL (creator uploads are backend-relative).
  String? get absoluteCoverUrl {
    final c = coverUrl;
    if (c == null) return null;
    return c.startsWith('http') ? c : '$apiBase$c';
  }

  factory City.fromJson(Map<String, dynamic> json) => City(
        slug: json['slug'] as String,
        name: json['name'] as String,
        videoCount: json['videoCount'] as int,
        coverUrl: json['coverUrl'] as String?,
        location: json['location'] as String? ?? '',
        description: json['description'] as String? ?? '',
        rating: (json['rating'] as num?)?.toDouble() ?? 4.5,
      );
}

/// Creator-set experience configuration for a video.
class ExperienceConfig {
  final bool haptics;
  final bool sound;
  final double intensity;

  const ExperienceConfig({
    this.haptics = true,
    this.sound = true,
    this.intensity = 0.7,
  });

  factory ExperienceConfig.fromJson(Map<String, dynamic>? json) =>
      ExperienceConfig(
        haptics: json?['haptics'] as bool? ?? true,
        sound: json?['sound'] as bool? ?? true,
        intensity: (json?['intensity'] as num?)?.toDouble() ?? 0.7,
      );

  Map<String, dynamic> toJson() =>
      {'haptics': haptics, 'sound': sound, 'intensity': intensity};
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
  });

  bool get isProcessing => status == 'processing';

  String? get absoluteThumbUrl => thumbUrl == null ? null : '$apiBase$thumbUrl';

  factory VideoItem.fromJson(Map<String, dynamic> json) => VideoItem(
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
  const AiOverview({required this.overview, required this.model});
}

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

  static Future<List<City>> fetchCities() async {
    final decoded = await _get('/cities');
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

  /// Minimal AI overview for a search query (backend → Groq + web search).
  static Future<AiOverview> aiSearch(String query) async {
    final decoded = await _postJson('/ai/search', {'query': query});
    return AiOverview(
      overview: decoded['overview'] as String,
      model: decoded['model'] as String? ?? 'groq',
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
  }) async {
    final decoded =
        await _get('/videos?city=$city&offset=$offset&limit=$limit');
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
    required Uint8List bytes,
  }) async {
    final uri = Uri.parse('$apiBase/upload').replace(queryParameters: {
      'city': city,
      'title': title,
      'filename': filename,
    });
    late http.Response response;
    try {
      response = await http
          .post(uri,
              headers: {'Content-Type': 'application/octet-stream'},
              body: bytes)
          .timeout(const Duration(minutes: 5));
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

  /// Creator: persist per-video experience settings.
  static Future<VideoItem> updateConfig(
      int videoId, ExperienceConfig config) async {
    final decoded = await _postJson('/videos/$videoId/config', config.toJson());
    return VideoItem.fromJson(decoded['video'] as Map<String, dynamic>);
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
