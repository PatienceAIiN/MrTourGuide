/// Base URL of the MrTouride backend.
///
/// Debug/dev default is the local backend. Release builds pass the real
/// API with: flutter build apk --dart-define=API_BASE=https://mrtourguide.patienceai.in/api
const String apiBase = String.fromEnvironment(
  'API_BASE',
  defaultValue: 'http://127.0.0.1:8080',
);
