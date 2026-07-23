import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'dart:typed_data';

import 'api_base.dart';
import 'auth_api.dart';
import 'transfer_service.dart';

/// One attachment on a post: a compressed image or an inline-playable video.
class PostMedia {
  final String type; // 'image' | 'video'
  final String url;
  final String? thumb;

  const PostMedia({required this.type, required this.url, this.thumb});

  bool get isVideo => type == 'video';
  String get absoluteUrl => url.startsWith('http') ? url : '$apiBase$url';
  String? get absoluteThumb =>
      thumb == null ? null : (thumb!.startsWith('http') ? thumb : '$apiBase$thumb');

  Map<String, String> toJson() => {
        'type': type,
        'url': url,
        if (thumb != null) 'thumb': thumb!,
      };
}

class CommunityPost {
  final int id;
  final String community;
  final int authorId;
  final String authorName;
  final String authorRole;
  final String? city;
  final String body;
  final DateTime createdAt;

  /// emoji -> count
  final Map<String, int> reactions;

  /// emojis the current user has given
  final Set<String> myReactions;

  /// Compressed image attached to the post (backend-relative), if any.
  final String? imageUrl;

  /// Who reshared this post here (null for original posts).
  final String? resharedBy;
  final int? resharedById;
  final String? resharedByRole;

  /// The resharer's own comment on top of the shared post.
  final String? reshareComment;

  /// All attachments (up to 10 images + 2 videos). For posts made before
  /// multi-media, this wraps the legacy single image.
  final List<PostMedia> media;
  int replyCount;

  CommunityPost({
    required this.id,
    required this.community,
    required this.authorId,
    required this.authorName,
    required this.authorRole,
    this.city,
    required this.body,
    required this.createdAt,
    required this.reactions,
    required this.myReactions,
    this.imageUrl,
    this.resharedBy,
    this.resharedById,
    this.resharedByRole,
    this.reshareComment,
    this.media = const [],
    this.replyCount = 0,
  });

  String? get absoluteImageUrl => imageUrl == null ? null : '$apiBase$imageUrl';

  bool get byCreator => authorRole == 'creator';

  factory CommunityPost.fromJson(Map<String, dynamic> json) => CommunityPost(
        id: json['id'] as int,
        community: json['community'] as String,
        authorId: json['authorId'] as int,
        authorName: json['authorName'] as String,
        authorRole: json['authorRole'] as String,
        city: json['city'] as String?,
        body: json['body'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        reactions: {
          for (final e in (json['reactions'] as Map<String, dynamic>).entries)
            e.key: (e.value as num).toInt()
        },
        myReactions: {for (final e in json['myReactions'] as List) e as String},
        imageUrl: json['imageUrl'] as String?,
        media: _parseMedia(json),
        replyCount: (json['replyCount'] as num?)?.toInt() ?? 0,
      );

  static List<PostMedia> _parseMedia(Map<String, dynamic> json) {
    final raw = json['media'];
    if (raw is List && raw.isNotEmpty) {
      return [
        for (final m in raw)
          if (m is Map && m['url'] is String)
            PostMedia(
              type: m['type'] as String? ?? 'image',
              url: m['url'] as String,
              thumb: m['thumb'] as String?,
            )
      ];
    }
    final legacy = json['imageUrl'] as String?;
    return legacy == null
        ? const []
        : [PostMedia(type: 'image', url: legacy)];
  }
}

class CommunityReply {
  final int id;
  final int authorId;
  final String authorName;
  final String authorRole;
  final String body;
  final DateTime createdAt;

  /// Threading: the reply this one answers (null = top-level).
  final int? parentReplyId;

  const CommunityReply({
    required this.id,
    required this.authorId,
    required this.authorName,
    required this.authorRole,
    required this.body,
    required this.createdAt,
    this.parentReplyId,
  });

  bool get byCreator => authorRole == 'creator';

  factory CommunityReply.fromJson(Map<String, dynamic> json) => CommunityReply(
        id: json['id'] as int,
        authorId: json['authorId'] as int,
        authorName: json['authorName'] as String,
        authorRole: json['authorRole'] as String,
        body: json['body'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        parentReplyId: json['parentReplyId'] as int?,
      );
}

class CommunityApi {
  static const emojis = ['❤️', '🔥', '👏', '📳', '😮'];

  static int? get _me => AuthApi.currentUser?.id;

  static Future<(List<CommunityPost>, bool)> fetchPosts(
    String community, {
    int offset = 0,
    int limit = 20,
  }) async {
    final me = _me;
    final decoded = await _send(
        'GET',
        '/community/posts?community=$community&offset=$offset&limit=$limit'
            '${me != null ? '&userId=$me' : ''}');
    return (
      [
        for (final p in decoded['posts'] as List)
          CommunityPost.fromJson(p as Map<String, dynamic>)
      ],
      decoded['hasMore'] as bool,
    );
  }

