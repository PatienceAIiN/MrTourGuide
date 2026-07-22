import 'package:flutter/material.dart';

import '../constant.dart';

/// Terms & Privacy in a native pop-up modal — no webview, works offline.
Future<void> showLegalSheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scroll) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 42,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
              child: Row(
                children: [
                  const Icon(Icons.policy_outlined, color: blue),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Terms & Privacy Policy',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: ink(context),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                controller: scroll,
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
                children: [
                  _p(context,
                      'Mr.Tour Guide is an accessibility-first virtual travel '
                      'platform by PatienceAI. By creating an account or using '
                      'the app you agree to these terms.'),
                  _h(context, 'Your account'),
                  _p(context,
                      'Provide accurate details, keep your password private, '
                      'and be at least 13 years old. You can change your '
                      'password, control what your profile shows, or delete '
                      'your account anytime from your Profile.'),
                  _h(context, 'Content you share'),
                  _p(context,
                      'You own what you upload. By publishing an experience, '
                      'post or reply you allow us to display it in the app so '
                      'other travelers can enjoy it. Unlawful, hateful, '
                      'explicit or unsafe content is not allowed and may be '
                      'removed; repeated abuse can close an account.'),
                  _h(context, 'Haptics, MR & VR safety'),
                  _p(context,
                      'Experiences are simulations. Vibration strength is '
                      'adjustable — lower it or stop if you feel discomfort. '
                      'VR mode needs a compatible device and a safe, seated '
                      'space. Take breaks during long sessions.'),
                  _h(context, 'Service availability'),
                  _p(context,
                      'We aim to keep the service running smoothly, but '
                      'features may change or pause as the platform grows.'),
                  _h(context, 'Privacy — what we collect'),
                  _p(context,
                      'Your name, email and role; optional profile details '
                      '(username, Instagram, phone) with per-field privacy '
                      'switches you control; content you upload; a device '
                      'token for notifications; and location only when you '
                      'use a location feature.'),
                  _h(context, 'How we use it'),
                  _p(context,
                      'To run the service, sync your content, send '
                      'verification and security emails, and deliver '
                      'notifications you can switch off in Settings. We never '
                      'sell your data and the app shows no third-party ads.'),
                  _h(context, 'Deleting your data'),
                  _p(context,
                      'Deleting your account removes your account and '
                      'personal details from our systems. Community posts are '
                      'marked as from a deleted account.'),
                  _h(context, 'Contact'),
                  _p(context,
                      'Questions or concerns? Use Share feedback in Settings '
                      'and we will get back to you.'),
                  const SizedBox(height: 12),
                  Text(
                    'Last updated: 23 July 2026',
                    style: TextStyle(
                      fontSize: 12,
                      color: ink(context).withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

Widget _h(BuildContext context, String text) => Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 6),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w700,
          color: ink(context),
        ),
      ),
    );

Widget _p(BuildContext context, String text) => Text(
      text,
      style: TextStyle(
        fontSize: 13.5,
        height: 1.45,
        color: ink(context).withValues(alpha: 0.85),
      ),
    );
