/// Version of THIS build. Keep in sync with pubspec.yaml `version:`.
/// The OTA check compares [appBuildNumber] with the backend's
/// /app/version manifest (backend/app_version.json).
const String appVersion = '1.5';
const int appBuildNumber = 20;

/// Google OAuth web client id — audience for ID tokens (all platforms).
/// The Android client (946282223370-odkhq0jlpf3qnf6t9gditibvndu5f3p4...)
/// is matched by Google automatically via package name + signing SHA-1;
/// it is never referenced in code.
const String googleWebClientId =
    '946282223370-0jn8n2cpqplc3kn5jv1halldg17acd1a.apps.googleusercontent.com';
