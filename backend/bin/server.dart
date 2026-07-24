import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:googleapis_auth/auth_io.dart' as gauth;
import 'package:postgres/postgres.dart';
import 'package:redis/redis.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_static/shelf_static.dart';

/// Local backend for MrTouride.
///
/// Connects to the local Postgres over the unix socket (peer auth — no
/// password needed) and exposes:
///
/// Auth:
///   POST /signup  {name, email, password} -> 201 {id, name, email}
///   POST /login   {email, password}       -> 200 {id, name, email}
///
/// Experience videos (per city, used later for haptics/MR-VR):
///   GET  /cities                                    -> {cities: [...]}
///   GET  /videos?city=<slug>&offset=0&limit=5       -> {videos: [...], hasMore}
///   POST /upload?city=<slug>&title=<t>&filename=<f> -> 201 {video}
///        (body = raw file bytes)
///   GET  /files/<city>/<name>                       -> the video file
///
///   GET  /health                                    -> {ok: true}

/// Render / Cloud Run inject the port to bind on; default 8080 locally.
int get _port => int.tryParse(Platform.environment['PORT'] ?? '') ?? 8080;
const _pbkdf2Rounds = 50000;
const _maxUploadBytes = 500 * 1024 * 1024; // 500 MB

late Connection _db;
late MediaStorage _storage;

// ---------------------------------------------------------------------------
// Storage abstraction.
//
// Uploads land in a local folder for now. When moving to Cloudflare R2, add
// an R2Storage implementing this same interface (S3-compatible PUT/GET) and
// swap the instance in main() — no route code changes needed.
// ---------------------------------------------------------------------------

abstract class MediaStorage {
  Future<int> save(String city, String filename, Stream<List<int>> bytes);
  Future<File?> open(String city, String filename);
}

/// Cloudflare R2 (S3-compatible) storage with SigV4 signing.
///
/// Write-through: every save() lands in R2 *and* the local cache dir, so
/// /files serving and ffmpeg processing keep working unchanged. open()
/// falls back to fetching from R2 into the cache — which is how a fresh
/// Cloud Run instance heals after a restart.
class R2Storage implements MediaStorage {
  final String endpoint; // https://<account>.r2.cloudflarestorage.com
  final String bucket;
  final String accessKey;
  final String secretKey;
  final LocalFolderStorage cache;

  R2Storage({
    required this.endpoint,
    required this.bucket,
    required this.accessKey,
    required this.secretKey,
    required this.cache,
  });

  String get _host => Uri.parse(endpoint).host;

  @override
  Future<int> save(String city, String filename, Stream<List<int>> bytes) async {
    // Stream straight to the on-disk cache — no giant in-memory buffer. The old
    // path accumulated the whole file into a growable List<int> (~8 bytes/elem,
    // so an 80 MB upload ballooned to ~640 MB of RAM and OOM-killed the small
    // container). Caches first so the file is immediately servable and the
    // caller returns right away.
    final size = await cache.save(city, filename, bytes);
    // The R2 push (slow leg) runs in the background. SigV4 needs the full
    // payload to sign, so read the cached file back as a COMPACT Uint8List
    // rather than re-buffering the stream as a List<int>.
    Future(() async {
      try {
        final file = await cache.open(city, filename);
        if (file == null) return;
        await _put('$city/$filename', await file.readAsBytes());
      } catch (e) {
        print('R2 put failed (served from cache) for $city/$filename: $e');
      }
    });
    return size;
  }

  @override
  Future<File?> open(String city, String filename) async {
    final local = await cache.open(city, filename);
    if (local != null) return local;
    // Cache miss: pull from R2.
    try {
      final data = await _get('$city/$filename');
      if (data == null) return null;
      await cache.save(city, filename, Stream.value(data));
      return cache.open(city, filename);
    } catch (_) {
      return null;
    }
  }

  // ------------------------- SigV4 (region "auto") ------------------------

  Future<void> _put(String key, List<int> data) async {
    final res = await _request('PUT', key, body: data);
    if (res.$1 != 200) {
      throw HttpException('R2 PUT $key failed: HTTP ${res.$1}');
    }
  }

  Future<List<int>?> _get(String key) async {
    final res = await _request('GET', key);
    if (res.$1 == 404) return null;
    if (res.$1 != 200) {
      throw HttpException('R2 GET $key failed: HTTP ${res.$1}');
    }
    return res.$2;
  }

  Future<(int, List<int>)> _request(String method, String key,
      {List<int>? body}) async {
    final now = DateTime.now().toUtc();
    final amzDate =
        '${now.year.toString().padLeft(4, '0')}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}'
        'T${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}Z';
    final dateStamp = amzDate.substring(0, 8);
    final payloadHash = sha256.convert(body ?? const []).toString();
    final canonicalUri = '/$bucket/$key';

    final canonicalRequest = [
      method,
      canonicalUri,
      '',
      'host:$_host',
      'x-amz-content-sha256:$payloadHash',
      'x-amz-date:$amzDate',
      '',
      'host;x-amz-content-sha256;x-amz-date',
      payloadHash,
    ].join('\n');

    const scopeSuffix = 'auto/s3/aws4_request';
    final stringToSign = [
      'AWS4-HMAC-SHA256',
      amzDate,
      '$dateStamp/$scopeSuffix',
      sha256.convert(utf8.encode(canonicalRequest)).toString(),
    ].join('\n');

    List<int> hmac(List<int> k, String msg) =>
        Hmac(sha256, k).convert(utf8.encode(msg)).bytes;
    var signingKey = hmac(utf8.encode('AWS4$secretKey'), dateStamp);
    signingKey = hmac(signingKey, 'auto');
    signingKey = hmac(signingKey, 's3');
    signingKey = hmac(signingKey, 'aws4_request');
    final signature = Hmac(sha256, signingKey)
        .convert(utf8.encode(stringToSign))
        .toString();

    final client = HttpClient();
    try {
      final req = await client.openUrl(method, Uri.parse('$endpoint$canonicalUri'));
      req.headers.set('x-amz-date', amzDate);
      req.headers.set('x-amz-content-sha256', payloadHash);
      req.headers.set(
          'Authorization',
          'AWS4-HMAC-SHA256 Credential=$accessKey/$dateStamp/$scopeSuffix, '
          'SignedHeaders=host;x-amz-content-sha256;x-amz-date, '
          'Signature=$signature');
      if (body != null) {
        req.contentLength = body.length;
        req.add(body);
      }
      final res = await req.close();
      final data = <int>[];
      await for (final chunk in res) {
        data.addAll(chunk);
      }
      return (res.statusCode, data);
    } finally {
      client.close();
    }
  }
}

class LocalFolderStorage implements MediaStorage {
  final String baseDir;
  LocalFolderStorage(this.baseDir);

  File _fileFor(String city, String filename) =>
      File('$baseDir/$city/$filename');

  @override
  Future<int> save(String city, String filename, Stream<List<int>> bytes) async {
    final file = _fileFor(city, filename);
    await file.parent.create(recursive: true);
    final sink = file.openWrite();
    var written = 0;
    try {
      await for (final chunk in bytes) {
        written += chunk.length;
        if (written > _maxUploadBytes) {
          throw const FormatException('File too large.');
        }
        sink.add(chunk);
      }
    } finally {
      await sink.close();
    }
    return written;
  }

  @override
  Future<File?> open(String city, String filename) async {
    final file = _fileFor(city, filename);
    return await file.exists() ? file : null;
  }
}

// ---------------------------------------------------------------------------
// Password hashing (PBKDF2-HMAC-SHA256)
// ---------------------------------------------------------------------------

String _hashPassword(String password, String saltHex) {
  final salt = _hexToBytes(saltHex);
  var block = Hmac(sha256, utf8.encode(password))
      .convert([...salt, 0, 0, 0, 1]).bytes;
  var result = List<int>.from(block);
  for (var i = 1; i < _pbkdf2Rounds; i++) {
    block = Hmac(sha256, utf8.encode(password)).convert(block).bytes;
    for (var j = 0; j < result.length; j++) {
      result[j] ^= block[j];
    }
  }
  return _bytesToHex(result);
}

String _newSalt() {
  final rng = Random.secure();
  return _bytesToHex(List<int>.generate(16, (_) => rng.nextInt(256)));
}

String _bytesToHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

List<int> _hexToBytes(String hex) => [
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16)
    ];

bool _constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Response _json(int status, Map<String, Object?> body) => Response(
      status,
      body: jsonEncode(body),
      headers: {'content-type': 'application/json'},
    );

/// Per-IP sliding-window rate limit: 120 requests/min general,
/// 10 uploads/min. In-memory — resets on restart, good enough until a
/// gateway (Cloud Armor / Cloudflare) fronts the API in production.
final Map<String, List<int>> _hits = {};

Middleware _rateLimit() {
  return (Handler inner) {
    return (Request request) async {
      // Behind nginx/Cloudflare every socket is 127.0.0.1 — use the real
      // client IP headers when present.
      final ip = request.headers['cf-connecting-ip'] ??
          request.headers['x-forwarded-for']?.split(',').first.trim() ??
          (request.context['shelf.io.connection_info'] as HttpConnectionInfo?)
              ?.remoteAddress
              .address ??
          'unknown';
      final isUpload = request.url.path.startsWith('upload') ||
          request.url.path.contains('/cover') ||
          request.url.path.contains('upload-image');
      final key = isUpload ? 'u:$ip' : ip;
      final limit = isUpload ? 10 : 120;

      // Prefer a shared Redis counter (survives restarts / multiple
      // instances); fall back to the in-memory window if Redis is absent
      // or errors — rate limiting must never take the API down.
      final cmd = await _redis();
      if (cmd != null) {
        try {
          final rkey = 'rl:$key';
          final raw = await cmd.send_object(['INCR', rkey]);
          final count = raw is int ? raw : int.tryParse('$raw') ?? 0;
          if (count == 1) {
            await cmd.send_object(['EXPIRE', rkey, '60']);
          }
          if (count > limit) {
            return _json(
                429, {'error': 'Too many requests — slow down a little.'});
          }
          return inner(request);
        } catch (_) {
          // Redis hiccup — degrade to the in-memory limiter below.
        }
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      final windowStart = now - 60000;
      final list = _hits.putIfAbsent(key, () => [])
        ..removeWhere((t) => t < windowStart);
      if (list.length >= limit) {
        return _json(429, {'error': 'Too many requests — slow down a little.'});
      }
      list.add(now);
      return inner(request);
    };
  };
}

// Lazily-connected Redis (Render Key Value). Tried once; on any failure we
// stay on the in-memory limiter for the process lifetime. Never throws.
Command? _redisCmd;
bool _redisTried = false;
Future<Command?> _redis() async {
  if (_redisTried) return _redisCmd;
  _redisTried = true;
  final url = Platform.environment['REDIS_URL'];
  if (url == null || url.isEmpty) return null;
  try {
    final u = Uri.parse(url);
    final cmd = await RedisConnection()
        .connect(u.host, u.hasPort ? u.port : 6379)
        .timeout(const Duration(seconds: 5));
    final pass =
        u.userInfo.contains(':') ? u.userInfo.split(':').last : u.userInfo;
    if (pass.isNotEmpty) {
      await cmd.send_object(['AUTH', pass]);
    }
    _redisCmd = cmd;
    print('Redis: connected (${u.host})');
  } catch (e) {
    print('Redis: unavailable, using in-memory rate limit ($e)');
    _redisCmd = null;
  }
  return _redisCmd;
}

/// Drops cached responses for a route family so a fresh write shows instantly
/// instead of waiting out the TTL. Uses SCAN (non-blocking) and never throws.
Future<void> _cacheBust(String pathPrefix) async {
  final cmd = await _redis();
  if (cmd == null) return;
  try {
    var cursor = '0';
    do {
      final res = await cmd.send_object(
              ['SCAN', cursor, 'MATCH', 'resp:/api/$pathPrefix*', 'COUNT', '200'])
          as List;
      cursor = '${res[0]}';
      final keys = (res[1] as List).map((e) => '$e').toList();
      if (keys.isNotEmpty) await cmd.send_object(['DEL', ...keys]);
    } while (cursor != '0');
  } catch (_) {}
}

/// Redis-backed response cache to keep Neon calls *super low*: hot catalog/feed
/// GETs are served from the in-container Redis for a few seconds/minutes instead
/// of re-querying Postgres on every screen load. Keys include the full query
/// string (so per-user feeds stay separated); writes/POSTs are never cached and
/// expire quickly so freshness stays acceptable. Falls straight through when
/// Redis is unavailable.
Middleware _redisCache() {
  // path (without the /api prefix) -> TTL seconds
  const ttls = <String, int>{
    'cities': 300,
    'videos': 120,
    'videos/trending': 180,
    'videos/suggest': 300,
    'guidevibe': 45,
    'search': 180,
    'search/media': 600,
    'news': 600,
    'whats-new': 45,
    'notifications': 30,
  };
  return (Handler inner) {
    return (Request request) async {
      if (request.method != 'GET') return inner(request);
      var path = request.url.path;
      if (path.startsWith('api/')) path = path.substring(4);
      var ttl = ttls[path];
      ttl ??= path.endsWith('/weather')
          ? 900
          : (path.endsWith('/rating') || path.endsWith('/comments') ? 30 : null);
      if (ttl == null) return inner(request);
      // NEVER cache personalized views ("my uploads", per-user feeds) —
      // caching them made fresh uploads invisible and deletes ghost for
      // up to the TTL.
      final qp = request.url.queryParameters;
      if (qp.containsKey('ownerId') ||
          qp.containsKey('mine') ||
          (path != 'notifications' && qp.containsKey('userId'))) {
        return inner(request);
      }

      final cmd = await _redis();
      if (cmd == null) return inner(request);

      final key = 'resp:${request.requestedUri.path}?${request.requestedUri.query}';
      try {
        final hit = await cmd.send_object(['GET', key]);
        if (hit != null) {
          final body = hit is String ? hit : utf8.decode(hit as List<int>);
          return Response.ok(body, headers: {
            'content-type': 'application/json',
            'x-cache': 'HIT',
          });
        }
      } catch (_) {}

      final response = await inner(request);
      if (response.statusCode == 200) {
        try {
          final body = await response.readAsString();
          cmd.send_object(['SET', key, body, 'EX', '$ttl']).catchError(
              (Object _) => null);
          return response.change(headers: {'x-cache': 'MISS'}, body: body);
        } catch (_) {
          return response;
        }
      }
      return response;
    };
  };
}

/// Short edge-cache for anonymous catalog GETs — Cloudflare absorbs bursts
/// so the free-tier VM stays cool. Personalized requests stay uncached.
Middleware _edgeCache() {
  const cacheable = {'cities', 'videos', 'videos/trending', 'search'};
  return (Handler inner) {
    return (Request request) async {
      final response = await inner(request);
      if (request.method == 'GET' &&
          cacheable.contains(request.url.path) &&
          !request.url.queryParameters.containsKey('userId') &&
          !request.url.queryParameters.containsKey('ownerId') &&
          response.statusCode == 200) {
        return response.change(
            headers: {'cache-control': 'public, max-age=60'});
      }
      if (request.method == 'GET' &&
          request.url.path.endsWith('/weather') &&
          response.statusCode == 200) {
        return response.change(
            headers: {'cache-control': 'public, max-age=600'});
      }
      return response;
    };
  };
}

Middleware _cors() {
  const headers = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
  };
  return (Handler inner) {
    return (Request request) async {
      if (request.method == 'OPTIONS') {
        return Response.ok('', headers: headers);
      }
      final response = await inner(request);
      return response.change(headers: headers);
    };
  };
}

Future<Map<String, dynamic>?> _readJsonBody(Request request) async {
  try {
    final raw = await request.readAsString();
    final decoded = jsonDecode(raw);
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  }
}

/// Keep only safe characters; prevents path traversal in stored names.
String _sanitizeFilename(String name) {
  final cleaned = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  return cleaned.isEmpty ? 'upload.bin' : cleaned;
}

String _mimeFor(String filename) {
  final ext = filename.split('.').last.toLowerCase();
  const map = {
    'mp4': 'video/mp4',
    'webm': 'video/webm',
    'mov': 'video/quicktime',
    'mkv': 'video/x-matroska',
    'm4v': 'video/x-m4v',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'webp': 'image/webp',
  };
  return map[ext] ?? 'application/octet-stream';
}

Map<String, Object?> _videoRowToJson(List<dynamic> row) => {
      'id': row[0],
      'city': row[1],
      'title': row[2],
      'filename': row[3],
      'mime': row[4],
      'sizeBytes': row[5],
      'hapticsReady': row[6] != null,
      'haptics': row[6],
      'uploadedAt': (row[7] as DateTime).toIso8601String(),
      'status': row[8],
      'config': row[9],
      'thumbUrl': row[10],
      'ownerId': row[11],
      'url': '/files/${row[1]}/${row[3]}',
    };

const _videoColumns =
    'id, city, title, filename, mime, size_bytes, haptics, uploaded_at, '
    'status, config, thumb_url, owner_id';

/// Simulated ML pipeline: after a short "processing" period the video is
/// trimmed/enhanced, a poster thumbnail is extracted (real ffmpeg) and a
/// haptic track is generated from its audio/motion. Replace with the real
/// ML worker later — same DB contract.
/// Soundtrack files parked by /videos/upload-audio, waiting for the video
/// upload that references them. Swept after an hour if never used.
final Map<String, (String, DateTime)> _pendingAudio = {};

void _sweepPendingAudio() {
  final cutoff = DateTime.now().subtract(const Duration(hours: 1));
  _pendingAudio.removeWhere((_, v) {
    if (v.$2.isBefore(cutoff)) {
      try {
        File(v.$1).deleteSync();
      } catch (_) {}
      return true;
    }
    return false;
  });
}

/// Creator uploads a soundtrack / voice-over (≤10 MB) to mix into an
/// experience video. Returns an audioId to pass along with the video upload.
Future<Response> _uploadVideoAudio(Request request) async {
  final userId = int.tryParse(request.url.queryParameters['userId'] ?? '');
  if (userId == null) return _json(401, {'error': 'Sign in first.'});
  final original =
      _sanitizeFilename(request.url.queryParameters['filename'] ?? 'audio.m4a');
  final ext = original.split('.').last.toLowerCase();
  if (!{'mp3', 'm4a', 'aac', 'wav', 'ogg', 'opus', 'flac'}.contains(ext)) {
    return _json(400, {'error': 'Only MP3, M4A, AAC, WAV or OGG audio.'});
  }
  _sweepPendingAudio();
  final id = 'aud_${DateTime.now().millisecondsSinceEpoch}_$userId';
  final tmp = File('${Directory.systemTemp.path}/mrt_$id.$ext');
  final sink = tmp.openWrite();
  var size = 0;
  try {
    await for (final chunk in request.read()) {
      size += chunk.length;
      if (size > 10 * 1024 * 1024) {
        await sink.close();
        await tmp.delete();
        return _json(413, {'error': 'Audio is limited to 10 MB.'});
      }
      sink.add(chunk);
    }
  } finally {
    try {
      await sink.close();
    } catch (_) {}
  }
  if (size == 0) return _json(400, {'error': 'Empty audio body.'});
  _pendingAudio[id] = (tmp.path, DateTime.now());
  return _json(201, {'audioId': id});
}

/// Mux a parked soundtrack into the stored video: 'mix' blends it over the
/// original audio (per-track volumes), 'replace' swaps the audio entirely.
/// [offset] delays the soundtrack start within the video (seconds).
Future<void> _muxVideoAudio(
  int videoId, {
  required String audioId,
  required double offset,
  required String mode,
  required double origVol,
  required double audioVol,
}) async {
  final parked = _pendingAudio.remove(audioId);
  if (parked == null) return;
  final audioPath = parked.$1;
  try {
    final rows = await _db.execute(
      Sql.named('SELECT city, filename FROM videos WHERE id = @id'),
      parameters: {'id': videoId},
    );
    if (rows.isEmpty) return;
    final city = rows.first[0] as String;
    final filename = rows.first[1] as String;
    final video = await _storage.open(city, filename);
    if (video == null) return;
    final out = File(
        '${Directory.systemTemp.path}/mrt_mux_${DateTime.now().millisecondsSinceEpoch}.mp4');
    final delayMs = (offset.clamp(0, 3600) * 1000).round();
    List<String> args;
    if (mode == 'mix') {
      args = [
        '-y', '-loglevel', 'error',
        '-i', video.path, '-i', audioPath,
        '-filter_complex',
        '[0:a]volume=${origVol.clamp(0, 2)}[a0];'
            '[1:a]adelay=$delayMs|$delayMs,volume=${audioVol.clamp(0, 2)}[a1];'
            '[a0][a1]amix=inputs=2:duration=first:dropout_transition=0[a]',
        '-map', '0:v', '-map', '[a]',
        '-c:v', 'copy', '-c:a', 'aac', '-b:a', '128k',
        out.path,
      ];
    } else {
      args = [
        '-y', '-loglevel', 'error',
        '-i', video.path, '-i', audioPath,
        '-filter_complex',
        '[1:a]adelay=$delayMs|$delayMs,volume=${audioVol.clamp(0, 2)}[a]',
        '-map', '0:v', '-map', '[a]',
        '-c:v', 'copy', '-c:a', 'aac', '-b:a', '128k', '-shortest',
        out.path,
      ];
    }
    var result = await Process.run('ffmpeg', args);
    if (result.exitCode != 0 && mode == 'mix') {
      // Source video may have no audio stream — fall back to replace.
      result = await Process.run('ffmpeg', [
        '-y', '-loglevel', 'error',
        '-i', video.path, '-i', audioPath,
        '-filter_complex',
        '[1:a]adelay=$delayMs|$delayMs,volume=${audioVol.clamp(0, 2)}[a]',
        '-map', '0:v', '-map', '[a]',
        '-c:v', 'copy', '-c:a', 'aac', '-b:a', '128k', '-shortest',
        out.path,
      ]);
    }
    if (result.exitCode == 0 && await out.length() > 0) {
      // Overwrite the stored video under the SAME name — the poster/haptics
      // pipeline then runs on the mixed result.
      await _storage.save(city, filename, out.openRead());
      print('audio-mix: video $videoId muxed ($mode, +${offset}s)');
    } else {
      print('audio-mix failed for video $videoId: ${result.stderr}');
    }
    try {
      await out.delete();
    } catch (_) {}
  } finally {
    try {
      await File(audioPath).delete();
    } catch (_) {}
  }
}

void _scheduleMlProcessing(int videoId, {Future<void> Function()? preprocess}) {
  Timer(const Duration(seconds: 15), () async {
    try {
      // Optional soundtrack mux runs BEFORE poster + haptic analysis so the
      // feel track is built from the final mixed audio.
      if (preprocess != null) await preprocess();
      // Poster frame via ffmpeg (this part is real, not simulated).
      String? thumbUrl;
      final rows = await _db.execute(
        Sql.named('SELECT city, filename FROM videos WHERE id = @id'),
        parameters: {'id': videoId},
      );
      if (rows.isNotEmpty) {
        final city = rows.first[0] as String;
        final filename = rows.first[1] as String;
        final video = await _storage.open(city, filename);
        if (video != null) {
          final thumbName = 'thumb_$filename.jpg';
          final tmpThumb = File(
              '${Directory.systemTemp.path}/mrt_thumb_${DateTime.now().millisecondsSinceEpoch}.jpg');
          final result = await Process.run('ffmpeg', [
            '-y', '-loglevel', 'error',
            '-i', video.path,
            '-ss', '00:00:01', '-frames:v', '1',
            '-vf', 'scale=640:-2',
            tmpThumb.path,
          ]);
          if (result.exitCode == 0) {
            await _storage.save(
                city, thumbName, Stream.value(await tmpThumb.readAsBytes()));
            await tmpThumb.delete();
            thumbUrl = '/files/$city/$thumbName';
          }
        }
      }

      // Real audio-energy analysis: background sound, music, wind and
      // ambience all raise the per-second energy, which becomes the haptic
      // track — light feel in quiet moments, heavy in loud ones.
      List<double> fine = const [];
      List<Map<String, num>> events = const [];
      final trackRows = await _db.execute(
        Sql.named('SELECT city, filename FROM videos WHERE id = @id'),
        parameters: {'id': videoId},
      );
      if (trackRows.isNotEmpty) {
        final file = await _storage.open(
            trackRows.first[0] as String, trackRows.first[1] as String);
        if (file != null) (fine, events) = await _audioEnergyAnalysis(file.path);
      }
      // Per-second averages keep older app builds working.
      final track = <double>[];
      for (var i = 0; i + 3 < fine.length; i += 4) {
        track.add(double.parse(
            ((fine[i] + fine[i + 1] + fine[i + 2] + fine[i + 3]) / 4)
                .toStringAsFixed(3)));
      }

      await _db.execute(
        Sql.named("UPDATE videos SET status = 'ready', haptics = @haptics, "
            // COALESCE: a creator-set thumbnail must survive processing —
            // the auto frame only fills the gap when none was uploaded.
            'thumb_url = COALESCE(thumb_url, @thumb) WHERE id = @id'),
        parameters: {
          'id': videoId,
          'thumb': thumbUrl,
          'haptics': jsonEncode({
            'profile': 'auto',
            'source': fine.isEmpty ? 'ml-sim' : 'audio-energy-v3',
            'generatedAt': DateTime.now().toIso8601String(),
            'track': track,
            'fine': fine,
            'events': events,
          }),
        },
      );
      print('ML: video $videoId processed '
          '(thumb + ${track.length}s haptic track).');
      // Processing done -> the "ready" flip must be visible immediately.
      await _cacheBust('videos');
      // Push: tell travelers a new experience just landed.
      final meta = await _db.execute(
        Sql.named('SELECT title, city, owner_id FROM videos WHERE id = @id'),
        parameters: {'id': videoId},
      );
      if (meta.isNotEmpty) {
        // Locals first, then everyone who wants all-location alerts.
        _sendPushByLocation(
          '${meta.first[1]}',
          'New experience in ${meta.first[1]}',
          '"${meta.first[0]}" is live \u2014 feel it now.',
          excludeUserId: meta.first[2] as int?,
          data: {'type': 'video', 'city': '${meta.first[1]}'},
        );
      }
    } catch (e) {
      print('ML-sim: failed for video $videoId: $e');
    }
  });
}

/// Per-second normalized audio energy (0..1) — the haptic track. Uses
/// ffmpeg's astats RMS levels; silence → 0, the loudest second → 1.
/// Community safety: blocks obviously abusive/unsafe text. Light-weight
/// word screen — heavier moderation can bolt on later without API changes.
const _blockedTerms = [
  'fuck', 'bitch', 'bastard', 'asshole', 'chutiya', 'madarchod',
  'bhenchod', 'randi', 'nude', 'porn', 'sex video', 'kill you',
  'rape', 'terrorist attack plan',
];

String? _unsafeText(String text) {
  final t = ' ${text.toLowerCase()} ';
  for (final w in _blockedTerms) {
    if (t.contains(w)) {
      return 'That content violates community safety rules. '
          'Keep Mr.TourGuide kind and travel-focused.';
    }
  }
  return null;
}

/// Fire-and-forget audit log — powers the admin activity view.
void _logActivity(String actor, String action, String details) {
  () async {
    try {
      await _db.execute(
        Sql.named('INSERT INTO activity_logs (actor, action, details) '
            'VALUES (@a, @ac, @d)'),
        parameters: {'a': actor, 'ac': action, 'd': details},
      );
    } catch (_) {}
  }();
}

/// 250ms-resolution audio analysis: [fine] is the smoothed energy curve,
/// [events] are sharp onsets (gunshots, slams, drum hits → recoil pulses)
/// with their millisecond timestamps and punch strength.
Future<(List<double> fine, List<Map<String, num>> events)>
    _audioEnergyAnalysis(String path) async {
  // One ffmpeg pass over a band of the spectrum -> 250ms RMS values in dB.
  Future<List<double>> rms(List<String> preFilter) async {
    final result = await Process.run('ffmpeg', [
      '-i', path, '-map', '0:a:0?', '-af',
      // 11025 samples ≈ 250 ms windows at 44.1 kHz.
      '${preFilter.isEmpty ? '' : '${preFilter.join(',')},'}'
          'asetnsamples=11025,astats=metadata=1:reset=1,'
          'ametadata=print:key=lavfi.astats.Overall.RMS_level:file=-',
      '-f', 'null', '-',
    ]).timeout(const Duration(minutes: 3));
    final db = <double>[];
    for (final m in RegExp(r'RMS_level=(-?[\d.]+|-inf)')
        .allMatches(result.stdout as String)) {
      final raw = m.group(1)!;
      db.add(raw == '-inf' ? -90.0 : (double.tryParse(raw) ?? -90.0));
      if (db.length >= 2400) break; // cap at 10 minutes
    }
    return db;
  }

  // Per-video adaptive normalization: quiet vlogs and loud action clips both
  // land on the full 0..1 range instead of a fixed -60..-5 dB window.
  List<double> normalize(List<double> db) {
    final sorted = [...db]..sort();
    final lo = sorted[(sorted.length * 0.10).floor()];
    var hi = sorted[((sorted.length - 1) * 0.95).floor()];
    if (hi - lo < 6) hi = lo + 6; // near-constant audio: avoid noise blowup
    return [for (final v in db) ((v - lo) / (hi - lo)).clamp(0.0, 1.0)];
  }

  try {
    final fullDb = await rms(const []);
    if (fullDb.isEmpty) return (const <double>[], const <Map<String, num>>[]);
    final raw = normalize(fullDb);

    // Second pass over the low band only: gunshots, explosions, slams and
    // drum hits live under ~160 Hz, where speech and wind barely register.
    var low = const <double>[];
    try {
      final lowDb = await rms(const ['lowpass=f=160']);
      if (lowDb.length == fullDb.length) low = normalize(lowDb);
    } catch (_) {}

    // Transient detection BEFORE smoothing: a sharp jump in either band is
    // an impact (recoil-style feedback); smoothing would hide it.
    final events = <Map<String, num>>[];
    for (var i = 1; i < raw.length; i++) {
      final jump = raw[i] - raw[i - 1];
      final lowJump =
          i < low.length ? low[i] - low[i - 1] : 0.0;
      final fullHit = jump > 0.26 && raw[i] > 0.42;
      final bassHit = lowJump > 0.30 && i < low.length && low[i] > 0.5;
      if (fullHit || bassHit) {
        final punch =
            (jump > lowJump ? jump : lowJump).clamp(0.0, 1.0);
        // Merge with a hit in the previous window: keep the stronger punch.
        if (events.isNotEmpty &&
            (i * 250) - (events.last['t'] as num) <= 250) {
          if (punch > (events.last['power'] as num)) {
            events.last['power'] =
                double.parse(punch.toStringAsFixed(2));
          }
          continue;
        }
        events.add({
          't': i * 250, // ms into the video
          'power': double.parse(punch.toStringAsFixed(2)),
        });
        if (events.length >= 150) break;
      }
    }

    // Fast attack, slow decay: rises hit instantly (the hand feels the drop
    // of a beat), falls glide so the motor never sputters.
    final fine = <double>[];
    var level = raw.first;
    for (var i = 0; i < raw.length; i++) {
      level = raw[i] >= level ? raw[i] : level * 0.55 + raw[i] * 0.45;
      fine.add(double.parse(level.toStringAsFixed(3)));
    }
    return (fine, events);
  } catch (_) {
    return (const <double>[], const <Map<String, num>>[]);
  }
}



