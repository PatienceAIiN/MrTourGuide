import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'api_base.dart';
import 'auth_api.dart';

/// One GuideVibe short — a platform (creator) upload. GuideVibe is
/// platform-only; there are no third-party/YouTube items.
class Short {
  final String id;
  final int? ownerId;
  final String ownerName;
  final String ownerRole;
  final String caption;
  final String? city;
  final String? thumbUrl;

  /// 'normal' | 'vr' | 'mr'.
  final String kind;

  /// Relative stream URL for the short.
  final String? url;

  int likes;
  final int views;
  bool liked;

  /// 'ready' | 'processing' (only meaningful in creator studio mode).
  final String status;

  /// Audio→haptics: the same {track, fine, events} contract as VideoItem.
  final List<double> hapticFine;
  final List<Map<String, num>> hapticEvents;

  Short({
    required this.id,
    this.ownerId,
    required this.ownerName,
    required this.ownerRole,
    required this.caption,
    this.city,
    this.thumbUrl,
    required this.kind,
    this.url,
    this.likes = 0,
    this.views = 0,
    this.liked = false,
    this.status = 'ready',
    this.hapticFine = const [],
    this.hapticEvents = const [],
  });

  bool get isProcessing => status == 'processing';

  bool get isVr => kind == 'vr';
  bool get isMr => kind == 'mr';
  bool get isImmersive => kind == 'vr' || kind == 'mr';
  bool get byCreator => ownerRole == 'creator';

  String? get absoluteUrl => url == null ? null : '$apiBase$url';
  String? get absoluteThumbUrl {
    if (thumbUrl == null) return null;
    return thumbUrl!.startsWith('http') ? thumbUrl : '$apiBase$thumbUrl';
  }

  factory Short.fromJson(Map<String, dynamic> json) => Short(
        id: '${json['id']}',
        ownerId: json['ownerId'] as int?,
        ownerName: json['ownerName'] as String? ?? 'Traveler',
        ownerRole: json['ownerRole'] as String? ?? 'traveler',
        caption: json['caption'] as String? ?? '',
        city: json['city'] as String?,
        thumbUrl: json['thumbUrl'] as String?,
        kind: json['kind'] as String? ?? 'normal',
        url: json['url'] as String?,
        likes: (json['likes'] as num?)?.toInt() ?? 0,
        views: (json['views'] as num?)?.toInt() ?? 0,
        liked: json['liked'] == true,
        status: json['status'] as String? ?? 'ready',
        hapticFine: [
          for (final v in ((json['haptics'] as Map<String, dynamic>?)?['fine']
                  as List? ??
              const []))
            (v as num).toDouble()
        ],
        hapticEvents: [
          for (final e
              in ((json['haptics'] as Map<String, dynamic>?)?['events']
                      as List? ??
                  const []))
            {'t': (e as Map)['t'] as num, 'power': e['power'] as num}
        ],
      );
}

/// A track from the music library — a 30-second official preview clip
/// (Hindi & global catalog) the creator can add to a short.
class MusicTrack {
  final String id;
  final String title;
  final String artist;
  final int duration; // seconds
  final String audio; // streamable/downloadable MP3 url
  final String image;

  const MusicTrack({
    required this.id,
    required this.title,
    required this.artist,
    required this.duration,
    required this.audio,
    required this.image,
  });

  factory MusicTrack.fromJson(Map<String, dynamic> j) => MusicTrack(
        id: '${j['id']}',
        title: j['title'] as String? ?? 'Untitled',
        artist: j['artist'] as String? ?? 'Unknown artist',
        duration: (j['duration'] as num?)?.toInt() ?? 0,
        audio: j['audio'] as String? ?? '',
        image: j['image'] as String? ?? '',
      );
}

class ShortComment {
  final int id;
  final int authorId;
  final String authorName;
  final String body;
  final DateTime createdAt;

  const ShortComment({
    required this.id,
    required this.authorId,
    required this.authorName,
    required this.body,
    required this.createdAt,
  });

  factory ShortComment.fromJson(Map<String, dynamic> j) => ShortComment(
        id: j['id'] as int,
        authorId: j['authorId'] as int,
        authorName: j['authorName'] as String,
        body: j['body'] as String,
        createdAt: DateTime.parse(j['createdAt'] as String),
      );
}

class GuideVibeApi {
  static int? get _me => AuthApi.currentUser?.id;

  /// The GuideVibe feed for a city (creator shorts + YouTube Shorts blend).
  static Future<(List<Short>, bool)> feed({
    String city = '',
    int offset = 0,
    int limit = 10,
    int? owner,
  }) async {
    final me = _me;
    final q = <String>[
      'offset=$offset',
      'limit=$limit',
      if (city.isNotEmpty) 'city=${Uri.encodeComponent(city)}',
      if (owner != null) 'owner=$owner',
      if (me != null) 'userId=$me',
    ].join('&');
    final decoded = await _get('/guidevibe?$q');
    return (
      [
        for (final s in decoded['shorts'] as List)
          Short.fromJson(s as Map<String, dynamic>)
      ],
      decoded['hasMore'] == true,
    );
  }

