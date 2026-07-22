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
