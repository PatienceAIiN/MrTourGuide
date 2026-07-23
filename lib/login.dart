import 'package:flutter/material.dart';

import 'constant.dart';
import 'widgets/ux.dart';
import 'package:mrtouride/navpages/main_page.dart';
import 'package:mrtouride/services/auth_api.dart';
import 'package:mrtouride/signup.dart';
import 'package:mrtouride/widgets/auth_dialogs.dart';
import 'package:mrtouride/widgets/password_reset.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final TextEditingController email = TextEditingController();
  final TextEditingController password = TextEditingController();
  bool loading = false;
  bool showPassword = false;

  @override
  void dispose() {
    email.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (email.text.trim().isEmpty) {
      newSnackBar(context, title: 'Email Required!');
      return;
    }
    if (password.text.isEmpty) {
      newSnackBar(context, title: 'Password Required!');
      return;
    }

    setState(() => loading = true);
    try {
      await AuthApi.login(email: email.text.trim(), password: password.text);
      if (!mounted) return;
      _enterApp();
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() => loading = false);
      if (e.needsVerification) {
        // Account exists but email not verified — resend a code and verify.
        final addr = email.text.trim();
        final devCode = await AuthApi.resendCode(addr).catchError((_) => null);
        if (!mounted) return;
        final user =
            await showVerifyEmailDialog(context, email: addr, devCode: devCode);
        if (user != null && mounted) _enterApp();
      } else {
        newSnackBar(context, title: e.message);
      }
    }
  }

  Future<void> _googleSignIn() async {
    final user = await signInWithGoogle(context, mode: 'signin');
    if (user != null && mounted) _enterApp();
  }

  void _enterApp() {
    // Clear the auth screens from history — back should never return here.
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (context) => MainPage()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Container(
              margin: const EdgeInsets.all(25),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Form(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          margin: const EdgeInsets.only(top: 30),
                          child: const Center(
                            child: CapsuleHero(),
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.all(12.0),
                          child: Text(
                            'Login to your Account',
                            style: TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: customFormFeild(
                            labelText: 'Email',
                            keyboardType: TextInputType.emailAddress,
                            obscureText: false,
                            controller: email,
                            textInputAction: TextInputAction.next,
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: customFormFeild(
                            controller: password,
                            labelText: 'Password',
                            keyboardType: TextInputType.text,
                            obscureText: !showPassword,
                            textInputAction: TextInputAction.done,
                            suffixIcon: IconButton(
                              icon: Icon(
                                showPassword
                                    ? Icons.visibility_off
                                    : Icons.visibility,
                                color: Colors.black45,
                              ),
                              onPressed: () =>
                                  setState(() => showPassword = !showPassword),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: loading
                              ? const Center(
                                  child: CircularProgressIndicator(color: blue),
                                )
                              : FilledButton(
                                  onPressed: _signIn,
                                  // Same pill as the welcome screen's
                                  // primary button — one look everywhere.
                                  style: FilledButton.styleFrom(
                                    backgroundColor: Theme.of(context).brightness ==
                                    Brightness.dark
                                ? const Color(0xFF0E5163)
                                : const Color(0xFF052933),
                                    foregroundColor: Colors.white,
                                    minimumSize:
                                        const Size(double.infinity, 60),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(50),
                                    ),
                                  ),
                                  child: const Text('Sign In',
                                      style: TextStyle(fontSize: 18)),
                                ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: GoogleButton(
                            label: 'Sign in with Google',
                            onPressed: _googleSignIn,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Footer — everything on ONE horizontal line, pinned to
                  // the bottom like the welcome screen's product line.
                  Padding(
                    padding: const EdgeInsets.only(top: 16, bottom: 6),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Flexible(
                          child: Text(
                            "Don't have an account? ",
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 13, color: inkSoft(context)),
                          ),
                        ),
                        GestureDetector(
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (context) => const SingUpPage(),
                              ),
                            );
                          },
                          child: Text(
                            'Create account',
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: brandInk(context)),
                          ),
                        ),
                        Text('  ·  ',
                            style: TextStyle(
                                fontSize: 13, color: inkSoft(context))),
                        GestureDetector(
                          onTap: () async {
                            final ok = await showForgotPasswordFlow(context);
                            if (ok && mounted) {
                              // ignore: use_build_context_synchronously
                              newSnackBar(context,
                                  title: 'Password changed — sign in with '
                                      'your new password.');
                            }
                          },
                          child: Text(
                            'Forgot password?',
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: brandInk(context)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget customFormFeild({
    required TextEditingController controller,
    required String labelText,
    required TextInputType keyboardType,
    required TextInputAction textInputAction,
    required bool obscureText,
    Widget? suffixIcon,
  }) {
    // Soft rounded filled field — the same visual language as the rest of
    // the app (cards, search bar), and readable in both themes.
    return TextFormField(
      autofocus: false,
      scrollPadding: const EdgeInsets.only(bottom: 180),
      textInputAction: textInputAction,
      keyboardType: keyboardType,
      controller: controller,
      obscureText: obscureText,
      decoration: InputDecoration(
        labelText: labelText,
        filled: true,
        fillColor: Theme.of(context).brightness == Brightness.dark
            ? Colors.white10
            : black.withValues(alpha: 0.05),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(28),
          borderSide: BorderSide.none,
        ),
        suffixIcon: suffixIcon,
      ),
    );
  }
}
