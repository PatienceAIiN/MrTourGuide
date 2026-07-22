import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

import 'auth_api.dart';
import 'media_api.dart';
import 'settings_service.dart';

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
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission();
      final token = await messaging.getToken();
      if (token != null) await _register(token);
      // Keep the backend current when FCM rotates the token.
      FirebaseMessaging.instance.onTokenRefresh.listen(_register);
    } catch (_) {
      // Push is a bonus — never let it break the app.
    }
  }

  static Future<void> _register(String token) async {
    try {
      await MediaApi.getJsonPost('/push/register', {
        'token': token,
        'userId': AuthApi.currentUser?.id,
      });
    } catch (_) {}
  }
}