// ---------------------------------------------------------------------------
// FCM push notifications (service-account file via FCM_SERVICE_ACCOUNT env).
// ---------------------------------------------------------------------------

gauth.AutoRefreshingAuthClient? _fcmClient;
String? _fcmProject;

Future<gauth.AutoRefreshingAuthClient?> _fcm() async {
  if (_fcmClient != null) return _fcmClient;
  final env = Platform.environment['FCM_SERVICE_ACCOUNT'];
  if (env == null || env.isEmpty) return null;
  // Accept either the inline service-account JSON (Render env var) or a path
  // to a JSON file on disk (the VM setup).
  final raw = env.trimLeft().startsWith('{')
      ? env
      : (File(env).existsSync() ? await File(env).readAsString() : null);
  if (raw == null) return null;
  try {
    final json = jsonDecode(raw) as Map<String, dynamic>;
    _fcmProject = json['project_id'] as String?;
    final creds = gauth.ServiceAccountCredentials.fromJson(json);
    _fcmClient = await gauth.clientViaServiceAccount(
        creds, ['https://www.googleapis.com/auth/firebase.messaging']);
    return _fcmClient;
  } catch (e) {
    print('FCM init failed: $e');
    return null;
  }
}

/// Sends a push to a set of device tokens; dead tokens are pruned.
Future<void> _sendPush(List<String> tokens, String title, String body,
    {Map<String, String>? data}) async {
  final client = await _fcm();
  if (client == null || tokens.isEmpty) return;
  for (final token in tokens) {
    try {
      final res = await client.post(
        Uri.parse('https://fcm.googleapis.com/v1/projects/'
            '$_fcmProject/messages:send'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'message': {
            'token': token,
            'notification': {'title': title, 'body': body},
            if (data != null) 'data': data,
            'android': {
              'priority': 'high',
              'notification': {'channel_id': 'mrtouride_default'},
            },
          }
        }),
      );
      if (res.statusCode == 404 || res.statusCode == 400) {
        await _db.execute(
          Sql.named('DELETE FROM push_tokens WHERE token = @t'),
          parameters: {'t': token},
        );
      }
    } catch (_) {}
  }
}

/// Location-targeted fan-out for "new content in <city>": wave 1 = devices
/// in that city; wave 2 = everyone else EXCEPT those who opted into
/// location-only alerts. Sent in that order so locals hear first.
Future<void> _sendPushByLocation(
  String city,
  String title,
  String body, {
  int? excludeUserId,
  Map<String, String>? data,
}) async {
  try {
    final local = await _db.execute(
      Sql.named('SELECT token FROM push_tokens '
          'WHERE city ILIKE @c AND user_id IS DISTINCT FROM @x LIMIT 500'),
      parameters: {'c': city, 'x': excludeUserId},
    );
    final localTokens = [for (final r in local) r[0] as String];
    if (localTokens.isNotEmpty) {
      await _sendPush(localTokens, title, body, data: data);
    }
    final rest = await _db.execute(
      Sql.named('SELECT token FROM push_tokens '
          'WHERE (city IS NULL OR city NOT ILIKE @c) AND loc_only = false '
          'AND user_id IS DISTINCT FROM @x LIMIT 500'),
      parameters: {'c': city, 'x': excludeUserId},
    );
    final restTokens = [for (final r in rest) r[0] as String];
    if (restTokens.isNotEmpty) {
      await _sendPush(restTokens, title, body, data: data);
    }
  } catch (e) {
    print('location push failed: $e');
  }
}

Future<List<String>> _tokensFor({int? userId, int? excludeUserId}) async {
  final rows = await _db.execute(
    Sql.named('SELECT token FROM push_tokens '
        '${userId != null ? 'WHERE user_id = @u' : excludeUserId != null ? 'WHERE user_id IS DISTINCT FROM @x' : ''} '
        'LIMIT 500'),
    parameters: {
      if (userId != null) 'u': userId,
      if (excludeUserId != null) 'x': excludeUserId,
    },
  );
  return [for (final r in rows) r[0] as String];
}

/// Device registers (or refreshes) its FCM token.
Future<Response> _pushRegister(Request request) async {
  final body = await _readJsonBody(request);
  final token = (body?['token'] as String?)?.trim() ?? '';
  final userId = body?['userId'] as int?;
  if (token.isEmpty || token.length > 512) {
    return _json(400, {'error': 'token required'});
  }
  final city = ((body?['city'] as String?) ?? '').trim();
  final locOnly = body?['locOnly'] == true;
  await _db.execute(
    Sql.named('INSERT INTO push_tokens (token, user_id, city, loc_only) '
        'VALUES (@t, @u, @c, @l) '
        'ON CONFLICT (token) DO UPDATE SET user_id = @u, city = @c, '
        'loc_only = @l, updated_at = now()'),
    parameters: {'t': token, 'u': userId, 'c': city, 'l': locOnly},
  );
  return _json(200, {'ok': true});
}

// ---------------------------------------------------------------------------
// Admin panel (/admin) — Basic-auth gated user CRUD + activity/audit logs.
// Credentials come from ADMIN_USER / ADMIN_PASS env (never committed).
// ---------------------------------------------------------------------------

bool _adminAuthed(Request request) {
  final user = Platform.environment['ADMIN_USER'] ?? 'admin';
  final pass = Platform.environment['ADMIN_PASS'] ?? '';
  if (pass.isEmpty) return false; // panel disabled until configured
  final header = request.headers['authorization'] ?? '';
  if (!header.startsWith('Basic ')) return false;
  try {
    final decoded = utf8.decode(base64.decode(header.substring(6)));
    return decoded == '$user:$pass';
  } catch (_) {
    return false;
  }
}

Response _adminChallenge() => Response(401,
    headers: {'WWW-Authenticate': 'Basic realm="Mr.TourGuide Admin"'},
    body: 'Authentication required.');

Future<Response> _adminPage(Request request) async {
  if (!_adminAuthed(request)) return _adminChallenge();
  _logActivity('admin', 'admin-login', 'panel opened');
  return Response.ok(_adminHtml, headers: {'content-type': 'text/html'});
}

Future<Response> _adminUsers(Request request) async {
  if (!_adminAuthed(request)) return _adminChallenge();
  final rows = await _db.execute(
      'SELECT u.id, u.name, u.email, u.role, u.provider, u.verified, '
      'u.created_at, u.about, '
      '(SELECT count(*) FROM videos v WHERE v.owner_id = u.id), '
      '(SELECT count(*) FROM posts p WHERE p.author_id = u.id), '
      '(SELECT count(*) FROM itineraries i WHERE i.user_id = u.id) '
      'FROM users u ORDER BY u.id DESC');
  return _json(200, {
    'users': [
      for (final r in rows)
        {
          'id': r[0],
          'name': r[1],
          'email': r[2],
          'role': r[3],
          'provider': r[4],
          'verified': r[5],
          'joined': (r[6] as DateTime).toIso8601String(),
          'about': r[7],
          'uploads': r[8],
          'posts': r[9],
          'itineraries': r[10],
        }
    ]
  });
}

Future<Response> _adminCreateUser(Request request) async {
  if (!_adminAuthed(request)) return _adminChallenge();
  final body = await _readJsonBody(request);
  final name = (body?['name'] as String?)?.trim() ?? '';
  final email = (body?['email'] as String?)?.trim().toLowerCase() ?? '';
  final password = body?['password'] as String? ?? '';
  final role = body?['role'] == 'creator' ? 'creator' : 'traveler';
  if (name.isEmpty || !email.contains('@') || password.length < 6) {
    return _json(400,
        {'error': 'Name, valid email and a 6+ char password required.'});
  }
  final salt = _newSalt();
  try {
    final rows = await _db.execute(
      Sql.named('INSERT INTO users (name, email, password_hash, salt, role, '
          "provider, verified) VALUES (@n, @e, @h, @s, @r, 'password', true) "
          'RETURNING id'),
      parameters: {
        'n': name,
        'e': email,
        'h': _hashPassword(password, salt),
        's': salt,
        'r': role,
      },
    );
    _logActivity('admin', 'admin-user-created', '$name <$email> role=$role');
    return _json(201, {'id': rows.first[0]});
  } catch (_) {
    return _json(409, {'error': 'That email already has an account.'});
  }
}

Future<Response> _adminUpdateUser(Request request, String id) async {
  if (!_adminAuthed(request)) return _adminChallenge();
  final userId = int.tryParse(id);
  if (userId == null) return _json(400, {'error': 'Bad user id.'});
  final body = await _readJsonBody(request);
  final name = (body?['name'] as String?)?.trim();
  final role = body?['role'] as String?;
  final verified = body?['verified'] as bool?;
  final rows = await _db.execute(
    Sql.named('UPDATE users SET '
        'name = COALESCE(@n, name), '
        'role = COALESCE(@r, role), '
        'verified = COALESCE(@v, verified) '
        'WHERE id = @id RETURNING name, email'),
    parameters: {
      'n': (name?.isEmpty ?? true) ? null : name,
      'r': const ['creator', 'traveler'].contains(role) ? role : null,
      'v': verified,
      'id': userId,
    },
  );
  if (rows.isEmpty) return _json(404, {'error': 'User not found.'});
  _logActivity('admin', 'admin-user-updated',
      '#$userId ${rows.first[0]} <${rows.first[1]}> '
      '${name != null ? 'name→$name ' : ''}'
      '${role != null ? 'role→$role ' : ''}'
      '${verified != null ? 'verified→$verified' : ''}');
  return _json(200, {'ok': true});
}

Future<Response> _adminDeleteUser(Request request, String id) async {
  if (!_adminAuthed(request)) return _adminChallenge();
  final userId = int.tryParse(id);
  if (userId == null) return _json(400, {'error': 'Bad user id.'});
  final exists = await _db.execute(
    Sql.named('SELECT name, email, role, created_at FROM users WHERE id = @id'),
    parameters: {'id': userId},
  );
  if (exists.isEmpty) return _json(404, {'error': 'User not found.'});
  final u = exists.first;
  try {
    for (final sql in [
      'DELETE FROM place_ratings WHERE user_id = @id',
      'DELETE FROM reactions WHERE user_id = @id',
      // Community history stays — marked so readers know.
      "UPDATE posts SET author_name = author_name || ' (account deleted)' "
          "WHERE author_id = @id AND author_name NOT LIKE '%(account deleted)'",
      "UPDATE replies SET author_name = author_name || ' (account deleted)' "
          "WHERE author_id = @id AND author_name NOT LIKE '%(account deleted)'",
      'DELETE FROM follows WHERE follower_id = @id OR followee_id = @id',
      'DELETE FROM push_tokens WHERE user_id = @id',
      'DELETE FROM videos WHERE owner_id = @id',
      'DELETE FROM users WHERE id = @id',
    ]) {
      await _db.execute(Sql.named(sql), parameters: {'id': userId});
    }
    _sendEmail(
            u[1] as String,
            'Your Mr.Tour Guide account was removed',
            _accountDeletedHtml(u[0] as String, byAdmin: true))
        .then((_) {});
    _logActivity(
        'admin',
        'user-deleted',
        '${u[0]} <${u[1]}> role=${u[2]} '
            'joined=${(u[3] as DateTime).toIso8601String().substring(0, 10)} '
            '(removed by admin)');
    return _json(200, {'ok': true});
  } catch (_) {
    return _json(500, {'error': 'Could not delete the user.'});
  }
}

/// Admin: list places with stats.
Future<Response> _adminCities(Request request) async {
  if (!_adminAuthed(request)) return _adminChallenge();
  final rows = await _db.execute(
      'SELECT c.slug, c.name, c.location, c.description, c.cover_url, '
      "(SELECT count(*) FROM videos v WHERE v.city = c.slug), "
      '(SELECT count(*) FROM place_ratings pr WHERE pr.city_slug = c.slug) '
      'FROM cities c ORDER BY c.name');
  return _json(200, {
    'cities': [
      for (final r in rows)
        {
          'slug': r[0],
          'name': r[1],
          'location': r[2],
          'description': r[3],
          'coverUrl': r[4],
          'videos': r[5],
          'ratings': r[6],
        }
    ]
  });
}

/// Admin: add a place — the HD cover embeds automatically.
Future<Response> _adminAddCity(Request request) async {
  if (!_adminAuthed(request)) return _adminChallenge();
  final body = await _readJsonBody(request);
  final name = (body?['name'] as String?)?.trim() ?? '';
  final location = (body?['location'] as String?)?.trim() ?? '';
  final description = (body?['description'] as String?)?.trim() ?? '';
  if (name.isEmpty || name.length > 60) {
    return _json(400, {'error': 'Name required (max 60 chars).'});
  }
  final slug = name
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final dup = await _db.execute(
    Sql.named('SELECT 1 FROM cities WHERE slug = @s'),
    parameters: {'s': slug},
  );
  if (dup.isNotEmpty) return _json(409, {'error': 'Place already exists.'});
  await _db.execute(
    Sql.named('INSERT INTO cities (slug, name, location, description, '
        'rating, owner_id) VALUES (@s, @n, @l, @d, 4.5, @owner)'),
    parameters: {
      's': slug,
      'n': name,
      'owner': null,
      'l': location,
      'd': description.isEmpty
          ? 'A new destination on Mr.TourGuide — experiences coming soon.'
          : description,
    },
  );
  _logActivity('admin', 'city-added', '$name ($slug)');
  _autoCityCover(slug, name, location); // HD cover embeds itself
  await _cacheBust('cities');
  return _json(201, {'slug': slug});
}

/// Admin: update a place; empty cover_url triggers a fresh auto-embed.
/// Creator manages a place from the app: edit details / refresh the cover
/// image / delete. Mirrors the admin tools but gated on the creator role.
/// Strict ownership: the place's owner_id must match — creators manage only
/// places THEY added (legacy places without an owner stay admin-only).
Future<Response?> _requireCityOwner(String slug, int? userId) async {
  if (userId == null) return _json(401, {'error': 'Sign in first.'});
  final rows = await _db.execute(
    Sql.named('SELECT owner_id FROM cities WHERE slug = @s'),
    parameters: {'s': slug},
  );
  if (rows.isEmpty) return _json(404, {'error': 'Place not found.'});
  if (rows.first[0] != userId) {
    return _json(403,
        {'error': 'Only the creator who added this place can manage it.'});
  }
  return null;
}

Future<Response> _editCity(Request request, String slug) async {
  final body = await _readJsonBody(request);
  final gate = await _requireCityOwner(slug, body?['userId'] as int?);
  if (gate != null) return gate;
  final name = (body?['name'] as String?)?.trim();
  final location = (body?['location'] as String?)?.trim();
  final description = (body?['description'] as String?)?.trim();
  final refreshCover = body?['refreshCover'] == true;
  final rows = await _db.execute(
    Sql.named('UPDATE cities SET '
        'name = COALESCE(@n, name), '
        'location = COALESCE(@l, location), '
        'description = COALESCE(@d, description) '
        '${refreshCover ? ', cover_url = NULL ' : ''}'
        'WHERE slug = @s RETURNING name, location'),
    parameters: {
      'n': (name?.isEmpty ?? true) ? null : name,
      'l': (location?.isEmpty ?? true) ? null : location,
      'd': (description?.isEmpty ?? true) ? null : description,
      's': slug,
    },
  );
  if (rows.isEmpty) return _json(404, {'error': 'Place not found.'});
  _logActivity('user:${body?['userId']}', 'city-updated', slug);
  if (refreshCover) {
    _autoCityCover(
        slug, rows.first[0] as String, rows.first[1] as String? ?? '');
  }
  await _cacheBust('cities');
  await _cacheBust('videos');
  return _json(200, {'ok': true});
}

Future<Response> _removeCity(Request request, String slug) async {
  final body = await _readJsonBody(request);
  final gate = await _requireCityOwner(slug, body?['userId'] as int?);
  if (gate != null) return gate;
  final exists = await _db.execute(
    Sql.named('SELECT name FROM cities WHERE slug = @s'),
    parameters: {'s': slug},
  );
  if (exists.isEmpty) return _json(404, {'error': 'Place not found.'});
  for (final sql in [
    'DELETE FROM place_ratings WHERE city_slug = @s',
    'DELETE FROM place_comments WHERE city_slug = @s',
    'DELETE FROM videos WHERE city = @s',
    'DELETE FROM cities WHERE slug = @s',
  ]) {
    try {
      await _db.execute(Sql.named(sql), parameters: {'s': slug});
    } catch (_) {}
  }
  _logActivity('user:${body?['userId']}', 'city-deleted',
      '${exists.first[0]} ($slug)');
  await _cacheBust('cities');
  await _cacheBust('videos');
  return _json(200, {'ok': true});
}

Future<Response> _adminUpdateCity(Request request, String slug) async {
  if (!_adminAuthed(request)) return _adminChallenge();
  final body = await _readJsonBody(request);
  final name = (body?['name'] as String?)?.trim();
  final location = (body?['location'] as String?)?.trim();
  final description = (body?['description'] as String?)?.trim();
  final refreshCover = body?['refreshCover'] == true;
  final rows = await _db.execute(
    Sql.named('UPDATE cities SET '
        'name = COALESCE(@n, name), '
        'location = COALESCE(@l, location), '
        'description = COALESCE(@d, description) '
        '${refreshCover ? ', cover_url = NULL ' : ''}'
        'WHERE slug = @s RETURNING name, location'),
    parameters: {
      'n': (name?.isEmpty ?? true) ? null : name,
      'l': location,
      'd': (description?.isEmpty ?? true) ? null : description,
      's': slug,
    },
  );
  if (rows.isEmpty) return _json(404, {'error': 'Place not found.'});
  _logActivity('admin', 'city-updated', '$slug');
  if (refreshCover) {
    _autoCityCover(
        slug, rows.first[0] as String, rows.first[1] as String? ?? '');
  }
  return _json(200, {'ok': true});
}

/// Admin: delete a place and everything published under it.
Future<Response> _adminDeleteCity(Request request, String slug) async {
  if (!_adminAuthed(request)) return _adminChallenge();
  final exists = await _db.execute(
    Sql.named('SELECT name FROM cities WHERE slug = @s'),
    parameters: {'s': slug},
  );
  if (exists.isEmpty) return _json(404, {'error': 'Place not found.'});
  for (final sql in [
    'DELETE FROM place_ratings WHERE city_slug = @s',
    'DELETE FROM videos WHERE city = @s',
    'DELETE FROM cities WHERE slug = @s',
  ]) {
    await _db.execute(Sql.named(sql), parameters: {'s': slug});
  }
  _logActivity('admin', 'city-deleted', '${exists.first[0]} ($slug)');
  return _json(200, {'ok': true});
}

/// Admin: fire a live welcome mail and report Brevo's verdict.
Future<Response> _adminTestMail(Request request) async {
  if (!_adminAuthed(request)) return _adminChallenge();
  final to = request.url.queryParameters['to'] ?? '';
  if (!to.contains('@')) return _json(400, {'error': 'to=<email> required'});
  final ok = await _sendEmail(
      to, 'Welcome to Mr.Tour Guide! 🌏', _welcomeEmailHtml('Test Traveler'));
  return _json(200, {'sent': ok});
}

Future<Response> _adminLogs(Request request) async {
  if (!_adminAuthed(request)) return _adminChallenge();
  final action = request.url.queryParameters['action'];
  final rows = await _db.execute(
    Sql.named('SELECT at, actor, action, details FROM activity_logs '
        '${action != null ? 'WHERE action = @a ' : ''}'
        'ORDER BY at DESC LIMIT 200'),
    parameters: {if (action != null) 'a': action},
  );
  return _json(200, {
    'logs': [
      for (final r in rows)
        {
          'at': (r[0] as DateTime).toIso8601String(),
          'actor': r[1],
          'action': r[2],
          'details': r[3],
        }
    ]
  });
}

const _adminHtml = r"""<!doctype html><html><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex,nofollow"><title>Mr.TourGuide Admin</title>
<style>
:root{--bg:#0e1116;--card:#171c24;--ink:#e8ecf2;--mut:#8b95a5;--blue:#3cebff;--purple:#b17ff5;--red:#ff6b6b;--green:#5bd6a2}
*{box-sizing:border-box;margin:0}body{background:var(--bg);color:var(--ink);font:14px/1.5 system-ui,sans-serif;padding:20px;max-width:1100px;margin:0 auto}
h1{font-size:20px;margin-bottom:2px}h1 span{color:var(--blue)}.sub{color:var(--mut);font-size:12px;margin-bottom:18px}
.tabs{display:flex;gap:8px;margin-bottom:14px;flex-wrap:wrap}.tabs button{background:var(--card);color:var(--mut);border:1px solid #2a3240;padding:8px 16px;border-radius:10px;cursor:pointer;font-size:13px}
.tabs button.on{color:var(--ink);border-color:var(--blue)}
.card{background:var(--card);border:1px solid #232b38;border-radius:14px;padding:16px;margin-bottom:14px;overflow-x:auto}
table{width:100%;border-collapse:collapse;font-size:13px}th{color:var(--mut);text-align:left;font-weight:600;padding:6px 10px;border-bottom:1px solid #2a3240}
td{padding:8px 10px;border-bottom:1px solid #1d2430}tr.u{cursor:pointer}tr.u:hover{background:#1b2230}
.chip{display:inline-block;padding:1px 9px;border-radius:9px;font-size:11px;font-weight:700}
.creator{background:rgba(177,127,245,.15);color:var(--purple)}.traveler{background:rgba(60,235,255,.12);color:var(--blue)}
.ok{color:var(--green)}.no{color:var(--red)}
input,select{background:#0e1420;border:1px solid #2a3240;color:var(--ink);padding:8px 10px;border-radius:8px;font-size:13px;width:100%}
label{font-size:11px;color:var(--mut);display:block;margin:8px 0 3px}
.btn{background:var(--blue);color:#04222b;border:0;padding:9px 18px;border-radius:9px;font-weight:700;cursor:pointer;font-size:13px}
.btn.red{background:var(--red);color:#fff}.btn.ghost{background:transparent;border:1px solid #2a3240;color:var(--mut)}
.row{display:flex;gap:10px;flex-wrap:wrap}.row>div{flex:1;min-width:140px}
#modal{position:fixed;inset:0;background:rgba(0,0,0,.65);display:none;align-items:center;justify-content:center;padding:16px}
#modal .box{background:var(--card);border:1px solid #2a3240;border-radius:16px;padding:20px;width:100%;max-width:460px;max-height:90vh;overflow:auto}
.stat{display:inline-block;margin-right:14px;color:var(--mut);font-size:12px}.stat b{color:var(--ink);font-size:16px;display:block}
.log-act{font-weight:700}.act-login{color:var(--blue)}.act-signup{color:var(--green)}.act-user-deleted{color:var(--red)}
.act-video-upload{color:var(--purple)}.act-admin-login,.act-admin-user-created,.act-admin-user-updated{color:#f0b354}
.mut{color:var(--mut);font-size:12px}
</style></head><body>
<h1>Mr.Tour Guide <span>Admin</span></h1>
<div class="sub">User management · security activity · a product of PatienceAI</div>
<div class="tabs">
<button id="t-users" class="on" onclick="show('users')">Users</button>
<button id="t-logs" onclick="show('logs')">Activity logs</button>
<button id="t-deleted" onclick="show('deleted')">Deleted users</button>
<button id="t-add" onclick="show('add')">+ Add user</button>
<button id="t-places" onclick="show('places')">Places</button>
</div>
<div id="p-users" class="card"><div id="stats"></div><table><thead><tr>
<th>#</th><th>Name</th><th>Email</th><th>Role</th><th>Verified</th><th>Uploads</th><th>Posts</th><th>Joined</th>
</tr></thead><tbody id="users"></tbody></table></div>
<div id="p-logs" class="card" style="display:none"><table><thead><tr>
<th>When</th><th>Actor</th><th>Action</th><th>Details</th></tr></thead><tbody id="logs"></tbody></table></div>
<div id="p-deleted" class="card" style="display:none"><div class="mut" style="margin-bottom:8px">Every removed account with its details — self-service and admin removals.</div>
<table><thead><tr><th>When</th><th>Details</th></tr></thead><tbody id="deleted"></tbody></table></div>
<div id="p-add" class="card" style="display:none">
<div class="row"><div><label>Name</label><input id="a-name"></div><div><label>Email</label><input id="a-email"></div></div>
<div class="row"><div><label>Password</label><input id="a-pass" type="password"></div><div><label>Role</label>
<select id="a-role"><option value="traveler">Traveler</option><option value="creator">Creator</option></select></div></div>
<div style="margin-top:12px"><button class="btn" onclick="createUser()">Create user</button> <span id="a-msg" class="mut"></span></div></div>
<div id="p-places" class="card" style="display:none">
<div class="row" style="margin-bottom:14px">
<div><label>Place name</label><input id="c-name"></div>
<div><label>Location (City, Country)</label><input id="c-loc"></div>
<div><label>Description</label><input id="c-desc"></div>
</div>
<button class="btn" onclick="createCity()">Add place (HD cover auto-embeds)</button>
<span id="c-msg" class="mut"></span>
<table style="margin-top:14px"><thead><tr>
<th>Cover</th><th>Name</th><th>Location</th><th>Videos</th><th>Ratings</th><th></th></tr></thead>
<tbody id="cities"></tbody></table></div>
<div id="modal" onclick="if(event.target===this)this.style.display='none'"><div class="box">
<h3 id="m-title" style="margin-bottom:2px"></h3><div id="m-sub" class="mut" style="margin-bottom:10px"></div>
<div id="m-stats" style="margin-bottom:8px"></div>
<label>Name</label><input id="m-name">
<label>Role</label><select id="m-role"><option value="traveler">Traveler</option><option value="creator">Creator</option></select>
<label>Verified</label><select id="m-verified"><option value="true">Verified</option><option value="false">Not verified</option></select>
<div style="margin-top:14px;display:flex;gap:8px">
<button class="btn" onclick="saveUser()">Save changes</button>
<button class="btn red" onclick="deleteUser()">Delete user</button>
<button class="btn ghost" onclick="modal.style.display='none'">Close</button></div>
<div id="m-msg" class="mut" style="margin-top:8px"></div></div></div>
<script>
const modal=document.getElementById('modal');let current=null;
const esc=s=>String(s??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
function show(p){for(const x of ['users','logs','deleted','add','places']){document.getElementById('p-'+x).style.display=x===p?'':'none';document.getElementById('t-'+x).className=x===p?'on':''}
if(p==='users')loadUsers();if(p==='logs')loadLogs();if(p==='deleted')loadDeleted();if(p==='places')loadCities()}
async function api(path,opts){const r=await fetch('/admin/api/'+path,opts);if(!r.ok&&r.status===401){location.reload();return null}return r.json()}
async function loadUsers(){const d=await api('users');if(!d)return;const u=d.users;
document.getElementById('stats').innerHTML=
'<span class="stat"><b>'+u.length+'</b>total users</span><span class="stat"><b>'+u.filter(x=>x.role==='creator').length+'</b>creators</span>'+
'<span class="stat"><b>'+u.filter(x=>x.verified).length+'</b>verified</span>';
document.getElementById('users').innerHTML=u.map(x=>'<tr class="u" onclick=\'openUser('+JSON.stringify(x).replace(/'/g,"&#39;")+')\'>'+
'<td>'+x.id+'</td><td>'+esc(x.name)+'</td><td>'+esc(x.email)+'</td><td><span class="chip '+x.role+'">'+x.role+'</span></td>'+
'<td class="'+(x.verified?'ok':'no')+'">'+(x.verified?'✓':'✗')+'</td><td>'+x.uploads+'</td><td>'+x.posts+'</td>'+
'<td class="mut">'+x.joined.slice(0,10)+'</td></tr>').join('')}
function openUser(x){current=x;document.getElementById('m-title').textContent='#'+x.id+' '+x.name;
document.getElementById('m-sub').textContent=x.email+' · '+x.provider+' · joined '+x.joined.slice(0,10);
document.getElementById('m-stats').innerHTML='<span class="stat"><b>'+x.uploads+'</b>uploads</span><span class="stat"><b>'+x.posts+'</b>posts</span><span class="stat"><b>'+x.itineraries+'</b>itineraries</span>';
document.getElementById('m-name').value=x.name;document.getElementById('m-role').value=x.role;
document.getElementById('m-verified').value=String(x.verified);document.getElementById('m-msg').textContent='';
modal.style.display='flex'}
async function saveUser(){if(!current)return;const d=await api('users/'+current.id+'/update',{method:'POST',headers:{'content-type':'application/json'},
body:JSON.stringify({name:document.getElementById('m-name').value,role:document.getElementById('m-role').value,verified:document.getElementById('m-verified').value==='true'})});
document.getElementById('m-msg').textContent=d.error||'Saved.';if(!d.error){loadUsers();setTimeout(()=>modal.style.display='none',600)}}
async function deleteUser(){if(!current)return;if(!confirm('Permanently delete '+current.name+' and all their data?'))return;
const d=await api('users/'+current.id+'/delete',{method:'POST'});document.getElementById('m-msg').textContent=d.error||'Deleted.';
if(!d.error){loadUsers();setTimeout(()=>modal.style.display='none',600)}}
async function createUser(){const d=await api('users',{method:'POST',headers:{'content-type':'application/json'},
body:JSON.stringify({name:document.getElementById('a-name').value,email:document.getElementById('a-email').value,
password:document.getElementById('a-pass').value,role:document.getElementById('a-role').value})});
document.getElementById('a-msg').textContent=d.error||'Created — verified and ready to sign in.';if(!d.error)loadUsers()}
async function loadLogs(){const d=await api('logs');if(!d)return;
document.getElementById('logs').innerHTML=d.logs.map(l=>'<tr><td class="mut">'+l.at.slice(0,19).replace('T',' ')+'</td>'+
'<td>'+esc(l.actor)+'</td><td class="log-act act-'+l.action+'">'+l.action+'</td><td>'+esc(l.details)+'</td></tr>').join('')}
async function loadDeleted(){const d=await api('logs?action=user-deleted');if(!d)return;
document.getElementById('deleted').innerHTML=d.logs.map(l=>'<tr><td class="mut">'+l.at.slice(0,19).replace('T',' ')+'</td>'+
'<td>'+esc(l.details)+'</td></tr>').join('')||'<tr><td colspan=2 class="mut">No deletions yet.</td></tr>'}
async function loadCities(){const d=await api('cities');if(!d)return;
const tb=document.getElementById('cities');tb.innerHTML='';
for(const c of d.cities){const tr=document.createElement('tr');
const cov=c.coverUrl?'<img src="/api'+c.coverUrl+'" style="width:64px;height:40px;object-fit:cover;border-radius:6px">':'<span class="mut">auto…</span>';
tr.innerHTML='<td>'+cov+'</td><td><b>'+esc(c.name)+'</b><div class="mut">'+c.slug+'</div></td><td>'+esc(c.location||'')+'</td><td>'+c.videos+'</td><td>'+c.ratings+'</td><td style="white-space:nowrap"></td>';
const td=tr.lastElementChild;
const mk=(t,cls,fn)=>{const b=document.createElement('button');b.className=cls;b.textContent=t;b.onclick=fn;td.appendChild(b);td.append(' ')};
mk('Edit','btn ghost',()=>editCity(c.slug,c.name));mk('↻ Cover','btn ghost',()=>refreshCover(c.slug));mk('Delete','btn red',()=>deleteCity(c.slug));
tb.appendChild(tr)}}
async function createCity(){const d=await api('cities',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({name:document.getElementById('c-name').value,location:document.getElementById('c-loc').value,description:document.getElementById('c-desc').value})});
document.getElementById('c-msg').textContent=d.error||'Added — cover embedding…';if(!d.error)setTimeout(loadCities,4000)}
async function editCity(slug,cur){const name=prompt('New name for '+cur+' (blank = keep):','');const loc=prompt('New location (blank = keep):','');
const d=await api('cities/'+slug+'/update',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({name:name||null,location:loc||null})});if(d.error)alert(d.error);loadCities()}
async function refreshCover(slug){await api('cities/'+slug+'/update',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({refreshCover:true})});setTimeout(loadCities,5000)}
async function deleteCity(slug){if(!confirm('Delete '+slug+' and ALL its experiences?'))return;
const d=await api('cities/'+slug+'/delete',{method:'POST'});if(d.error)alert(d.error);loadCities()}
loadUsers();
</script></body></html>""";

