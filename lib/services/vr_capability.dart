import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

/// VR/MR eligibility for this device: Android version + motion sensors.
class VrCapability {
  final bool eligible;
  final String reason;
  final String model;
  const VrCapability(
      {required this.eligible, required this.reason, required this.model});

  static const _channel = MethodChannel('mrtouride/installer');
  static VrCapability? _cached;

  static Future<VrCapability> check() async {
    if (_cached != null) return _cached!;
    if (kIsWeb) {
      return _cached = const VrCapability(
          eligible: false,
          reason: 'VR mode needs the Android app — the web preview cannot '
              'drive a headset.',
          model: 'Web');
    }
    try {
      final info =
          await _channel.invokeMapMethod<String, dynamic>('deviceInfo');
      final sdk = info?['sdk'] as int? ?? 0;
      final gyro = info?['gyro'] as bool? ?? false;
      final model = info?['model'] as String? ?? 'this device';
      if (sdk < 24) {
        return _cached = VrCapability(
            eligible: false,
            reason: 'Android version too old (needs Android 7.0 / API 24+, '
                'this device runs API $sdk).',
            model: model);
      }
      if (!gyro) {
        return _cached = VrCapability(
            eligible: false,
            reason: 'No gyroscope sensor — head tracking is not possible '
                'on $model.',
            model: model);
      }
      return _cached = VrCapability(eligible: true, reason: '', model: model);
    } catch (_) {
      // Channel unavailable (old build/tests): allow, VR view still works.
      return _cached =
          const VrCapability(eligible: true, reason: '', model: 'this device');
    }
  }
}
