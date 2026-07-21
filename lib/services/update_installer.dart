import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

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

  /// Streams the APK to the app cache, reporting 0.0 → 1.0 via [onProgress].
  /// Returns the downloaded file path. Throws [UpdateDownloadException] on
  /// any failure (never leaves a partial file behind).
  static Future<String> download(
    UpdateInfo info,
    void Function(double progress) onProgress, {
    bool Function()? isCancelled,
  }) async {
    final path = '${await _downloadDir()}/$_fileName';
    final file = File(path);
    if (await file.exists()) await file.delete(); // clean stale builds

    final client = http.Client();
    IOSink? sink;
    try {
      final response = await client
          .send(http.Request('GET', Uri.parse(info.absoluteApkUrl)))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw const UpdateDownloadException(
            'Update server did not return the app package.');
      }
      final total = response.contentLength ?? 0;
      var received = 0;
      sink = file.openWrite();
      await for (final chunk in response.stream) {
        if (isCancelled?.call() ?? false) {
          throw const UpdateDownloadException('Download cancelled.');
        }
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress(received / total);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (total > 0 && received < total) {
        throw const UpdateDownloadException('Download ended early.');
      }
      onProgress(1);
      return path;
    } on UpdateDownloadException {
      await _cleanup(sink, file);
      rethrow;
    } catch (_) {
      await _cleanup(sink, file);
      throw const UpdateDownloadException(
          'Download failed — check your connection and try again.');
    } finally {
      client.close();
    }
  }

  static Future<void> _cleanup(IOSink? sink, File file) async {
    try {
      await sink?.close();
    } catch (_) {}
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
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