// ---------------------------------------------------------------------------
// Auth handlers
// ---------------------------------------------------------------------------

/// Sends a transactional email via Brevo. Returns true on success.
/// When BREVO_API_KEY is unset (local dev), returns false so callers fall
/// back to the on-screen dev code.
Future<bool> _sendEmail(String to, String subject, String html) async {
  final key = Platform.environment['BREVO_API_KEY'];
  if (key == null || key.isEmpty) return false;
  final sender = Platform.environment['BREVO_SENDER_EMAIL'] ?? 'info@patienceai.in';
  final senderName = Platform.environment['BREVO_SENDER_NAME'] ?? 'Mr.Tour Guide';
  try {
    final client = HttpClient();
    final req = await client.postUrl(Uri.parse('https://api.brevo.com/v3/smtp/email'));
    req.headers.set('api-key', key);
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({
      'sender': {'name': senderName, 'email': sender},
      'to': [{'email': to}],
      'subject': subject,
      'htmlContent': html,
    }));
    final res = await req.close();
    final bodyText = await res.transform(utf8.decoder).join();
    client.close();
    final ok = res.statusCode == 201;
    _logActivity('system', ok ? 'mail-sent' : 'mail-failed',
        '"$subject" → $to (HTTP ${res.statusCode}'
        '${ok ? '' : ': ${bodyText.length > 120 ? bodyText.substring(0, 120) : bodyText}'})');
    return ok;
  } catch (e) {
    _logActivity('system', 'mail-failed', '"$subject" → $to ($e)');
    return false;
  }
}

/// Layman-friendly welcome mail: what the app does, with visuals.
String _welcomeEmailHtml(String name) => '''
<div style="font-family:system-ui,sans-serif;max-width:560px;margin:0 auto;background:#0e1116;color:#e8ecf2;border-radius:16px;overflow:hidden">
  <div style="background:linear-gradient(135deg,#1E319D,#3CEBFF);padding:34px 28px;text-align:center">
    <div style="font-size:26px;font-weight:800;color:#fff">Mr.Tour Guide</div>
    <div style="font-size:13px;color:#e6faff;margin-top:4px">Travel with your senses. From home.</div>
  </div>
  <div style="padding:28px">
    <p style="font-size:16px">Hi <b>$name</b>, welcome aboard! 🎉</p>
    <p style="font-size:14px;line-height:1.6;color:#c7cfdb">Mr.Tour Guide lets you <b>feel</b> places — not just watch them. Here is what you can do right away:</p>
    <table style="width:100%;border-collapse:collapse;margin-top:8px">
      <tr><td style="font-size:26px;padding:10px 12px 10px 0">📳</td><td style="font-size:13.5px;line-height:1.55;color:#e8ecf2;padding:10px 0"><b>Feel every video.</b> Your phone vibrates with the sound of each place — waves, bells, crowds — light to heavy, like being there.</td></tr>
      <tr><td style="font-size:26px;padding:10px 12px 10px 0">🥽</td><td style="font-size:13.5px;line-height:1.55;color:#e8ecf2;padding:10px 0"><b>Step inside with VR.</b> 360° experiences open in headset view — try the free <b>Feel Demo</b> place first.</td></tr>
      <tr><td style="font-size:26px;padding:10px 12px 10px 0">🤖</td><td style="font-size:13.5px;line-height:1.55;color:#e8ecf2;padding:10px 0"><b>Plan trips by chatting.</b> Ask the AI planner anything — "3 days in the mountains" — then keep tweaking: add a day, make it cheaper.</td></tr>
      <tr><td style="font-size:26px;padding:10px 12px 10px 0">📷</td><td style="font-size:13.5px;line-height:1.55;color:#e8ecf2;padding:10px 0"><b>Share your journeys.</b> Post photos and experiences, follow fellow travelers, and upload your own videos for others to feel.</td></tr>
    </table>
    <div style="text-align:center;margin:26px 0 10px">
      <a href="https://mrtourguide.patienceai.in" style="background:#3CEBFF;color:#04222b;text-decoration:none;font-weight:700;padding:13px 30px;border-radius:12px;font-size:14px">Start exploring</a>
    </div>
    <p style="font-size:11px;color:#8b95a5;text-align:center;margin-top:22px">Mr.Tour Guide · A product of <a href="https://patienceai.in" style="color:#3CEBFF">PatienceAI</a></p>
  </div>
</div>
''';

/// Sent when an account is removed (self-service or by moderation).
String _accountDeletedHtml(String name, {required bool byAdmin}) => '''
<div style="font-family:system-ui,sans-serif;max-width:520px;margin:0 auto;background:#0e1116;color:#e8ecf2;border-radius:16px;padding:30px">
  <div style="font-size:20px;font-weight:800;color:#3CEBFF;margin-bottom:14px">Mr.Tour Guide</div>
  <p style="font-size:14px;line-height:1.6">Hi <b>$name</b>,</p>
  <p style="font-size:14px;line-height:1.6;color:#c7cfdb">${byAdmin ? 'Your Mr.Tour Guide account has been removed by our moderation team.' : 'Your Mr.Tour Guide account has been deleted, as you requested.'} Your uploads, saved itineraries and personal details are gone; any community posts you wrote remain visible, marked as from a deleted account.</p>
  <p style="font-size:14px;line-height:1.6;color:#c7cfdb">You are welcome back any time — creating a new account takes a minute.</p>
  <p style="font-size:11px;color:#8b95a5;margin-top:20px">Mr.Tour Guide · A product of <a href="https://patienceai.in" style="color:#3CEBFF">PatienceAI</a></p>
</div>
''';

String _resetEmailHtml(String code) => '''
<div style="font-family:sans-serif;max-width:480px;margin:0 auto;padding:24px">
  <h2 style="color:#1E319D">Mr.Tour Guide</h2>
  <p>Use this code to reset your password:</p>
  <p style="font-size:34px;letter-spacing:10px;font-weight:bold;color:#052933">$code</p>
  <p style="color:#777;font-size:13px">If you didn't request a password reset,
  you can safely ignore this email — your password stays unchanged.<br>
  Mr.Tour Guide · A product of PatienceAI · patienceai.in</p>
</div>''';

String _verifyEmailHtml(String code) => '''
<div style="font-family:sans-serif;max-width:480px;margin:0 auto;padding:24px">
  <h2 style="color:#1E319D">Mr.Tour Guide</h2>
  <p>Welcome! Use this code to verify your email:</p>
  <p style="font-size:34px;letter-spacing:10px;font-weight:bold;color:#052933">$code</p>
  <p style="color:#777;font-size:13px">If you didn't sign up, ignore this email.<br>
  Mr.Tour Guide · A product of PatienceAI · patienceai.in</p>
</div>''';

Future<Response> _signup(Request request) async {
  final body = await _readJsonBody(request);
  final name = (body?['name'] as String?)?.trim() ?? '';
  final email = (body?['email'] as String?)?.trim().toLowerCase() ?? '';
  final password = body?['password'] as String? ?? '';
  final role = body?['role'] == 'creator' ? 'creator' : 'traveler';

  if (name.isEmpty) return _json(400, {'error': 'Name Required!'});
  if (email.isEmpty || !email.contains('@')) {
    return _json(400, {'error': 'Valid Email Required!'});
  }
  if (password.length < 6) {
    return _json(400, {'error': 'The password provided is too weak.'});
  }
  if (body?['acceptedTerms'] != true) {
    return _json(400,
        {'error': 'Please accept the Terms & Privacy Policy to sign up.'});
  }

  final salt = _newSalt();
  final hash = _hashPassword(password, salt);
  // 6-digit email verification code. There is no SMTP locally, so the code
  // is printed to the server log AND returned as devCode — remove devCode
  // once a real mail provider is wired up.
  final code = (100000 + Random.secure().nextInt(900000)).toString();
  try {
    final rows = await _db.execute(
      Sql.named('INSERT INTO users (name, email, password_hash, salt, role, '
          "provider, verified, verify_code) "
          "VALUES (@name, @email, @hash, @salt, @role, 'password', false, @code) "
          'RETURNING id, name, email, role'),
      parameters: {
        'name': name,
        'email': email,
        'hash': hash,
        'salt': salt,
        'role': role,
        'code': code,
      },
    );
    final row = rows.first;
    _logActivity('user:${row[0]}', 'signup', '$name <$email> role=$role');
    final sent = await _sendEmail(
        email, 'Your Mr.Tour Guide verification code', _verifyEmailHtml(code));
    if (!sent) print('VERIFY-EMAIL (no mailer): code for $email is $code');
    return _json(201, {
      'id': row[0],
      'name': row[1],
      'email': row[2],
      'role': row[3],
      'needsVerification': true,
      if (!sent) 'devCode': code,
    });
  } on ServerException catch (e) {
    if (e.code == '23505') {
      return _json(409, {'error': 'The account already exists for that email.'});
    }
    rethrow;
  }
}

Future<Response> _verify(Request request) async {
  final body = await _readJsonBody(request);
  final email = (body?['email'] as String?)?.trim().toLowerCase() ?? '';
  final code = (body?['code'] as String?)?.trim() ?? '';
  if (email.isEmpty || code.isEmpty) {
    return _json(400, {'error': 'Email and code required.'});
  }
  final rows = await _db.execute(
    Sql.named('UPDATE users SET verified = true, verify_code = NULL '
        'WHERE email = @email AND verify_code = @code '
        'RETURNING id, name, email, role'),
    parameters: {'email': email, 'code': code},
  );
  if (rows.isEmpty) {
    return _json(400, {'error': 'Invalid verification code.'});
  }
  final row = rows.first;
  // First successful entry: greet them with the feature tour.
  _sendEmail(row[2] as String, 'Welcome to Mr.Tour Guide! 🌏',
          _welcomeEmailHtml(row[1] as String))
      .then((_) {});
  return _json(
      200, {'id': row[0], 'name': row[1], 'email': row[2], 'role': row[3]});
}

/// Forgot password: emails a 6-digit OTP (works for password accounts).
Future<Response> _forgotPassword(Request request) async {
  final body = await _readJsonBody(request);
  final email = (body?['email'] as String?)?.trim().toLowerCase() ?? '';
  if (email.isEmpty) return _json(400, {'error': 'Email required.'});
  final code = (100000 + Random.secure().nextInt(900000)).toString();
  final rows = await _db.execute(
    Sql.named("UPDATE users SET verify_code = @c WHERE email = @e "
        "AND provider = 'password' RETURNING name"),
    parameters: {'c': code, 'e': email},
  );
  if (rows.isEmpty) {
    return _json(404,
        {'error': 'No password account for that email (Google accounts '
            'sign in with Google).'});
  }
  final sent = await _sendEmail(email, 'Your Mr.Tour Guide password reset code',
      _resetEmailHtml(code));
  return _json(200, {'ok': true, if (!sent) 'devCode': code});
}

/// Reset password with the emailed OTP.
Future<Response> _resetPassword(Request request) async {
  final body = await _readJsonBody(request);
  final email = (body?['email'] as String?)?.trim().toLowerCase() ?? '';
  final code = (body?['code'] as String?)?.trim() ?? '';
  final newPassword = body?['newPassword'] as String? ?? '';
  if (email.isEmpty || code.isEmpty) {
    return _json(400, {'error': 'Email and code required.'});
  }
  if (newPassword.length < 6) {
    return _json(400, {'error': 'The new password is too weak (6+ chars).'});
  }
  final salt = _newSalt();
  final rows = await _db.execute(
    Sql.named('UPDATE users SET password_hash = @h, salt = @s, '
        'verify_code = NULL, verified = true '
        'WHERE email = @e AND verify_code = @c RETURNING id'),
    parameters: {
      'h': _hashPassword(newPassword, salt),
      's': salt,
      'e': email,
      'c': code,
    },
  );
  if (rows.isEmpty) return _json(400, {'error': 'Invalid or expired code.'});
  _logActivity('user:${rows.first[0]}', 'password-reset', email);
  return _json(200, {'ok': true});
}

Future<Response> _resendCode(Request request) async {
  final body = await _readJsonBody(request);
  final email = (body?['email'] as String?)?.trim().toLowerCase() ?? '';
  if (email.isEmpty) return _json(400, {'error': 'Email required.'});
  final code = (100000 + Random.secure().nextInt(900000)).toString();
  final rows = await _db.execute(
    Sql.named('UPDATE users SET verify_code = @code '
        'WHERE email = @email AND verified = false RETURNING id'),
    parameters: {'email': email, 'code': code},
  );
  if (rows.isEmpty) {
    return _json(404, {'error': 'No unverified account for that email.'});
  }
  final sent = await _sendEmail(
      email, 'Your Mr.Tour Guide verification code', _verifyEmailHtml(code));
  if (!sent) print('VERIFY-EMAIL (no mailer): new code for $email is $code');
  return _json(200, {'ok': true, if (!sent) 'devCode': code});
}

/// Google SSO.
///
/// In production the client sends a Google ID token which we verify against
/// Google's JWKS; here (local dev, no OAuth client id yet) the app sends the
/// chosen Google email directly. The account rules are identical either way:
///  - signup: creates a pre-verified 'google' account (Google owns the email)
///  - signin: only works for accounts created via Google; password accounts
///    are told to use their password; unknown emails are asked to sign up.
Future<Response> _googleAuth(Request request) async {
  final body = await _readJsonBody(request);
  final mode = body?['mode'] as String? ?? 'signin';
  final role = body?['role'] == 'creator' ? 'creator' : 'traveler';
  final idToken = (body?['idToken'] as String?)?.trim();

  String email = (body?['email'] as String?)?.trim().toLowerCase() ?? '';
  String name = (body?['name'] as String?)?.trim() ?? '';

  final clientId = Platform.environment['GOOGLE_CLIENT_ID'];
  if (idToken != null && idToken.isNotEmpty) {
    // Real SSO: validate the Google ID token (signature is checked by
    // Google's tokeninfo endpoint; we verify audience + verified email).
    try {
      final infoRaw = await _httpGetText(
          'https://oauth2.googleapis.com/tokeninfo?id_token='
          '${Uri.encodeQueryComponent(idToken)}');
      final info = jsonDecode(infoRaw) as Map<String, dynamic>;
      if (clientId != null && info['aud'] != clientId) {
        return _json(401, {'error': 'Google token audience mismatch.'});
      }
      if (info['email_verified'] != 'true' && info['email_verified'] != true) {
        return _json(401, {'error': 'Google email not verified.'});
      }
      email = (info['email'] as String).toLowerCase();
      if (name.isEmpty) name = info['name'] as String? ?? '';
    } catch (_) {
      return _json(401, {'error': 'Invalid Google sign-in token.'});
    }
  } else if (Platform.environment['ALLOW_DEV_GOOGLE'] != '1') {
    // Without a token only local dev mode may pass a bare email.
    return _json(401, {'error': 'Google sign-in requires a valid token.'});
  }

  if (email.isEmpty || !email.contains('@')) {
    return _json(400, {'error': 'Valid Google email required.'});
  }

  final existing = await _db.execute(
    Sql.named(
        'SELECT id, name, email, role, provider, avatar_url, about '
        'FROM users WHERE email = @email'),
    parameters: {'email': email},
  );

  if (mode == 'signup') {
    if (body?['acceptedTerms'] != true) {
      return _json(400,
          {'error': 'Please accept the Terms & Privacy Policy to sign up.'});
    }
    if (existing.isNotEmpty) {
      return _json(409, {'error': 'The account already exists for that email.'});
    }
    final rows = await _db.execute(
      Sql.named('INSERT INTO users (name, email, password_hash, salt, role, '
          "provider, verified) "
          "VALUES (@name, @email, '', '', @role, 'google', true) "
          'RETURNING id, name, email, role'),
      parameters: {
        'name': name.isEmpty ? email.split('@').first : name,
        'email': email,
        'role': role,
      },
    );
    final row = rows.first;
    _sendEmail(row[2] as String, 'Welcome to Mr.Tour Guide! 🌏',
            _welcomeEmailHtml(row[1] as String))
        .then((_) {});
    return _json(201,
        {'id': row[0], 'name': row[1], 'email': row[2], 'role': row[3]});
  }

  // signin
  if (existing.isEmpty) {
    return _json(404,
        {'error': 'No account found for that Google email. Please sign up first.'});
  }
  final row = existing.first;
  if (row[4] != 'google') {
    return _json(409, {
      'error':
          'This email signed up with a password. Sign in with your password instead.'
    });
  }
  return _json(200, {
    'id': row[0],
    'name': row[1],
    'email': row[2],
    'role': row[3],
    'avatarUrl': row[5],
    'about': row[6],
  });
}

Future<Response> _login(Request request) async {
  final body = await _readJsonBody(request);
  final email = (body?['email'] as String?)?.trim().toLowerCase() ?? '';
  final password = body?['password'] as String? ?? '';

  if (email.isEmpty || password.isEmpty) {
    return _json(400, {'error': 'Email and Password Required!'});
  }

  final rows = await _db.execute(
    Sql.named('SELECT id, name, email, password_hash, salt, role, provider, '
        'verified, avatar_url, about FROM users WHERE email = @email'),
    parameters: {'email': email},
  );
  if (rows.isEmpty) {
    return _json(404, {'error': 'No user found for that email.'});
  }
  final row = rows.first;
  if (row[6] == 'google') {
    return _json(409,
        {'error': 'This account uses Google Sign-In. Continue with Google.'});
  }
  final hash = _hashPassword(password, row[4] as String);
  if (!_constantTimeEquals(hash, row[3] as String)) {
    return _json(401, {'error': 'Wrong password provided for that user.'});
  }
  if (row[7] != true) {
    return _json(403, {
      'error': 'Please verify your email first.',
      'needsVerification': true,
    });
  }
  _logActivity('user:${row[0]}', 'login', '${row[1]} <${row[2]}>');
  return _json(200, {
    'id': row[0],
    'name': row[1],
    'email': row[2],
    'role': row[5],
    'avatarUrl': row[8],
    'about': row[9],
  });
}

// ---------------------------------------------------------------------------
// Video handlers
// ---------------------------------------------------------------------------

Future<Response> _cities(Request request) async {
  // ownerId: chip counters show only that creator's uploads.
  final owner = int.tryParse(request.url.queryParameters['ownerId'] ?? '');
  final join = owner == null
      ? "LEFT JOIN videos v ON v.city = c.slug AND v.status = 'ready'"
      : 'LEFT JOIN videos v ON v.city = c.slug AND v.owner_id = @owner';
  // Ratings are user-given only: average of real stars, 0 when unrated.
  final rows = await _db.execute(
      Sql.named('SELECT c.slug, c.name, COUNT(v.id), c.cover_url, c.location, '
          'c.description, '
          'COALESCE((SELECT avg(stars) FROM place_ratings pr '
          'WHERE pr.city_slug = c.slug), 0), '
          'c.model_url, '
          '(SELECT count(*) FROM place_ratings pr WHERE pr.city_slug = c.slug), '
          'c.owner_id '
          'FROM cities c '
          '$join '
          'GROUP BY c.slug, c.name, c.cover_url, c.location, c.description, '
          'c.model_url, c.owner_id ORDER BY c.name'),
      parameters: {if (owner != null) 'owner': owner});
  return _json(200, {
    'cities': [
      for (final r in rows)
        {
          'slug': r[0],
          'name': r[1],
          'videoCount': r[2],
          'coverUrl': r[3],
          'location': r[4],
          'description': r[5],
          'rating': double.parse(
              double.parse(r[6].toString()).toStringAsFixed(2)),
          'modelUrl': r[7],
          'ratingCount': r[8],
          'ownerId': r[9],
        }
    ]
  });
}

/// Reshare a post into the same community — original author is credited
/// and notified; the resharer is tagged on the new post.
Future<Response> _resharePost(Request request, String id) async {
  final postId = int.tryParse(id);
  final body = await _readJsonBody(request);
  final userId = body?['userId'] as int?;
  if (postId == null) return _json(400, {'error': 'Bad post id.'});
  if (userId == null) return _json(401, {'error': 'Sign in to reshare.'});
  final orig = await _db.execute(
    Sql.named('SELECT community, author_id, author_name, author_role, body, '
        'image_url, city, media FROM posts WHERE id = @p'),
    parameters: {'p': postId},
  );
  if (orig.isEmpty) return _json(404, {'error': 'Post not found.'});
  final gate = await _gateCommunity(orig.first[0] as String, userId);
  if (gate != null) return gate;
  final me = await _db.execute(
    Sql.named('SELECT name, role FROM users WHERE id = @u'),
    parameters: {'u': userId},
  );
  if (me.isEmpty) return _json(401, {'error': 'Unknown user.'});
  if (orig.first[1] == userId) {
    return _json(400, {'error': 'That is already your post.'});
  }
  final dup = await _db.execute(
    Sql.named('SELECT 1 FROM posts WHERE reshared_from = @p '
        'AND reshared_by_id = @u'),
    parameters: {'p': postId, 'u': userId},
  );
  if (dup.isNotEmpty) {
    return _json(409, {'error': 'You already reshared this post.'});
  }
  await _db.execute(
    Sql.named('INSERT INTO posts (community, author_id, author_name, '
        'author_role, body, image_url, city, media, reshared_from, '
        'reshared_by, reshared_by_id, reshared_by_role) '
        'VALUES (@c, @aid, @aname, @arole, @body, @img, @city, @media, '
        '@from, @by, @byId, @byRole)'),
    parameters: {
      'c': orig.first[0],
      'aid': orig.first[1],
      'aname': orig.first[2],
      'arole': orig.first[3],
      'body': orig.first[4],
      'img': orig.first[5],
      'city': orig.first[6],
      'media': orig.first[7] == null ? null : jsonEncode(orig.first[7]),
      'from': postId,
      'by': me.first[0],
      'byId': userId,
      'byRole': me.first[1],
    },
  );
  // Tell the original author their post is travelling.
  _tokensFor(userId: orig.first[1] as int).then((tokens) => _sendPush(
        tokens,
        'Your post was reshared',
        '${me.first[0]} reshared your post on Mr.TourGuide.',
        data: {'type': 'reshare'},
      ));
  _logActivity('user:$userId', 'post-reshared', 'post #$postId');
  return _json(201, {'ok': true});
}

/// The resharer adds or edits the comment on their reshare.
Future<Response> _reshareComment(Request request, String id) async {
  final postId = int.tryParse(id);
  final body = await _readJsonBody(request);
  final userId = body?['userId'] as int?;
  final comment = (body?['comment'] as String?)?.trim() ?? '';
  if (postId == null) return _json(400, {'error': 'Bad post id.'});
  if (userId == null) return _json(401, {'error': 'Sign in first.'});
  if (comment.length > 300) {
    return _json(400, {'error': 'Keep the comment under 300 characters.'});
  }
  final unsafe = _unsafeText(comment);
  if (unsafe != null) return _json(400, {'error': unsafe});
  final rows = await _db.execute(
    Sql.named('UPDATE posts SET reshare_comment = @c '
        'WHERE id = @id AND reshared_by_id = @u RETURNING id'),
    parameters: {
      'c': comment.isEmpty ? null : comment,
      'id': postId,
      'u': userId,
    },
  );
  if (rows.isEmpty) {
    return _json(403, {'error': 'Only the resharer can edit this.'});
  }
  return _json(200, {'ok': true});
}

/// A signed-in user rates a place 1-5 stars (one rating each, updatable).
Future<Response> _ratePlace(Request request, String slug) async {
  final body = await _readJsonBody(request);
  final userId = body?['userId'] as int?;
  final stars = body?['stars'] as int?;
  if (userId == null) return _json(401, {'error': 'Sign in to rate.'});
  if (stars == null || stars < 1 || stars > 5) {
    return _json(400, {'error': 'Rating must be 1-5 stars.'});
  }
  final known = await _db.execute(
    Sql.named('SELECT 1 FROM cities WHERE slug = @s'),
    parameters: {'s': _sanitizeFilename(slug)},
  );
  if (known.isEmpty) return _json(404, {'error': 'Unknown place.'});
  try {
    await _db.execute(
      Sql.named('INSERT INTO place_ratings (city_slug, user_id, stars) '
          'VALUES (@c, @u, @s) '
          'ON CONFLICT (city_slug, user_id) DO UPDATE SET stars = @s, '
          'created_at = now()'),
      parameters: {'c': slug, 'u': userId, 's': stars},
    );
  } catch (_) {
    return _json(401, {'error': 'Sign in to rate.'});
  }
  final agg = await _db.execute(
    Sql.named('SELECT COALESCE(avg(stars), 0), count(*) FROM place_ratings '
        'WHERE city_slug = @c'),
    parameters: {'c': slug},
  );
  return _json(200, {
    'rating': double.parse(
        double.parse(agg.first[0].toString()).toStringAsFixed(2)),
    'ratingCount': agg.first[1],
  });
}

/// Authoritative rating for a place + the caller's own stars (so the city
/// page shows a stable, correct rating and remembers what the user rated).
Future<Response> _placeRating(Request request, String slug) async {
  final userId = int.tryParse(request.url.queryParameters['userId'] ?? '');
  final agg = await _db.execute(
    Sql.named('SELECT COALESCE(avg(stars), 0), count(*) FROM place_ratings '
        'WHERE city_slug = @c'),
    parameters: {'c': slug},
  );
  var mine = 0;
  if (userId != null) {
    final r = await _db.execute(
      Sql.named('SELECT stars FROM place_ratings WHERE city_slug = @c '
          'AND user_id = @u'),
      parameters: {'c': slug, 'u': userId},
    );
    if (r.isNotEmpty) mine = r.first[0] as int;
  }
  return _json(200, {
    'rating': double.parse(
        double.parse(agg.first[0].toString()).toStringAsFixed(2)),
    'ratingCount': agg.first[1],
    'myStars': mine,
  });
}

Future<Response> _placeComments(Request request, String slug) async {
  final rows = await _db.execute(
    Sql.named('SELECT id, author_id, author_name, author_role, body, '
        'parent_id, created_at FROM place_comments WHERE city_slug = @c '
        'ORDER BY created_at, id LIMIT 300'),
    parameters: {'c': slug},
  );
  return _json(200, {
    'comments': [
      for (final r in rows)
        {
          'id': r[0],
          'authorId': r[1],
          'authorName': r[2],
          'authorRole': r[3],
          'body': r[4],
          'parentId': r[5],
          'createdAt': (r[6] as DateTime).toIso8601String(),
        }
    ]
  });
}

Future<Response> _addPlaceComment(Request request, String slug) async {
  final body = await _readJsonBody(request);
  final userId = body?['userId'] as int?;
  final text = (body?['body'] as String?)?.trim() ?? '';
  final parentId = body?['parentId'] as int?;
  if (userId == null) return _json(401, {'error': 'Sign in to comment.'});
  if (text.isEmpty) return _json(400, {'error': 'Say something first!'});
  if (text.length > 500) return _json(400, {'error': 'Keep it under 500 chars.'});
  final unsafe = _unsafeText(text);
  if (unsafe != null) return _json(400, {'error': unsafe});
  final user = await _db.execute(
    Sql.named('SELECT name, role FROM users WHERE id = @id'),
    parameters: {'id': userId},
  );
  if (user.isEmpty) return _json(401, {'error': 'Unknown user.'});
  await _db.execute(
    Sql.named('INSERT INTO place_comments (city_slug, author_id, author_name, '
        'author_role, body, parent_id) VALUES (@c, @a, @an, @ar, @b, @p)'),
    parameters: {
      'c': slug,
      'a': userId,
      'an': user.first[0],
      'ar': user.first[1],
      'b': text,
      'p': parentId,
    },
  );
  return _json(201, {'ok': true});
}

/// Owner deletes their own place comment.
Future<Response> _deletePlaceComment(Request request, String id) async {
  final commentId = int.tryParse(id);
  final body = await _readJsonBody(request);
  final userId = body?['userId'] as int?;
  if (commentId == null) return _json(400, {'error': 'Bad id.'});
  if (userId == null) return _json(401, {'error': 'Sign in first.'});
  final rows = await _db.execute(
    Sql.named('DELETE FROM place_comments WHERE id = @id AND author_id = @u '
        'RETURNING 1'),
    parameters: {'id': commentId, 'u': userId},
  );
  if (rows.isEmpty) return _json(403, {'error': 'Not your comment.'});
  return _json(200, {'ok': true});
}

/// Travel news: precautions, advisories and fresh ideas — Google News RSS
/// parsed server-side and cached 60 min (free-tier friendly).
final Map<String, (DateTime, Map<String, Object?>)> _newsCache = {};

/// Country-keyed publisher feeds. India keeps its rich local set; everywhere
/// else gets stable global travel desks. Feeds that fail are just skipped.
const _newsFeedsIndia = [
  ('https://timesofindia.indiatimes.com/rssfeeds/2647163.cms', 'TOI Travel'),
  ('https://www.hindustantimes.com/feeds/rss/lifestyle/travel/rssfeed.xml',
      'HT Travel'),
  ('https://www.indiatoday.in/rss/1206577', 'India Today'),
  ('https://www.thehindu.com/life-and-style/travel/feeder/default.rss',
      'The Hindu Travel'),
  ('https://travel.economictimes.indiatimes.com/rss/topstories',
      'ET TravelWorld'),
  ('https://www.news18.com/commonfeeds/v1/eng/rss/travel.xml', 'News18'),
];
const _newsFeedsGlobal = [
  ('https://www.theguardian.com/uk/travel/rss', 'The Guardian'),
  ('http://rss.cnn.com/rss/edition_travel.rss', 'CNN Travel'),
  ('https://rss.nytimes.com/services/xml/rss/nyt/Travel.xml', 'NYT Travel'),
];

