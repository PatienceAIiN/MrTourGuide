import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_base.dart';
import 'app_info.dart';

class UpdateInfo {
  final String version;
  final int buildNumber;
  final String notes;
  final bool apkAvailable;
  final String apkUrl;

  const UpdateInfo({
    required this.version,
    required this.buildNumber,
    required this.notes,
    required this.apkAvailable,
    required this.apkUrl,
  });

  bool get isNewer => buildNumber > appBuildNumber;
  String get absoluteApkUrl => '$apiBase$apkUrl';
}

/// OTA update detection against the backend's /app/version manifest.
///
/// On Android the flow is: detect newer build -> download APK from
/// [UpdateInfo.absoluteApkUrl] -> the installer replaces the app (old build
/// is removed by the OS), and our downloader deletes any previously
/// downloaded APK before fetching the new one so stale builds never pile up.
/// On web, the same check just points users at the landing page.
class UpdateService {
  static Future<UpdateInfo?> check() async {
    try {
      final response = await http
          .get(Uri.parse('$apiBase/app/version'))
          .timeout(const Duration(seconds: 6));
      if (response.statusCode != 200) return null;
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      return UpdateInfo(
        version: decoded['version'] as String? ?? '0.0.0',
        buildNumber: decoded['buildNumber'] as int? ?? 0,
        notes: decoded['notes'] as String? ?? '',
        apkAvailable: decoded['apkAvailable'] as bool? ?? false,
        apkUrl: decoded['apkUrl'] as String? ?? '/apk',
      );
    } catch (_) {
      return null; // Update check must never break the app.
    }
  }
}
