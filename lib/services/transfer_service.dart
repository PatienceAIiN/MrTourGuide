import 'package:background_downloader/background_downloader.dart';

/// Thrown when a background upload/download does not complete successfully.
class TransferException implements Exception {
  final String? body;
  final int? statusCode;
  final TaskStatus status;
  const TransferException(this.body, this.statusCode, this.status);
}

/// Native background uploads + downloads (via background_downloader).
///
/// Transfers keep running when the user switches apps (Android foreground
/// service), show live progress in the notification shade, and — for
/// downloads — survive the app being closed. Progress is also surfaced to the
/// caller for an in-app progress bar.
class TransferService {
  static final FileDownloader _dl = FileDownloader();
  static bool _init = false;

  static void ensureInit() {
    if (_init) return;
    _init = true;
    // Shade notifications with a live progress bar for every transfer.
    _dl.configureNotification(
      running: const TaskNotification('{displayName}', 'In progress · {progress}'),
      complete: const TaskNotification('{displayName}', 'Done'),
      error: const TaskNotification('{displayName}', 'Failed — try again'),
      progressBar: true,
      tapOpensFile: false,
    );
  }

  /// Uploads [filePath] as a raw binary POST body to [url] (matches the
  /// backend's raw-body handlers). Reports 0..1 progress; returns the response
  /// body on a 2xx, otherwise throws [TransferException].
  static Future<String> uploadBinary({
    required String filePath,
    required String url,
    required String displayName,
    void Function(double progress)? onProgress,
  }) async {
    ensureInit();
    final parts = await Task.split(filePath: filePath);
    final task = UploadTask(
      url: url,
      baseDirectory: parts.$1,
      directory: parts.$2,
      filename: parts.$3,
      httpRequestMethod: 'POST',
      post: 'binary',
      headers: const {'Content-Type': 'application/octet-stream'},
      displayName: displayName,
      updates: Updates.statusAndProgress,
      retries: 1,
    );
    final result = await _dl.upload(
      task,
      onProgress: (p) {
        if (p >= 0) onProgress?.call(p);
      },
    );
    final code = result.responseStatusCode;
    if (result.status == TaskStatus.complete &&
        (code == null || (code >= 200 && code < 300))) {
      return result.responseBody ?? '';
    }
    throw TransferException(result.responseBody, code, result.status);
  }

  /// Downloads [url] into app storage, running in the background so it
  /// completes even if the app is switched away or closed. Returns the local
  /// file path on success.
  static Future<String> downloadToFile({
    required String url,
    required String filename,
    required String displayName,
    void Function(double progress)? onProgress,
  }) async {
    ensureInit();
    final task = DownloadTask(
      url: url,
      filename: filename,
      baseDirectory: BaseDirectory.applicationSupport,
      displayName: displayName,
      updates: Updates.statusAndProgress,
      allowPause: true,
      retries: 2,
    );
    final result = await _dl.download(
      task,
      onProgress: (p) {
        if (p >= 0) onProgress?.call(p);
      },
    );
    if (result.status == TaskStatus.complete) {
      return task.filePath();
    }
    throw TransferException(
        result.responseBody, result.responseStatusCode, result.status);
  }
}