Future<Response> _travelNews(Request request) async {
  final country =
      (request.url.queryParameters['country'] ?? 'india').trim().toLowerCase();
  final city = (request.url.queryParameters['city'] ?? '').trim().toLowerCase();
  final india = country.isEmpty || country.contains('india') || country == 'in';
  final key = india ? 'news.in' : 'news.global';
  final cached = _newsCache[key];
  if (cached != null &&
      DateTime.now().difference(cached.$1) < const Duration(minutes: 60)) {
    return _json(200, _rankNews(cached.$2, country, city));
  }
  final items = <Map<String, String>>[];
  // Publisher feeds: direct article URLs + real cover images (enclosures).
  final feeds = india
      ? [..._newsFeedsIndia, _newsFeedsGlobal.first]
      : _newsFeedsGlobal;
  for (final (feedUrl, sourceName) in feeds) {
    if (items.length >= 14) break;
    try {
      final xml = await _httpGetText(feedUrl,
              userAgent: 'Mozilla/5.0 (X11; Linux x86_64)')
          .timeout(const Duration(seconds: 10));
      String clean(String t) => t
          .replaceAll('<![CDATA[', '')
          .replaceAll(']]>', '')
          .replaceAll('&amp;', '&')
          .replaceAll('&#39;', "'")
          .replaceAll('&quot;', '"')
          .trim();
      for (final m
          in RegExp(r'<item>(.*?)</item>', dotAll: true).allMatches(xml)) {
        final item = m.group(1)!;
        final title = clean(RegExp(r'<title>(.*?)</title>', dotAll: true)
                .firstMatch(item)
                ?.group(1) ??
            '');
        final link = clean(RegExp(r'<link>(.*?)</link>', dotAll: true)
                .firstMatch(item)
                ?.group(1) ??
            '');
        if (title.isEmpty || !link.startsWith('http')) continue;
        final image = RegExp(r'<enclosure[^>]*url="([^"]+)"')
                .firstMatch(item)
                ?.group(1) ??
            RegExp(r'<media:content[^>]*url="([^"]+)"')
                .firstMatch(item)
                ?.group(1);
        final pub = RegExp(r'<pubDate>(.*?)</pubDate>', dotAll: true)
                .firstMatch(item)
                ?.group(1) ??
            '';
        items.add({
          'title': title,
          'url': link,
          'published': pub.trim(),
          'source': sourceName,
          if (image != null && image.startsWith('http')) 'image': image,
        });
        if (items.length >= 14) break;
      }
    } catch (_) {}
  }
  final payload = <String, Object?>{'items': items};
  if (items.isNotEmpty) _newsCache[key] = (DateTime.now(), payload);
  return _json(200, _rankNews(payload, country, city));
}

/// Reorders cached items so pieces mentioning the reader's city float to the
/// top, then their country — ranking is per-request, the cache stays shared.
Map<String, Object?> _rankNews(
    Map<String, Object?> payload, String country, String city) {
  final items = (payload['items'] as List?)?.cast<Map>() ?? const [];
  if (items.isEmpty || (city.isEmpty && country.isEmpty)) return payload;
  int score(Map it) {
    final t = '${it['title']}'.toLowerCase();
    if (city.isNotEmpty && t.contains(city)) return 2;
    if (country.isNotEmpty && t.contains(country)) return 1;
    return 0;
  }
  final ranked = [...items]..sort((a, b) => score(b).compareTo(score(a)));
  return {...payload, 'items': ranked.take(10).toList()};
}

/// Reverse geocoding proxy (OpenStreetMap Nominatim) — the upload sheet's
/// "Use my location". Cached per rounded coordinate; UA identifies us.
final Map<String, (DateTime, Map<String, Object?>)> _geoCache = {};

Future<Response> _geoReverse(Request request) async {
  final lat = double.tryParse(request.url.queryParameters['lat'] ?? '');
  final lon = double.tryParse(request.url.queryParameters['lon'] ?? '');
  if (lat == null || lon == null) {
    return _json(400, {'error': 'lat and lon required'});
  }
  final key = '${lat.toStringAsFixed(2)},${lon.toStringAsFixed(2)}';
  final cached = _geoCache[key];
  if (cached != null &&
      DateTime.now().difference(cached.$1) < const Duration(hours: 24)) {
    return _json(200, cached.$2);
  }
  try {
    final raw = await _httpGetText(
        'https://nominatim.openstreetmap.org/reverse?format=json'
        '&lat=$lat&lon=$lon&zoom=10&accept-language=en',
        userAgent: 'MrTourGuide/1.0 (info@patienceai.in)');
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final addr = (decoded['address'] as Map<String, dynamic>?) ?? {};
    final payload = <String, Object?>{
      'city': addr['city'] ??
          addr['town'] ??
          addr['village'] ??
          addr['suburb'] ??
          addr['county'] ??
          addr['state_district'] ??
          '',
      // Nominatim names the state differently by zoom/region — fall back
      // through every variant so it always auto-fills.
      'state': addr['state'] ??
          addr['state_district'] ??
          addr['region'] ??
          addr['province'] ??
          addr['county'] ??
          '',
      'country': addr['country'] ?? '',
    };
    _geoCache[key] = (DateTime.now(), payload);
    return _json(200, payload);
  } catch (_) {
    return _json(502, {'error': 'Could not resolve the location.'});
  }
}

/// Creator enrolls a new place on the platform (city/monument/region).
Future<Response> _addCity(Request request) async {
  final body = await _readJsonBody(request);
  final userId = body?['userId'] as int?;
  final name = (body?['name'] as String?)?.trim() ?? '';
  final location = (body?['location'] as String?)?.trim() ?? '';
  final description = (body?['description'] as String?)?.trim() ?? '';
  if (userId == null || await _roleOf(userId) != 'creator') {
    return _json(403, {'error': 'Only creator accounts can add places.'});
  }
  if (name.isEmpty || name.length > 60) {
    return _json(400, {'error': 'Give the place a name (max 60 chars).'});
  }
  final slug = name
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  if (slug.isEmpty) return _json(400, {'error': 'Invalid place name.'});
  final dup = await _db.execute(
    Sql.named('SELECT 1 FROM cities WHERE slug = @s'),
    parameters: {'s': slug},
  );
  if (dup.isNotEmpty) {
    return _json(409, {'error': 'That place is already on the platform.'});
  }
  await _db.execute(
    Sql.named('INSERT INTO cities (slug, name, location, description, '
        'rating, owner_id) VALUES (@s, @n, @l, @d, 4.5, @owner)'),
    parameters: {
      's': slug,
      'n': name,
      'owner': userId,
      'l': location,
      'd': description.isEmpty
          ? 'A new destination on Mr.TourGuide — experiences coming soon.'
          : description,
    },
  );
  _logActivity('user:$userId', 'city-added', '$name ($slug) $location');
  // Fire-and-forget: fetch a high-res cover so the place looks alive
  // in the carousel and hero the moment it exists.
  _autoCityCover(slug, name, location);
  await _cacheBust('cities');
  return _json(201, {'slug': slug, 'name': name});
}

/// Finds a high-resolution photo of the place (Wikipedia article lead
/// image at 1920px) and installs it as the city cover.
Future<void> _autoCityCover(String slug, String name, String location) async {
  File? tmpIn;
  File? tmpOut;
  HttpClient? client;
  try {
    final q = Uri.encodeQueryComponent(
        location.isEmpty ? name : '$name ${location.split(',').first}');
    final body = await _httpGetText(
            'https://en.wikipedia.org/w/api.php?action=query&format=json'
            '&generator=search&gsrsearch=$q&gsrlimit=5'
            '&prop=pageimages&piprop=thumbnail&pithumbsize=1920')
        .timeout(const Duration(seconds: 15));
    final decoded = jsonDecode(body) as Map<String, dynamic>;
    final pages = (decoded['query']?['pages'] as Map<String, dynamic>?) ?? {};
    final entries = pages.values.toList()
      ..sort((a, b) =>
          ((a['index'] as num?) ?? 99).compareTo((b['index'] as num?) ?? 99));
    String? imgUrl;
    for (final p in entries) {
      final t =
          (p['thumbnail'] as Map<String, dynamic>?)?['source'] as String?;
      if (t == null) continue;
      final lower = t.toLowerCase();
      if (lower.contains('.pdf') ||
          lower.contains('.djvu') ||
          lower.contains('.tif') ||
          lower.endsWith('.svg.png')) {
        continue;
      }
      imgUrl = t;
      break;
    }
    if (imgUrl == null) return;
    client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    final req = await client
        .getUrl(Uri.parse(imgUrl))
        .timeout(const Duration(seconds: 15));
    req.headers.set('User-Agent', 'MrTourGuide/1.0 (info@patienceai.in)');
    final res = await req.close().timeout(const Duration(seconds: 15));
    final bytes = <int>[];
    var oversized = false;
    await for (final chunk
        in res.timeout(const Duration(seconds: 30), onTimeout: (sink) {
      sink.close();
    })) {
      bytes.addAll(chunk);
      if (bytes.length > 12 * 1024 * 1024) {
        oversized = true; // reject, never process a truncated image
        break;
      }
    }
    if (oversized || bytes.length < 10240) return;
    final stamp = DateTime.now().millisecondsSinceEpoch;
    tmpIn = File('${Directory.systemTemp.path}/mrt_cc_$stamp.img');
    await tmpIn.writeAsBytes(bytes);
    tmpOut = File('${Directory.systemTemp.path}/mrt_cc_$stamp.jpg');
    final result = await Process.run('ffmpeg', [
      '-y', '-loglevel', 'error',
      '-i', tmpIn.path,
      '-vf', "scale='trunc(min(1920,iw)/2)*2':-2",
      '-q:v', '4',
      tmpOut.path,
    ]).timeout(const Duration(minutes: 2));
    if (result.exitCode != 0 || !await tmpOut.exists()) return;
    final coverName = 'autocover_$slug$stamp.jpg';
    await _storage.save(
        slug, coverName, Stream.value(await tmpOut.readAsBytes()));
    // Never clobber a creator-uploaded cover.
    await _db.execute(
      Sql.named('UPDATE cities SET cover_url = COALESCE(cover_url, @c) '
          'WHERE slug = @s'),
      parameters: {'c': '/files/$slug/$coverName', 's': slug},
    );
    _logActivity('system', 'auto-cover', '$name ($slug) ← Wikipedia HD');
  } catch (_) {
  } finally {
    client?.close(force: true);
    try {
      if (tmpIn != null && await tmpIn.exists()) await tmpIn.delete();
    } catch (_) {}
    try {
      if (tmpOut != null && await tmpOut.exists()) await tmpOut.delete();
    } catch (_) {}
  }
}

/// Creator: upload a high-res cover image for a city (raw bytes).
/// The cover shows in the app's home carousel and place page hero.
Future<Response> _uploadCover(Request request, String city) async {
  final coverUser = int.tryParse(request.url.queryParameters['userId'] ?? '');
  if (coverUser == null || await _roleOf(coverUser) != 'creator') {
    return _json(403, {'error': 'Only creator accounts can change covers.'});
  }
  final known = await _db.execute(
    Sql.named('SELECT 1 FROM cities WHERE slug = @city'),
    parameters: {'city': _sanitizeFilename(city)},
  );
  if (known.isEmpty) return _json(404, {'error': 'Unknown city: $city'});

  final original =
      _sanitizeFilename(request.url.queryParameters['filename'] ?? 'cover.jpg');
  final stored = 'cover_${DateTime.now().millisecondsSinceEpoch}_$original';
  final int size;
  try {
    size = await _storage.save(city, stored, request.read());
  } on FormatException {
    return _json(413, {'error': 'File exceeds the 500 MB upload limit.'});
  }
  if (size == 0) return _json(400, {'error': 'Empty upload body.'});

  final url = '/files/$city/$stored';
  await _db.execute(
    Sql.named('UPDATE cities SET cover_url = @url WHERE slug = @city'),
    parameters: {'url': url, 'city': city},
  );
  return _json(201, {'coverUrl': url});
}

// City weather: live temperature via Open-Meteo (free, keyless), cached
// 10 minutes per city so we are a polite client.
final Map<String, (DateTime, Map<String, Object?>)> _weatherCache = {};

String _weatherDescription(int code) {
  if (code == 0) return 'Clear sky';
  if (code <= 3) return 'Partly cloudy';
  if (code <= 48) return 'Foggy';
  if (code <= 57) return 'Drizzle';
  if (code <= 67) return 'Rain';
  if (code <= 77) return 'Snow';
  if (code <= 82) return 'Showers';
  if (code <= 99) return 'Thunderstorm';
  return 'Unknown';
}

/// Name → coordinates via open-meteo's keyless geocoder (first match).
Future<(double, double)?> _geocodePlace(String name) async {
  try {
    final client = HttpClient();
    final req = await client.getUrl(Uri.parse(
        'https://geocoding-api.open-meteo.com/v1/search'
        '?name=${Uri.encodeQueryComponent(name)}&count=1'));
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    client.close();
    final decoded = jsonDecode(body) as Map<String, dynamic>;
    final results = decoded['results'] as List?;
    if (results == null || results.isEmpty) return null;
    final r = results.first as Map<String, dynamic>;
    return ((r['latitude'] as num).toDouble(), (r['longitude'] as num).toDouble());
  } catch (_) {
    return null;
  }
}

Future<Response> _weather(Request request, String slug) async {
  final cached = _weatherCache[slug];
  if (cached != null &&
      DateTime.now().difference(cached.$1) < const Duration(minutes: 10)) {
    return _json(200, cached.$2);
  }
  final rows = await _db.execute(
    Sql.named('SELECT name, lat, lon FROM cities WHERE slug = @slug'),
    parameters: {'slug': slug},
  );
  if (rows.isEmpty) {
    return _json(404, {'error': 'No weather available for $slug.'});
  }
  Object? lat = rows.first[1], lon = rows.first[2];
  if (lat == null || lon == null) {
    // New places get coordinates automatically: geocode by name once, save,
    // and every later request is a plain lookup — creator-added places show
    // live temperature exactly like the seeded ones.
    final geo = await _geocodePlace(rows.first[0] as String);
    if (geo == null) {
      return _json(404, {'error': 'No weather available for $slug.'});
    }
    lat = geo.$1;
    lon = geo.$2;
    await _db.execute(
      Sql.named('UPDATE cities SET lat = @lat, lon = @lon '
          'WHERE slug = @slug AND lat IS NULL'),
      parameters: {'lat': lat, 'lon': lon, 'slug': slug},
    );
  }
  try {
    final client = HttpClient();
    final req = await client.getUrl(Uri.parse(
        'https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon'
        '&current=temperature_2m,weather_code'));
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    client.close();
    final decoded = jsonDecode(body) as Map<String, dynamic>;
    final current = decoded['current'] as Map<String, dynamic>;
    final payload = <String, Object?>{
      'city': slug,
      'temperatureC': current['temperature_2m'],
      'weatherCode': current['weather_code'],
      'description': _weatherDescription(current['weather_code'] as int),
    };
    _weatherCache[slug] = (DateTime.now(), payload);
    return _json(200, payload);
  } catch (_) {
    return _json(502, {'error': 'Weather service unavailable.'});
  }
}

/// "You may also feel..." — cross-city recommendations. Currently a simple
/// heuristic ranker (haptics-ready first, then freshest) standing in for the
/// real ML recommender; same response contract when it lands.
Future<Response> _suggest(Request request) async {
  final params = request.url.queryParameters;
  final exclude = params['city'] ?? '';
  final limit = (int.tryParse(params['limit'] ?? '4') ?? 4).clamp(1, 12);
  final rows = await _db.execute(
    Sql.named("SELECT $_videoColumns FROM videos WHERE status = 'ready' "
        'AND city <> @city '
        'ORDER BY (haptics IS NOT NULL) DESC, uploaded_at DESC, id DESC '
        'LIMIT @limit'),
    parameters: {'city': exclude, 'limit': limit},
  );
  return _json(200, {
    'engine': 'ml-sim-v1',
    'videos': [for (final r in rows) _videoRowToJson(r)],
  });
}

// ---------------------------------------------------------------------------
// Communities: 'travelers' (public) and 'creators' (creator accounts only —
// creators can see both; travelers must never see the creators feed).
// Role checks happen HERE, not just in the UI.
// ---------------------------------------------------------------------------

Future<String?> _roleOf(int userId) async {
  final rows = await _db.execute(
    Sql.named('SELECT role FROM users WHERE id = @id'),
    parameters: {'id': userId},
  );
  return rows.isEmpty ? null : rows.first[0] as String;
}

/// Returns an error response if [community] is not allowed for [userId].
Future<Response?> _gateCommunity(String community, int? userId) async {
  if (community != 'travelers' && community != 'creators') {
    return _json(400, {'error': 'Unknown community.'});
  }
  if (community == 'creators') {
    if (userId == null) {
      return _json(403, {'error': 'Creators community requires sign-in.'});
    }
    final role = await _roleOf(userId);
    if (role != 'creator') {
      return _json(403, {'error': 'The creators community is creators-only.'});
    }
  }
  return null;
}

Future<Response> _communityPosts(Request request) async {
  final params = request.url.queryParameters;
  final community = params['community'] ?? 'travelers';
  final userId = int.tryParse(params['userId'] ?? '');
  final offset = int.tryParse(params['offset'] ?? '0') ?? 0;
  final limit = (int.tryParse(params['limit'] ?? '20') ?? 20).clamp(1, 50);

  final gate = await _gateCommunity(community, userId);
  if (gate != null) return gate;

  final rows = await _db.execute(
    Sql.named('''
      SELECT p.id, p.community, p.author_id, p.author_name, p.author_role,
             p.city, p.body, p.created_at,
             COALESCE(json_object_agg(r.emoji, r.n) FILTER (WHERE r.emoji IS NOT NULL), '{}'::json),
             COALESCE(json_agg(DISTINCT mr.emoji) FILTER (WHERE mr.emoji IS NOT NULL), '[]'::json),
             p.image_url,
             (SELECT count(*) FROM replies rp WHERE rp.post_id = p.id),
             p.reshared_by, p.reshared_by_id, p.reshared_by_role,
             p.reshare_comment, p.media
      FROM posts p
      LEFT JOIN (SELECT post_id, emoji, count(*) AS n FROM reactions
                 GROUP BY post_id, emoji) r ON r.post_id = p.id
      LEFT JOIN reactions mr ON mr.post_id = p.id AND mr.user_id = @me
      WHERE p.community = @community
      GROUP BY p.id
      ORDER BY p.created_at DESC, p.id DESC
      OFFSET @offset LIMIT @limit
    '''),
    parameters: {
      'community': community,
      'me': userId ?? -1,
      'offset': offset,
      'limit': limit + 1,
    },
  );
  final hasMore = rows.length > limit;
  final page = hasMore ? rows.take(limit) : rows;
  return _json(200, {
    'posts': [
      for (final r in page)
        {
          'id': r[0],
          'community': r[1],
          'authorId': r[2],
          'authorName': r[3],
          'authorRole': r[4],
          'city': r[5],
          'body': r[6],
          'createdAt': (r[7] as DateTime).toIso8601String(),
          'reactions': r[8],
          'myReactions': r[9],
          'imageUrl': r[10],
          'replyCount': r[11],
          'resharedBy': r[12],
          'resharedById': r[13],
          'resharedByRole': r[14],
          'reshareComment': r[15],
          'media': r[16],
        }
    ],
    'hasMore': hasMore,
  });
}

// ------------------------------- replies ----------------------------------

Future<Response> _replies(Request request, String id) async {
  final postId = int.tryParse(id);
  if (postId == null) return _json(400, {'error': 'Bad post id.'});
  final userId = int.tryParse(request.url.queryParameters['userId'] ?? '');
  final post = await _db.execute(
    Sql.named('SELECT community FROM posts WHERE id = @id'),
    parameters: {'id': postId},
  );
  if (post.isEmpty) return _json(404, {'error': 'Post not found.'});
  final gate = await _gateCommunity(post.first[0] as String, userId);
  if (gate != null) return gate;

  final rows = await _db.execute(
    Sql.named('SELECT id, author_id, author_name, author_role, body, '
        'created_at, parent_reply_id FROM replies WHERE post_id = @p '
        'ORDER BY created_at, id'),
    parameters: {'p': postId},
  );
  return _json(200, {
    'replies': [
      for (final r in rows)
        {
          'id': r[0],
          'authorId': r[1],
          'authorName': r[2],
          'authorRole': r[3],
          'body': r[4],
          'createdAt': (r[5] as DateTime).toIso8601String(),
          'parentReplyId': r[6],
        }
    ]
  });
}

Future<Response> _addReply(Request request, String id) async {
  final postId = int.tryParse(id);
  final body = await _readJsonBody(request);
  final userId = body?['userId'] as int?;
  final text = (body?['body'] as String?)?.trim() ?? '';
  if (postId == null) return _json(400, {'error': 'Bad post id.'});
  if (userId == null) return _json(401, {'error': 'Sign in to reply.'});
  if (text.isEmpty) return _json(400, {'error': 'Say something first!'});
  if (text.length > 500) return _json(400, {'error': 'Keep replies under 500 characters.'});
  final unsafeReply = _unsafeText(text);
  if (unsafeReply != null) return _json(400, {'error': unsafeReply});
  final parentReplyId = body?['parentReplyId'] as int?;

  final post = await _db.execute(
    Sql.named('SELECT community FROM posts WHERE id = @id'),
    parameters: {'id': postId},
  );
  if (post.isEmpty) return _json(404, {'error': 'Post not found.'});
  final gate = await _gateCommunity(post.first[0] as String, userId);
  if (gate != null) return gate;

  final user = await _db.execute(
    Sql.named('SELECT name, role FROM users WHERE id = @id'),
    parameters: {'id': userId},
  );
  if (user.isEmpty) return _json(401, {'error': 'Unknown user.'});
  // Thread notifications: the person being replied to + the post author.
  final notifyIds = <int>{};
  if (parentReplyId != null) {
    final parent = await _db.execute(
      Sql.named('SELECT author_id FROM replies WHERE id = @r AND post_id = @p'),
      parameters: {'r': parentReplyId, 'p': postId},
    );
    if (parent.isNotEmpty && parent.first[0] != userId) {
      notifyIds.add(parent.first[0] as int);
    }
  }
  final postAuthorRow = await _db.execute(
    Sql.named('SELECT author_id FROM posts WHERE id = @p'),
    parameters: {'p': postId},
  );
  if (postAuthorRow.isNotEmpty && postAuthorRow.first[0] != userId) {
    notifyIds.add(postAuthorRow.first[0] as int);
  }
  for (final target in notifyIds) {
    _tokensFor(userId: target).then((tokens) => _sendPush(
          tokens,
          parentReplyId != null && notifyIds.length > 1
              ? 'New reply in your thread'
              : 'New reply on Mr.TourGuide',
          '${user.first[0]} replied: '
              '${text.length > 60 ? '${text.substring(0, 57)}...' : text}',
          data: {'type': 'reply'},
        ));
  }
  await _db.execute(
    Sql.named('INSERT INTO replies (post_id, author_id, author_name, '
        'author_role, body, parent_reply_id) '
        'VALUES (@p, @u, @name, @role, @body, @parent)'),
    parameters: {
      'parent': parentReplyId,
      'p': postId,
      'u': userId,
      'name': user.first[0],
      'role': user.first[1],
      'body': text,
    },
  );
  return _json(201, {'ok': true});
}

Future<Response> _deleteReply(Request request, String id) async {
  final replyId = int.tryParse(id);
  final body = await _readJsonBody(request);
  final userId = body?['userId'] as int?;
  if (replyId == null) return _json(400, {'error': 'Bad reply id.'});
  if (userId == null) return _json(401, {'error': 'Sign in first.'});
  final rows = await _db.execute(
    Sql.named(
        'DELETE FROM replies WHERE id = @r AND author_id = @u RETURNING 1'),
    parameters: {'r': replyId, 'u': userId},
  );
  if (rows.isEmpty) {
    return _json(403, {'error': 'You can only delete your own replies.'});
  }
  return _json(200, {'ok': true});
}

// --------------------------- community images -----------------------------

const _maxImageBytes = 5 * 1024 * 1024; // hard cap per image (5 MB)

/// Community image upload: size-capped, recompressed server-side (max 1280px
/// JPEG) to save storage, stored through [MediaStorage] — the same swap
/// point that moves everything to Cloudflare R2 in production.
Future<Response> _uploadCommunityImage(Request request) async {
  final params = request.url.queryParameters;
  final userId = int.tryParse(params['userId'] ?? '');
  if (userId == null || await _roleOf(userId) == null) {
    return _json(401, {'error': 'Sign in to attach images.'});
  }
  final original = _sanitizeFilename(params['filename'] ?? 'photo.jpg');
  final ext = original.split('.').last.toLowerCase();
  if (!{'jpg', 'jpeg', 'png', 'webp'}.contains(ext)) {
    return _json(400, {'error': 'Only JPG, PNG or WebP images.'});
  }

  // Read with the hard size cap — reject before touching disk.
  final bytes = <int>[];
  await for (final chunk in request.read()) {
    bytes.addAll(chunk);
    if (bytes.length > _maxImageBytes) {
      return _json(413, {'error': 'Images are limited to 5 MB.'});
    }
  }
  if (bytes.isEmpty) return _json(400, {'error': 'Empty upload body.'});

  final stamp = DateTime.now().millisecondsSinceEpoch;
  // Compress in a temp dir first; only the final artifact goes to storage
  // (local cache + R2 when configured).
  final tmpIn = File('${Directory.systemTemp.path}/mrt_raw_$stamp.$ext');
  await tmpIn.writeAsBytes(bytes);
  final tmpOut = File('${Directory.systemTemp.path}/mrt_img_$stamp.jpg');
  final result = await Process.run('ffmpeg', [
    '-y', '-loglevel', 'error',
    '-i', tmpIn.path,
    '-vf', "scale='trunc(min(1280,iw)/2)*2':-2",
    '-q:v', '5',
    tmpOut.path,
  ]);
  final finalName = 'img_$stamp.jpg';
  if (result.exitCode == 0) {
    final compressed = await tmpOut.readAsBytes();
    await _storage.save('community', finalName, Stream.value(compressed));
    print('community image: ${bytes.length} -> ${compressed.length} bytes');
    await tmpIn.delete();
    await tmpOut.delete();
    return _json(201, {'imageUrl': '/files/community/$finalName'});
  }
  // ffmpeg unavailable/failed: keep the (size-capped) original.
  final rawName = 'img_$stamp.$ext';
  await _storage.save('community', rawName, Stream.value(bytes));
  await tmpIn.delete();
  return _json(201, {'imageUrl': '/files/community/$rawName'});
}

const _maxPostVideoBytes = 80 * 1024 * 1024; // hard cap per video (80 MB)

/// One community video is compressed at a time — the free-tier VM cannot
/// afford parallel ffmpeg runs.
Future<void> _videoCompressQueue = Future.value();

