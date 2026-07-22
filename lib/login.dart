import 'package:flutter/material.dart';

import 'constant.dart';
import 'package:mrtouride/navpages/main_page.dart';
import 'package:mrtouride/services/auth_api.dart';
import 'package:mrtouride/signup.dart';
import 'package:mrtouride/widgets/auth_dialogs.dart';

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
                            child: Image(
                              image: AssetImage("assets/image/logbg.png"),
                              width: 200,
                            ),
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
                              : MaterialButton(
                                  minWidth: double.infinity,
                                  onPressed: _signIn,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  color: blue,
                                  child: const Padding(
                                    padding: EdgeInsets.fromLTRB(0, 15, 0, 15),
                                    child: Text(
                                      'Sign In',
                                      style: TextStyle(color: white),
                                    ),
                                  ),
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
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        "Don't have an account? ",
                        style: TextStyle(color: ink(context)),
                      ),
                      TextButton(
                        onPressed: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (context) => const SingUpPage(),
                            ),
                          );
                        },
                        child: const Text(
                          'Sign Up',
                          style: TextStyle(
                            color: blue,
                          ),
                        ),
                      ),
                    ],
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
    return Material(
      elevation: 2,
      shadowColor: black,
      color: white,
      borderRadius: BorderRadius.circular(5.0),
      child: TextFormField(
        autofocus: false,
        scrollPadding: const EdgeInsets.only(bottom: 180),
        textInputAction: textInputAction,
        keyboardType: keyboardType,
        controller: controller,
        cursorColor: black,
        style: const TextStyle(color: black),
        obscureText: obscureText,
        decoration: InputDecoration(
          labelText: labelText,
          labelStyle: const TextStyle(color: black),
          contentPadding: const EdgeInsets.all(8),
          border: InputBorder.none,
          suffixIcon: suffixIcon,
        ),
      ),
    );
  }
}
