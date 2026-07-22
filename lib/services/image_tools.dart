import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Decodes any picker image with the PHONE's own codecs (JPEG, PNG, WebP,
/// HEIC/HEIF...) and re-encodes it as a clean PNG, downscaled to [maxWidth].
/// The server then always receives a format its ffmpeg can process —
/// which is what killed HEIC photos renamed .jpg.
Future<Uint8List> normalizeImage(Uint8List bytes, {int maxWidth = 1600}) async {
  if (kIsWeb) return bytes; // browsers hand over decodable formats already
  try {
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: maxWidth,
      allowUpscaling: false,
    );
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    if (data == null) return bytes;
    return data.buffer.asUint8List();
  } catch (_) {
    // Undecodable? Send the original — the server will answer clearly.
    return bytes;
  }
}