/// Community post video upload. The original (size-capped) file is served
/// immediately; a queued background ffmpeg pass re-encodes it to 720p/CRF28
/// and overwrites the same storage key, so the URL never changes but the
/// stored bytes shrink.
Future<Response> _uploadCommunityVideo(Request request) async {
  final params = request.url.queryParameters;
  final userId = int.tryParse(params['userId'] ?? '');
  if (userId == null || await _roleOf(userId) == null) {
    return _json(401, {'error': 'Sign in to attach videos.'});
  }
  final original = _sanitizeFilename(params['filename'] ?? 'clip.mp4');
  final ext = original.split('.').last.toLowerCase();
  if (!{'mp4', 'mov', 'm4v', 'webm'}.contains(ext)) {
    return _json(400, {'error': 'Only MP4, MOV or WebM videos.'});
  }

  final stamp = DateTime.now().millisecondsSinceEpoch;
  final tmpIn = File('${Directory.systemTemp.path}/mrt_pvid_$stamp.$ext');
  final sink = tmpIn.openWrite();
  var size = 0;
  try {
    await for (final chunk in request.read()) {
      size += chunk.length;
      if (size > _maxPostVideoBytes) {
        await sink.close();
        await tmpIn.delete();
        return _json(413, {'error': 'Post videos are limited to 80 MB.'});
      }
      sink.add(chunk);
    }
  } finally {
    try {
      await sink.close();
    } catch (_) {}
  }
  if (size == 0) {
    try {
      await tmpIn.delete();
    } catch (_) {}
    return _json(400, {'error': 'Empty upload body.'});
  }

  final finalName = 'vid_$stamp.mp4';
  // Poster frame first (fast — reads only the head of the file).
  String? thumbUrl;
  final poster = File('${Directory.systemTemp.path}/mrt_pposter_$stamp.jpg');
  try {
    final r = await Process.run('ffmpeg', [
      '-y', '-loglevel', 'error',
      '-ss', '0.5', '-i', tmpIn.path,
      '-frames:v', '1',
      '-vf', "scale='trunc(min(720,iw)/2)*2':-2",
      '-q:v', '5',
      poster.path,
    ]).timeout(const Duration(seconds: 45));
    if (r.exitCode == 0 && await poster.exists()) {
      final thumbName = 'vthumb_$stamp.jpg';
      await _storage.save(
          'community', thumbName, Stream.value(await poster.readAsBytes()));
      thumbUrl = '/files/community/$thumbName';
    }
  } catch (_) {} finally {
    try {
      if (await poster.exists()) await poster.delete();
    } catch (_) {}
  }

  // Serve the original right away so the post can publish immediately.
  await _storage.save('community', finalName, tmpIn.openRead());

  // Queue the compression pass; the temp original is deleted afterwards.
  _videoCompressQueue = _videoCompressQueue.then((_) async {
    final tmpOut = File('${Directory.systemTemp.path}/mrt_pvidc_$stamp.mp4');
    try {
      final r = await Process.run('ffmpeg', [
        '-y', '-loglevel', 'error',
        '-i', tmpIn.path,
        '-vf', "scale='trunc(min(720,iw)/2)*2':-2",
        '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '28',
        '-c:a', 'aac', '-b:a', '96k',
        '-movflags', '+faststart',
        tmpOut.path,
      ]).timeout(const Duration(minutes: 8));
      if (r.exitCode == 0 && await tmpOut.exists()) {
        final outSize = await tmpOut.length();
        // Only replace when the re-encode actually saved space.
        if (outSize > 0 && outSize < size) {
          await _storage.save('community', finalName, tmpOut.openRead());
          print('community video: $size -> $outSize bytes ($finalName)');
        }
      }
    } catch (e) {
      print('community video compress skipped: $e');
    } finally {
      for (final f in [tmpIn, tmpOut]) {
        try {
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
  });

  return _json(201, {
    'videoUrl': '/files/community/$finalName',
    if (thumbUrl != null) 'thumbUrl': thumbUrl,
  });
}


// ===========================================================================
// GuideVibe — short vertical videos (Reels/Shorts). Creator uploads are
// compressed to a lean 720-wide vertical clip; the feed blends them with
// YouTube Shorts picks (aesthetic chip marks the YouTube ones).
// ===========================================================================
const _shortColumns =
    'id, owner_id, owner_name, owner_role, caption, city, filename, '
    'thumb_url, kind, haptics, likes, views, created_at';

Map<String, Object?> _shortRowToJson(List<dynamic> row, {bool liked = false}) =>
    {
      'id': row[0],
      'source': 'creator',
      'ownerId': row[1],
      'ownerName': row[2],
      'ownerRole': row[3],
      'caption': row[4],
      'city': row[5],
      'thumbUrl': row[7],
      'kind': row[8],
      'haptics': row[9],
      'likes': row[10],
      'views': row[11],
      'createdAt': (row[12] as DateTime).toIso8601String(),
      'liked': liked,
      'url': '/files/guidevibe/${row[6]}',
    };

const _maxShortBytes = 20 * 1024 * 1024; // hard cap per short (20 MB raw)
const _maxShortSeconds = 60; // GuideVibe clips: 1 minute max

/// Streams a URL to disk with a hard byte cap + timeout. Returns true on a
/// complete, within-cap download. Used to fetch the chosen soundtrack.
Future<bool> _downloadCapped(String url, File dest,
    {required int maxBytes, required Duration timeout}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final req = await client.getUrl(Uri.parse(url));
    final res = await req.close().timeout(timeout);
    if (res.statusCode != 200) return false;
    final sink = dest.openWrite();
    var n = 0;
    var ok = true;
    await for (final chunk in res.timeout(timeout)) {
      n += chunk.length;
      if (n > maxBytes) {
        ok = false;
        break;
      }
      sink.add(chunk);
    }
    await sink.close();
    return ok && n > 0;
  } finally {
    client.close(force: true);
  }
}

/// Music search via Deezer's public API (no key) — Hindi/Bollywood + global
/// catalog. Returns official 30-second preview clips (the perfect length for
/// short GuideVibe clips). Cached per query for 30 min.
final Map<String, (DateTime, List<Map<String, Object?>>)> _musicCache = {};

Future<Response> _musicSearch(Request request) async {
  final q = (request.url.queryParameters['q'] ?? '').trim();
  final key = q.toLowerCase();
  final cached = _musicCache[key];
  if (cached != null &&
      DateTime.now().difference(cached.$1) < const Duration(minutes: 30)) {
    return _json(200, {'items': cached.$2});
  }
  // Empty query → a popular Hindi + global starter set.
  final query = q.isEmpty ? 'top hits' : q;
  final uri = Uri.https('api.deezer.com', '/search',
      {'q': query, 'limit': '30', 'order': 'RANKING'});
  try {
    final text = await _httpGetText(uri.toString())
        .timeout(const Duration(seconds: 12));
    final decoded = jsonDecode(text) as Map<String, dynamic>;
    final results = (decoded['data'] as List?) ?? const [];
    final items = <Map<String, Object?>>[
      for (final t in results)
        if (t is Map &&
            t['preview'] is String &&
            (t['preview'] as String).isNotEmpty)
          {
            'id': '${t['id']}',
            'title': t['title_short'] ?? t['title'] ?? 'Untitled',
            'artist': (t['artist'] is Map ? t['artist']['name'] : null) ??
                'Unknown artist',
            // Deezer previews are ~30s clips.
            'duration': 30,
            'audio': t['preview'],
            'image': (t['album'] is Map
                    ? (t['album']['cover_medium'] ?? t['album']['cover'])
                    : null) ??
                '',
          }
    ];
    _musicCache[key] = (DateTime.now(), items);
    return _json(200, {'items': items});
  } catch (_) {
    return _json(502, {'error': 'Music search is unavailable right now.'});
  }
}

/// One short is transcoded at a time — the free-tier VM can't run parallel
/// ffmpeg passes.
Future<void> _shortQueue = Future.value();

/// Creator uploads a GuideVibe short. The raw file is size-capped and served
/// immediately (status processing); a queued background pass re-encodes it to
/// 720-wide vertical H.264 CRF28, extracts a poster, and runs the same
/// audio-to-haptics analysis the experience player uses.
Future<Response> _uploadShort(Request request) async {
  final params = request.url.queryParameters;
  final userId = int.tryParse(params['userId'] ?? '');
  if (userId == null) return _json(401, {'error': 'Sign in to post a GuideVibe.'});
  final user = await _db.execute(
    Sql.named('SELECT name, role FROM users WHERE id = @id'),
    parameters: {'id': userId},
  );
  if (user.isEmpty) return _json(401, {'error': 'Unknown user.'});
  final caption = (params['caption'] ?? '').trim();
  if (caption.length > 400) {
    return _json(400, {'error': 'Keep captions under 400 characters.'});
  }
  final unsafe = caption.isEmpty ? null : _unsafeText(caption);
  if (unsafe != null) return _json(400, {'error': unsafe});
  final city = (params['city'] ?? '').trim();
  final kind = const ['normal', 'vr', 'mr'].contains(params['kind'])
      ? params['kind']!
      : 'normal';
  // Optional soundtrack (Deezer preview clip). Only https Deezer preview-CDN
  // URLs are accepted — prevents the server being turned into a fetch proxy
  // (SSRF).
  final musicUrlRaw = (params['musicUrl'] ?? '').trim();
  final musicUri = Uri.tryParse(musicUrlRaw);
  final musicHost = musicUri?.host.toLowerCase() ?? '';
  final musicOk = musicUrlRaw.isNotEmpty &&
      musicUri != null &&
      musicUri.scheme == 'https' &&
      (musicHost.contains('dzcdn.net') ||
          musicHost.contains('deezer') ||
          musicHost.contains('jamendo'));
  final musicUrl = musicOk ? musicUrlRaw : null;
  final musicStart =
      (double.tryParse(params['musicStart'] ?? '0') ?? 0).clamp(0, 3600);
  final original = _sanitizeFilename(params['filename'] ?? 'short.mp4');
  final ext = original.split('.').last.toLowerCase();
  if (!{'mp4', 'mov', 'm4v', 'webm', '3gp'}.contains(ext)) {
    return _json(400, {'error': 'Only MP4, MOV or WebM videos.'});
  }

  final stamp = DateTime.now().millisecondsSinceEpoch;
  final tmpIn = File('${Directory.systemTemp.path}/mrt_short_$stamp.$ext');
  final sink = tmpIn.openWrite();
  var size = 0;
  try {
    await for (final chunk in request.read()) {
      size += chunk.length;
      if (size > _maxShortBytes) {
        await sink.close();
        await tmpIn.delete();
        return _json(413, {'error': 'GuideVibe clips are limited to 20 MB.'});
      }
      sink.add(chunk);
    }
  } finally {
    try {
      await sink.close();
    } catch (_) {}
  }
  if (size == 0) {
    try {
      await tmpIn.delete();
    } catch (_) {}
    return _json(400, {'error': 'Empty upload body.'});
  }

  // Enforce the 1-minute limit (safety net — the app also checks before
  // uploading). ffprobe reads only the container metadata, so it's cheap.
  try {
    final probe = await Process.run('ffprobe', [
      '-v', 'error',
      '-show_entries', 'format=duration',
      '-of', 'default=noprint_wrappers=1:nokey=1',
      tmpIn.path,
    ]);
    final dur = double.tryParse('${probe.stdout}'.trim()) ?? 0;
    if (dur > _maxShortSeconds + 5) {
      await tmpIn.delete();
      return _json(400,
          {'error': 'GuideVibe clips must be 1 minute or less.'});
    }
  } catch (_) {
    // If ffprobe is unavailable/fails, don't block the upload on the guard.
  }

  final finalName = 'gv_$stamp.mp4';
  // Insert the row and respond IMMEDIATELY (status processing, no thumb yet).
  // All the heavy work — storing the file, the poster frame, transcode, music
  // mux and haptics — runs in the background queue below, so the client's
  // upload progress bar completes the moment the bytes are received instead of
  // sitting near the end while the VM finalizes.
  final rows = await _db.execute(
    Sql.named('INSERT INTO shorts (owner_id, owner_name, owner_role, caption, '
        'city, filename, thumb_url, kind, size_bytes, status) VALUES '
        '(@o, @on, @or, @cap, @city, @f, NULL, @k, @sz, \'processing\') '
        'RETURNING $_shortColumns'),
    parameters: {
      'o': userId,
      'on': user.first[0],
      'or': user.first[1],
      'cap': caption,
      'city': city.isEmpty ? null : city,
      'f': finalName,
      'k': kind,
      'sz': size,
    },
  );
  final shortId = rows.first[0] as int;
  _logActivity('user:$userId', 'guidevibe-upload', 'short #$shortId ($kind)');

  // Background queue: store original, poster, transcode + music + haptics.
  _shortQueue = _shortQueue.then((_) async {
    final tmpOut = File('${Directory.systemTemp.path}/mrt_shortc_$stamp.mp4');
    final tmpMusic = File('${Directory.systemTemp.path}/mrt_gvmusic_$stamp.mp3');
    var haveMusic = false;
    try {
      // Store the original first so the clip exists even before transcoding.
      await _storage.save('guidevibe', finalName, tmpIn.openRead());
      // Poster frame (updates the row's thumb once ready).
      final poster =
          File('${Directory.systemTemp.path}/mrt_gvposter_$stamp.jpg');
      try {
        final pr = await Process.run('ffmpeg', [
          '-y', '-loglevel', 'error',
          '-ss', '0.5', '-i', tmpIn.path,
          '-frames:v', '1',
          '-vf', "scale='trunc(min(720,iw)/2)*2':-2",
          '-q:v', '5',
          poster.path,
        ]).timeout(const Duration(seconds: 45));
        if (pr.exitCode == 0 && await poster.exists()) {
          final thumbName = 'gvthumb_$stamp.jpg';
          await _storage.save('guidevibe', thumbName,
              Stream.value(await poster.readAsBytes()));
          await _db.execute(
            Sql.named('UPDATE shorts SET thumb_url = @t WHERE id = @id'),
            parameters: {'t': '/files/guidevibe/$thumbName', 'id': shortId},
          );
          // Fresh thumbnail ready → drop cached feeds so it shows immediately.
          await _cacheBust('guidevibe');
        }
      } catch (_) {} finally {
        try {
          if (await poster.exists()) await poster.delete();
        } catch (_) {}
      }
      // Fetch the chosen soundtrack (size-capped) before transcoding.
      if (musicUrl != null) {
        try {
          haveMusic = await _downloadCapped(musicUrl, tmpMusic,
              maxBytes: 20 * 1024 * 1024,
              timeout: const Duration(seconds: 40));
        } catch (_) {
          haveMusic = false;
        }
      }

      final ffArgs = <String>['-y', '-loglevel', 'error', '-i', tmpIn.path];
      if (haveMusic) {
        // Seek into the track to the creator-chosen start, then let
        // -shortest trim it to the clip length. The music REPLACES the
        // original audio, so the audio→haptics feel follows the song.
        ffArgs.addAll(['-ss', musicStart.toStringAsFixed(1), '-i', tmpMusic.path]);
      }
      ffArgs.addAll(['-vf', "scale='trunc(min(720,iw)/2)*2':-2"]);
      if (haveMusic) {
        ffArgs.addAll(['-map', '0:v:0', '-map', '1:a:0', '-shortest']);
      }
      ffArgs.addAll([
        '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '28',
        '-c:a', 'aac', '-b:a', haveMusic ? '128k' : '96k',
        '-movflags', '+faststart',
        tmpOut.path,
      ]);
      final r = await Process.run('ffmpeg', ffArgs)
          .timeout(const Duration(minutes: 8));
      var analyzePath = tmpIn.path;
      if (r.exitCode == 0 && await tmpOut.exists()) {
        final outSize = await tmpOut.length();
        // With music we always keep the muxed output; otherwise only when it
        // actually shrank.
        if (outSize > 0 && (haveMusic || outSize < size)) {
          await _storage.save('guidevibe', finalName, tmpOut.openRead());
          analyzePath = tmpOut.path;
          await _db.execute(
            Sql.named('UPDATE shorts SET size_bytes = @s WHERE id = @id'),
            parameters: {'s': outSize, 'id': shortId},
          );
          print('guidevibe short: $size -> $outSize bytes ($finalName)'
              '${haveMusic ? ' +music' : ''}');
        }
      }
      // Audio -> haptics (same {track, fine, events} contract) — on the
      // muxed file when music was added, so the feel matches the song.
      final (fine, events) = await _audioEnergyAnalysis(analyzePath);
      final track = <double>[];
      for (var i = 0; i + 3 < fine.length; i += 4) {
        track.add(double.parse(
            ((fine[i] + fine[i + 1] + fine[i + 2] + fine[i + 3]) / 4)
                .toStringAsFixed(3)));
      }
      await _db.execute(
        Sql.named("UPDATE shorts SET status = 'ready', haptics = @h "
            'WHERE id = @id'),
        parameters: {
          'id': shortId,
          'h': jsonEncode({
            'profile': 'auto',
            'source': fine.isEmpty ? 'ml-sim' : 'audio-energy-v3',
            'track': track,
            'fine': fine,
            'events': events,
          }),
        },
      );
      // Tell travelers a new GuideVibe just landed.
      _sendPushByLocation(
        city,
        'New GuideVibe',
        '${user.first[0]} shared a new GuideVibe short.',
        excludeUserId: userId,
        data: {'type': 'guidevibe'},
      );
    } catch (e) {
      print('guidevibe transcode failed for $shortId: $e');
      try {
        await _db.execute(
          Sql.named("UPDATE shorts SET status = 'ready' WHERE id = @id"),
          parameters: {'id': shortId},
        );
      } catch (_) {}
    } finally {
      for (final f in [tmpIn, tmpOut, tmpMusic]) {
        try {
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
  });

  return _json(201, {'short': _shortRowToJson(rows.first)});
}

/// GuideVibe feed: ready creator shorts ranked by the reader's city then
/// recency. Platform-only — no third-party sources.
Future<Response> _guidevibeFeed(Request request) async {
  final params = request.url.queryParameters;
  final userId = int.tryParse(params['userId'] ?? '');
  final city = (params['city'] ?? '').trim();
  final owner = int.tryParse(params['owner'] ?? '');
  final offset = int.tryParse(params['offset'] ?? '0') ?? 0;
  final limit = (int.tryParse(params['limit'] ?? '10') ?? 10).clamp(1, 20);

  // Creator "studio" mode: only this owner's shorts (any status, so they can
  // preview clips still processing), newest first, no YouTube blend.
  if (owner != null) {
    final rows = await _db.execute(
      Sql.named('''
        SELECT $_shortColumns, status,
               EXISTS(SELECT 1 FROM short_likes sl
                      WHERE sl.short_id = shorts.id AND sl.user_id = @me) AS liked
        FROM shorts
        WHERE owner_id = @owner
        ORDER BY created_at DESC
        OFFSET @offset LIMIT @limit
      '''),
      parameters: {
        'me': userId ?? -1,
        'owner': owner,
        'offset': offset,
        'limit': limit + 1,
      },
    );
    final more = rows.length > limit;
    final page = more ? rows.take(limit).toList() : rows.toList();
    // base cols 0-12, status at 13, liked at 14.
    return _json(200, {
      'shorts': [
        for (final r in page)
          {..._shortRowToJson(r, liked: r[14] == true), 'status': r[13]}
      ],
      'hasMore': more,
    });
  }

  final rows = await _db.execute(
    Sql.named('''
      SELECT $_shortColumns,
             EXISTS(SELECT 1 FROM short_likes sl
                    WHERE sl.short_id = shorts.id AND sl.user_id = @me) AS liked
      FROM shorts
      WHERE status = 'ready'
      ORDER BY (city IS NOT NULL AND city = @city) DESC, created_at DESC
      OFFSET @offset LIMIT @limit
    '''),
    parameters: {
      'me': userId ?? -1,
      'city': city,
      'offset': offset,
      'limit': limit + 1,
    },
  );
  final hasMore = rows.length > limit;
  final page = hasMore ? rows.take(limit).toList() : rows.toList();
  return _json(200, {
    'shorts': [for (final r in page) _shortRowToJson(r, liked: r[13] == true)],
    'hasMore': hasMore,
  });
}

/// Toggle a like on a short.
Future<Response> _likeShort(Request request, String id) async {
  final shortId = int.tryParse(id);
  final body = await _readJsonBody(request);
  final userId = body?['userId'] as int?;
  if (shortId == null) return _json(400, {'error': 'Bad id.'});
  if (userId == null) return _json(401, {'error': 'Sign in to like.'});
  final removed = await _db.execute(
    Sql.named('DELETE FROM short_likes WHERE short_id = @s AND user_id = @u '
        'RETURNING 1'),
    parameters: {'s': shortId, 'u': userId},
  );
  if (removed.isEmpty) {
    await _db.execute(
      Sql.named('INSERT INTO short_likes (short_id, user_id) VALUES (@s, @u) '
          'ON CONFLICT DO NOTHING'),
      parameters: {'s': shortId, 'u': userId},
    );
    await _db.execute(
      Sql.named('UPDATE shorts SET likes = likes + 1 WHERE id = @s'),
      parameters: {'s': shortId},
    );
    return _json(200, {'ok': true, 'liked': true});
  }
  await _db.execute(
    Sql.named('UPDATE shorts SET likes = GREATEST(0, likes - 1) WHERE id = @s'),
    parameters: {'s': shortId},
  );
  return _json(200, {'ok': true, 'liked': false});
}

/// Count a view (fire-and-forget from the client).
Future<Response> _viewShort(Request request, String id) async {
  final shortId = int.tryParse(id);
  if (shortId == null) return _json(400, {'error': 'Bad id.'});
  await _db.execute(
    Sql.named('UPDATE shorts SET views = views + 1 WHERE id = @s'),
    parameters: {'s': shortId},
  );
  return _json(200, {'ok': true});
}

Future<Response> _shortComments(Request request, String id) async {
  final shortId = int.tryParse(id);
  if (shortId == null) return _json(400, {'error': 'Bad id.'});
  final rows = await _db.execute(
    Sql.named('SELECT id, author_id, author_name, body, created_at '
        'FROM short_comments WHERE short_id = @s ORDER BY created_at DESC '
        'LIMIT 200'),
    parameters: {'s': shortId},
  );
  return _json(200, {
    'comments': [
      for (final r in rows)
        {
          'id': r[0],
          'authorId': r[1],
          'authorName': r[2],
          'body': r[3],
          'createdAt': (r[4] as DateTime).toIso8601String(),
        }
    ]
  });
}

Future<Response> _addShortComment(Request request, String id) async {
  final shortId = int.tryParse(id);
  final body = await _readJsonBody(request);
  final userId = body?['userId'] as int?;
  final text = (body?['body'] as String?)?.trim() ?? '';
  if (shortId == null) return _json(400, {'error': 'Bad id.'});
  if (userId == null) return _json(401, {'error': 'Sign in to comment.'});
  if (text.isEmpty) return _json(400, {'error': 'Say something first!'});
  if (text.length > 400) return _json(400, {'error': 'Keep it under 400 chars.'});
  final unsafe = _unsafeText(text);
  if (unsafe != null) return _json(400, {'error': unsafe});
  final user = await _db.execute(
    Sql.named('SELECT name FROM users WHERE id = @id'),
    parameters: {'id': userId},
  );
  if (user.isEmpty) return _json(401, {'error': 'Unknown user.'});
  await _db.execute(
    Sql.named('INSERT INTO short_comments (short_id, author_id, author_name, '
        'body) VALUES (@s, @a, @an, @b)'),
    parameters: {'s': shortId, 'a': userId, 'an': user.first[0], 'b': text},
  );
  return _json(201, {'ok': true});
}

/// Owner-only: update a short's caption / kind.
Future<Response> _updateShort(Request request, String id) async {
  final shortId = int.tryParse(id);
  final body = await _readJsonBody(request);
  final userId = body?['userId'] as int?;
  if (shortId == null) return _json(400, {'error': 'Bad id.'});
  if (userId == null) return _json(401, {'error': 'Sign in first.'});
  final owner = await _db.execute(
    Sql.named('SELECT owner_id FROM shorts WHERE id = @s'),
    parameters: {'s': shortId},
  );
  if (owner.isEmpty) return _json(404, {'error': 'Short not found.'});
  if (owner.first[0] != userId) {
    return _json(403, {'error': 'You can only edit your own GuideVibe.'});
  }
  final caption = (body?['caption'] as String?)?.trim();
  if (caption != null) {
    if (caption.length > 400) {
      return _json(400, {'error': 'Keep captions under 400 characters.'});
    }
    final unsafe = caption.isEmpty ? null : _unsafeText(caption);
    if (unsafe != null) return _json(400, {'error': unsafe});
  }
  final kind = const ['normal', 'vr', 'mr'].contains(body?['kind'])
      ? body!['kind'] as String
      : null;
  await _db.execute(
    Sql.named('UPDATE shorts SET '
        'caption = COALESCE(@cap, caption), '
        'kind = COALESCE(@kind, kind) WHERE id = @s'),
    parameters: {'cap': caption, 'kind': kind, 's': shortId},
  );
  await _cacheBust('guidevibe');
  return _json(200, {'ok': true});
}

/// Owner-only: delete a short and its likes/comments.
Future<Response> _deleteShort(Request request, String id) async {
  final shortId = int.tryParse(id);
  final body = await _readJsonBody(request);
  final userId = body?['userId'] as int?;
  if (shortId == null) return _json(400, {'error': 'Bad id.'});
  if (userId == null) return _json(401, {'error': 'Sign in first.'});
  final rows = await _db.execute(
    Sql.named('DELETE FROM shorts WHERE id = @s AND owner_id = @u RETURNING 1'),
    parameters: {'s': shortId, 'u': userId},
  );
  if (rows.isEmpty) {
    return _json(403, {'error': 'You can only delete your own GuideVibe.'});
  }
  await _db.execute(Sql.named('DELETE FROM short_likes WHERE short_id = @s'),
      parameters: {'s': shortId});
  await _db.execute(Sql.named('DELETE FROM short_comments WHERE short_id = @s'),
      parameters: {'s': shortId});
  _logActivity('user:$userId', 'guidevibe-delete', 'short #$shortId');
  await _cacheBust('guidevibe');
  return _json(200, {'ok': true});
}

/// Per-short analytics for the owner (views/likes/comments).
Future<Response> _shortAnalytics(Request request, String id) async {
  final shortId = int.tryParse(id);
  if (shortId == null) return _json(400, {'error': 'Bad id.'});
  final userId = int.tryParse(request.url.queryParameters['userId'] ?? '');
  final rows = await _db.execute(
    Sql.named('''
      SELECT s.owner_id, s.views, s.likes, s.created_at, s.kind, s.caption,
             (SELECT count(*) FROM short_comments c WHERE c.short_id = s.id)
      FROM shorts s WHERE s.id = @s
    '''),
    parameters: {'s': shortId},
  );
  if (rows.isEmpty) return _json(404, {'error': 'Short not found.'});
  final r = rows.first;
  if (r[0] != userId) {
    return _json(403, {'error': 'Analytics are private to the creator.'});
  }
  return _json(200, {
    'views': r[1],
    'likes': r[2],
    'comments': r[6],
    'createdAt': (r[3] as DateTime).toIso8601String(),
    'kind': r[4],
    'caption': r[5],
  });
}

/// Public, shareable page for a single GuideVibe short (no auth). Plays the
/// vertical video; after two minutes a download/sign-up card slides in.
Future<Response> _publicShort(Request request, String id) async {
  final shortId = int.tryParse(id);
  if (shortId == null) return Response.notFound('Not found');
  final rows = await _db.execute(
    Sql.named('SELECT owner_name, caption, city, filename, thumb_url, kind, '
        'likes FROM shorts WHERE id = @s AND status = \'ready\''),
    parameters: {'s': shortId},
  );
  if (rows.isEmpty) {
    return Response.notFound('This GuideVibe is no longer available.');
  }
  final r = rows.first;
  final name = _escapeHtml(r[0] as String? ?? 'Traveler');
  final caption = _escapeHtml(r[1] as String? ?? '');
  final city = _escapeHtml(r[2] as String? ?? '');
  const base = 'https://mrtourguide.patienceai.in';
  final videoUrl = '$base/api/files/guidevibe/${r[3]}';
  final poster = r[4] is String ? '$base/api/files/guidevibe/${r[4]}' : '';
  final kind = (r[5] as String? ?? 'normal').toUpperCase();
  final immersive = kind == 'VR' || kind == 'MR';
  final html = '''<!DOCTYPE html>
<html lang="en"><head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$name on GuideVibe</title>
<meta property="og:title" content="$name on Mr.Tour Guide GuideVibe">
<meta property="og:description" content="$caption">
<meta property="og:image" content="${_escapeHtml(poster)}">
<meta property="og:type" content="video.other">
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,'Segoe UI',Roboto,Helvetica,sans-serif;
  background:#0d0e12;min-height:100vh;color:#fff;
  display:flex;flex-direction:column;align-items:center}
.brand{font-weight:800;font-size:16px;color:#aebaff;padding:14px}
.brand b{color:#fff}
.wrap{position:relative;width:100%;max-width:440px;flex:1;
  display:flex;align-items:center;justify-content:center}
video{width:100%;max-height:82vh;background:#000;border-radius:14px}
.meta{max-width:440px;width:100%;padding:14px 18px 120px}
.who{font-weight:800;font-size:15px}
.cap{font-size:13.5px;line-height:1.5;color:#d9dcef;margin-top:6px}
.pill{display:inline-block;font-size:10.5px;font-weight:800;color:#fff;
  background:rgba(255,255,255,.14);border-radius:999px;padding:3px 9px;margin-top:8px}
.cta{position:fixed;left:0;right:0;bottom:-110%;transition:bottom .5s
  cubic-bezier(.2,.9,.3,1.1);padding:14px}
.cta.show{bottom:0}
.cta .in{max-width:440px;margin:0 auto;background:linear-gradient(135deg,
  #1E319D,#3D53D8);border-radius:18px;padding:18px;
  box-shadow:0 -8px 30px rgba(30,49,157,.4)}
.cta h3{font-size:16px;margin-bottom:4px}
.cta p{font-size:12.5px;opacity:.9}
.cta .row{display:flex;gap:10px;margin-top:12px}
.cta a{flex:1;text-align:center;border-radius:12px;padding:11px 8px;
  font-size:13.5px;font-weight:800;text-decoration:none}
.cta a.dl{background:#fff;color:#1E319D}
.cta a.web{border:1.5px solid rgba(255,255,255,.7);color:#fff}
.cta .x{float:right;background:none;border:none;color:#fff;font-size:18px;cursor:pointer;opacity:.8}
</style></head><body>
<div class="brand"><b>Mr.Tour Guide</b> · GuideVibe</div>
<div class="wrap">
  <video controls playsinline autoplay muted loop ${poster.isEmpty ? '' : 'poster="${_escapeHtml(poster)}"'} src="${_escapeHtml(videoUrl)}"></video>
</div>
<div class="meta">
  <div class="who">$name${city.isEmpty ? '' : ' · $city'}</div>
  ${caption.isEmpty ? '' : '<div class="cap">$caption</div>'}
  ${immersive ? '<span class="pill">&#129406; $kind · immersive</span>' : ''}
</div>
<div class="cta" id="cta"><div class="in">
  <button class="x" onclick="document.getElementById('cta').classList.remove('show')">&times;</button>
  <h3>Feel it, don&rsquo;t just watch it</h3>
  <p>Mr.Tour Guide turns travel shorts into touch &mdash; haptics, MR/VR and
  an AI trip planner. Join $name on GuideVibe.</p>
  <div class="row">
    <a class="dl" href="$base/api/apk">&#11015; Download the app</a>
    <a class="web" href="$base/">Explore</a>
  </div>
</div></div>
<script>setTimeout(function(){document.getElementById('cta').classList.add('show')},120000);</script>
</body></html>''';
  return Response.ok(html, headers: {
    'content-type': 'text/html; charset=utf-8',
    'cache-control': 'public, max-age=300',
  });
}

String _escapeHtml(String t) => t
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// Public, shareable post page (no auth): an app-styled card view in the
/// browser. After two minutes an interactive install/sign-up card slides in.
Future<Response> _publicPost(Request request, String id) async {
  final postId = int.tryParse(id);
  if (postId == null) return Response.notFound('Not found');
  final rows = await _db.execute(
    Sql.named('''
      SELECT p.author_name, p.author_role, p.city, p.body, p.created_at,
             p.image_url, p.media, p.reshared_by, p.reshare_comment,
             COALESCE(json_object_agg(r.emoji, r.n)
               FILTER (WHERE r.emoji IS NOT NULL), '{}'::json),
             (SELECT count(*) FROM replies rp WHERE rp.post_id = p.id)
      FROM posts p
      LEFT JOIN (SELECT post_id, emoji, count(*) AS n FROM reactions
                 GROUP BY post_id, emoji) r ON r.post_id = p.id
      WHERE p.id = @p
      GROUP BY p.id
    '''),
    parameters: {'p': postId},
  );
  if (rows.isEmpty) {
    return Response.notFound('This post is no longer available.');
  }
  final r = rows.first;
  final name = _escapeHtml(r[0] as String? ?? 'Traveler');
  final role = (r[1] as String?) == 'creator' ? 'Creator' : 'Traveler';
  final roleIcon = role == 'Creator' ? '&#127909;' : '&#129523;';
  final city = _escapeHtml(r[2] as String? ?? '');
  final body = _escapeHtml(r[3] as String? ?? '');
  final created = r[4] as DateTime;
  final when =
      '${created.day} ${const ['', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][created.month]} ${created.year}';
  final sharedBy = r[7] as String?;
  final shareComment = r[8] as String?;
  final reactions = (r[9] as Map?) ?? const {};
  final replyCount = r[10];

  // Media: prefer the media list; fall back to the legacy single image.
  final media = <Map<String, dynamic>>[];
  if (r[6] is List) {
    for (final m in r[6] as List) {
      if (m is Map && m['url'] is String) {
        media.add({'type': m['type'], 'url': m['url'], 'thumb': m['thumb']});
      }
    }
  }
  if (media.isEmpty && r[5] is String) {
    media.add({'type': 'image', 'url': r[5]});
  }
  const base = 'https://mrtourguide.patienceai.in';
  String abs(String u) => u.startsWith('http') ? u : '$base/api$u';

  final slides = StringBuffer();
  for (final m in media) {
    final url = _escapeHtml(abs(m['url'] as String));
    if (m['type'] == 'video') {
      final poster = m['thumb'] is String
          ? ' poster="${_escapeHtml(abs(m['thumb'] as String))}"'
          : '';
      slides.write('<div class="slide"><video controls playsinline '
          'preload="metadata"$poster src="$url"></video></div>');
    } else {
      slides.write('<div class="slide"><img src="$url" alt=""></div>');
    }
  }
  final reactHtml = StringBuffer();
  var reactTotal = 0;
  reactions.forEach((emoji, n) {
    reactTotal += (n as num).toInt();
    reactHtml.write('<span class="rx">$emoji&nbsp;$n</span>');
  });
  final ogImage = media.isNotEmpty
      ? abs((media.first['thumb'] ?? media.first['url']) as String)
      : '$base/api/files/covers/placeholder.jpg';
  final preview =
      _escapeHtml((r[3] as String? ?? '').replaceAll('\n', ' ')).trim();

  final html = '''<!DOCTYPE html>
<html lang="en"><head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$name on Mr.Tour Guide</title>
<meta property="og:title" content="$name on Mr.Tour Guide">
<meta property="og:description" content="$preview">
<meta property="og:image" content="${_escapeHtml(ogImage)}">
<meta property="og:type" content="article">
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,'Segoe UI',Roboto,Helvetica,sans-serif;
  background:#F3F5FA;min-height:100vh;padding:18px 12px 120px}
.wrap{max-width:520px;margin:0 auto}
.brand{display:flex;align-items:center;gap:8px;margin:2px 4px 14px;
  color:#1E319D;font-weight:800;font-size:17px}
.brand span{background:#1E319D;color:#fff;border-radius:9px;
  padding:4px 9px;font-size:14px}
.card{background:#fff;border-radius:16px;padding:16px;
  box-shadow:0 6px 24px rgba(30,49,157,.10)}
.head{display:flex;align-items:center;gap:10px}
.av{width:44px;height:44px;border-radius:50%;background:#1E319D;color:#fff;
  display:flex;align-items:center;justify-content:center;
  font-weight:800;font-size:19px}
.who b{font-size:15px;color:#0d1330}
.sub{font-size:12px;color:#7a7f95}
.badge{font-size:11px;background:#eef1ff;color:#1E319D;border-radius:8px;
  padding:2px 7px;margin-left:6px}
.shared{font-size:12.5px;color:#5a5f78;background:#f4f6ff;border-radius:10px;
  padding:7px 10px;margin:10px 0 0}
.body{font-size:14.5px;line-height:1.5;color:#23283e;margin-top:12px;
  white-space:pre-wrap}
.carousel{display:flex;overflow-x:auto;scroll-snap-type:x mandatory;
  gap:8px;margin-top:12px;border-radius:12px;-webkit-overflow-scrolling:touch}
.carousel::-webkit-scrollbar{display:none}
.slide{flex:0 0 100%;scroll-snap-align:center}
.slide img,.slide video{width:100%;max-height:420px;object-fit:cover;
  border-radius:12px;display:block;background:#000}
.count{font-size:11px;color:#fff;background:rgba(13,19,48,.65);
  border-radius:8px;padding:2px 8px;position:relative;top:-34px;left:10px;
  display:inline-block}
.foot{display:flex;align-items:center;gap:8px;margin-top:10px;
  flex-wrap:wrap;color:#5a5f78;font-size:13px}
.rx{background:#f4f6ff;border-radius:10px;padding:3px 8px;font-size:12.5px}
.cta{position:fixed;left:0;right:0;bottom:-100%;transition:bottom .5s
  cubic-bezier(.2,.9,.3,1.1);padding:14px}
.cta.show{bottom:0}
.cta .in{max-width:520px;margin:0 auto;background:linear-gradient(135deg,
  #1E319D,#3D53D8);border-radius:18px;padding:18px;color:#fff;
  box-shadow:0 -8px 30px rgba(30,49,157,.35)}
.cta h3{font-size:16.5px;margin-bottom:4px}
.cta p{font-size:12.5px;opacity:.9}
.cta .row{display:flex;gap:10px;margin-top:12px}
.cta a{flex:1;text-align:center;border-radius:12px;padding:11px 8px;
  font-size:13.5px;font-weight:700;text-decoration:none}
.cta a.dl{background:#fff;color:#1E319D}
.cta a.web{border:1.5px solid rgba(255,255,255,.7);color:#fff}
.cta .x{float:right;background:none;border:none;color:#fff;font-size:18px;
  cursor:pointer;opacity:.8}
@media (prefers-color-scheme: dark){
  body{background:#0d1020}.card{background:#171b2e}
  .who b{color:#eef0ff}.body{color:#d9dcef}
  .rx,.shared{background:#20263f}.brand{color:#aebaff}}
</style></head><body>
<div class="wrap">
  <div class="brand"><span>Mr.Tour Guide</span> Community</div>
  <div class="card">
    <div class="head">
      <div class="av">${name.isEmpty ? 'T' : name[0].toUpperCase()}</div>
      <div class="who"><b>$name</b><span class="badge">$roleIcon $role</span>
        <div class="sub">$when${city.isEmpty ? '' : ' &middot; $city'}</div>
      </div>
    </div>
    ${sharedBy == null ? '' : '<div class="shared">&#8634; ${_escapeHtml(sharedBy)} shared this${shareComment == null || shareComment.isEmpty ? '' : ' &mdash; &ldquo;${_escapeHtml(shareComment)}&rdquo;'}</div>'}
    <div class="body">$body</div>
    ${media.isEmpty ? '' : '<div class="carousel" id="car">$slides</div>${media.length > 1 ? '<span class="count" id="cnt">1/${media.length}</span>' : ''}'}
    <div class="foot">
      $reactHtml
      <span>$reactTotal reactions</span> &middot; <span>$replyCount replies</span>
    </div>
  </div>
</div>
<div class="cta" id="cta"><div class="in">
  <button class="x" onclick="document.getElementById('cta').classList.remove('show')">&times;</button>
  <h3>Feel this journey, don&rsquo;t just read it</h3>
  <p>Mr.Tour Guide turns travel videos into touch &mdash; haptics, MR/VR and
  an AI trip planner. Join $name and the community.</p>
  <div class="row">
    <a class="dl" href="$base/api/apk">&#11015; Download the app</a>
    <a class="web" href="$base/">Explore Mr.Tour Guide</a>
  </div>
</div></div>
<script>
setTimeout(function(){document.getElementById('cta').classList.add('show')},120000);
var car=document.getElementById('car'),cnt=document.getElementById('cnt');
if(car&&cnt){car.addEventListener('scroll',function(){
  var i=Math.round(car.scrollLeft/car.clientWidth)+1;
  cnt.textContent=i+'/'+${media.length};},{passive:true});}
</script>
</body></html>''';
  return Response.ok(html, headers: {
    'content-type': 'text/html; charset=utf-8',
    'cache-control': 'public, max-age=300',
  });
}

Future<Response> _createPost(Request request) async {
  final body = await _readJsonBody(request);
  final userId = body?['userId'] as int?;
  final community = body?['community'] as String? ?? 'travelers';
  final text = (body?['body'] as String?)?.trim() ?? '';
  final city = (body?['city'] as String?)?.trim();
  if (userId == null) return _json(401, {'error': 'Sign in to post.'});
  if (text.isEmpty) return _json(400, {'error': 'Say something first!'});
  if (text.length > 1000) return _json(400, {'error': 'Keep it under 1000 characters.'});
  final unsafe = _unsafeText(text);
  if (unsafe != null) return _json(400, {'error': unsafe});

  final gate = await _gateCommunity(community, userId);
  if (gate != null) return gate;

  final user = await _db.execute(
    Sql.named('SELECT name, role FROM users WHERE id = @id'),
    parameters: {'id': userId},
  );
  if (user.isEmpty) return _json(401, {'error': 'Unknown user.'});

  final imageUrl = (body?['imageUrl'] as String?)?.trim();
  // Only accept images that went through our upload pipeline.
  final safeImage = (imageUrl != null &&
          imageUrl.startsWith('/files/community/'))
      ? imageUrl
      : null;

  // Multi-media attachments: up to 10 images + 2 videos per post, every
  // URL must come from our own upload pipeline.
  final mediaIn = body?['media'] as List?;
  final media = <Map<String, String>>[];
  if (mediaIn != null) {
    var images = 0, videos = 0;
    for (final m in mediaIn) {
      if (m is! Map) continue;
      final type = m['type'] as String?;
      final url = (m['url'] as String?)?.trim() ?? '';
      final thumb = (m['thumb'] as String?)?.trim();
      if (!url.startsWith('/files/community/')) continue;
      if (type == 'image' && images < 10) {
        images++;
        media.add({'type': 'image', 'url': url});
      } else if (type == 'video' && videos < 2) {
        videos++;
        media.add({
          'type': 'video',
          'url': url,
          if (thumb != null && thumb.startsWith('/files/community/'))
            'thumb': thumb,
        });
      }
    }
  }
  // Older clients read image_url only — mirror the first image there.
  final firstImage = media
      .firstWhere((m) => m['type'] == 'image', orElse: () => const {})['url'];

  final rows = await _db.execute(
    Sql.named('INSERT INTO posts (community, author_id, author_name, '
        'author_role, city, body, image_url, media) VALUES (@community, @id, '
        '@name, @role, @city, @body, @image, @media) RETURNING id'),
    parameters: {
      'community': community,
      'id': userId,
      'name': user.first[0],
      'role': user.first[1],
      'city': (city?.isEmpty ?? true) ? null : city,
      'body': text,
      'image': firstImage ?? safeImage,
      'media': media.isEmpty ? null : jsonEncode(media),
    },
  );
  // Tell everyone else a new community message landed (fire-and-forget so
  // posting stays snappy).
  final preview = text.length > 80 ? '${text.substring(0, 77)}…' : text;
  _tokensFor(excludeUserId: userId).then((tokens) => _sendPush(
        tokens,
        'New in $community',
        '${user.first[0]}: $preview',
        data: {'type': 'community'},
      ));
  return _json(201, {'ok': true, 'id': rows.first[0]});
}

/// Toggle a reaction (tap once = react, tap again = remove).
Future<Response> _react(Request request, String id) async {
  final postId = int.tryParse(id);
  final body = await _readJsonBody(request);
  final userId = body?['userId'] as int?;
  final emoji = (body?['emoji'] as String?) ?? '';
  const allowed = {'❤️', '🔥', '👏', '📳', '😮'};
  if (postId == null) return _json(400, {'error': 'Bad post id.'});
  if (userId == null) return _json(401, {'error': 'Sign in to react.'});
  if (!allowed.contains(emoji)) return _json(400, {'error': 'Unknown reaction.'});

  // Gate by the post's community.
  final post = await _db.execute(
    Sql.named('SELECT community FROM posts WHERE id = @id'),
    parameters: {'id': postId},
  );
  if (post.isEmpty) return _json(404, {'error': 'Post not found.'});
  final gate = await _gateCommunity(post.first[0] as String, userId);
  if (gate != null) return gate;

  final removed = await _db.execute(
    Sql.named('DELETE FROM reactions WHERE post_id = @p AND user_id = @u '
        'AND emoji = @e RETURNING 1'),
    parameters: {'p': postId, 'u': userId, 'e': emoji},
  );
  if (removed.isEmpty) {
    await _db.execute(
      Sql.named(
          'INSERT INTO reactions (post_id, user_id, emoji) VALUES (@p, @u, @e)'),
      parameters: {'p': postId, 'u': userId, 'e': emoji},
    );
  }
  return _json(200, {'ok': true, 'reacted': removed.isEmpty});
}

/// Authors can delete their own posts.
Future<Response> _deletePost(Request request, String id) async {
  final postId = int.tryParse(id);
  final body = await _readJsonBody(request);
  final userId = body?['userId'] as int?;
  if (postId == null) return _json(400, {'error': 'Bad post id.'});
  if (userId == null) return _json(401, {'error': 'Sign in first.'});
  // Strictly owner-only: authors delete their own posts (resharers their own
  // reshares). No moderation override — creators included.
  final rows = await _db.execute(
    Sql.named('DELETE FROM posts WHERE id = @p AND '
        '(CASE WHEN reshared_by_id IS NOT NULL '
        'THEN reshared_by_id = @u ELSE author_id = @u END) RETURNING 1'),
    parameters: {'p': postId, 'u': userId},
  );
  if (rows.isEmpty) {
    return _json(403, {'error': 'You can only delete your own posts.'});
  }
  return _json(200, {'ok': true});
}

/// Cities on the platform matching any word of an AI query — powers the
/// "available on Mr.TourGuide" suggestion cards under AI answers, with the
/// same JSON shape as /cities so the app reuses its City model.
Future<List<Map<String, Object?>>> _matchPlaces(String query) async {
  final words = query
      .toLowerCase()
      .split(RegExp(r'[^a-z]+'))
      .where((w) => w.length > 3)
      .toSet();
  if (words.isEmpty) return [];
  final like = words.map((w) => '%$w%').toList();
  try {
    final rows = await _db.execute(
      Sql.named("SELECT c.slug, c.name, "
          "(SELECT count(*) FROM videos v WHERE v.city = c.slug "
          "AND v.status = 'ready'), c.cover_url, c.location, c.description, "
          'COALESCE((SELECT avg(stars) FROM place_ratings pr '
          'WHERE pr.city_slug = c.slug), 0), c.model_url, '
          '(SELECT count(*) FROM place_ratings pr WHERE pr.city_slug = c.slug) '
          'FROM cities c '
          'WHERE EXISTS (SELECT 1 FROM unnest(@words::text[]) w WHERE '
          'lower(c.name) LIKE w OR lower(c.slug) LIKE w OR '
          'lower(c.location) LIKE w OR lower(c.description) LIKE w) '
          'ORDER BY 7 DESC LIMIT 4'),
      parameters: {'words': like},
    );
    return [
      for (final r in rows)
        {
          'slug': r[0],
          'name': r[1],
          'videoCount': r[2],
          'coverUrl': r[3],
          'location': r[4],
          'description': r[5],
          'rating': double.parse(
              double.parse(r[6].toString()).toStringAsFixed(2)),
          'modelUrl': r[7],
          'ratingCount': r[8],
        }
    ];
  } catch (_) {
    return [];
  }
}

/// Save an AI plan/overview under the signed-in user's account.
Future<Response> _saveItinerary(Request request) async {
  final body = await _readJsonBody(request);
  final userId = body?['userId'] as int?;
  final title = (body?['title'] as String?)?.trim() ?? '';
  final query = (body?['query'] as String?)?.trim() ?? '';
  final plan = (body?['plan'] as String?)?.trim() ?? '';
  if (userId == null) return _json(401, {'error': 'Sign in first.'});
  if (title.isEmpty || plan.isEmpty) {
    return _json(400, {'error': 'title and plan required'});
  }
  if (title.length > 120 || plan.length > 8000) {
    return _json(400, {'error': 'Itinerary too long to save.'});
  }
  final count = await _db.execute(
    Sql.named('SELECT count(*) FROM itineraries WHERE user_id = @u'),
    parameters: {'u': userId},
  );
  if ((count.first[0] as int) >= 30) {
    return _json(400, {'error': 'Saved limit reached — delete an old one.'});
  }
  try {
    final row = await _db.execute(
      Sql.named('INSERT INTO itineraries (user_id, title, query, plan) '
          'VALUES (@u, @t, @q, @p) RETURNING id, created_at'),
      parameters: {'u': userId, 't': title, 'q': query, 'p': plan},
    );
    return _json(200, {
      'id': row.first[0],
      'createdAt': (row.first[1] as DateTime).toIso8601String(),
    });
  } catch (_) {
    // Unknown user (FK) or transient DB error — never a 500 to the app.
    return _json(401, {'error': 'Sign in first.'});
  }
}

Future<Response> _listItineraries(Request request) async {
  final userId = int.tryParse(request.url.queryParameters['userId'] ?? '');
  if (userId == null) return _json(401, {'error': 'Sign in first.'});
  final rows = await _db.execute(
    Sql.named('SELECT id, title, query, plan, created_at FROM itineraries '
        'WHERE user_id = @u ORDER BY created_at DESC'),
    parameters: {'u': userId},
  );
  return _json(200, {
    'itineraries': [
      for (final r in rows)
        {
          'id': r[0],
          'title': r[1],
          'query': r[2],
          'plan': r[3],
          'createdAt': (r[4] as DateTime).toIso8601String(),
        }
    ]
  });
}

/// Edit a saved itinerary's title and/or plan (owner only).
Future<Response> _updateItinerary(Request request, String id) async {
  final body = await _readJsonBody(request);
  final userId = body?['userId'] as int?;
  final itineraryId = int.tryParse(id);
  final title = (body?['title'] as String?)?.trim();
  final plan = (body?['plan'] as String?)?.trim();
  if (userId == null) return _json(401, {'error': 'Sign in first.'});
  if (itineraryId == null) return _json(400, {'error': 'Bad itinerary id.'});
  if ((title == null || title.isEmpty) && (plan == null || plan.isEmpty)) {
    return _json(400, {'error': 'Nothing to update.'});
  }
  if ((title?.length ?? 0) > 120 || (plan?.length ?? 0) > 8000) {
    return _json(400, {'error': 'Itinerary too long to save.'});
  }
  final rows = await _db.execute(
    Sql.named('UPDATE itineraries SET '
        'title = COALESCE(@t, title), plan = COALESCE(@p, plan) '
        'WHERE id = @id AND user_id = @u RETURNING id'),
    parameters: {
      't': (title?.isEmpty ?? true) ? null : title,
      'p': (plan?.isEmpty ?? true) ? null : plan,
      'id': itineraryId,
      'u': userId,
    },
  );
  if (rows.isEmpty) {
    return _json(403, {'error': 'You can only edit your own itineraries.'});
  }
  return _json(200, {'ok': true});
}

Future<Response> _deleteItinerary(Request request, String id) async {
  final body = await _readJsonBody(request);
  final userId = body?['userId'] as int?;
  final itineraryId = int.tryParse(id);
  if (userId == null) return _json(401, {'error': 'Sign in first.'});
  if (itineraryId == null) return _json(400, {'error': 'Bad itinerary id.'});
  final rows = await _db.execute(
    Sql.named('DELETE FROM itineraries WHERE id = @id AND user_id = @u '
        'RETURNING id'),
    parameters: {'id': itineraryId, 'u': userId},
  );
  if (rows.isEmpty) {
    return _json(403, {'error': 'You can only delete your own itineraries.'});
  }
  return _json(200, {'ok': true});
}

// AI itinerary planner: Groq compound-mini (web search built in) drafts a
// day-by-day plan; the app pairs it with photos + YouTube via /search/media.
final Map<String, (DateTime, Map<String, Object?>)> _itineraryCache = {};

Future<Response> _aiItinerary(Request request) async {
  final apiKey = Platform.environment['GROQ_API_KEY'];
  if (apiKey == null || apiKey.isEmpty) {
    return _json(503, {'error': 'AI planner is not configured.'});
  }
  final body = await _readJsonBody(request);
  final query = (body?['query'] as String?)?.trim() ?? '';
  if (query.isEmpty) return _json(400, {'error': 'query required'});

  // Follow-up chat: prior turns come along so the AI can revise the same
  // plan ("add a day", "make it cheaper"). Capped hard to protect tokens.
  final history = <Map<String, String>>[];
  for (final h in (body?['history'] as List? ?? const [])) {
    if (h is! Map) continue;
    final role = h['role'] == 'assistant' ? 'assistant' : 'user';
    var content = (h['content'] as String? ?? '').trim();
    if (content.isEmpty) continue;
    if (content.length > 2500) content = content.substring(0, 2500);
    history.add({'role': role, 'content': content});
    if (history.length >= 8) break;
  }

  // Only first turns are cacheable — follow-ups depend on the conversation.
  final cacheKey = query.toLowerCase();
  if (history.isEmpty) {
    final cached = _itineraryCache[cacheKey];
    if (cached != null &&
        DateTime.now().difference(cached.$1) < const Duration(minutes: 30)) {
      return _json(200, cached.$2);
    }
  }

  try {
    final client = HttpClient();
    final req = await client
        .postUrl(Uri.parse('https://api.groq.com/openai/v1/chat/completions'));
    req.headers.set('Authorization', 'Bearer $apiKey');
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({
      'model': 'groq/compound-mini',
      'messages': [
        {
          'role': 'system',
          'content': "You are Mr.Tour Guide's AI travel planner and helper. "
              'When the user asks to plan or revise a trip, draft a concise '
              'practical day-by-day itinerary. Format strictly: a one-line '
              "intro, then lines starting with 'Day N: <title>' each "
              'followed by 2-3 short sentences, then a section starting '
              "with 'Getting there:' (realistic flight and train options), "
              "then a section starting with 'Stay:' (hotel, homestay and "
              "budget options), then a final section starting with 'Tips:'. "
              'Max 6 days. On follow-ups like "add a day" or "make it '
              'cheaper", revise the previous plan from the conversation and '
              'reply with the FULL updated plan in the same format. When '
              'the user instead asks a question about the trip (packing, '
              'safety, food, costs, weather, anything), answer naturally '
              'and helpfully in a few short sentences using the '
              'conversation context — never say you lack context. Plain '
              'text only — no markdown symbols. '
              'SCOPE: you ONLY help with travel, destinations, and using the '
              'Mr.Tour Guide app. You must REFUSE anything else — do not write '
              'or debug code, do essays/homework, math, or discuss unrelated '
              'topics. If asked, reply in one line: "I can only help with '
              'travel planning and the Mr.Tour Guide app." Never output code.'
        },
        ...history,
        {'role': 'user', 'content': query},
      ],
      'max_tokens': 900,
      'temperature': 0.5,
    }));
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    client.close();
    final decoded = jsonDecode(text) as Map<String, dynamic>;
    final plan = decoded['choices']?[0]?['message']?['content'] as String?;
    if (plan == null) {
      return _json(502, {'error': 'AI planner unavailable right now.'});
    }
    final payload = <String, Object?>{
      'plan': plan.trim(),
      'places': await _matchPlaces(query),
    };
    if (history.isEmpty) {
      _itineraryCache[cacheKey] = (DateTime.now(), payload);
    }
    return _json(200, payload);
  } catch (_) {
    return _json(502, {'error': 'AI planner unavailable right now.'});
  }
}

// Rich search media: place photos (Wikimedia Commons) + YouTube suggestions.
// Cached 30 min per query; all fetched server-side (no keys, no client CORS).
final Map<String, (DateTime, Map<String, Object?>)> _mediaCache = {};

Future<String> _httpGetText(String url, {String? userAgent}) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set('User-Agent',
        userAgent ?? 'MrTouride/1.0 (local dev; contact: dev@mrtouride.app)');
    final res = await req.close();
    return await res.transform(utf8.decoder).join();
  } finally {
    client.close();
  }
}

const _mediaStopwords = {
  'plan', 'plans', 'planning', 'trip', 'trips', 'itinerary', 'days', 'day',
  'week', 'weekend', 'weeks', 'budget', 'cheap', 'friendly', 'wheelchair',
  'wheel', 'chair', 'accessible', 'accessibility', 'disabled', 'elderly',
  'senior', 'seniors', 'with', 'for', 'and', 'the', 'a', 'an', 'in', 'of',
  'to', 'my', 'me', 'add', 'more', 'make', 'best', 'top', 'around', 'near',
  'nearby', 'visit', 'visiting', 'travel', 'tour', 'tours', 'touring',
  'ideas', 'food', 'stops', 'one', 'two', 'three', 'four', 'five', 'six',
  'monsoon', 'summer', 'winter', 'rainy', 'getaway', 'kids', 'family',
  'solo', 'want', 'need', 'show', 'give', 'from', 'into', 'via', 'how',
  'what', 'where', 'when', 'place', 'places', 'city', 'cities', 'things',
  'thing', 'see', 'must', 'guide', 'help', 'please', 'suggest',
};

/// Keeps only the meaningful terms (place names, subjects) so visuals
/// match what was actually asked — not the filler words around it.
String _focusMediaQuery(String q) {
  final words = q
      .split(RegExp(r'[^A-Za-z]+'))
      .where((w) =>
          w.length > 2 && !_mediaStopwords.contains(w.toLowerCase()))
      .toList();
  final focused = words.take(3).join(' ');
  if (focused.isEmpty) return q;
  // Bias toward destination content: a bare place name becomes
  // "<place> tourism" so images AND videos show the destination.
  return words.length <= 2 ? '$focused tourism' : focused;
}

Future<Response> _searchMedia(Request request) async {
  final raw = (request.url.queryParameters['q'] ?? '').trim();
  final q = _focusMediaQuery(raw);
  if (q.isEmpty) return _json(200, {'images': [], 'youtube': []});
  final key = q.toLowerCase();
  final cached = _mediaCache[key];
  if (cached != null &&
      DateTime.now().difference(cached.$1) < const Duration(minutes: 30)) {
    return _json(200, cached.$2);
  }

  // Wikipedia ARTICLE lead images: searching articles (not raw files)
  // returns landmark photos of the actual destination — no newspaper
  // scans or unrelated files. Thumbs come from upload.wikimedia.org
  // which sends CORS headers, so the app can render them.
  final images = <String>[];
  try {
    final body = await _httpGetText(
        'https://en.wikipedia.org/w/api.php?action=query&format=json'
        '&generator=search&gsrsearch=${Uri.encodeQueryComponent(q)}'
        '&gsrlimit=10&prop=pageimages&piprop=thumbnail&pithumbsize=640');
    final decoded = jsonDecode(body) as Map<String, dynamic>;
    final pages =
        (decoded['query']?['pages'] as Map<String, dynamic>?) ?? {};
    final entries = pages.values.toList()
      ..sort((a, b) =>
          ((a['index'] as num?) ?? 99).compareTo((b['index'] as num?) ?? 99));
    for (final p in entries) {
      final thumb = (p['thumbnail'] as Map<String, dynamic>?)?['source']
          as String?;
      if (thumb == null) continue;
      final lower = thumb.toLowerCase();
      if (lower.contains('.pdf') ||
          lower.contains('.djvu') ||
          lower.contains('.tif') ||
          lower.endsWith('.svg.png')) {
        continue; // documents, maps and logos are not travel visuals
      }
      images.add(thumb);
      if (images.length >= 6) break;
    }
  } catch (_) {}

  // YouTube suggestions: parse the public results page (no API key).
  final youtube = <Map<String, String>>[];
  try {
    final html = await _httpGetText(
        'https://www.youtube.com/results?search_query='
        '${Uri.encodeQueryComponent(q)}',
        userAgent: 'Mozilla/5.0 (X11; Linux x86_64)');
    final matches = RegExp(
            r'"videoRenderer":\{"videoId":"([\w-]{11})".*?"title":\{"runs":\[\{"text":"((?:[^"\\]|\\.)*)"')
        .allMatches(html);
    final seen = <String>{};
    for (final m in matches) {
      final id = m.group(1)!;
      if (!seen.add(id)) continue;
      var title = m.group(2)!;
      title = title
          .replaceAll(r'&', '&')
          .replaceAll(r'\"', '"')
          .replaceAll(r'\\', r'\');
      youtube.add({
        'title': title,
        'videoId': id,
        'thumbnail': 'https://i.ytimg.com/vi/$id/mqdefault.jpg',
        'url': 'https://www.youtube.com/watch?v=$id',
      });
      if (youtube.length >= 4) break;
    }
  } catch (_) {}

  final payload = <String, Object?>{'images': images, 'youtube': youtube};
  _mediaCache[key] = (DateTime.now(), payload);
  return _json(200, payload);
}

// AI search overview via Groq (compound-mini has built-in web search).
// The key stays server-side; the app only ever talks to this endpoint.
final Map<String, (DateTime, Map<String, Object?>)> _aiCache = {};

Future<Response> _aiSearch(Request request) async {
  final apiKey = Platform.environment['GROQ_API_KEY'];
  if (apiKey == null || apiKey.isEmpty) {
    return _json(503, {'error': 'AI search is not configured.'});
  }
  final body = await _readJsonBody(request);
  final query = (body?['query'] as String?)?.trim() ?? '';
  if (query.isEmpty) return _json(400, {'error': 'query required'});

  final cacheKey = query.toLowerCase();
  final cached = _aiCache[cacheKey];
  if (cached != null &&
      DateTime.now().difference(cached.$1) < const Duration(minutes: 10)) {
    return _json(200, cached.$2);
  }

  try {
    final client = HttpClient();
    final req = await client
        .postUrl(Uri.parse('https://api.groq.com/openai/v1/chat/completions'));
    req.headers.set('Authorization', 'Bearer $apiKey');
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({
      'model': 'groq/compound-mini', // agentic: searches the web itself
      'messages': [
        {
          'role': 'system',
          'content':
              "You are Mr.Tour Guide's travel AI helper. The user searches "
                  'for places, monuments or travel experiences (often in '
                  'India). Structure the reply so it renders as clean cards: '
                  'FIRST a 2-3 sentence overview paragraph (what it feels '
                  'like + accessibility for elderly/disabled visitors), THEN '
                  'these labelled sections, each on its own line as '
                  '"Label: one concise sentence" — only include a label when '
                  'you have something useful for it: '
                  '"Getting there:" (realistic flight/train options), '
                  '"Stay:" (hotel + homestay with typical budgets), '
                  '"Best time:" (season/months), "Tips:" (1-2 practical '
                  'notes). Keep it tight. No markdown, no bullet characters, '
                  'no headings other than those exact labels. '
                  'SCOPE: only travel, destinations, and the Mr.Tour Guide '
                  'app. Refuse everything else — never write or debug code, '
                  'do homework/math, or discuss unrelated topics. If the '
                  'query is off-topic, reply with exactly: "I can only help '
                  'with travel and the Mr.Tour Guide app."'
        },
        {'role': 'user', 'content': query},
      ],
      'max_tokens': 480,
      'temperature': 0.4,
    }));
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    client.close();
    final decoded = jsonDecode(text) as Map<String, dynamic>;
    final overview =
        decoded['choices']?[0]?['message']?['content'] as String?;
    if (overview == null) {
      return _json(502, {'error': 'AI overview unavailable right now.'});
    }
    final payload = <String, Object?>{
      'overview': overview.trim(),
      'model': decoded['model'] ?? 'groq/compound-mini',
      'places': await _matchPlaces(query),
    };
    _aiCache[cacheKey] = (DateTime.now(), payload);
    return _json(200, payload);
  } catch (_) {
    return _json(502, {'error': 'AI overview unavailable right now.'});
  }
}

/// Aggregated notification inbox: new experiences, new places, and social
/// activity (reactions + replies) on the caller's community posts.
Future<Response> _notifications(Request request) async {
  final since = DateTime.tryParse(request.url.queryParameters['since'] ?? '') ??
      DateTime.now().toUtc().subtract(const Duration(days: 7));
  final userId = int.tryParse(request.url.queryParameters['userId'] ?? '');
  final items = <Map<String, Object?>>[];

  // ONE round-trip: every notification source in a single UNION query.
  // The old version ran 7 sequential queries on one connection — with a
  // far-away Postgres that meant 2s+ just in wire latency.
  final me = userId != null;
  final sql = """
    SELECT * FROM (
      (SELECT 'video' AS kind, title AS a, city AS b, NULL::int AS pid,
              uploaded_at AS at
         FROM videos WHERE status = 'ready' AND uploaded_at > @since
              ${me ? 'AND (owner_id IS NULL OR owner_id != @me)' : ''}
        ORDER BY uploaded_at DESC LIMIT 10)
      UNION ALL
      (SELECT 'city', name, slug, NULL::int, created_at
         FROM cities WHERE created_at > @since
        ORDER BY created_at DESC LIMIT 5)
      UNION ALL
      (SELECT 'guidevibe', owner_name, caption, NULL::int, created_at
         FROM shorts WHERE status = 'ready' AND created_at > @since
              ${me ? 'AND owner_id != @me' : ''}
        ORDER BY created_at DESC LIMIT 10)
      UNION ALL
      (SELECT 'community', author_name || ' in ' || community, body,
              NULL::int, created_at
         FROM posts WHERE created_at > @since AND reshared_by IS NULL
              ${me ? 'AND author_id != @me' : ''}
        ORDER BY created_at DESC LIMIT 10)
      ${me ? """
      UNION ALL
      (SELECT 'follow', u.name, NULL::text, NULL::int, f.created_at
         FROM follows f JOIN users u ON u.id = f.follower_id
        WHERE f.followee_id = @me AND f.created_at > @since
        ORDER BY f.created_at DESC LIMIT 10)
      UNION ALL
      (SELECT 'reaction', u.name, r.emoji, p.id, r.created_at
         FROM reactions r JOIN posts p ON p.id = r.post_id
              JOIN users u ON u.id = r.user_id
        WHERE p.author_id = @me AND r.user_id != @me
              AND r.created_at > @since
        ORDER BY r.created_at DESC LIMIT 10)
      UNION ALL
      (SELECT 'reply', rp.author_name, rp.body, p.id, rp.created_at
         FROM replies rp JOIN posts p ON p.id = rp.post_id
        WHERE p.author_id = @me AND rp.author_id != @me
              AND rp.created_at > @since
        ORDER BY rp.created_at DESC LIMIT 10)
      """ : ''}
    ) merged ORDER BY at DESC LIMIT 25
  """;

  try {
    final rows = await _db.execute(
      Sql.named(sql),
      parameters: {'since': since, if (me) 'me': userId},
    );
    String clip(String? t, int n) {
      final v = (t ?? '').trim();
      return v.length > n ? '${v.substring(0, n - 3)}...' : v;
    }

    for (final r in rows) {
      final kind = r[0] as String;
      final a = r[1] as String?;
      final b = r[2] as String?;
      final at = (r[4] as DateTime).toIso8601String();
      switch (kind) {
        case 'video':
          items.add({
            'type': 'video',
            'title': 'New experience: $a',
            'city': b,
            'at': at,
          });
        case 'city':
          items.add({
            'type': 'city',
            'title': 'New place on Mr.TourGuide: $a',
            'city': b,
            'at': at,
          });
        case 'guidevibe':
          final cap = (b ?? '').trim();
          items.add({
            'type': 'guidevibe',
            'title': cap.isEmpty
                ? 'New GuideVibe from $a'
                : 'New GuideVibe: ${clip(cap, 50)}',
            'at': at,
          });
        case 'community':
          items.add({
            'type': 'community',
            'title': '$a: ${clip(b, 60)}',
            'at': at,
          });
        case 'follow':
          items.add({
            'type': 'follow',
            'title': '$a started following you',
            'at': at,
          });
        case 'reaction':
          items.add({
            'type': 'reaction',
            'title': '$a reacted $b to your post',
            'postId': r[3],
            'at': at,
          });
        case 'reply':
          items.add({
            'type': 'reply',
            'title': '$a replied: ${clip(b, 60)}',
            'postId': r[3],
            'at': at,
          });
      }
    }
  } catch (e) {
    print('notifications query failed: $e');
  }

  return _json(200, {'items': items});
}

/// What's new since a timestamp — powers the in-app "new content" toast.
/// Excludes the caller's own uploads so creators aren't notified of
/// themselves.
Future<Response> _whatsNew(Request request) async {
  final since = DateTime.tryParse(request.url.queryParameters['since'] ?? '');
  final userId = int.tryParse(request.url.queryParameters['userId'] ?? '');
  if (since == null) return _json(400, {'error': 'since (ISO time) required'});
  final rows = await _db.execute(
    Sql.named("SELECT $_videoColumns FROM videos WHERE status = 'ready' "
        'AND uploaded_at > @since '
        '${userId != null ? 'AND (owner_id IS NULL OR owner_id != @me) ' : ''}'
        'ORDER BY uploaded_at DESC LIMIT 5'),
    parameters: {
      'since': since,
      if (userId != null) 'me': userId,
    },
  );
  // Also count fresh GuideVibe shorts so the badge/toast fires for them.
  var shortsCount = 0;
  try {
    final s = await _db.execute(
      Sql.named("SELECT count(*) FROM shorts WHERE status = 'ready' "
          'AND created_at > @since '
          '${userId != null ? 'AND owner_id != @me' : ''}'),
      parameters: {'since': since, if (userId != null) 'me': userId},
    );
    shortsCount = (s.first[0] as int?) ?? 0;
  } catch (_) {}
  return _json(200, {
    'count': rows.length + shortsCount,
    'shorts': shortsCount,
    'videos': [for (final r in rows) _videoRowToJson(r)],
  });
}

/// Latest ready experience videos across all cities (home "trending" rail).
Future<Response> _trending(Request request) async {
  final limit =
      (int.tryParse(request.url.queryParameters['limit'] ?? '6') ?? 6)
          .clamp(1, 20);
  final rows = await _db.execute(
    Sql.named("SELECT $_videoColumns FROM videos WHERE status = 'ready' "
        'ORDER BY uploaded_at DESC, id DESC LIMIT @limit'),
    parameters: {'limit': limit},
  );
  return _json(200, {'videos': [for (final r in rows) _videoRowToJson(r)]});
}

Future<Response> _videos(Request request) async {
  final params = request.url.queryParameters;
  final city = params['city'] ?? '';
  final offset = int.tryParse(params['offset'] ?? '0') ?? 0;
  final limit = (int.tryParse(params['limit'] ?? '5') ?? 5).clamp(1, 50);
  final mine = params['mine'] == '1';
  final userId = int.tryParse(params['userId'] ?? '');
  if (city.isEmpty && !mine) {
    return _json(400, {'error': 'city query param required'});
  }

  // "mine": a creator's own uploads (any status). Public: ready-only.
  final where = mine
      ? 'owner_id = @owner ${city.isEmpty ? '' : 'AND city = @city'}'
      : "city = @city AND status = 'ready'";
  if (mine && userId == null) {
    return _json(401, {'error': 'Sign in to view your uploads.'});
  }
  // Fetch one extra row to know whether more pages exist.
  final rows = await _db.execute(
    Sql.named('SELECT $_videoColumns FROM videos WHERE $where '
        'ORDER BY uploaded_at DESC, id DESC OFFSET @offset LIMIT @limit'),
    parameters: {
      if (city.isNotEmpty) 'city': city,
      if (mine) 'owner': userId,
      'offset': offset,
      'limit': limit + 1,
    },
  );
  final hasMore = rows.length > limit;
  final page = hasMore ? rows.take(limit) : rows;
  return _json(200, {
    'videos': [for (final r in page) _videoRowToJson(r)],
    'hasMore': hasMore,
  });
}

Future<Response> _search(Request request) async {
  final q = (request.url.queryParameters['q'] ?? '').trim();
  if (q.isEmpty) return _json(200, {'cities': [], 'videos': []});
  final pattern = '%$q%';

  // Location-aware: state/country queries ("Rajasthan", "India") match
  // via the city's location line and each video's creator-set location.
  final cities = await _db.execute(
    Sql.named('SELECT c.slug, c.name, COUNT(v.id) FROM cities c '
        'LEFT JOIN videos v ON v.city = c.slug '
        'WHERE c.name ILIKE @p OR c.slug ILIKE @p OR c.location ILIKE @p '
        'GROUP BY c.slug, c.name ORDER BY c.name'),
    parameters: {'p': pattern},
  );
  final videos = await _db.execute(
    Sql.named('SELECT $_videoColumns FROM videos '
        "WHERE title ILIKE @p OR city ILIKE @p "
        "OR coalesce(config->>'state', '') ILIKE @p "
        "OR coalesce(config->>'country', '') ILIKE @p "
        "OR coalesce(config->>'cityName', '') ILIKE @p "
        'ORDER BY uploaded_at DESC, id DESC LIMIT 30'),
    parameters: {'p': pattern},
  );
  // People: match by name, @username or email.
  final users = await _db.execute(
    Sql.named('SELECT u.id, u.name, u.username, u.role, u.avatar_url, '
        '(SELECT count(*) FROM follows f WHERE f.followee_id = u.id) '
        'FROM users u WHERE u.name ILIKE @p OR u.username ILIKE @p '
        'OR u.email ILIKE @p ORDER BY 6 DESC LIMIT 8'),
    parameters: {'p': pattern},
  );
  return _json(200, {
    'cities': [
      for (final r in cities) {'slug': r[0], 'name': r[1], 'videoCount': r[2]}
    ],
    'videos': [for (final r in videos) _videoRowToJson(r)],
    'users': [
      for (final r in users)
        {
          'id': r[0],
          'name': r[1],
          'username': r[2],
          'role': r[3],
          'avatarUrl': r[4],
          'followers': r[5],
        }
    ],
  });
}

Future<Response> _upload(Request request) async {
  final params = request.url.queryParameters;
  final city = params['city'] ?? '';
  final title = (params['title'] ?? '').trim();
  final original = _sanitizeFilename(params['filename'] ?? 'upload.bin');
  final userId = int.tryParse(params['userId'] ?? '');

  if (city.isEmpty || title.isEmpty) {
    return _json(400, {'error': 'city and title query params required'});
  }
  // Everyone shares experiences now — creators and travelers alike
  // (traveler uploads carry the traveler badge, not the creator one).
  if (userId == null || await _roleOf(userId) == null) {
    return _json(401, {'error': 'Sign in to upload.'});
  }
  final known = await _db.execute(
    Sql.named('SELECT 1 FROM cities WHERE slug = @city'),
    parameters: {'city': city},
  );
  if (known.isEmpty) return _json(404, {'error': 'Unknown city: $city'});
  const videoExts = {
    'mp4', 'mov', 'm4v', 'mkv', 'webm', 'avi', '3gp', '3g2', 'mts', 'm2ts'
  };
  if (!videoExts.contains(original.split('.').last.toLowerCase())) {
    return _json(400,
        {'error': 'Only video files can be published (MP4, MOV, MKV...).'});
  }

  // Unique stored name: <epoch-ms>_<original>.
  final stored =
      '${DateTime.now().millisecondsSinceEpoch}_$original';

  final int size;
  try {
    size = await _storage.save(city, stored, request.read());
  } on FormatException {
    return _json(413, {'error': 'File exceeds the 500 MB upload limit.'});
  }
  if (size == 0) return _json(400, {'error': 'Empty upload body.'});

  _logActivity('user:$userId', 'video-upload', '"$title" → $city');
  final rows = await _db.execute(
    Sql.named('INSERT INTO videos (city, title, filename, mime, size_bytes, '
        "status, owner_id) VALUES (@city, @title, @filename, @mime, @size, "
        "'processing', @owner) RETURNING $_videoColumns"),
    parameters: {
      'city': city,
      'title': title,
      'filename': stored,
      'mime': _mimeFor(original),
      'size': size,
      'owner': userId,
    },
  );
  final video = _videoRowToJson(rows.first);
  // Optional soundtrack (uploaded first via /videos/upload-audio): muxed in
  // the background before poster + haptics run.
  final audioId = (params['audioId'] ?? '').trim();
  final videoId = video['id'] as int;
  _scheduleMlProcessing(
    videoId,
    preprocess: audioId.isEmpty || !_pendingAudio.containsKey(audioId)
        ? null
        : () => _muxVideoAudio(
              videoId,
              audioId: audioId,
              offset: double.tryParse(params['audioOffset'] ?? '0') ?? 0,
              mode: params['audioMode'] == 'replace' ? 'replace' : 'mix',
              origVol: double.tryParse(params['origVol'] ?? '1') ?? 1,
              audioVol: double.tryParse(params['audioVol'] ?? '1') ?? 1,
            ),
  );
  await _cacheBust('videos');
  await _cacheBust('cities');
  return _json(201, {'video': video});
}

/// Owner check: only the uploader may manage a video.
Future<Response?> _requireOwner(int videoId, int? userId) async {
  if (userId == null) return _json(401, {'error': 'Sign in first.'});
  final rows = await _db.execute(
    Sql.named('SELECT owner_id FROM videos WHERE id = @id'),
    parameters: {'id': videoId},
  );
  if (rows.isEmpty) return _json(404, {'error': 'Video not found.'});
  if (rows.first[0] != userId) {
    return _json(403, {'error': 'You can only manage your own uploads.'});
  }
  return null;
}

/// Creator: update a video's experience configuration (haptics/sound/feel).
Future<Response> _updateConfig(Request request, String id) async {
  final videoId = int.tryParse(id);
  if (videoId == null) return _json(400, {'error': 'Bad video id.'});
  final body = await _readJsonBody(request);
  if (body == null) return _json(400, {'error': 'JSON body required.'});
  final gate = await _requireOwner(videoId, body['userId'] as int?);
  if (gate != null) return gate;

  final config = {
    'haptics': body['haptics'] is bool ? body['haptics'] : true,
    'sound': body['sound'] is bool ? body['sound'] : true,
    'intensity': body['intensity'] is num
        ? (body['intensity'] as num).clamp(0, 1)
        : 0.7,
    'kind': const ['normal', 'vr', 'mr'].contains(body['kind'])
        ? body['kind']
        : 'normal',
    'autoplay': body['autoplay'] is bool ? body['autoplay'] : true,
    'feelMode': const ['auto', 'perframe'].contains(body['feelMode'])
        ? body['feelMode']
        : 'auto',
    // Creator-set location — powers state/country search.
    'country': body['country'] is String
        ? (body['country'] as String).trim().substring(
            0, (body['country'] as String).trim().length.clamp(0, 60))
        : '',
    'state': body['state'] is String
        ? (body['state'] as String).trim().substring(
            0, (body['state'] as String).trim().length.clamp(0, 60))
        : '',
    'cityName': body['cityName'] is String
        ? (body['cityName'] as String).trim().substring(
            0, (body['cityName'] as String).trim().length.clamp(0, 60))
        : '',
  };
  final rows = await _db.execute(
    Sql.named('UPDATE videos SET config = @config WHERE id = @id '
        'RETURNING $_videoColumns'),
    parameters: {'id': videoId, 'config': jsonEncode(config)},
  );
  if (rows.isEmpty) return _json(404, {'error': 'Video not found.'});
  await _cacheBust('videos');
  return _json(200, {'video': _videoRowToJson(rows.first)});
}

/// Creator sets a custom thumbnail for an owned video (like YouTube
/// Studio). Image is compressed server-side to a 640px JPG.
Future<Response> _uploadThumbnail(Request request, String id) async {
  final videoId = int.tryParse(id);
  if (videoId == null) return _json(400, {'error': 'Bad video id.'});
  final params = request.url.queryParameters;
  final gate = await _requireOwner(videoId, int.tryParse(params['userId'] ?? ''));
  if (gate != null) return gate;

  final original = _sanitizeFilename(params['filename'] ?? 'thumb.jpg');
  final ext = original.split('.').last.toLowerCase();
  if (!{'jpg', 'jpeg', 'png', 'webp'}.contains(ext)) {
    return _json(400, {'error': 'Thumbnails must be JPG, PNG or WebP.'});
  }
  final bytes = <int>[];
  await for (final chunk in request.read()) {
    bytes.addAll(chunk);
    if (bytes.length > _maxAvatarBytes) {
      return _json(413, {'error': 'Thumbnails are limited to 5 MB.'});
    }
  }
  if (bytes.isEmpty) return _json(400, {'error': 'Empty upload body.'});

  final cityRow = await _db.execute(
    Sql.named('SELECT city FROM videos WHERE id = @id'),
    parameters: {'id': videoId},
  );
  if (cityRow.isEmpty) return _json(404, {'error': 'Video not found.'});
  final city = cityRow.first[0] as String;

  final stamp = DateTime.now().millisecondsSinceEpoch;
  final tmpIn = File('${Directory.systemTemp.path}/mrt_th_$stamp.$ext');
  await tmpIn.writeAsBytes(bytes);
  final tmpOut = File('${Directory.systemTemp.path}/mrt_th_$stamp.jpg');
  final result = await Process.run('ffmpeg', [
    '-y', '-loglevel', 'error',
    '-i', tmpIn.path,
    '-vf', "scale='trunc(min(640,iw)/2)*2':-2",
    '-q:v', '5',
    tmpOut.path,
  ]);
  await tmpIn.delete();
  if (result.exitCode != 0 || !await tmpOut.exists()) {
    return _json(400, {'error': 'That image could not be processed.'});
  }
  final thumbName = 'custthumb_${videoId}_$stamp.jpg';
  await _storage.save(
      city, thumbName, Stream.value(await tmpOut.readAsBytes()));
  await tmpOut.delete();
  final thumbUrl = '/files/$city/$thumbName';
  final rows = await _db.execute(
    Sql.named('UPDATE videos SET thumb_url = @t WHERE id = @id '
        'RETURNING $_videoColumns'),
    parameters: {'t': thumbUrl, 'id': videoId},
  );
  await _cacheBust('videos');
  return _json(200, {'video': _videoRowToJson(rows.first)});
}

/// Creator fine-tunes the per-second feel track (values 0..1). The player
/// picks the new track up on next play.
Future<Response> _updateHaptics(Request request, String id) async {
  final videoId = int.tryParse(id);
  if (videoId == null) return _json(400, {'error': 'Bad video id.'});
  final body = await _readJsonBody(request);
  final gate = await _requireOwner(videoId, body?['userId'] as int?);
  if (gate != null) return gate;
  final raw = body?['track'] as List?;
  if (raw == null || raw.isEmpty || raw.length > 900) {
    return _json(400, {'error': 'track (1-900 per-second values) required'});
  }
  final track = <double>[];
  for (final v in raw) {
    if (v is! num) return _json(400, {'error': 'track values must be 0-1'});
    track.add(double.parse(v.clamp(0, 1).toStringAsFixed(3)));
  }
  final rows = await _db.execute(
    Sql.named("UPDATE videos SET haptics = jsonb_set("
        "COALESCE(haptics, '{}'::jsonb), '{track}', @track::jsonb) "
        "|| '{\"source\": \"creator-tuned\"}'::jsonb "
        'WHERE id = @id RETURNING $_videoColumns'),
    parameters: {'id': videoId, 'track': jsonEncode(track)},
  );
  if (rows.isEmpty) return _json(404, {'error': 'Video not found.'});
  _logActivity('user:${body?['userId']}', 'haptics-tuned',
      'video #$videoId (${track.length}s track)');
  await _cacheBust('videos');
  return _json(200, {'video': _videoRowToJson(rows.first)});
}

Future<Response> _feedback(Request request) async {
  final body = await _readJsonBody(request);
  final message = (body?['message'] as String?)?.trim() ?? '';
  final email = (body?['email'] as String?)?.trim();
  final rating = body?['rating'] is int ? body!['rating'] as int : null;
  if (message.isEmpty) return _json(400, {'error': 'Feedback message required.'});
  if (rating != null && (rating < 1 || rating > 5)) {
    return _json(400, {'error': 'Rating must be 1-5.'});
  }
  await _db.execute(
    Sql.named('INSERT INTO feedback (email, rating, message) '
        'VALUES (@email, @rating, @message)'),
    parameters: {'email': email, 'rating': rating, 'message': message},
  );
  // Tell the team by mail, fire-and-forget (FEEDBACK_EMAIL overrides the
  // default inbox = the Brevo sender address).
  final inbox = Platform.environment['FEEDBACK_EMAIL'] ??
      Platform.environment['BREVO_SENDER_EMAIL'] ??
      'info@patienceai.in';
  final stars = rating == null ? '' : ' · ${'★' * rating}${'☆' * (5 - rating)}';
  _sendEmail(
    inbox,
    'New Mr.Tour Guide feedback$stars',
    '<div style="font-family:system-ui,sans-serif;max-width:560px">'
        '<h2 style="margin:0 0 8px">New feedback from the app</h2>'
        '${rating != null ? '<p style="margin:0 0 6px;font-size:15px">Rating: <b>$rating/5</b></p>' : ''}'
        '${email != null && email.isNotEmpty ? '<p style="margin:0 0 6px;font-size:15px">From: <b>${_escapeHtml(email)}</b></p>' : ''}'
        '<blockquote style="margin:10px 0;padding:10px 14px;background:#f4f6f8;'
        'border-left:4px solid #1E319D;border-radius:6px;white-space:pre-wrap">'
        '${_escapeHtml(message)}</blockquote>'
        '<p style="color:#888;font-size:12px">Sent automatically by the '
        'Mr.Tour Guide backend.</p></div>',
  ).catchError((Object _) => false);
  return _json(201, {'ok': true, 'thanks': 'Feedback received — thank you!'});
}

// ---------------------------------------------------------------------------
// App distribution: landing page, APK download, OTA version check
// ---------------------------------------------------------------------------

String get _backendDir =>
    File(Platform.script.toFilePath()).parent.parent.path;

/// Version manifest for OTA checks. Bump backend/app_version.json when a new
/// APK is dropped into backend/apk/mrtouride.apk.
Future<Map<String, dynamic>> _versionManifest() async {
  final f = File('$_backendDir/app_version.json');
  if (await f.exists()) {
    try {
      return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    } catch (_) {}
  }
  return {'version': '1.0.0', 'buildNumber': 1, 'notes': 'Initial release'};
}

Future<Response> _appVersion(Request request) async {
  final manifest = await _versionManifest();
  final apk = File('$_backendDir/apk/mrtouride.apk');
  // The manifest may point at an absolute URL (e.g. Cloudflare R2 public
  // bucket) and explicitly control availability; otherwise fall back to the
  // locally served /apk file.
  return _json(200, {
    ...manifest,
    'apkAvailable':
        manifest['apkAvailable'] as bool? ?? await apk.exists(),
    'apkUrl': manifest['apkUrl'] as String? ?? '/apk',
  });
}

Future<Response> _apk(Request request) async {
  final apk = File('$_backendDir/apk/mrtouride.apk');
  if (!await apk.exists()) {
    return _json(404,
        {'error': 'No APK published yet. Build one with: flutter build apk'});
  }
  return Response.ok(
    apk.openRead(),
    headers: {
      'content-type': 'application/vnd.android.package-archive',
      'content-disposition': 'attachment; filename="mrtouride.apk"',
      'content-length': '${await apk.length()}',
    },
  );
}

Future<Response> _landing(Request request) async {
  final manifest = await _versionManifest();
  final apkAvailable = await File('$_backendDir/apk/mrtouride.apk').exists();
  final dl = apkAvailable ? '/apk' : '#download';
  final dlLabel = apkAvailable ? 'Download Android APK' : 'APK coming soon';
  final dlClass = apkAvailable ? '' : ' off';
  final html = '''
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>MrTouride — Feel the world from home</title>
<style>
  * { margin:0; padding:0; box-sizing:border-box; }
  html { scroll-behavior:smooth; }
  body { font-family: system-ui, sans-serif; color:#eef2ff;
         background:#04121a; line-height:1.6; }
  a { text-decoration:none; }
  .wrap { max-width:1060px; margin:0 auto; padding:0 24px; }
  nav { display:flex; align-items:center; justify-content:space-between;
        padding:22px 0; }
  .logo { font-size:1.4rem; font-weight:800; color:#fff; }
  .logo span { color:#3CEBFF; }
  nav .links a { color:#b7c4ff; margin-left:26px; font-size:.95rem; }
  nav .links a:hover { color:#3CEBFF; }

  .hero { padding:72px 0 88px; text-align:center;
          background: radial-gradient(1000px 500px at 50% -10%,
                      #1E319D 0%, #0a1f3d 45%, #04121a 100%); }
  .hero h1 { font-size:3.2rem; line-height:1.15; margin-bottom:18px; }
  .hero h1 em { font-style:normal; color:#3CEBFF; }
  .hero p { max-width:640px; margin:0 auto 36px; color:#c7d2ff; }
  .cta-row { display:flex; gap:16px; justify-content:center; flex-wrap:wrap; }
  .btn { display:inline-flex; align-items:center; gap:10px;
         padding:16px 34px; border-radius:40px; font-weight:700;
         font-size:1.02rem; transition:transform .15s, box-shadow .15s; }
  .btn:hover { transform:translateY(-2px); }
  .btn.primary { background:#3CEBFF; color:#052933;
                 box-shadow:0 8px 30px rgba(60,235,255,.35); }
  .btn.creator { background:#9C27B0; color:#fff;
                 box-shadow:0 8px 30px rgba(156,39,176,.35); }
  .btn.ghost { border:1px solid #3d548f; color:#c7d2ff; }
  .btn.off { background:#2a3a55; color:#8fa2c4; pointer-events:none;
             box-shadow:none; }
  .ver { margin-top:18px; font-size:.85rem; color:#7d90b5; }

  section { padding:70px 0; }
  h2 { font-size:1.9rem; text-align:center; margin-bottom:44px; }
  .grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(240px,1fr));
          gap:22px; }
  .card { background:#0b2233; border:1px solid #17395a; border-radius:18px;
          padding:28px 24px; }
  .card .ico { font-size:1.9rem; }
  .card h3 { margin:14px 0 8px; font-size:1.1rem; color:#fff; }
  .card p { color:#9fb3d9; font-size:.93rem; }

  .creators { background:linear-gradient(135deg,#1a0b2e 0%,#3d1053 100%);
              border-radius:26px; padding:56px 44px; text-align:center; }
  .creators h2 { margin-bottom:14px; }
  .creators p { max-width:620px; margin:0 auto 30px; color:#d9c6ea; }
  .steps { display:flex; gap:18px; justify-content:center; flex-wrap:wrap;
           margin-bottom:34px; }
  .step { background:rgba(255,255,255,.07); border-radius:14px;
          padding:16px 22px; font-size:.92rem; color:#e6d5f5; }
  .step b { color:#E1BEE7; display:block; margin-bottom:2px; }

  footer { padding:44px 0 60px; text-align:center; color:#6e82a8;
           font-size:.88rem; }
  @media (max-width:640px){ .hero h1{font-size:2.2rem;} }
</style>
</head>
<body>
  <div class="wrap">
    <nav>
      <div class="logo">Mr<span>Touride</span></div>
      <div class="links">
        <a href="#travelers">Travelers</a>
        <a href="#creators">Creators</a>
        <a href="#download">Download</a>
      </div>
    </nav>
  </div>

  <header class="hero" id="download">
    <div class="wrap">
      <h1>Travel with your senses.<br><em>From home.</em></h1>
      <p>Immersive city experiences with video, MR/VR and real-feel haptics —
         built for everyone the world is hard to reach for: people with
         disabilities, the elderly, students, and anyone facing barriers.</p>
      <div class="cta-row">
        <a class="btn primary$dlClass" href="$dl">&#11015;&#65039; $dlLabel</a>
        <a class="btn creator" href="#creators">&#127916; I'm a Creator</a>
      </div>
      <div class="ver">v${manifest['version']} (build ${manifest['buildNumber']}) · Android · MR/VR headsets supported</div>
    </div>
  </header>

  <section id="travelers">
    <div class="wrap">
      <h2>Feel every destination</h2>
      <div class="grid">
        <div class="card"><div class="ico">&#128241;</div>
          <h3>Real-feel haptics</h3>
          <p>Your phone pulses with each experience — waves, wind, footsteps.
             ML tunes the touch to every video's sound and motion.</p></div>
        <div class="card"><div class="ico">&#129405;</div>
          <h3>MR / VR mode</h3>
          <p>Step inside monuments and streets in mixed or virtual reality —
             or watch in classic video mode with full controls.</p></div>
        <div class="card"><div class="ico">&#9855;</div>
          <h3>Made for everyone</h3>
          <p>Accessibility-first: reduce motion, tailor intensity, sound and
             feel. Your settings always come first.</p></div>
        <div class="card"><div class="ico">&#127758;</div>
          <h3>City by city</h3>
          <p>Jaipur, Agra, Amritsar — and growing. Search, tap, and you're
             there.</p></div>
      </div>
    </div>
  </section>

  <section id="creators">
    <div class="wrap">
      <div class="creators">
        <h2>Creators & influencers — bring the world to those who can't go</h2>
        <p>Upload your travel videos, VR and MR captures. Configure the feel,
           sound and intensity for each video. Our ML pipeline trims, enhances
           and generates the haptic track automatically.</p>
        <div class="steps">
          <div class="step"><b>1. Sign up as Creator</b>one login, app &amp; web</div>
          <div class="step"><b>2. Upload experiences</b>video · VR · MR</div>
          <div class="step"><b>3. Tune the feel</b>haptics · sound · intensity</div>
          <div class="step"><b>4. ML does the rest</b>trim · enhance · haptic track</div>
        </div>
        <a class="btn creator$dlClass" href="$dl">&#11015;&#65039; Get the Creator App (APK)</a>
      </div>
    </div>
  </section>

  <footer>
    <div class="wrap">
      Mr<b style="color:#3CEBFF">Touride</b> — Feel it. Anywhere. Anyone.<br>
      Team Trikers · v${manifest['version']} build ${manifest['buildNumber']}
    </div>
  </footer>
</body>
</html>''';
  return Response.ok(html, headers: {'content-type': 'text/html; charset=utf-8'});
}

/// Owner deletes an upload (row cascade removes reactions is N/A here;
/// stored files stay in R2/cache as orphans — cheap and recoverable).
Future<Response> _deleteVideo(Request request, String id) async {
  final videoId = int.tryParse(id);
  if (videoId == null) return _json(400, {'error': 'Bad video id.'});
  final body = await _readJsonBody(request);
  final gate = await _requireOwner(videoId, body?['userId'] as int?);
  if (gate != null) return gate;
  await _db.execute(
    Sql.named('DELETE FROM videos WHERE id = @id'),
    parameters: {'id': videoId},
  );
  // Drop cached catalog responses so the deletion is visible IMMEDIATELY.
  await _cacheBust('videos');
  await _cacheBust('cities');
  return _json(200, {'ok': true});
}

/// Owner renames an upload.
Future<Response> _renameVideo(Request request, String id) async {
  final videoId = int.tryParse(id);
  if (videoId == null) return _json(400, {'error': 'Bad video id.'});
  final body = await _readJsonBody(request);
  final title = (body?['title'] as String?)?.trim() ?? '';
  if (title.isEmpty || title.length > 120) {
    return _json(400, {'error': 'Title must be 1-120 characters.'});
  }
  final gate = await _requireOwner(videoId, body?['userId'] as int?);
  if (gate != null) return gate;
  final rows = await _db.execute(
    Sql.named(
        'UPDATE videos SET title = @t WHERE id = @id RETURNING $_videoColumns'),
    parameters: {'t': title, 'id': videoId},
  );
  await _cacheBust('videos');
  return _json(200, {'video': _videoRowToJson(rows.first)});
}

const _maxAvatarBytes = 5 * 1024 * 1024;

/// Profile picture upload: 5 MB cap, recompressed server-side to 512px JPEG
/// (storage-friendly), stored via MediaStorage under avatars/.
Future<Response> _uploadAvatar(Request request) async {
  final params = request.url.queryParameters;
  final userId = int.tryParse(params['userId'] ?? '');
  if (userId == null || await _roleOf(userId) == null) {
    return _json(401, {'error': 'Sign in first.'});
  }
  final original = _sanitizeFilename(params['filename'] ?? 'avatar.jpg');
  final ext = original.split('.').last.toLowerCase();
  if (!{'jpg', 'jpeg', 'png', 'webp'}.contains(ext)) {
    return _json(400, {'error': 'Only JPG, PNG or WebP images.'});
  }
  final bytes = <int>[];
  await for (final chunk in request.read()) {
    bytes.addAll(chunk);
    if (bytes.length > _maxAvatarBytes) {
      return _json(413, {'error': 'Profile pictures are limited to 5 MB.'});
    }
  }
  if (bytes.isEmpty) return _json(400, {'error': 'Empty upload body.'});

  final stamp = DateTime.now().millisecondsSinceEpoch;
  final tmpIn = File('${Directory.systemTemp.path}/mrt_av_$stamp.$ext');
  await tmpIn.writeAsBytes(bytes);
  final tmpOut = File('${Directory.systemTemp.path}/mrt_av_$stamp.jpg');
  final result = await Process.run('ffmpeg', [
    '-y', '-loglevel', 'error',
    '-i', tmpIn.path,
    '-vf', "scale='trunc(min(512,iw)/2)*2':-2",
    '-q:v', '6',
    tmpOut.path,
  ]);
  final name = 'u${userId}_$stamp.jpg';
  final data =
      result.exitCode == 0 ? await tmpOut.readAsBytes() : bytes;
  await _storage.save('avatars', name, Stream.value(data));
  await tmpIn.delete();
  if (await tmpOut.exists()) await tmpOut.delete();
  final url = '/files/avatars/$name';
  await _db.execute(
    Sql.named('UPDATE users SET avatar_url = @url WHERE id = @id'),
    parameters: {'url': url, 'id': userId},
  );
  return _json(201, {'avatarUrl': url});
}

/// Short bio ("about").
Future<Response> _updateAbout(Request request) async {
  final body = await _readJsonBody(request);
  final userId = body?['userId'] as int?;
  final about = (body?['about'] as String?)?.trim() ?? '';
  if (userId == null) return _json(401, {'error': 'Sign in first.'});
  if (about.length > 300) {
    return _json(400, {'error': 'Keep your bio under 300 characters.'});
  }
  await _db.execute(
    Sql.named('UPDATE users SET about = @a WHERE id = @id'),
    parameters: {'a': about.isEmpty ? null : about, 'id': userId},
  );
  return _json(200, {'ok': true});
}

/// Permanent account deletion (profile "Delete profile"): removes the
/// user's community activity, saved itineraries, owned uploads and the
/// account row itself. DPDP: user data is gone from the catalog and DB.
Future<Response> _deleteAccount(Request request) async {
  final body = await _readJsonBody(request);
  final userId = body?['userId'] as int?;
  if (userId == null) return _json(401, {'error': 'Sign in first.'});
  final exists = await _db.execute(
    Sql.named('SELECT name, email, role, created_at FROM users WHERE id = @id'),
    parameters: {'id': userId},
  );
  if (exists.isEmpty) return _json(404, {'error': 'Account not found.'});
  final u = exists.first;
  _logActivity(
      'user:$userId',
      'user-deleted',
      '${u[0]} <${u[1]}> role=${u[2]} joined=${(u[3] as DateTime).toIso8601String().substring(0, 10)} '
          '(self-service deletion)');
  try {
    for (final sql in [
      'DELETE FROM place_ratings WHERE user_id = @id',
      'DELETE FROM reactions WHERE user_id = @id',
      // Community history stays — marked so readers know.
      "UPDATE posts SET author_name = author_name || ' (account deleted)' "
          "WHERE author_id = @id AND author_name NOT LIKE '%(account deleted)'",
      "UPDATE replies SET author_name = author_name || ' (account deleted)' "
          "WHERE author_id = @id AND author_name NOT LIKE '%(account deleted)'",
      'DELETE FROM follows WHERE follower_id = @id OR followee_id = @id',
      'DELETE FROM push_tokens WHERE user_id = @id',
      'DELETE FROM videos WHERE owner_id = @id',
      'DELETE FROM users WHERE id = @id', // itineraries cascade
    ]) {
      await _db.execute(Sql.named(sql), parameters: {'id': userId});
    }
    _sendEmail(
        u[1] as String,
        'Your Mr.Tour Guide account was deleted',
        _accountDeletedHtml(u[0] as String, byAdmin: false)).then((_) {});
    return _json(200, {'ok': true});
  } catch (_) {
    return _json(500, {'error': 'Could not delete the account. Try again.'});
  }
}

/// Follow / unfollow another member (toggle). Notifies on new follow.
Future<Response> _followToggle(Request request, String id) async {
  final body = await _readJsonBody(request);
  final me = body?['userId'] as int?;
  final target = int.tryParse(id);
  if (me == null) return _json(401, {'error': 'Sign in to follow.'});
  if (target == null || target == me) {
    return _json(400, {'error': 'Invalid user.'});
  }
  final exists = await _db.execute(
    Sql.named('SELECT 1 FROM follows WHERE follower_id = @f '
        'AND followee_id = @t'),
    parameters: {'f': me, 't': target},
  );
  bool following;
  if (exists.isNotEmpty) {
    await _db.execute(
      Sql.named('DELETE FROM follows WHERE follower_id = @f '
          'AND followee_id = @t'),
      parameters: {'f': me, 't': target},
    );
    following = false;
  } else {
    try {
      await _db.execute(
        Sql.named('INSERT INTO follows (follower_id, followee_id) '
            'VALUES (@f, @t)'),
        parameters: {'f': me, 't': target},
      );
    } catch (_) {
      return _json(400, {'error': 'Could not follow that user.'});
    }
    following = true;
    final who = await _db.execute(
      Sql.named('SELECT name FROM users WHERE id = @u'),
      parameters: {'u': me},
    );
    _tokensFor(userId: target).then((tokens) => _sendPush(
          tokens,
          'New follower!',
          '${who.isEmpty ? 'A traveler' : who.first[0]} started following '
              'you on Mr.TourGuide.',
          data: {'type': 'follow'},
        ));
  }
  final counts = await _db.execute(
    Sql.named('SELECT (SELECT count(*) FROM follows WHERE followee_id = @t)'),
    parameters: {'t': target},
  );
  return _json(200, {'following': following, 'followers': counts.first[0]});
}

/// Owner updates handle, socials, contact and per-field visibility.
Future<Response> _updateProfile(Request request) async {
  final body = await _readJsonBody(request);
  final userId = body?['userId'] as int?;
  if (userId == null) return _json(401, {'error': 'Sign in first.'});
  final username =
      (body?['username'] as String?)?.trim().toLowerCase().replaceAll(' ', '');
  if (username != null && username.isNotEmpty) {
    if (!RegExp(r'^[a-z0-9_.]{3,24}$').hasMatch(username)) {
      return _json(400, {
        'error': 'Usernames are 3-24 chars: letters, numbers, _ and . only.'
      });
    }
  }
  final instagram = (body?['instagram'] as String?)?.trim();
  final phone = (body?['phone'] as String?)?.trim();
  final privacy = body?['privacy'];
  try {
    await _db.execute(
      Sql.named('UPDATE users SET '
          'username = COALESCE(@un, username), '
          'instagram = COALESCE(@ig, instagram), '
          'phone = COALESCE(@ph, phone), '
          'privacy = COALESCE(@pr::jsonb, privacy) '
          'WHERE id = @id'),
      parameters: {
        'un': (username?.isEmpty ?? true) ? null : username,
        'ig': instagram,
        'ph': phone,
        'pr': privacy is Map ? jsonEncode(privacy) : null,
        'id': userId,
      },
    );
  } catch (_) {
    return _json(409, {'error': 'That username is already taken.'});
  }
  return _json(200, {'ok': true});
}

/// Public profile card (community username taps).
Future<Response> _publicProfile(Request request, String id) async {
  final userId = int.tryParse(id);
  final viewer = int.tryParse(request.url.queryParameters['viewerId'] ?? '');
  if (userId == null) return _json(400, {'error': 'Bad user id.'});
  final rows = await _db.execute(
    Sql.named('SELECT u.name, u.role, u.avatar_url, u.about, u.created_at, '
        '(SELECT count(*) FROM videos v WHERE v.owner_id = u.id), '
        'u.username, u.cover_url, u.instagram, u.phone, u.privacy, u.email, '
        '(SELECT count(*) FROM follows f WHERE f.followee_id = u.id), '
        '(SELECT count(*) FROM follows f WHERE f.follower_id = u.id) '
        'FROM users u WHERE u.id = @id'),
    parameters: {'id': userId},
  );
  if (rows.isEmpty) return _json(404, {'error': 'User not found.'});
  final r = rows.first;
  final privacy = (r[10] is Map)
      ? Map<String, dynamic>.from(r[10] as Map)
      : <String, dynamic>{};
  bool show(String field) =>
      viewer == userId || (privacy[field] as bool? ?? false);
  bool isFollowing = false;
  if (viewer != null && viewer != userId) {
    final f = await _db.execute(
      Sql.named('SELECT 1 FROM follows WHERE follower_id = @v '
          'AND followee_id = @t'),
      parameters: {'v': viewer, 't': userId},
    );
    isFollowing = f.isNotEmpty;
  }
  return _json(200, {
    'id': userId,
    'name': r[0],
    'role': r[1],
    'avatarUrl': r[2],
    'about': r[3],
    'joined': (r[4] as DateTime).toIso8601String(),
    'uploads': r[5],
    'username': r[6],
    'coverUrl': r[7],
    // Contact + socials: shown only when their owner toggled them public.
    if (show('instagram') && r[8] != null) 'instagram': r[8],
    if (show('phone') && r[9] != null) 'phone': r[9],
    if (show('email')) 'email': r[11],
    'followers': r[12],
    'following': r[13],
    'isFollowing': isFollowing,
    if (viewer == userId) 'privacy': privacy,
  });
}

/// Profile cover/banner upload (compressed to 1280px server-side).
Future<Response> _uploadUserCover(Request request) async {
  final params = request.url.queryParameters;
  final userId = int.tryParse(params['userId'] ?? '');
  if (userId == null || await _roleOf(userId) == null) {
    return _json(401, {'error': 'Sign in first.'});
  }
  final original = _sanitizeFilename(params['filename'] ?? 'cover.jpg');
  final ext = original.split('.').last.toLowerCase();
  if (!{'jpg', 'jpeg', 'png', 'webp'}.contains(ext)) {
    return _json(400, {'error': 'Only JPG, PNG or WebP images.'});
  }
  final bytes = <int>[];
  await for (final chunk in request.read()) {
    bytes.addAll(chunk);
    if (bytes.length > _maxAvatarBytes) {
      return _json(413, {'error': 'Covers are limited to 5 MB.'});
    }
  }
  if (bytes.isEmpty) return _json(400, {'error': 'Empty upload body.'});
  final stamp = DateTime.now().millisecondsSinceEpoch;
  final tmpIn = File('${Directory.systemTemp.path}/mrt_uc_$stamp.$ext');
  await tmpIn.writeAsBytes(bytes);
  final tmpOut = File('${Directory.systemTemp.path}/mrt_uc_$stamp.jpg');
  final result = await Process.run('ffmpeg', [
    '-y', '-loglevel', 'error',
    '-i', tmpIn.path,
    '-vf', "scale='trunc(min(1280,iw)/2)*2':-2",
    '-q:v', '5',
    tmpOut.path,
  ]);
  await tmpIn.delete();
  if (result.exitCode != 0 || !await tmpOut.exists()) {
    return _json(400, {'error': 'That image could not be processed.'});
  }
  final name = 'usercover_${userId}_$stamp.jpg';
  await _storage.save(
      'avatars', name, Stream.value(await tmpOut.readAsBytes()));
  await tmpOut.delete();
  final url = '/files/avatars/$name';
  await _db.execute(
    Sql.named('UPDATE users SET cover_url = @c WHERE id = @id'),
    parameters: {'c': url, 'id': userId},
  );
  return _json(200, {'coverUrl': url});
}

/// Password change (verifies the old password first).
Future<Response> _changePassword(Request request) async {
  final body = await _readJsonBody(request);
  final userId = body?['userId'] as int?;
  final oldPassword = body?['oldPassword'] as String? ?? '';
  final newPassword = body?['newPassword'] as String? ?? '';
  if (userId == null) return _json(401, {'error': 'Sign in first.'});
  if (newPassword.length < 6) {
    return _json(400, {'error': 'New password is too weak (min 6 chars).'});
  }
  final rows = await _db.execute(
    Sql.named('SELECT password_hash, salt, provider FROM users WHERE id = @id'),
    parameters: {'id': userId},
  );
  if (rows.isEmpty) return _json(404, {'error': 'Unknown user.'});
  if (rows.first[2] == 'google') {
    return _json(409, {'error': 'Google accounts manage their password with Google.'});
  }
  final oldHash = _hashPassword(oldPassword, rows.first[1] as String);
  if (!_constantTimeEquals(oldHash, rows.first[0] as String)) {
    return _json(401, {'error': 'Current password is incorrect.'});
  }
  final salt = _newSalt();
  await _db.execute(
    Sql.named('UPDATE users SET password_hash = @hash, salt = @salt WHERE id = @id'),
    parameters: {
      'hash': _hashPassword(newPassword, salt),
      'salt': salt,
      'id': userId,
    },
  );
  return _json(200, {'ok': true});
}

Future<Response> _serveFile(Request request, String city, String name) async {
  // Sanitize to block path traversal.
  final file =
      await _storage.open(_sanitizeFilename(city), _sanitizeFilename(name));
  if (file == null) return _json(404, {'error': 'File not found.'});
  return Response.ok(
    file.openRead(),
    headers: {
      'content-type': _mimeFor(name),
      'content-length': '${await file.length()}',
      'accept-ranges': 'bytes',
      // Filenames are content-stamped → let Cloudflare/browsers cache hard.
      // Keeps the free-tier VM out of the media path almost entirely.
      'cache-control': 'public, max-age=604800, immutable',
    },
  );
}

// ---------------------------------------------------------------------------

/// Opens the database. When DATABASE_URL is set (e.g. the Neon cloud
/// Postgres), connects there over TLS; otherwise falls back to the local
/// Postgres unix socket. Use Neon's DIRECT endpoint (no "-pooler") — the
/// server holds one long-lived session.
Future<Connection> _openDb() async {
  final url = Platform.environment['DATABASE_URL'];
  if (url != null && url.isNotEmpty) {
    final u = Uri.parse(url);
    final userInfo = u.userInfo.split(':');
    final ssl = u.queryParameters['sslmode'] != 'disable';
    // A single long-lived session should talk to Neon's DIRECT endpoint, not
    // Neon wants its DIRECT endpoint for a long-lived session (strip
    // "-pooler"); Supabase, by contrast, is reached VIA its pooler, so only
    // rewrite Neon hosts.
    final host = u.host.contains('neon.tech')
        ? u.host.replaceFirst('-pooler.', '.')
        : u.host;
    print('DB: connecting to $host/${u.path.replaceFirst('/', '')} '
        '(ssl: $ssl)');
    final conn = await Connection.open(
      Endpoint(
        host: host,
        port: u.hasPort ? u.port : 5432,
        database: u.path.replaceFirst('/', ''),
        username: Uri.decodeComponent(userInfo[0]),
        password: userInfo.length > 1 ? Uri.decodeComponent(userInfo[1]) : null,
      ),
      settings: ConnectionSettings(
          sslMode: ssl ? SslMode.require : SslMode.disable),
    );
    // Managed roles can ship an empty/non-public search_path; pin it to the
    // app's schema. DB_SCHEMA lets us isolate into e.g. "mrtouride" when the
    // Postgres database is shared with another app (Supabase).
    await conn.execute(
        'SET search_path TO ${Platform.environment['DB_SCHEMA'] ?? 'public'}');
    return conn;
  }
  print('DB: connecting to local Postgres (unix socket)');
  final conn = await Connection.open(
    Endpoint(
      host: '/var/run/postgresql/.s.PGSQL.5432',
      database: 'mrtouride',
      username: 'harsh',
      isUnixSocket: true,
    ),
    settings: ConnectionSettings(sslMode: SslMode.disable),
  );
  await conn.execute('SET search_path TO public');
  return conn;
}

Future<void> main() async {
  _db = await _openDb();

  // Saved AI itineraries (auto-migrates on every deploy).
  await _db.execute('CREATE TABLE IF NOT EXISTS itineraries ('
      'id SERIAL PRIMARY KEY, '
      'user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE, '
      'title TEXT NOT NULL, '
      'query TEXT NOT NULL, '
      'plan TEXT NOT NULL, '
      'created_at TIMESTAMPTZ NOT NULL DEFAULT now())');
  // User place ratings — replaces hardcoded catalog ratings.
  await _db.execute('CREATE TABLE IF NOT EXISTS place_ratings ('
      'id SERIAL PRIMARY KEY, '
      'city_slug TEXT NOT NULL, '
      'user_id INTEGER NOT NULL, '
      'stars INTEGER NOT NULL CHECK (stars BETWEEN 1 AND 5), '
      'created_at TIMESTAMPTZ NOT NULL DEFAULT now(), '
      'UNIQUE (city_slug, user_id))');

  // Push notification device tokens (FCM).
  await _db.execute('CREATE TABLE IF NOT EXISTS push_tokens ('
      'token TEXT PRIMARY KEY, '
      'user_id INTEGER, '
      'updated_at TIMESTAMPTZ NOT NULL DEFAULT now())');
  // Place ownership: only the creator who ADDED a place can manage it.
  await _db.execute(
      'ALTER TABLE cities ADD COLUMN IF NOT EXISTS owner_id INTEGER');
  // Location targeting: the device's city + "my location only" preference.
  await _db.execute(
      'ALTER TABLE push_tokens ADD COLUMN IF NOT EXISTS city TEXT');
  await _db.execute('ALTER TABLE push_tokens '
      'ADD COLUMN IF NOT EXISTS loc_only BOOLEAN NOT NULL DEFAULT false');

  // Social layer: follows, profile extras, threaded replies, reshares.
  await _db.execute('CREATE TABLE IF NOT EXISTS follows ('
      'follower_id INTEGER NOT NULL, '
      'followee_id INTEGER NOT NULL, '
      'created_at TIMESTAMPTZ NOT NULL DEFAULT now(), '
      'PRIMARY KEY (follower_id, followee_id))');
  for (final ddl in [
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS username TEXT",
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS cover_url TEXT",
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS instagram TEXT",
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS phone TEXT",
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS privacy JSONB",
    "ALTER TABLE replies ADD COLUMN IF NOT EXISTS parent_reply_id INTEGER",
    "ALTER TABLE posts ADD COLUMN IF NOT EXISTS reshared_from INTEGER",
    "ALTER TABLE posts ADD COLUMN IF NOT EXISTS reshared_by TEXT",
    "ALTER TABLE posts ADD COLUMN IF NOT EXISTS reshared_by_id INTEGER",
    "ALTER TABLE posts ADD COLUMN IF NOT EXISTS reshared_by_role TEXT",
    "ALTER TABLE posts ADD COLUMN IF NOT EXISTS reshare_comment TEXT",
    "ALTER TABLE posts ADD COLUMN IF NOT EXISTS media JSONB",
  ]) {
    try {
      await _db.execute(ddl);
    } catch (e) {
      print('migration note: $ddl ($e)');
    }
  }
  try {
    await _db.execute('CREATE UNIQUE INDEX IF NOT EXISTS users_username_key '
        'ON users (lower(username)) WHERE username IS NOT NULL');
  } catch (_) {}

  // GuideVibe: short vertical videos (Reels/Shorts). Kept separate from the
  // long-form `videos` table so the two features never interfere. haptics is
  // the same {track, fine, events} contract used by the experience player.
  await _db.execute('CREATE TABLE IF NOT EXISTS shorts ('
      'id SERIAL PRIMARY KEY, '
      'owner_id INTEGER NOT NULL, '
      'owner_name TEXT NOT NULL, '
      'owner_role TEXT NOT NULL, '
      'caption TEXT NOT NULL DEFAULT \'\', '
      'city TEXT, '
      'filename TEXT NOT NULL, '
      'thumb_url TEXT, '
      'kind TEXT NOT NULL DEFAULT \'normal\', ' // normal | vr | mr
      'haptics JSONB, '
      'likes INTEGER NOT NULL DEFAULT 0, '
      'views INTEGER NOT NULL DEFAULT 0, '
      'size_bytes BIGINT NOT NULL DEFAULT 0, '
      'status TEXT NOT NULL DEFAULT \'processing\', '
      'created_at TIMESTAMPTZ NOT NULL DEFAULT now())');
  await _db.execute('CREATE TABLE IF NOT EXISTS short_likes ('
      'short_id INTEGER NOT NULL, '
      'user_id INTEGER NOT NULL, '
      'created_at TIMESTAMPTZ NOT NULL DEFAULT now(), '
      'PRIMARY KEY (short_id, user_id))');
  await _db.execute('CREATE TABLE IF NOT EXISTS short_comments ('
      'id SERIAL PRIMARY KEY, '
      'short_id INTEGER NOT NULL, '
      'author_id INTEGER NOT NULL, '
      'author_name TEXT NOT NULL, '
      'body TEXT NOT NULL, '
      'created_at TIMESTAMPTZ NOT NULL DEFAULT now())');

  // Ratings/discussion threads on a place (city) page.
  await _db.execute('CREATE TABLE IF NOT EXISTS place_comments ('
      'id SERIAL PRIMARY KEY, '
      'city_slug TEXT NOT NULL, '
      'author_id INTEGER NOT NULL, '
      'author_name TEXT NOT NULL, '
      'author_role TEXT NOT NULL DEFAULT \'traveler\', '
      'body TEXT NOT NULL, '
      'parent_id INTEGER, ' // one-level threads (reply to a comment)
      'created_at TIMESTAMPTZ NOT NULL DEFAULT now())');

  // Security / audit trail for the admin panel.
  await _db.execute('CREATE TABLE IF NOT EXISTS activity_logs ('
      'id SERIAL PRIMARY KEY, '
      'at TIMESTAMPTZ NOT NULL DEFAULT now(), '
      'actor TEXT NOT NULL, '
      'action TEXT NOT NULL, '
      'details TEXT)');

  // Notification timeline columns (no-ops when already present). Guarded:
  // on databases where the app user doesn't own these tables the ALTER is
  // applied manually instead — startup must never crash on it.
  for (final table in ['cities', 'reactions']) {
    try {
      await _db.execute('ALTER TABLE $table ADD COLUMN IF NOT EXISTS '
          'created_at TIMESTAMPTZ NOT NULL DEFAULT now()');
    } catch (e) {
      print('migration note: $table.created_at not added ($e)');
    }
  }

  final uploadsDir =
      '${File(Platform.script.toFilePath()).parent.parent.path}/uploads';
  final r2Endpoint = Platform.environment['R2_ENDPOINT'];
  final r2Bucket = Platform.environment['R2_BUCKET'];
  final r2Key = Platform.environment['R2_ACCESS_KEY_ID'];
  final r2Secret = Platform.environment['R2_SECRET_ACCESS_KEY'];
  if (r2Endpoint != null &&
      r2Bucket != null &&
      r2Key != null &&
      r2Secret != null) {
    _storage = R2Storage(
      endpoint: r2Endpoint,
      bucket: r2Bucket,
      accessKey: r2Key,
      secretKey: r2Secret,
      cache: LocalFolderStorage(uploadsDir),
    );
    print('Storage: Cloudflare R2 ($r2Bucket) with local cache');
  } else {
    _storage = LocalFolderStorage(uploadsDir);
    print('Storage: local folder only (set R2_* env for Cloudflare R2)');
  }

  final router = Router()
    ..get('/', _landing)
    ..get('/health', (Request r) => _json(200, {'ok': true}))
    ..post('/signup', _signup)
    ..post('/login', _login)
    ..post('/verify', _verify)
    ..post('/resend-code', _resendCode)
    ..post('/auth/forgot', _forgotPassword)
    ..post('/auth/reset', _resetPassword)
    ..post('/auth/google', _googleAuth)
    ..get('/cities', _cities)
    ..post('/cities', _addCity)
    ..post('/cities/<slug>/rate', _ratePlace)
    ..post('/cities/<slug>/edit', _editCity)
    ..post('/cities/<slug>/remove', _removeCity)
    ..get('/cities/<slug>/rating', _placeRating)
    ..get('/cities/<slug>/comments', _placeComments)
    ..post('/cities/<slug>/comments', _addPlaceComment)
    ..post('/place-comments/<id>/delete', _deletePlaceComment)
    ..get('/news', _travelNews)
    ..get('/geo/reverse', _geoReverse)
    ..post('/cities/<city>/cover', _uploadCover)
    ..get('/videos', _videos)
    ..get('/videos/trending', _trending)
    ..get('/whats-new', _whatsNew)
    ..get('/notifications', _notifications)
    ..post('/push/register', _pushRegister)
    ..get('/videos/suggest', _suggest)
    ..get('/cities/<slug>/weather', _weather)
    ..get('/search', _search)
    ..get('/search/media', _searchMedia)
    ..post('/ai/search', _aiSearch)
    ..post('/ai/itinerary', _aiItinerary)
    ..post('/itineraries', _saveItinerary)
    ..get('/itineraries', _listItineraries)
    ..post('/itineraries/<id>/update', _updateItinerary)
    ..post('/itineraries/<id>/delete', _deleteItinerary)
    ..get('/community/posts', _communityPosts)
    ..post('/community/posts', _createPost)
    ..post('/community/posts/<id>/react', _react)
    ..post('/community/posts/<id>/reshare', _resharePost)
    ..post('/community/posts/<id>/reshare-comment', _reshareComment)
    ..post('/community/posts/<id>/delete', _deletePost)
    ..get('/community/posts/<id>/replies', _replies)
    ..post('/community/posts/<id>/replies', _addReply)
    ..post('/community/replies/<id>/delete', _deleteReply)
    ..post('/community/upload-image', _uploadCommunityImage)
    ..post('/community/upload-video', _uploadCommunityVideo)
    ..get('/post/<id>', _publicPost)
    ..get('/guidevibe', _guidevibeFeed)
    ..get('/music/search', _musicSearch)
    ..post('/guidevibe/upload', _uploadShort)
    ..post('/guidevibe/<id>/like', _likeShort)
    ..post('/guidevibe/<id>/view', _viewShort)
    ..get('/guidevibe/<id>/comments', _shortComments)
    ..post('/guidevibe/<id>/comments', _addShortComment)
    ..post('/guidevibe/<id>/update', _updateShort)
    ..post('/guidevibe/<id>/delete', _deleteShort)
    ..get('/guidevibe/<id>/analytics', _shortAnalytics)
    ..get('/short/<id>', _publicShort)
    ..post('/upload', _upload)
    ..post('/videos/upload-audio', _uploadVideoAudio)
    ..post('/videos/<id>/config', _updateConfig)
    ..post('/videos/<id>/thumbnail', _uploadThumbnail)
    ..post('/videos/<id>/haptics', _updateHaptics)
    ..post('/videos/<id>/delete', _deleteVideo)
    ..post('/videos/<id>/rename', _renameVideo)
    ..post('/auth/change-password', _changePassword)
    ..post('/users/avatar', _uploadAvatar)
    ..post('/users/about', _updateAbout)
    ..post('/users/profile', _updateProfile)
    ..post('/users/cover', _uploadUserCover)
    ..post('/users/<id>/follow', _followToggle)
    ..post('/users/delete-account', _deleteAccount)
    ..get('/users/<id>/profile', _publicProfile)
    ..post('/feedback', _feedback)
    ..get('/admin', _adminPage)
    ..get('/admin/api/users', _adminUsers)
    ..post('/admin/api/users', _adminCreateUser)
    ..post('/admin/api/users/<id>/update', _adminUpdateUser)
    ..post('/admin/api/users/<id>/delete', _adminDeleteUser)
    ..get('/admin/api/logs', _adminLogs)
    ..get('/admin/api/test-mail', _adminTestMail)
    ..get('/admin/api/cities', _adminCities)
    ..post('/admin/api/cities', _adminAddCity)
    ..post('/admin/api/cities/<slug>/update', _adminUpdateCity)
    ..post('/admin/api/cities/<slug>/delete', _adminDeleteCity)
    ..get('/app/version', _appVersion)
    ..get('/apk', _apk)
    ..get('/files/<city>/<name>', _serveFile);

  // On the VM, nginx maps /api/* → backend (prefix stripped), /admin → backend
  // and serves the landing statically. On Render there is no nginx, so this
  // one service replicates all three. /api/* is routed by EXPLICIT prefix
  // strip — NOT a Cascade — because Cascade falls through on ANY 404,
  // swallowing legitimate 404 JSON responses (e.g. login "no user found",
  // forgot-password "no password account") and replacing them with a plain
  // "Route not found" the app can't parse (it surfaced as a fake
  // "check your internet" error).
  final landingDir = '$_backendDir/web/landing';
  final Handler rootHandler = Directory(landingDir).existsSync()
      // Static files first; anything the landing doesn't have falls to the
      // router (/admin, /health, /files, /post/<id>, /short/<id>…), whose
      // responses — including 404s — are final.
      ? (Cascade()
              .add(createStaticHandler(landingDir,
                  defaultDocument: 'index.html'))
              .add(router.call))
          .handler
      : router.call;

  Future<Response> route(Request request) async {
    final p = request.url.path;
    if (p == 'api' || p.startsWith('api/')) {
      // Strip the /api prefix; the router's response is FINAL (no cascade).
      return await router.call(request.change(path: 'api'));
    }
    return await rootHandler(request);
  }

  final handler = const Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(_rateLimit())
      .addMiddleware(_edgeCache())
      .addMiddleware(_redisCache())
      .addMiddleware(_cors())
      .addHandler(route);

  final server = await shelf_io.serve(handler, InternetAddress.anyIPv4, _port);
  print('MrTouride backend listening on http://${server.address.host}:${server.port}');

  // Keep the Neon connection warm (its free compute auto-suspends after a few
  // idle minutes) and self-heal a dropped session by reconnecting.
  Timer.periodic(const Duration(minutes: 4), (_) async {
    try {
      await _db.execute('SELECT 1');
    } catch (e) {
      print('DB keep-alive failed, reconnecting: $e');
      try {
        _db = await _openDb();
      } catch (e2) {
        print('DB reconnect failed: $e2');
      }
    }
  });

  // App-update push: each shipped build redeploys this server, so on boot we
  // announce the manifest's build to every device ONCE (activity_logs
  // remembers what was already announced — restarts don't re-push).
  Future(() async {
    try {
      final manifest = await _versionManifest();
      final build = manifest['buildNumber'];
      final version = manifest['version'];
      if (build == null) return;
      final announced = await _db.execute(
        Sql.named('SELECT 1 FROM activity_logs WHERE action = @a '
            'AND details = @d LIMIT 1'),
        parameters: {'a': 'update-announced', 'd': 'build $build'},
      );
      if (announced.isNotEmpty) return;
      _logActivity('system', 'update-announced', 'build $build');
      _sendPush(
        await _tokensFor(),
        'Update available — v$version',
        '${manifest['notes'] ?? 'A new version of Mr.Tour Guide is ready.'}',
        data: {'type': 'update'},
      );
    } catch (e) {
      print('update announce skipped: $e');
    }
  });
}
