import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'update_installer.dart';

/// Local (on-device) notifications: the update-downloaded alert and the
/// "notifications active" test. Taps on an install notification hand the
/// downloaded APK to the system installer.
class LocalNotifs {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  static const _channel = AndroidNotificationDetails(
    'mrtouride_default',
    'Mr.TourGuide',
    channelDescription: 'Updates and alerts',
    importance: Importance.high,
    priority: Priority.high,
  );

  static Future<void> init() async {
    if (kIsWeb || _ready) return;
    try {
      await _plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
        onDidReceiveNotificationResponse: (response) {
          final payload = response.payload ?? '';
          if (payload.startsWith('install:')) {
            UpdateInstaller.install(payload.substring(8)).catchError((_) {});
          }
        },
      );
      _ready = true;
    } catch (_) {}
  }

  /// Ongoing progress notification — visible even when the user switches
  /// apps while an update downloads.
  static Future<void> showProgress(int id, String title, int percent) async {
    if (kIsWeb) return;
    await init();
    try {
      await _plugin.show(
        id,
        title,
        '$percent% downloaded',
        NotificationDetails(
          android: AndroidNotificationDetails(
            'mrtouride_progress',
            'Downloads',
            channelDescription: 'Update download progress',
            importance: Importance.low,
            priority: Priority.low,
            onlyAlertOnce: true,
            showProgress: true,
            maxProgress: 100,
            progress: percent,
            ongoing: percent < 100,
          ),
        ),
      );
    } catch (_) {}
  }

  static Future<void> cancel(int id) async {
    if (kIsWeb) return;
    try {
      await _plugin.cancel(id);
    } catch (_) {}
  }

  static Future<void> show(String title, String body, {String? payload}) async {
    if (kIsWeb) return;
    await init();
    try {
      await _plugin.show(
        DateTime.now().millisecondsSinceEpoch ~/ 1000,
        title,
        body,
        const NotificationDetails(android: _channel),
        payload: payload,
      );
    } catch (_) {}
  }
}
