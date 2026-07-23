import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'transfer_service.dart';
import 'update_service.dart';

/// In-app OTA delivery: downloads the new APK inside the app (with live
/// progress) and hands it to the Android package installer — no browser.
///
/// Old downloaded builds are deleted before each new download, so stale
/// APKs never pile up in the cache.
class UpdateInstaller {
  static const _channel = MethodChannel('mrtouride/installer');
  static const _fileName = 'mrtouride-update.apk';

  static bool get supported => !kIsWeb && Platform.isAndroid;

  static Future<String> _downloadDir() async {
    final dir = await _channel.invokeMethod<String>('getDownloadDir');
    if (dir == null) throw const UpdateDownloadException('No download dir.');
    return dir;
  }

  /// Downloads the new APK in the BACKGROUND (survives the user switching
  /// apps or leaving the app — via the OS transfer service, with shade
  /// progress), reporting 0.0 → 1.0 via [onProgress]. The file is then placed
  /// in the installer-shared directory. Throws [UpdateDownloadException] on
  /// failure.
  static Future<String> download(
    UpdateInfo info,
    void Function(double progress) onProgress, {
    bool Function()? isCancelled,
  }) async {
    final destPath = '${await _downloadDir()}/$_fileName';
    final dest = File(destPath);
    if (await dest.exists()) await dest.delete(); // clean stale builds
    try {
      final downloaded = await TransferService.downloadToFile(
        url: info.absoluteApkUrl,
        filename: _fileName,
        displayName: 'Mr.Tour Guide update',
        onProgress: onProgress,
      );
      // Place it where the installer's FileProvider can read it.
      if (downloaded != destPath) {
        await File(downloaded).copy(destPath);
        try {
          await File(downloaded).delete();
        } catch (_) {}
      }
      onProgress(1);
      return destPath;
    } on TransferException {
      try {
        if (await dest.exists()) await dest.delete();
      } catch (_) {}
      throw const UpdateDownloadException(
          'Download failed — check your connection and try again.');
    }
  }

  /// Opens the system package installer for the downloaded build. Android
  /// asks the user to confirm (and to allow installs from this app the
  /// first time); the OS replaces the old build on install.
  static Future<void> install(String path) async {
    try {
      await _channel.invokeMethod('installApk', {'path': path});
    } on PlatformException {
      throw const UpdateDownloadException('Could not start the installer.');
    }
  }
}

class UpdateDownloadException implements Exception {
  final String message;
  const UpdateDownloadException(this.message);
}
