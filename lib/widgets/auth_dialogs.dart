import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../constant.dart';
import '../services/app_info.dart';
import '../services/auth_api.dart';
import 'ux.dart';

/// Production Google SSO.
///
/// On Android/iOS this launches the native Google account chooser and sends
/// the verified ID token to the backend (audience = the web client id). On
/// web — our dev harness — it falls back to the dev dialog.
Future<AuthUser?> signInWithGoogle(
  BuildContext context, {
  required String mode, // 'signup' | 'signin'
  String role = 'traveler',
}) async {
  if (kIsWeb) {
    return showGoogleAuthDialog(context, mode: mode, role: role);
  }
  try {
    final signIn = GoogleSignIn.instance;
    await signIn.initialize(serverClientId: googleWebClientId);
    final account = await signIn.authenticate();
    final idToken = account.authentication.idToken;
    if (idToken == null) {
      throw const AuthException('Google did not return a sign-in token.');
    }
    return await AuthApi.google(
      mode: mode,
      idToken: idToken,
      role: role,
      acceptedTerms: true, // gated by the signup page checkbox
    );
  } on AuthException catch (e) {
    if (context.mounted) newSnackBar(context, title: e.message);
    return null;
  } on GoogleSignInException catch (e) {
    if (e.code == GoogleSignInExceptionCode.canceled) return null;
    if (context.mounted) {
      newSnackBar(context,
          title: 'Google sign-in failed (${e.code.name}). If this says '
              'clientConfigurationError, the app needs its SHA key added '
              'in Firebase.');
    }
    return null;
  } catch (_) {
    if (context.mounted) {
      newSnackBar(context, title: 'Google sign-in failed. Try again.');
    }
    return null;
  }
}

/// Email verification: user enters the 6-digit code sent to their inbox.
/// Returns the signed-in user on success, null if dismissed.
///
/// [devCode] is the local-dev hint (no SMTP configured yet); it pre-fills
/// nothing but is shown so the flow is fully testable.
Future<AuthUser?> showVerifyEmailDialog(
  BuildContext context, {
  required String email,
  String? devCode,
}) {
  final controller = TextEditingController();
  var busy = false;
  String? hint = devCode;
  String? error;
  return showDialog<AuthUser>(
    context: context,
    barrierDismissible: false,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Verify your email'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('We sent a 6-digit code to\n$email',
                style: const TextStyle(fontSize: 14)),
            const SizedBox(height: 14),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 22, letterSpacing: 8),
              decoration: InputDecoration(
                counterText: '',
                border: const OutlineInputBorder(),
                errorText: error,
              ),
            ),
            if (hint != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Dev hint (no mail server yet): $hint',
                    style: const TextStyle(fontSize: 11, color: Colors.grey)),
              ),
            TextButton(
              onPressed: () async {
                try {
                  final newCode = await AuthApi.resendCode(email);
                  setState(() {
                    hint = newCode ?? hint;
                    error = null;
                  });
                } on AuthException catch (e) {
                  setState(() => error = e.message);
                }
              },
              child: const Text('Resend code'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Later'),
          ),
          SizedBox(
            width: 120,
            child: LoadingButton(
              busy: busy,
              label: 'Verify',
              onPressed: () async {
                if (controller.text.trim().length != 6) {
                  setState(() => error = 'Enter the 6-digit code');
                  return;
                }
                setState(() {
                  busy = true;
                  error = null;
                });
                try {
                  final user = await AuthApi.verify(
                      email: email, code: controller.text.trim());
                  if (context.mounted) Navigator.pop(context, user);
                } on AuthException catch (e) {
                  setState(() {
                    busy = false;
                    error = e.message;
                  });
                }
              },
            ),
          ),
        ],
      ),
    ),
  );
}

/// Google account chooser.
///
/// Local dev has no OAuth client id yet, so this asks for the Google email
/// directly (clearly labelled). When a client id is available, replace the
/// body with the `google_sign_in` package flow — the AuthApi.google call
/// and all account rules stay identical.
Future<AuthUser?> showGoogleAuthDialog(
  BuildContext context, {
  required String mode, // 'signup' | 'signin'
  String role = 'traveler',
}) {
  final email = TextEditingController();
  final name = TextEditingController();
  var busy = false;
  String? error;
  final signup = mode == 'signup';
  return showDialog<AuthUser>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.black12),
              ),
              child: const Text('G',
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                      color: Color(0xFF4285F4))),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                  signup ? 'Sign up with Google' : 'Sign in with Google',
                  style: const TextStyle(fontSize: 17)),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Dev mode: enter your Google account email. (Real Google SSO '
              'plugs in here once an OAuth client id is configured.)',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: email,
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                labelText: 'Google email',
                border: const OutlineInputBorder(),
                errorText: error,
              ),
            ),
            if (signup) ...[
              const SizedBox(height: 12),
              TextField(
                controller: name,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          SizedBox(
            width: 130,
            child: LoadingButton(
              busy: busy,
              label: 'Continue',
              color: const Color(0xFF4285F4),
              onPressed: () async {
                setState(() {
                  busy = true;
                  error = null;
                });
                try {
                  final user = await AuthApi.google(
                    mode: mode,
                    email: email.text.trim(),
                    name: name.text.trim().isEmpty ? null : name.text.trim(),
                    role: role,
                    acceptedTerms: true, // gated by the signup page checkbox
                  );
                  if (context.mounted) Navigator.pop(context, user);
                } on AuthException catch (e) {
                  setState(() {
                    busy = false;
                    error = e.message;
                  });
                }
              },
            ),
          ),
        ],
      ),
    ),
  );
}

/// "Continue with Google" button shared by login and signup pages.
class GoogleButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;

  const GoogleButton({super.key, required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(double.infinity, 50),
        // Theme-aware: black-on-dark was invisible in dark mode.
        side: BorderSide(
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.white24
                : Colors.black26),
        foregroundColor: ink(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      onPressed: onPressed,
      icon: const Text('G',
          style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 18,
              color: Color(0xFF4285F4))),
      label: Text(label),
    );
  }
}
