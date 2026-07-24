/// Base URL of the MrTouride backend.
///
/// Debug/dev default is the local backend. Release builds pass the real
/// API with: flutter build apk --dart-define=API_BASE=https://mrtourguide.patienceai.in/api
const String apiBase = String.fromEnvironment(
  'API_BASE',
  defaultValue: 'http://127.0.0.1:8080',
);

/// Direct origin (no Cloudflare in front). Big uploads use this: the edge
/// proxy caps request bodies at ~100 MB, so 100MB+ raw clips for
/// server-side reduction must skip it. Everything else stays on [apiBase].
const String originApiBase = String.fromEnvironment(
  'ORIGIN_API_BASE',
  defaultValue: 'https://mrtouride-api.onrender.com/api',
);
