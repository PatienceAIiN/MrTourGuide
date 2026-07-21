import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../constant.dart';
import '../services/api_base.dart';
import '../services/haptic_service.dart';
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
        '\n\nThe app downloads the update itself and asks to install when '
        'it is ready. Old builds are cleaned up automatically.',
    confirmLabel: 'Update now',
    cancelLabel: 'Later',
  );
  if (!go || !context.mounted) return;

  if (!UpdateInstaller.supported || !info.apkAvailable) {
    launchUrl(Uri.parse(info.apkAvailable ? info.absoluteApkUrl : apiBase));
    return;
  }

  final progress = ValueNotifier<double>(0);
  var cancelled = false;
  var dialogOpen = true;

  // Progress dialog — no barrier dismiss; Cancel stops the download.
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => PopScope(
      canPop: false,
      child: AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Downloading update'),
        content: ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (context, v, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinearProgressIndicator(
                value: v > 0 ? v : null,
                minHeight: 8,
                borderRadius: BorderRadius.circular(8),
                color: blue,
              ),
              const SizedBox(height: 10),
              Text(
                v > 0
                    ? '${(v * 100).round()}% · v${info.version} '
                        '(build ${info.buildNumber})'
                    : 'Starting download…',
                style: const TextStyle(fontSize: 12.5, color: Colors.grey),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              cancelled = true;
              Navigator.pop(dialogContext);
            },
            child: const Text('Cancel'),
          ),
        ],
      ),
    ),
  ).then((_) => dialogOpen = false);

  String path;
  try {
    path = await UpdateInstaller.download(
      info,
      (v) => progress.value = v,
      isCancelled: () => cancelled,
    );
  } on UpdateDownloadException catch (e) {
    if (!context.mounted) return;
    if (dialogOpen) Navigator.pop(context);
    if (!cancelled) newSnackBar(context, title: e.message);
    return;
  }

  if (!context.mounted) return;
  if (dialogOpen) Navigator.pop(context);
  Haptics.medium();

  // Downloaded — ask before handing over to the system installer.
  final install = await confirmDialog(
    context,
    title: 'Update downloaded',
    message: 'v${info.version} (build ${info.buildNumber}) is ready. '
        'Install now? Android will confirm before replacing the app.',
    confirmLabel: 'Install',
    cancelLabel: 'Later',
  );
  if (!install || !context.mounted) return;
  try {
    await UpdateInstaller.install(path);
  } on UpdateDownloadException catch (e) {
    if (context.mounted) newSnackBar(context, title: e.message);
  }
}
