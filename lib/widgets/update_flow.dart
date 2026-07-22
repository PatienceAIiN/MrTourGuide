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

  // Background mode: no blocking dialog — a progress notification shows
  // the download even when the user switches apps.
  newSnackBar(context,
      title: 'Downloading v${info.version} in the background…');
  const notifId = 4242;
  var lastPct = -1;
  LocalNotifs.showProgress(
      notifId, 'Downloading Mr.TourGuide v${info.version}', 0);
  UpdateInstaller.download(info, (p) {
    final pct = (p * 100).round();
    if (pct != lastPct && pct % 4 == 0) {
      lastPct = pct;
      LocalNotifs.showProgress(
          notifId, 'Downloading Mr.TourGuide v${info.version}', pct);
    }
  }).then((path) async {
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
    LocalNotifs.cancel(notifId);
    if (context.mounted) {
      newSnackBar(context,
          title: e is UpdateDownloadException
              ? e.message
              : 'Update download failed — try again from Settings.');
    }
  });
}
