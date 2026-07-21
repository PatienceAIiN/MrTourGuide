/// Version of THIS build. Keep in sync with pubspec.yaml `version:`.
/// The OTA check compares [appBuildNumber] with the backend's
/// /app/version manifest (backend/app_version.json).
const String appVersion = '1.0.2';
const int appBuildNumber = 3;

/// Google OAuth web client id — audience for ID tokens (all platforms).
const String googleWebClientId =
    '946282223370-0jn8n2cpqplc3kn5jv1halldg17acd1a.apps.googleusercontent.com';
