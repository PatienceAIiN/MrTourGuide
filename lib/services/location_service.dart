import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'media_api.dart';

/// The device's current country + city, resolved once and cached so news and
/// other geo features don't re-prompt or re-hit the free-tier VM every open.
class LocationService {
  static const _kCountry = 'geo.country';
  static const _kCity = 'geo.city';
  static const _kAt = 'geo.at';

  static String country = '';
  static String city = '';
  static bool _loaded = false;

  /// Returns the cached (country, city) immediately if fresh (< 12h); the
  /// first call loads from disk, and refreshes from GPS in the background
  /// when stale. Never throws — falls back to empty strings (→ default feed).
  static Future<(String, String)> current({bool refresh = false}) async {
    if (!_loaded) {
      try {
        final prefs = await SharedPreferences.getInstance();
        country = prefs.getString(_kCountry) ?? '';
        city = prefs.getString(_kCity) ?? '';
      } catch (_) {}
      _loaded = true;
    }
    final fresh = await _isFresh();
    if (!refresh && fresh && (country.isNotEmpty || city.isNotEmpty)) {
      return (country, city);
    }
    await _resolve();
    return (country, city);
  }

  static Future<bool> _isFresh() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final at = prefs.getInt(_kAt) ?? 0;
      return DateTime.now().millisecondsSinceEpoch - at <
          const Duration(hours: 12).inMilliseconds;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _resolve() async {
    if (kIsWeb) return;
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.low, timeLimit: Duration(seconds: 10)),
      );
      final (c, _, ct) = await MediaApi.geoReverse(pos.latitude, pos.longitude);
      if (c.isEmpty && ct.isEmpty) return;
      country = c;
      city = ct;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kCountry, country);
      await prefs.setString(_kCity, city);
      await prefs.setInt(_kAt, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {
      // GPS off, denied, or timed out — keep whatever we had.
    }
  }
}
