import 'package:flutter/material.dart';

import 'constant.dart';
import 'widgets/ux.dart';
import 'navpages/main_page.dart';
import 'services/auth_api.dart';
import 'widgets/auth_dialogs.dart';
import 'widgets/legal_sheet.dart';

class SingUpPage extends StatefulWidget {
  const SingUpPage({super.key});

  @override
  State<SingUpPage> createState() => _SingUpPageState();
}

class _SingUpPageState extends State<SingUpPage> {
  final TextEditingController email = TextEditingController();
  final TextEditingController name = TextEditingController();
  final TextEditingController password = TextEditingController();
  bool loading = false;
  bool showPassword = false;
  bool acceptedTerms = false;
  String role = 'traveler';

  @override
  void dispose() {
    email.dispose();
    name.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> _signUp() async {
    if (name.text.trim().isEmpty) {
      newSnackBar(context, title: 'Name Required!');
      return;
    }
    if (email.text.trim().isEmpty) {
      newSnackBar(context, title: 'Email Required!');
      return;
    }
    if (password.text.isEmpty) {
      newSnackBar(context, title: 'Password Required!');
      return;
    }
    if (!acceptedTerms) {
      newSnackBar(context,
          title: 'Please accept the Terms & Privacy Policy first.');
      return;
    }

    setState(() => loading = true);
    try {
      final result = await AuthApi.signup(
        name: name.text.trim(),
        email: email.text.trim(),
        password: password.text,
        role: role,
        acceptedTerms: acceptedTerms,
      );
      if (!mounted) return;
      setState(() => loading = false);
      // Verify the email before entering the app.
      final user = await showVerifyEmailDialog(
        context,
        email: result.email,
        devCode: result.devCode,
      );
      if (user == null || !mounted) return;
      email.clear();
      name.clear();
      password.clear();
      _enterApp();
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() => loading = false);
      newSnackBar(context, title: e.message);
    }
  }

  Future<void> _googleSignUp() async {
    if (!acceptedTerms) {
      newSnackBar(context,
          title: 'Please accept the Terms & Privacy Policy first.');
      return;
    }
    final user = await signInWithGoogle(context, mode: 'signup', role: role);
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
      appBar: AppBar(
        iconTheme: const IconThemeData(
          color: blue,
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        child: Container(
          margin: const EdgeInsets.all(25),
          child: Form(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.start,
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
                    'Create your Account',
                    style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: customFormFeild(
                    labelText: 'Name',
                    keyboardType: TextInputType.text,
                    obscureText: false,
                    controller: name,
                    textInputAction: TextInputAction.next,
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
                        showPassword ? Icons.visibility_off : Icons.visibility,
                        color: Colors.black45,
                      ),
                      onPressed: () =>
                          setState(() => showPassword = !showPassword),
                    ),
                  ),
                ),
                // Account type: travelers experience, creators publish.
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: ChoiceChip(
                          avatar: const Icon(Icons.travel_explore, size: 18),
                          label: const Text('Traveler'),
                          selected: role == 'traveler',
                          selectedColor: blue.withValues(alpha: 0.15),
                          onSelected: (_) => setState(() => role = 'traveler'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ChoiceChip(
                          avatar: const Icon(Icons.video_camera_back, size: 18),
                          label: const Text('Creator'),
                          selected: role == 'creator',
                          selectedColor: blue.withValues(alpha: 0.15),
                          onSelected: (_) => setState(() => role = 'creator'),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: CheckboxListTile(
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: acceptedTerms,
                    activeColor: blue,
                    onChanged: (v) =>
                        setState(() => acceptedTerms = v ?? false),
                    title: Text.rich(
                      TextSpan(
                        text: 'I agree to the ',
                        style: const TextStyle(fontSize: 12.5),
                        children: [
                          WidgetSpan(
                            alignment: PlaceholderAlignment.baseline,
                            baseline: TextBaseline.alphabetic,
                            child: InkWell(
                              onTap: () => showLegalSheet(context),
                              child: const Text('Terms',
                                  style: TextStyle(
                                      fontSize: 12.5,
                                      color: blue,
                                      decoration: TextDecoration.underline)),
                            ),
                          ),
                          const TextSpan(text: ' and '),
                          WidgetSpan(
                            alignment: PlaceholderAlignment.baseline,
                            baseline: TextBaseline.alphabetic,
                            child: InkWell(
                              onTap: () => showLegalSheet(context),
                              child: const Text('Privacy Policy',
                                  style: TextStyle(
                                      fontSize: 12.5,
                                      color: blue,
                                      decoration: TextDecoration.underline)),
                            ),
                          ),
                        ],
                      ),
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
                          onPressed: _signUp,
                          // Same pill as the welcome screen's primary button.
                          style: FilledButton.styleFrom(
                            backgroundColor: Theme.of(context).brightness ==
                                    Brightness.dark
                                ? const Color(0xFF0E5163)
                                : const Color(0xFF052933),
                            foregroundColor: Colors.white,
                            minimumSize: const Size(double.infinity, 60),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(50),
                            ),
                          ),
                          child: const Text('Sign Up',
                              style: TextStyle(fontSize: 18)),
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: GoogleButton(
                    label: 'Sign up with Google',
                    onPressed: _googleSignUp,
                  ),
                ),
              ],
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
    // Soft rounded filled field — identical to the login screen so both
    // auth pages share one visual language, readable in both themes.
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
