import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

import 'auth_api.dart';
import 'local_notifs.dart';
import 'location_service.dart';
import 'media_api.dart';
import 'settings_service.dart';
import 'tab_events.dart';

/// Firebase Cloud Messaging: real push notifications, even when the app is
/// closed. Token registers against the signed-in account so social pushes
/// (likes, replies) reach the right person.
class PushService {
  static bool _ready = false;

  /// Call once at startup. Safe to call again after login (re-registers
  /// the token under the new user).
  static Future<void> init() async {
    if (kIsWeb) return;
    try {
      if (!_ready) {
        await Firebase.initializeApp();
        _ready = true;
      }
      if (!SettingsService.instance.notifications) return;
      // Make sure the notification channels exist BEFORE any push arrives —
      // Android silently drops FCM messages aimed at a missing channel.
      await LocalNotifs.init();
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission();
      final token = await messaging.getToken();
      if (token != null) await _register(token);
      // Keep the backend current when FCM rotates the token.
      FirebaseMessaging.instance.onTokenRefresh.listen(_register);
      // Foreground pushes don't display by default on Android — mirror them
      // to a local notification so the user is notified while in the app too.
      FirebaseMessaging.onMessage.listen((message) {
        final n = message.notification;
        if (n != null && SettingsService.instance.notifications) {
          LocalNotifs.show(n.title ?? 'Mr.Tour Guide', n.body ?? '');
        }
        // New content just landed — let every open screen refresh itself.
        ContentEvents.ping();
      });
    } catch (_) {
      // Push is a bonus — never let it break the app.
    }
  }

  static Future<void> _register(String token) async {
    try {
      // City + the location-only preference power location-targeted pushes
      // ("new Delhi experience" goes to Delhi people first).
      String city = '';
      try {
        city = (await LocationService.current()).$2;
      } catch (_) {}
      await MediaApi.getJsonPost('/push/register', {
        'token': token,
        'userId': AuthApi.currentUser?.id,
        'city': city,
        'locOnly': SettingsService.instance.locationNotifs,
      });
    } catch (_) {}
  }

  /// Re-register with current prefs (e.g. after the location-only toggle).
  static Future<void> refreshRegistration() async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) await _register(token);
    } catch (_) {}
  }
}
