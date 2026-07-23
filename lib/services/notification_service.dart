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

/// One row in the bell inbox. [type]: video | city | reaction | reply |
/// update (the last is added client-side from the OTA manifest).
class AppNotification {
  final String type;
  final String title;
  final String? city;
  final int? postId;
  final DateTime at;

  const AppNotification({
    required this.type,
    required this.title,
    this.city,
    this.postId,
    required this.at,
  });

  factory AppNotification.fromJson(Map<String, dynamic> json) =>
      AppNotification(
        type: json['type'] as String? ?? 'video',
        title: json['title'] as String? ?? '',
        city: json['city'] as String?,
        postId: json['postId'] as int?,
        at: DateTime.tryParse(json['at'] as String? ?? '') ?? DateTime.now(),
      );
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

  static const _kCommunityOpened = 'notify.communityOpened';

  /// Call when the Community tab is opened — clears its unread dot.
  static Future<void> markCommunityOpened() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _kCommunityOpened, DateTime.now().toUtc().toIso8601String());
    } catch (_) {}
  }

  /// Unread state for the bell + the Community tab in ONE inbox fetch.
  /// A dot stays on until its surface is opened (persisted per device), then
  /// clears — and only returns when something genuinely newer arrives.
  static Future<({bool bell, bool community})> unreadStatus() async {
    try {
      final items = await recent();
      final prefs = await SharedPreferences.getInstance();
      DateTime? seen(String key) {
        final raw = prefs.getString(key);
        return raw == null ? null : DateTime.tryParse(raw);
      }

      // First run: baseline both markers to now so a fresh install doesn't
      // light up for week-old content.
      var bellSeen = seen(_kLastSeen);
      if (bellSeen == null) {
        await markSeen();
        bellSeen = DateTime.now().toUtc();
      }
      var commSeen = seen(_kCommunityOpened);
      if (commSeen == null) {
        await markCommunityOpened();
        commSeen = DateTime.now().toUtc();
      }

      const commTypes = {'community', 'reply', 'reaction', 'reshare'};
      return (
        bell: items.any((n) => n.at.isAfter(bellSeen!)),
        community: items.any(
            (n) => commTypes.contains(n.type) && n.at.isAfter(commSeen!)),
      );
    } catch (_) {
      return (bell: false, community: false);
    }
  }

  /// Aggregated inbox for the bell modal: new experiences, new places and
  /// social activity (reactions/replies on your posts) — last 7 days.
  static Future<List<AppNotification>> recent() async {
    try {
      final since = DateTime.now().toUtc().subtract(const Duration(days: 7));
      final me = AuthApi.currentUser?.id;
      final decoded = await MediaApi.getJson(
          '/notifications?since=${Uri.encodeQueryComponent(since.toIso8601String())}'
          '${me != null ? '&userId=$me' : ''}');
      return [
        for (final n in decoded['items'] as List)
          AppNotification.fromJson(n as Map<String, dynamic>)
      ];
    } catch (_) {
      return const [];
    }
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
