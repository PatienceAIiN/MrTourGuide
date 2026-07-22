import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/haptic_service.dart';

/// Fullscreen image viewer: pinch/drag zoom, Save (downloads via the
/// system browser) and Share-style open. Used for AI planner visuals and
/// community photos.
Future<void> showImageViewer(BuildContext context, String url,
    {String? caption}) {
  Haptics.light();
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.92),
    builder: (context) => Dialog.fullscreen(
      backgroundColor: Colors.transparent,
      child: Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              minScale: 0.8,
              maxScale: 5,
              child: Center(
                child: Image.network(
                  url,
                  fit: BoxFit.contain,
                  loadingBuilder: (context, child, progress) => progress == null
                      ? child
                      : const Center(
                          child:
                              CircularProgressIndicator(color: Colors.white54)),
                  errorBuilder: (context, error, stack) => const Center(
                    child: Icon(Icons.broken_image,
                        color: Colors.white38, size: 48),
                  ),
                ),
              ),
            ),
          ),
          // Top bar: close + caption
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                  if (caption != null)
                    Expanded(
                      child: Text(caption,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 13)),
                    ),
                ],
              ),
            ),
          ),
          // Bottom actions
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white.withValues(alpha: 0.16),
                        foregroundColor: Colors.white,
                      ),
                      onPressed: () {
                        Haptics.tick();
                        // System browser handles the download/save.
                        launchUrl(Uri.parse(url),
                            mode: LaunchMode.externalApplication);
                      },
                      icon: const Icon(Icons.download, size: 18),
                      label: const Text('Save'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
