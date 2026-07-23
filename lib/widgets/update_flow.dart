import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../constant.dart';
import '../services/api_base.dart';
import '../services/haptic_service.dart';
import '../services/local_notifs.dart';
import '../services/update_installer.dart';
import '../services/update_service.dart';
import 'ux.dart';

/// Full in-app update flow: confirm → download inside the app with live
/// progress → ask to install (system installer takes over). On platforms
/// without a package installer (web/desktop) it falls back to the browser.
Future<void> runUpdateFlow(BuildContext context, UpdateInfo info) async {
  final go = await confirmDialog(
    context,
    title: 'Update available',
    message: 'v${info.version} (build ${info.buildNumber})\n${info.notes}'
        '\n\nThe update downloads in the background — keep using the app. '
        "You'll get a notification when it's ready to install.",
    confirmLabel: 'Update now',
    cancelLabel: 'Later',
  );
  if (!go || !context.mounted) return;

  if (!UpdateInstaller.supported || !info.apkAvailable) {
    launchUrl(Uri.parse(info.apkAvailable ? info.absoluteApkUrl : apiBase));
    return;
  }

  // Live foreground progress pill (in-app) + an ongoing progress
  // notification (notification shade) — both track the same download, which
  // keeps running when the user minimizes or switches apps.
  const notifId = 4242;
  var lastPct = -1;
  final progress = ValueNotifier<double>(0);
  final overlay = _showProgressPill(context, info.version, progress);
  LocalNotifs.showProgress(
      notifId, 'Downloading Mr.TourGuide v${info.version}', 0);
  UpdateInstaller.download(info, (p) {
    progress.value = p;
    final pct = (p * 100).round();
    if (pct != lastPct && pct % 2 == 0) {
      lastPct = pct;
      LocalNotifs.showProgress(
          notifId, 'Downloading Mr.TourGuide v${info.version}', pct);
    }
  }).then((path) async {
    overlay.remove();
    await LocalNotifs.cancel(notifId);
    Haptics.string();
    await LocalNotifs.show(
      'Update ready to install',
      'Mr.TourGuide v${info.version} downloaded — tap to install.',
      payload: 'install:$path',
    );
    if (context.mounted) {
      final install = await confirmDialog(
        context,
        title: 'Update downloaded',
        message: 'v${info.version} is ready. Install now? Android will '
            'confirm before replacing the app.',
        confirmLabel: 'Install',
        cancelLabel: 'Later',
      );
      if (install) await UpdateInstaller.install(path);
    }
  }).catchError((Object e) {
    overlay.remove();
    LocalNotifs.cancel(notifId);
    if (context.mounted) {
      newSnackBar(context,
          title: e is UpdateDownloadException
              ? e.message
              : 'Update download failed — try again from Settings.');
    }
  });
}

/// A small top overlay pill showing live download progress inside the app.
OverlayEntry _showProgressPill(
    BuildContext context, String version, ValueNotifier<double> progress) {
  final entry = OverlayEntry(
    builder: (context) => Positioned(
      top: MediaQuery.of(context).padding.top + 8,
      left: 16,
      right: 16,
      child: Material(
        color: Colors.transparent,
        child: ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (context, p, _) => Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: blue,
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 12,
                    offset: const Offset(0, 4)),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.system_update,
                        color: Colors.white, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('Downloading v$version…',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w700)),
                    ),
                    Text('${(p * 100).round()}%',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w800)),
                  ],
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: p == 0 ? null : p,
                    minHeight: 5,
                    backgroundColor: Colors.white24,
                    valueColor:
                        const AlwaysStoppedAnimation(Color(0xFF3CEBFF)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  Overlay.of(context, rootOverlay: true).insert(entry);
  return entry;
}
