import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

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

const _port = 8080;
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
    // Buffer (upload caps are enforced by the callers).
    final data = <int>[];
    await for (final chunk in bytes) {
      data.addAll(chunk);
      if (data.length > _maxUploadBytes) {
        throw const FormatException('File too large.');
      }
    }
    await _put('$city/$filename', data);
    await cache.save(city, filename, Stream.value(data));
    return data.length;
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
      'uploadedAt': (row[7] as DateTime).toIso8601String(),
      'status': row[8],
      'config': row[9],
      'thumbUrl': row[10],
      'url': '/files/${row[1]}/${row[3]}',
    };

const _videoColumns =
    'id, city, title, filename, mime, size_bytes, haptics, uploaded_at, '
    'status, config, thumb_url';

/// Simulated ML pipeline: after a short "processing" period the video is
/// trimmed/enhanced, a poster thumbnail is extracted (real ffmpeg) and a
/// haptic track is generated from its audio/motion. Replace with the real
/// ML worker later — same DB contract.
void _scheduleMlProcessing(int videoId) {
  Timer(const Duration(seconds: 15), () async {
    try {
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

      await _db.execute(
        Sql.named("UPDATE videos SET status = 'ready', haptics = @haptics, "
            'thumb_url = @thumb WHERE id = @id'),
        parameters: {
          'id': videoId,
          'thumb': thumbUrl,
          'haptics': jsonEncode({
            'profile': 'auto',
            'source': 'ml-sim',
            'generatedAt': DateTime.now().toIso8601String(),
            'events': 8 + Random().nextInt(24),
          }),
        },
      );
      print('ML-sim: video $videoId processed (trim/enhance/thumb/haptics).');
    } catch (e) {
      print('ML-sim: failed for video $videoId: $e');
    }
  });
}

// ---------------------------------------------------------------------------
// Auth handlers
// ---------------------------------------------------------------------------

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
    print('VERIFY-EMAIL: code for $email is $code');
    return _json(201, {
      'id': row[0],
      'name': row[1],
      'email': row[2],
      'role': row[3],
      'needsVerification': true,
      'devCode': code,
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
  return _json(
      200, {'id': row[0], 'name': row[1], 'email': row[2], 'role': row[3]});
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
  print('VERIFY-EMAIL: new code for $email is $code');
  return _json(200, {'ok': true, 'devCode': code});
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
  final email = (body?['email'] as String?)?.trim().toLowerCase() ?? '';
  final name = (body?['name'] as String?)?.trim() ?? '';
  final role = body?['role'] == 'creator' ? 'creator' : 'traveler';
  if (email.isEmpty || !email.contains('@')) {
    return _json(400, {'error': 'Valid Google email required.'});
  }

  final existing = await _db.execute(
    Sql.named(
        'SELECT id, name, email, role, provider FROM users WHERE email = @email'),
    parameters: {'email': email},
  );

  if (mode == 'signup') {
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
  return _json(
      200, {'id': row[0], 'name': row[1], 'email': row[2], 'role': row[3]});
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
        'verified FROM users WHERE email = @email'),
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
  return _json(
      200, {'id': row[0], 'name': row[1], 'email': row[2], 'role': row[5]});
}

// ---------------------------------------------------------------------------
// Video handlers
// ---------------------------------------------------------------------------

Future<Response> _cities(Request request) async {
  final rows = await _db.execute(
      'SELECT c.slug, c.name, COUNT(v.id), c.cover_url, c.location, '
      'c.description, c.rating FROM cities c '
      'LEFT JOIN videos v ON v.city = c.slug '
      'GROUP BY c.slug, c.name, c.cover_url, c.location, c.description, '
      'c.rating ORDER BY c.name');
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
          'rating': r[6],
        }
    ]
  });
}

