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
/// Aggregates social activity, new content and app updates; tapping an item
/// redirects to the right place. Marks everything seen on open.
Future<void> showNotificationsSheet(
  BuildContext context, {
  void Function(int tabIndex)? onSelectTab,
}) async {
  Haptics.tick();
  NotificationService.markSeen();
  final results = await Future.wait([
    NotificationService.recent(),
    UpdateService.check(),
  ]);
  final items = List<AppNotification>.from(results[0] as List<AppNotification>);
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
  if (!context.mounted) return;

  void openTarget(AppNotification n) {
    Haptics.light();
    switch (n.type) {
      case 'reaction':
      case 'reply':
      case 'reshare':
      case 'follow':
        onSelectTab?.call(3); // Community
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
          if (items.isEmpty)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Center(
                child: Text("You're all caught up — nothing new this week.",
                    style: TextStyle(color: Colors.grey, fontSize: 13)),
              ),
            )
          else
            Flexible(
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
                            _ => blue,
                          },
                          child: Icon(
                            switch (n.type) {
                              'reaction' => Icons.favorite,
                              'reply' => Icons.chat_bubble,
                              'city' => Icons.location_city,
                              'update' => Icons.system_update,
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
                        trailing: const Icon(Icons.chevron_right, color: blue),
                        onTap: () {
                          Navigator.pop(context);
                          openTarget(n);
                        },
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}