  static Future<void> createPost({
    required String community,
    required String body,
    String? city,
    String? imageUrl,
    List<PostMedia> media = const [],
  }) async {
    await _send('POST', '/community/posts', {
      'userId': _me,
      'community': community,
      'body': body,
      if (city != null) 'city': city,
      if (imageUrl != null) 'imageUrl': imageUrl,
      if (media.isNotEmpty) 'media': [for (final m in media) m.toJson()],
    });
  }

  static Future<List<CommunityReply>> fetchReplies(int postId) async {
    final decoded = await _send('GET',
        '/community/posts/$postId/replies${_me != null ? '?userId=$_me' : ''}');
    return [
      for (final r in decoded['replies'] as List)
        CommunityReply.fromJson(r as Map<String, dynamic>)
    ];
  }

  /// Reshare a post (original author credited + notified).
  static Future<void> reshare(int postId) async {
    await _send('POST', '/community/posts/$postId/reshare', {'userId': _me});
  }

  /// Add or edit the resharer's comment on their reshare.
  static Future<void> setReshareComment(int postId, String comment) async {
    await _send('POST', '/community/posts/$postId/reshare-comment',
        {'userId': _me, 'comment': comment});
  }

  static Future<void> addReply(int postId, String body,
      {int? parentReplyId}) async {
    await _send('POST', '/community/posts/$postId/replies', {
      'userId': _me,
      'body': body,
      if (parentReplyId != null) 'parentReplyId': parentReplyId,
    });
  }

  static Future<void> deleteReply(int replyId) async {
    await _send('POST', '/community/replies/$replyId/delete', {'userId': _me});
  }

  /// Uploads an image (client cap 5 MB); the backend recompresses it to save
  /// storage and returns the served URL. Storage sits behind the R2-ready
  /// MediaStorage layer.
  static Future<String> uploadImage(String filename, Uint8List bytes) async {
    if (bytes.length > 5 * 1024 * 1024) {
      throw const AuthException('Images are limited to 5 MB.');
    }
    final me = _me;
    if (me == null) throw const AuthException('Sign in to attach images.');
    late http.Response response;
    try {
      response = await http
          .post(
            Uri.parse('$apiBase/community/upload-image').replace(
                queryParameters: {'userId': '$me', 'filename': filename}),
            headers: {'Content-Type': 'application/octet-stream'},
            body: bytes,
          )
          .timeout(const Duration(minutes: 2));
    } catch (_) {
      throw const AuthException('Image upload failed — is the backend up?');
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode != 201) {
      throw AuthException(decoded['error'] as String? ?? 'Upload failed.');
    }
    return decoded['imageUrl'] as String;
  }

  /// Uploads a post video (client cap 80 MB) via a background transfer so a
  /// sits fully in memory. The backend serves it immediately and re-encodes
  /// it to 720p in the background under the same URL.
  static Future<PostMedia> uploadVideo(String filePath,
      {void Function(double progress)? onProgress}) async {
    final me = _me;
    if (me == null) throw const AuthException('Sign in to attach videos.');
    final file = File(filePath);
    final size = await file.length();
    if (size > 80 * 1024 * 1024) {
      throw const AuthException('Post videos are limited to 80 MB.');
    }
    final url = Uri.parse('$apiBase/community/upload-video').replace(
        queryParameters: {
          'userId': '$me',
          'filename': filePath.split('/').last,
        }).toString();
    try {
      // Background upload: continues on app-switch with shade progress.
      final body = await TransferService.uploadBinary(
        filePath: filePath,
        url: url,
        displayName: 'Community video upload',
        onProgress: onProgress,
      );
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      return PostMedia(
        type: 'video',
        url: decoded['videoUrl'] as String,
        thumb: decoded['thumbUrl'] as String?,
      );
    } on TransferException catch (e) {
      String msg = 'Video upload failed — please try again.';
      try {
        final d = jsonDecode(e.body ?? '') as Map<String, dynamic>;
        if (d['error'] is String) msg = d['error'] as String;
      } catch (_) {}
      throw AuthException(msg);
    } catch (_) {
      throw const AuthException('Video upload failed — please try again.');
    }
  }

  /// The public, shareable browser link for a post.
  static String shareUrl(int postId) => '$apiBase/post/$postId';

  static Future<void> react(int postId, String emoji) async {
    await _send('POST', '/community/posts/$postId/react',
        {'userId': _me, 'emoji': emoji});
  }

  static Future<void> deletePost(int postId) async {
    await _send('POST', '/community/posts/$postId/delete', {'userId': _me});
  }

  static Future<Map<String, dynamic>> _send(String method, String path,
      [Map<String, dynamic>? body]) async {
    late http.Response response;
    try {
      final uri = Uri.parse('$apiBase$path');
      response = await (method == 'GET'
              ? http.get(uri)
              : http.post(uri,
                  headers: {'Content-Type': 'application/json'},
                  body: jsonEncode(body)))
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      throw const AuthException(
          'Could not sync — check your internet and try again.');
    }
    final Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw const AuthException(
          'Could not sync — check your internet and try again.');
    }
    if (response.statusCode >= 400) {
      throw AuthException(decoded['error'] as String? ?? 'Request failed.');
    }
    return decoded;
  }
}
