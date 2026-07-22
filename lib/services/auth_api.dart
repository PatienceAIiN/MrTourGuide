import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'api_base.dart';

/// Signed-in user returned by the local auth backend.
class AuthUser {
  final int id;
  final String name;
  final String email;

  /// 'traveler' (viewer) or 'creator' (can upload + configure experiences).
  final String role;

  /// Profile picture (backend-relative) and short bio — editable in Profile.
  String? avatarUrl;
  String? about;

  AuthUser({
    required this.id,
    required this.name,
    required this.email,
    this.role = 'traveler',
    this.avatarUrl,
    this.about,
  });

  bool get isCreator => role == 'creator';

  factory AuthUser.fromJson(Map<String, dynamic> json) => AuthUser(
        id: json['id'] as int,
        name: json['name'] as String,
        email: json['email'] as String,
        role: json['role'] as String? ?? 'traveler',
        avatarUrl: json['avatarUrl'] as String?,
        about: json['about'] as String?,
      );
}

/// Thrown when the backend rejects a request (bad credentials, dup email...).
class AuthException implements Exception {
  final String message;

  /// True when the account exists but the email is not verified yet.
  final bool needsVerification;

  const AuthException(this.message, {this.needsVerification = false});

  @override
  String toString() => message;
}

/// Result of a password signup: account created, email verification pending.
class SignupResult {
  final String email;

  /// Local-dev only: the verification code (no SMTP yet). Shown as a hint.
  final String? devCode;

  const SignupResult({required this.email, this.devCode});
}

/// Client for the local Postgres-backed auth backend (backend/bin/server.dart).
class AuthApi {
  static const String _base = apiBase;
  static const _kSession = 'auth.session';

  /// The currently signed-in user, if any.
  static AuthUser? currentUser;

  /// Restores the persisted session (if any) — the user stays signed in
  /// across app restarts until they explicitly sign out.
  static Future<AuthUser?> restoreSession() async {
    if (currentUser != null) return currentUser;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kSession);
      if (raw == null) return null;
      currentUser = AuthUser.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      return currentUser;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _persistSession(AuthUser user) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _kSession,
          jsonEncode({
            'id': user.id,
            'name': user.name,
            'email': user.email,
            'role': user.role,
            'avatarUrl': user.avatarUrl,
            'about': user.about,
          }));
    } catch (_) {}
  }

  /// Signs out and forgets the persisted session.
  static Future<void> signOut() async {
    currentUser = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kSession);
    } catch (_) {}
  }

  /// Password signup. The account requires email verification before login;
  /// call [verify] with the emailed code to complete it.
  static Future<SignupResult> signup({
    required String name,
    required String email,
    required String password,
    String role = 'traveler',
    bool acceptedTerms = false,
  }) async {
    final decoded = await _postRaw('/signup', {
      'name': name,
      'email': email,
      'password': password,
      'role': role,
      'acceptedTerms': acceptedTerms,
    });
    return SignupResult(
      email: decoded['email'] as String,
      devCode: decoded['devCode'] as String?,
    );
  }

  /// Confirms the email verification code and signs the user in.
  static Future<AuthUser> verify({
    required String email,
    required String code,
  }) {
    return _post('/verify', {'email': email, 'code': code});
  }

  static Future<String?> resendCode(String email) async {
    final decoded = await _postRaw('/resend-code', {'email': email});
    return decoded['devCode'] as String?;
  }

  static Future<AuthUser> login({
    required String email,
    required String password,
  }) {
    return _post('/login', {'email': email, 'password': password});
  }

  /// Google SSO (signup creates a pre-verified account; signin only works
  /// for accounts that were created with Google).
  static Future<AuthUser> google({
    required String mode, // 'signup' | 'signin'
    String? email,
    String? idToken,
    String? name,
    String role = 'traveler',
    bool acceptedTerms = false,
  }) {
    return _post('/auth/google', {
      'mode': mode,
      if (email != null) 'email': email,
      if (idToken != null) 'idToken': idToken,
      if (name != null) 'name': name,
      'role': role,
      'acceptedTerms': acceptedTerms,
    });
  }

  static Future<AuthUser> _post(String path, Map<String, dynamic> body) async {
    final decoded = await _postRaw(path, body);
    final user = AuthUser.fromJson(decoded);
    currentUser = user;
    await _persistSession(user);
    return user;
  }

  static Future<Map<String, dynamic>> _postRaw(
      String path, Map<String, dynamic> body) async {
    late http.Response response;
    try {
      response = await http
          .post(
            Uri.parse('$_base$path'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      throw const AuthException(
          'Cannot reach the auth server. Is the backend running on port 8080?');
    }

    final Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw const AuthException(
          'Cannot reach the auth server. Is the backend running on port 8080?');
    }
    if (response.statusCode == 200 || response.statusCode == 201) {
      return decoded;
    }
    throw AuthException(
      decoded['error'] as String? ?? 'Something went wrong.',
      needsVerification: decoded['needsVerification'] == true,
    );
  }
}
