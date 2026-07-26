import 'package:package_info_plus/package_info_plus.dart';

/// Version of THIS build — read from the installed package at startup so it
/// can NEVER drift from pubspec.yaml (a hardcoded copy once left an updated
/// app believing it was the old build, offering itself as an update forever).
/// The OTA check compares [appBuildNumber] with the backend's /app/version
/// manifest (backend/app_version.json). Values below are only the fallback
/// if the platform lookup fails.
String appVersion = '1.2';
int appBuildNumber = 37;

/// Called once in main() before anything reads the values above.
Future<void> loadAppInfo() async {
  try {
    final info = await PackageInfo.fromPlatform();
    if (info.version.isNotEmpty) {
      final parts = info.version.split('.');
      appVersion = parts.take(2).join('.');
    }
    final code = int.tryParse(info.buildNumber);
    if (code != null && code > 0) appBuildNumber = code;
  } catch (_) {}
}

/// Google OAuth web client id — audience for ID tokens (all platforms).
/// The Android client (946282223370-odkhq0jlpf3qnf6t9gditibvndu5f3p4...)
/// is matched by Google automatically via package name + signing SHA-1;
/// it is never referenced in code.
const String googleWebClientId =
    '946282223370-0jn8n2cpqplc3kn5jv1halldg17acd1a.apps.googleusercontent.com';