/// Creator: upload a high-res cover image for a city (raw bytes).
/// The cover shows in the app's home carousel and place page hero.
Future<Response> _uploadCover(Request request, String city) async {
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
  if (rows.isEmpty || rows.first[1] == null) {
    return _json(404, {'error': 'No weather available for $slug.'});
  }
  final lat = rows.first[1], lon = rows.first[2];
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
             (SELECT count(*) FROM replies rp WHERE rp.post_id = p.id)
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
        'created_at FROM replies WHERE post_id = @p ORDER BY created_at, id'),
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
  await _db.execute(
    Sql.named('INSERT INTO replies (post_id, author_id, author_name, '
        'author_role, body) VALUES (@p, @u, @name, @role, @body)'),
    parameters: {
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
    '-vf', "scale='min(1280,iw)':-2",
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

Future<Response> _createPost(Request request) async {
  final body = await _readJsonBody(request);
  final userId = body?['userId'] as int?;
  final community = body?['community'] as String? ?? 'travelers';
  final text = (body?['body'] as String?)?.trim() ?? '';
  final city = (body?['city'] as String?)?.trim();
  if (userId == null) return _json(401, {'error': 'Sign in to post.'});
  if (text.isEmpty) return _json(400, {'error': 'Say something first!'});
  if (text.length > 1000) return _json(400, {'error': 'Keep it under 1000 characters.'});

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

  final rows = await _db.execute(
    Sql.named('INSERT INTO posts (community, author_id, author_name, '
        'author_role, city, body, image_url) VALUES (@community, @id, @name, '
        '@role, @city, @body, @image) RETURNING id'),
    parameters: {
      'community': community,
      'id': userId,
      'name': user.first[0],
      'role': user.first[1],
      'city': (city?.isEmpty ?? true) ? null : city,
      'body': text,
      'image': safeImage,
    },
  );
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
  final rows = await _db.execute(
    Sql.named('DELETE FROM posts WHERE id = @p AND author_id = @u RETURNING 1'),
    parameters: {'p': postId, 'u': userId},
  );
  if (rows.isEmpty) {
    return _json(403, {'error': 'You can only delete your own posts.'});
  }
  return _json(200, {'ok': true});
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

Future<Response> _searchMedia(Request request) async {
  final q = (request.url.queryParameters['q'] ?? '').trim();
  if (q.isEmpty) return _json(200, {'images': [], 'youtube': []});
  final key = q.toLowerCase();
  final cached = _mediaCache[key];
  if (cached != null &&
      DateTime.now().difference(cached.$1) < const Duration(minutes: 30)) {
    return _json(200, cached.$2);
  }

  // Wikimedia Commons photo search (direct upload.wikimedia.org thumbs
  // send CORS headers, so the app can render them).
  final images = <String>[];
  try {
    final body = await _httpGetText(
        'https://commons.wikimedia.org/w/api.php?action=query&format=json'
        '&generator=search&gsrsearch=${Uri.encodeQueryComponent(q)}'
        '&gsrnamespace=6&gsrlimit=8&prop=imageinfo&iiprop=url&iiurlwidth=640');
    final decoded = jsonDecode(body) as Map<String, dynamic>;
    final pages =
        (decoded['query']?['pages'] as Map<String, dynamic>?) ?? {};
    for (final p in pages.values) {
      final info = (p['imageinfo'] as List?)?.first as Map<String, dynamic>?;
      final thumb = info?['thumburl'] as String?;
      if (thumb != null &&
          (thumb.endsWith('.jpg') ||
              thumb.endsWith('.jpeg') ||
              thumb.endsWith('.png'))) {
        images.add(thumb);
      }
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
              "You are MrTouride's travel AI. The user searches for places, "
                  'monuments or travel experiences (often in India). Reply '
                  'with a MINIMAL overview: 2-4 short sentences. Focus on '
                  'what the place feels like, accessibility for elderly/'
                  'disabled visitors, and current practical tips. No '
                  'headings, no lists, no markdown.'
        },
        {'role': 'user', 'content': query},
      ],
      'max_tokens': 220,
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
    };
    _aiCache[cacheKey] = (DateTime.now(), payload);
    return _json(200, payload);
  } catch (_) {
    return _json(502, {'error': 'AI overview unavailable right now.'});
  }
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
  if (city.isEmpty) return _json(400, {'error': 'city query param required'});

  // Fetch one extra row to know whether more pages exist.
  final rows = await _db.execute(
    Sql.named('SELECT $_videoColumns FROM videos WHERE city = @city '
        'ORDER BY uploaded_at DESC, id DESC OFFSET @offset LIMIT @limit'),
    parameters: {'city': city, 'offset': offset, 'limit': limit + 1},
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

  final cities = await _db.execute(
    Sql.named('SELECT c.slug, c.name, COUNT(v.id) FROM cities c '
        'LEFT JOIN videos v ON v.city = c.slug '
        'WHERE c.name ILIKE @p OR c.slug ILIKE @p '
        'GROUP BY c.slug, c.name ORDER BY c.name'),
    parameters: {'p': pattern},
  );
  final videos = await _db.execute(
    Sql.named('SELECT $_videoColumns FROM videos '
        'WHERE title ILIKE @p OR city ILIKE @p '
        'ORDER BY uploaded_at DESC, id DESC LIMIT 30'),
    parameters: {'p': pattern},
  );
  return _json(200, {
    'cities': [
      for (final r in cities) {'slug': r[0], 'name': r[1], 'videoCount': r[2]}
    ],
    'videos': [for (final r in videos) _videoRowToJson(r)],
  });
}

Future<Response> _upload(Request request) async {
  final params = request.url.queryParameters;
  final city = params['city'] ?? '';
  final title = (params['title'] ?? '').trim();
  final original = _sanitizeFilename(params['filename'] ?? 'upload.bin');

  if (city.isEmpty || title.isEmpty) {
    return _json(400, {'error': 'city and title query params required'});
  }
  final known = await _db.execute(
    Sql.named('SELECT 1 FROM cities WHERE slug = @city'),
    parameters: {'city': city},
  );
  if (known.isEmpty) return _json(404, {'error': 'Unknown city: $city'});

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

  final rows = await _db.execute(
    Sql.named('INSERT INTO videos (city, title, filename, mime, size_bytes, '
        "status) VALUES (@city, @title, @filename, @mime, @size, 'processing') "
        'RETURNING $_videoColumns'),
    parameters: {
      'city': city,
      'title': title,
      'filename': stored,
      'mime': _mimeFor(original),
      'size': size,
    },
  );
  final video = _videoRowToJson(rows.first);
  _scheduleMlProcessing(video['id'] as int);
  return _json(201, {'video': video});
}

/// Creator: update a video's experience configuration (haptics/sound/feel).
Future<Response> _updateConfig(Request request, String id) async {
  final videoId = int.tryParse(id);
  if (videoId == null) return _json(400, {'error': 'Bad video id.'});
  final body = await _readJsonBody(request);
  if (body == null) return _json(400, {'error': 'JSON body required.'});

  final config = {
    'haptics': body['haptics'] is bool ? body['haptics'] : true,
    'sound': body['sound'] is bool ? body['sound'] : true,
    'intensity': body['intensity'] is num
        ? (body['intensity'] as num).clamp(0, 1)
        : 0.7,
  };
  final rows = await _db.execute(
    Sql.named('UPDATE videos SET config = @config WHERE id = @id '
        'RETURNING $_videoColumns'),
    parameters: {'id': videoId, 'config': jsonEncode(config)},
  );
  if (rows.isEmpty) return _json(404, {'error': 'Video not found.'});
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
  return _json(200, {
    ...manifest,
    'apkAvailable': await apk.exists(),
    'apkUrl': '/apk',
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
    },
  );
}

// ---------------------------------------------------------------------------

/// Opens the database. When DATABASE_URL is set (e.g. the Neon cloud
/// Postgres), connects there over TLS; otherwise falls back to the local
/// Postgres unix socket. Use Neon's DIRECT endpoint (no "-pooler") — the
/// server holds one long-lived session.
Future<Connection> _openDb() {
  final url = Platform.environment['DATABASE_URL'];
  if (url != null && url.isNotEmpty) {
    final u = Uri.parse(url);
    final userInfo = u.userInfo.split(':');
    print('DB: connecting to ${u.host}/${u.path.replaceFirst('/', '')}');
    return Connection.open(
      Endpoint(
        host: u.host,
        port: u.hasPort ? u.port : 5432,
        database: u.path.replaceFirst('/', ''),
        username: Uri.decodeComponent(userInfo[0]),
        password: userInfo.length > 1 ? Uri.decodeComponent(userInfo[1]) : null,
      ),
      settings: ConnectionSettings(sslMode: SslMode.require),
    );
  }
  print('DB: connecting to local Postgres (unix socket)');
  return Connection.open(
    Endpoint(
      host: '/var/run/postgresql/.s.PGSQL.5432',
      database: 'mrtouride',
      username: 'harsh',
      isUnixSocket: true,
    ),
    settings: ConnectionSettings(sslMode: SslMode.disable),
  );
}

Future<void> main() async {
  _db = await _openDb();

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
    ..post('/auth/google', _googleAuth)
    ..get('/cities', _cities)
    ..post('/cities/<city>/cover', _uploadCover)
    ..get('/videos', _videos)
    ..get('/videos/trending', _trending)
    ..get('/videos/suggest', _suggest)
    ..get('/cities/<slug>/weather', _weather)
    ..get('/search', _search)
    ..get('/search/media', _searchMedia)
    ..post('/ai/search', _aiSearch)
    ..get('/community/posts', _communityPosts)
    ..post('/community/posts', _createPost)
    ..post('/community/posts/<id>/react', _react)
    ..post('/community/posts/<id>/delete', _deletePost)
    ..get('/community/posts/<id>/replies', _replies)
    ..post('/community/posts/<id>/replies', _addReply)
    ..post('/community/replies/<id>/delete', _deleteReply)
    ..post('/community/upload-image', _uploadCommunityImage)
    ..post('/upload', _upload)
    ..post('/videos/<id>/config', _updateConfig)
    ..post('/feedback', _feedback)
    ..get('/app/version', _appVersion)
    ..get('/apk', _apk)
    ..get('/files/<city>/<name>', _serveFile);

  final handler = const Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(_rateLimit())
      .addMiddleware(_cors())
      .addHandler(router.call);

  final server = await shelf_io.serve(handler, InternetAddress.loopbackIPv4, _port);
  print('MrTouride backend listening on http://${server.address.host}:${server.port}');
}
