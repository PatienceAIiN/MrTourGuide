import 'package:flutter/material.dart';

import '../constant.dart';
import '../services/haptic_service.dart';
import '../services/notification_service.dart';
import '../services/update_service.dart';
import 'update_flow.dart';

String _timeAgo(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  return '${d.inDays}d ago';
}

/// The notifications inbox — a bottom-sheet popup shared by the navbar bell.
/// Opens INSTANTLY (no awaiting the network first); the items stream in via a
/// FutureBuilder inside the sheet. Marks everything seen on open.
Future<void> showNotificationsSheet(
  BuildContext context, {
  void Function(int tabIndex)? onSelectTab,
}) async {
  Haptics.tick();
  NotificationService.markSeen();

  // Stale-while-revalidate: the LAST fetched inbox paints instantly from
  // disk; the fresh list (plus any update banner) replaces it when ready.
  Stream<List<AppNotification>> loadStream() async* {
    final cached = await NotificationService.recentCached();
    if (cached != null && cached.isNotEmpty) yield cached;
    final results = await Future.wait<Object?>([
      NotificationService.recent(),
      UpdateService.check(),
    ]);
    final items =
        List<AppNotification>.from(results[0] as List<AppNotification>);
    final update = results[1] as UpdateInfo?;
    if (update != null && update.isNewer) {
      items.insert(
          0,
          AppNotification(
            type: 'update',
            title: 'App update v${update.version}: ${update.notes}',
            at: DateTime.now(),
          ));
    }
    yield items;
  }

  final load = loadStream().asBroadcastStream();

  void openTarget(AppNotification n) {
    Haptics.light();
    switch (n.type) {
      case 'reaction':
      case 'reply':
      case 'reshare':
      case 'follow':
      case 'community':
        onSelectTab?.call(3); // Community
      case 'guidevibe':
        onSelectTab?.call(4); // GuideVibe feed
      case 'update':
        UpdateService.check().then((info) {
          if (context.mounted && info != null && info.isNewer) {
            runUpdateFlow(context, info);
          }
        });
      default:
        onSelectTab?.call(1); // Explore
    }
  }

  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: cardBg(context),
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (context) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                  color: Colors.grey.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              const Icon(Icons.notifications, color: blue, size: 19),
              const SizedBox(width: 8),
              Text('Notifications',
                  style: TextStyle(
                      color: ink(context),
                      fontWeight: FontWeight.bold,
                      fontSize: 16)),
            ],
          ),
          const SizedBox(height: 10),
          StreamBuilder<List<AppNotification>>(
            stream: load,
            builder: (context, snap) {
              if (!snap.hasData) {
                // Instant open: a light placeholder while items stream in.
                return const Padding(
                  padding: EdgeInsets.all(28),
                  child: Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    ),
                  ),
                );
              }
              final items = snap.data!;
              if (items.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(20),
                  child: Center(
                    child: Text(
                        "You're all caught up — nothing new this week.",
                        style: TextStyle(color: Colors.grey, fontSize: 13)),
                  ),
                );
              }
              return Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final n in items)
                      Card(
                        color: pageBg(context),
                        margin: const EdgeInsets.only(bottom: 8),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        child: ListTile(
                          dense: true,
                          leading: CircleAvatar(
                            radius: 16,
                            backgroundColor: switch (n.type) {
                              'reaction' => Colors.pink,
                              'reply' => Colors.teal,
                              'city' => Colors.purple,
                              'update' => Colors.indigo,
                              'guidevibe' => const Color(0xFFFF4D5E),
                              'follow' => Colors.green,
                              'community' => Colors.orange,
                              _ => blue,
                            },
                            child: Icon(
                              switch (n.type) {
                                'reaction' => Icons.favorite,
                                'reply' => Icons.chat_bubble,
                                'city' => Icons.location_city,
                                'update' => Icons.system_update,
                                'guidevibe' => Icons.play_circle_fill,
                                'follow' => Icons.person_add,
                                'community' => Icons.forum,
                                _ => Icons.fiber_new,
                              },
                              color: white,
                              size: 16,
                            ),
                          ),
                          title: Text(n.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600, fontSize: 13)),
                          subtitle: Text(_timeAgo(n.at),
                              style: const TextStyle(
                                  fontSize: 11, color: Colors.grey)),
                          trailing:
                              const Icon(Icons.chevron_right, color: blue),
                          onTap: () {
                            Navigator.pop(context);
                            openTarget(n);
                          },
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    ),
  );
}
