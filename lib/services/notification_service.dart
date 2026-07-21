import 'package:shared_preferences/shared_preferences.dart';

import 'auth_api.dart';
import 'media_api.dart';

/// New-content notifications: polls /whats-new against the last-seen
/// timestamp (persisted per device). No push infra needed — the app checks
/// on open and on a gentle interval while running.
class WhatsNew {
  final int count;
  final List<VideoItem> videos;
  const WhatsNew({required this.count, required this.videos});

  String get headline {
    if (videos.isEmpty) return '';
    final first = videos.first.title;
    return count == 1
        ? 'New experience: $first'
        : '$count new experiences · $first…';
  }
}

class NotificationService {
  static const _kLastSeen = 'notify.lastSeen';

  static Future<DateTime> _lastSeen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kLastSeen);
      if (raw != null) return DateTime.parse(raw);
    } catch (_) {}
    // First run: only announce content from now on.
    final now = DateTime.now().toUtc();
    await markSeen(now);
    return now;
  }

  static Future<void> markSeen([DateTime? at]) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _kLastSeen, (at ?? DateTime.now().toUtc()).toIso8601String());
    } catch (_) {}
  }

  /// Returns new content since the device last saw the catalog, or null
  /// when there is nothing new / the backend is unreachable.
  static Future<WhatsNew?> check() async {
    try {
      final since = await _lastSeen();
      final me = AuthApi.currentUser?.id;
      final decoded = await MediaApi.getJson(
          '/whats-new?since=${Uri.encodeQueryComponent(since.toIso8601String())}'
          '${me != null ? '&userId=$me' : ''}');
      final videos = [
        for (final v in decoded['videos'] as List)
          VideoItem.fromJson(v as Map<String, dynamic>)
      ];
      if (videos.isEmpty) return null;
      return WhatsNew(count: decoded['count'] as int, videos: videos);
    } catch (_) {
      return null;
    }
  }
}
