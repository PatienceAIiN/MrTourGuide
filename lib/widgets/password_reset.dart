import 'package:flutter/material.dart';

import '../constant.dart';
import '../services/auth_api.dart';

/// Email-OTP password flow shared by "Forgot password?" on the login page
/// and "Change password" in the profile. Returns true once the password
/// was actually changed.
Future<bool> showForgotPasswordFlow(BuildContext context,
    {String? presetEmail}) async {
  final changed = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _ResetDialog(presetEmail: presetEmail),
  );
  return changed == true;
}

class _ResetDialog extends StatefulWidget {
  const _ResetDialog({this.presetEmail});

  final String? presetEmail;

  @override
  State<_ResetDialog> createState() => _ResetDialogState();
}

class _ResetDialogState extends State<_ResetDialog> {
  late final TextEditingController email =
      TextEditingController(text: widget.presetEmail ?? '');
  final TextEditingController code = TextEditingController();
  final TextEditingController pass = TextEditingController();
  final TextEditingController pass2 = TextEditingController();
  bool codeSent = false;
  bool busy = false;
  bool showPass = false;
  String? error;

  @override
  void dispose() {
    email.dispose();
    code.dispose();
    pass.dispose();
    pass2.dispose();
    super.dispose();
  }

  Future<void> _sendCode() async {
    final addr = email.text.trim();
    if (addr.isEmpty || !addr.contains('@')) {
      setState(() => error = 'Enter a valid email address.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await AuthApi.forgotPassword(addr);
      if (!mounted) return;
      setState(() {
        codeSent = true;
        busy = false;
      });
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        error = e.message;
        busy = false;
      });
    }
  }

  Future<void> _changePassword() async {
    if (code.text.trim().length < 4) {
      setState(() => error = 'Enter the 6-digit code from your email.');
      return;
    }
    if (pass.text.length < 6) {
      setState(() => error = 'New password must be at least 6 characters.');
      return;
    }
    if (pass.text != pass2.text) {
      setState(() => error = 'Passwords do not match.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await AuthApi.resetPassword(
        email: email.text.trim(),
        code: code.text.trim(),
        newPassword: pass.text,
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        error = e.message;
        busy = false;
      });
    }
  }

  InputDecoration _dec(String label, {Widget? suffix}) => InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        suffixIcon: suffix,
      );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: Row(
        children: [
          const Icon(Icons.lock_reset, color: blue),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              codeSent ? 'Verify & set password' : 'Reset password',
              style: const TextStyle(fontSize: 17),
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              codeSent
                  ? 'We emailed a 6-digit code to ${email.text.trim()}. '
                      'Enter it below with your new password.'
                  : 'We will email you a 6-digit code to verify it is you.',
              style: TextStyle(
                fontSize: 13,
                color: ink(context).withValues(alpha: 0.75),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: email,
              enabled: widget.presetEmail == null && !codeSent,
              keyboardType: TextInputType.emailAddress,
              decoration: _dec('Email'),
            ),
            if (codeSent) ...[
              const SizedBox(height: 12),
              TextField(
                controller: code,
                keyboardType: TextInputType.number,
                decoration: _dec('6-digit code'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: pass,
                obscureText: !showPass,
                decoration: _dec(
                  'New password',
                  suffix: IconButton(
                    icon: Icon(
                        showPass ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => showPass = !showPass),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: pass2,
                obscureText: !showPass,
                decoration: _dec('Confirm new password'),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: busy ? null : _sendCode,
                  child: const Text('Resend code',
                      style: TextStyle(fontSize: 12.5)),
                ),
              ),
            ],
            if (error != null) ...[
              const SizedBox(height: 8),
              Text(
                error!,
                style: const TextStyle(color: red, fontSize: 12.5),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        busy
            ? const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2.4),
                ),
              )
            : ElevatedButton(
                style: ElevatedButton.styleFrom(
                    backgroundColor: blue, foregroundColor: white),
                onPressed: codeSent ? _changePassword : _sendCode,
                child: Text(codeSent ? 'Change password' : 'Send code'),
              ),
      ],
    );
  }
}