  /// Search the royalty-free music library (Creative-Commons, safe to
  /// publish). Returns [] if the library isn't configured yet.
  static Future<List<MusicTrack>> searchMusic(String query) async {
    final decoded =
        await _get('/music/search?q=${Uri.encodeComponent(query)}');
    return [
      for (final t in (decoded['items'] as List? ?? const []))
        MusicTrack.fromJson(t as Map<String, dynamic>)
    ];
  }

  /// Streams a short up (client cap 80 MB) and returns the created Short.
  /// Optionally overlays a chosen soundtrack segment (musicUrl + start sec).
  static Future<Short> upload({
    required String filePath,
    required String caption,
    String city = '',
    String kind = 'normal',
    String? musicUrl,
    double musicStart = 0,
  }) async {
    final me = _me;
    if (me == null) throw const AuthException('Sign in to post a GuideVibe.');
    final file = File(filePath);
    final size = await file.length();
    if (size > 80 * 1024 * 1024) {
      throw const AuthException('GuideVibe clips are limited to 80 MB.');
    }
    try {
      final req = http.StreamedRequest(
        'POST',
        Uri.parse('$apiBase/guidevibe/upload').replace(queryParameters: {
          'userId': '$me',
          'filename': filePath.split('/').last,
          'caption': caption,
          if (city.isNotEmpty) 'city': city,
          'kind': kind,
          if (musicUrl != null && musicUrl.isNotEmpty) 'musicUrl': musicUrl,
          if (musicUrl != null && musicUrl.isNotEmpty)
            'musicStart': musicStart.toStringAsFixed(1),
        }),
      );
      req.headers['Content-Type'] = 'application/octet-stream';
      req.contentLength = size;
      file.openRead().listen(req.sink.add,
          onDone: req.sink.close, onError: req.sink.addError);
      final streamed = await req.send().timeout(const Duration(minutes: 6));
      final body = await streamed.stream.bytesToString();
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      if (streamed.statusCode != 201) {
        throw AuthException(decoded['error'] as String? ?? 'Upload failed.');
      }
      return Short.fromJson(decoded['short'] as Map<String, dynamic>);
    } on AuthException {
      rethrow;
    } catch (_) {
      throw const AuthException(
          'GuideVibe upload failed — check your internet and try again.');
    }
  }

  static Future<bool> toggleLike(String shortId) async {
    final decoded =
        await _post('/guidevibe/$shortId/like', {'userId': _me});
    return decoded['liked'] == true;
  }

  static void view(String shortId) {
    // Fire-and-forget; failures are irrelevant to the viewer.
    _post('/guidevibe/$shortId/view', {}).catchError((_) => <String, dynamic>{});
  }

  static Future<List<ShortComment>> comments(String shortId) async {
    final decoded = await _get('/guidevibe/$shortId/comments');
    return [
      for (final c in decoded['comments'] as List)
        ShortComment.fromJson(c as Map<String, dynamic>)
    ];
  }

  static Future<void> addComment(String shortId, String body) async {
    await _post('/guidevibe/$shortId/comments', {'userId': _me, 'body': body});
  }

  /// The public, shareable browser link for a short.
  static String shareUrl(String shortId) => '$apiBase/short/$shortId';

  static Future<void> updateShort(String shortId, {String? caption}) async {
    await _post('/guidevibe/$shortId/update', {
      'userId': _me,
      if (caption != null) 'caption': caption,
    });
  }

  static Future<void> deleteShort(String shortId) async {
    await _post('/guidevibe/$shortId/delete', {'userId': _me});
  }

  static Future<Map<String, dynamic>> analytics(String shortId) async {
    return _get('/guidevibe/$shortId/analytics?userId=$_me');
  }

  static Future<Map<String, dynamic>> _get(String path) async {
    late http.Response r;
    try {
      r = await http.get(Uri.parse('$apiBase$path')).timeout(
          const Duration(seconds: 15));
    } catch (_) {
      throw const AuthException(
          'Could not load GuideVibe — check your internet.');
    }
    final decoded = _decode(r);
    if (r.statusCode >= 400) {
      throw AuthException(decoded['error'] as String? ?? 'Request failed.');
    }
    return decoded;
  }

  static Future<Map<String, dynamic>> _post(
      String path, Map<String, dynamic> body) async {
    late http.Response r;
    try {
      r = await http
          .post(Uri.parse('$apiBase$path'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(body))
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      throw const AuthException('Could not sync — check your internet.');
    }
    final decoded = _decode(r);
    if (r.statusCode >= 400) {
      throw AuthException(decoded['error'] as String? ?? 'Request failed.');
    }
    return decoded;
  }

  static Map<String, dynamic> _decode(http.Response r) {
    try {
      return jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {
      return const {};
    }
  }
}
