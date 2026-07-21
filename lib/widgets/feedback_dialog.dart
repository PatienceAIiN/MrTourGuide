import 'package:flutter/material.dart';

import '../constant.dart';
import '../services/auth_api.dart';
import '../services/media_api.dart';
import 'ux.dart';

/// In-app feedback: star rating + message, stored via the backend.
Future<void> showFeedbackDialog(BuildContext context) {
  final controller = TextEditingController();
  var rating = 5;
  var sending = false;
  return showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Share feedback'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 1; i <= 5; i++)
                  IconButton(
                    icon: Icon(
                      i <= rating ? Icons.star : Icons.star_border,
                      color: Colors.amber,
                      size: 30,
                    ),
                    onPressed: () => setState(() => rating = i),
                  ),
              ],
            ),
            TextField(
              controller: controller,
              maxLines: 4,
              decoration: const InputDecoration(
                hintText: 'How does MrTouride feel? What should we improve?',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          SizedBox(
            width: 110,
            child: LoadingButton(
              busy: sending,
              label: 'Send',
              onPressed: () async {
                if (controller.text.trim().isEmpty) return;
                setState(() => sending = true);
                try {
                  final thanks = await MediaApi.sendFeedback(
                    email: AuthApi.currentUser?.email,
                    rating: rating,
                    message: controller.text.trim(),
                  );
                  if (!context.mounted) return;
                  Navigator.pop(context);
                  newSnackBar(context, title: thanks);
                } on AuthException catch (e) {
                  setState(() => sending = false);
                  if (context.mounted) {
                    newSnackBar(context, title: e.message);
                  }
                }
              },
            ),
          ),
        ],
      ),
    ),
  );
}
