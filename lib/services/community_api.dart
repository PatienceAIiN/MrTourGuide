import 'dart:convert';

import 'package:http/http.dart' as http;

import 'dart:typed_data';

import 'api_base.dart';
import 'auth_api.dart';

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
        replyCount: (json['replyCount'] as num?)?.toInt() ?? 0,
      );
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
  }) async {
    await _send('POST', '/community/posts', {
      'userId': _me,
      'community': community,
      'body': body,
      if (city != null) 'city': city,
      if (imageUrl != null) 'imageUrl': imageUrl,
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
          'Cannot reach the community server. Is the backend running?');
    }
    final Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw const AuthException(
          'Cannot reach the community server. Is the backend running?');
    }
    if (response.statusCode >= 400) {
      throw AuthException(decoded['error'] as String? ?? 'Request failed.');
    }
    return decoded;
  }
}
