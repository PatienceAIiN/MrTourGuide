import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'haptic_service.dart';
import 'local_notifs.dart';

/// App-wide shake-to-SOS. Lives as a service (not page state) so the
/// gesture works ANYWHERE in the app once enabled — three hard jolts
/// inside 1.5s open a 5-second cancellable countdown, then the SOS SMS
/// auto-sends to the saved Safety contact with live GPS.
///
/// The toggle appears both in Settings and on the Safety page; both drive
/// this one service, and the preference is the Safety key ('hill.shake')
/// so existing users keep their choice.
class ShakeSos extends ChangeNotifier {
  ShakeSos._();
  static final ShakeSos instance = ShakeSos._();

  /// Set as MaterialApp.navigatorKey — lets the service show the countdown
  /// dialog from anywhere.
  static final navKey = GlobalKey<NavigatorState>();

  static const _sms = MethodChannel('mrtouride/sms');
  static const _ble = MethodChannel('mrtouride/blesos-ctl');

  StreamSubscription? _sub;
  final List<int> _jolts = [];
  bool _armed = false; // countdown dialog is up
  bool _on = false;
  bool get on => _on;

  Future<void> init() async {
    final p = await SharedPreferences.getInstance();
    _on = p.getBool('hill.shake') ?? false;
    if (_on) _listen();
    notifyListeners();
  }

  Future<void> set(bool on) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('hill.shake', on);
    _on = on;
    _sub?.cancel();
    _sub = null;
    if (on) _listen();
    notifyListeners();
  }

  void _listen() {
    _sub = accelerometerEventStream().listen((e) {
      final g = (e.x * e.x + e.y * e.y + e.z * e.z) / 96.2; // 1.0 ≈ gravity
      if (g < 3.2) return; // hard jolt only
      final now = DateTime.now().millisecondsSinceEpoch;
      _jolts.removeWhere((t) => now - t > 1500);
      if (_jolts.isNotEmpty && now - _jolts.last < 180) return; // debounce
      _jolts.add(now);
      if (_jolts.length >= 3 && !_armed) {
        _jolts.clear();
        _countdown();
      }
    });
  }

  Future<void> _countdown() async {
    final ctx = navKey.currentContext;
    if (ctx == null) {
      await _send(); // no UI available — send rather than stay silent
      return;
    }
    _armed = true;
    Haptics.heavy();
    var left = 5;
    Timer? tick;
    final cancelled = await showDialog<bool>(
      context: ctx,
      barrierDismissible: false,
      builder: (c) => StatefulBuilder(builder: (c, setD) {
        tick ??= Timer.periodic(const Duration(seconds: 1), (t) {
          left--;
          Haptics.medium();
          if (left <= 0) {
            t.cancel();
            if (c.mounted) Navigator.pop(c, false);
          } else {
            setD(() {});
          }
        });
        return AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          icon: const Icon(Icons.vibration_rounded,
              color: Colors.red, size: 40),
          title: Text('Sending SOS in $left…'),
          content: const Text('Shake detected. Cancel if this was accidental.',
              textAlign: TextAlign.center),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.teal),
                onPressed: () => Navigator.pop(c, true),
                child: const Text('Cancel')),
          ],
        );
      }),
    );
    tick?.cancel();
    _armed = false;
    if (cancelled != true) await _send();
  }

  Future<void> _send() async {
    final p = await SharedPreferences.getInstance();
    final to = (p.getString('hill.contact') ?? '').trim().isNotEmpty
        ? p.getString('hill.contact')!.trim()
        : '112';
    Position? pos;
    try {
      pos = await Geolocator.getCurrentPosition(
              locationSettings:
                  const LocationSettings(accuracy: LocationAccuracy.high))
          .timeout(const Duration(seconds: 12),
              onTimeout: () async =>
                  (await Geolocator.getLastKnownPosition())!);
    } catch (_) {
      pos = await Geolocator.getLastKnownPosition();
    }
    final loc = pos == null
        ? 'location unavailable'
        : 'https://maps.google.com/?q=${pos.latitude},${pos.longitude}';
    if (pos != null) {
      // Shout over Bluetooth too — nearby app users can relay.
      _ble.invokeMethod('advertise',
          {'lat': pos.latitude, 'lon': pos.longitude}).catchError((_) => null);
    }
    final body =
        'SOS — I need help. My location: $loc (Mr.Tour Guide Safety)';
    var sent = false;
    try {
      sent = await _sms.invokeMethod<bool>(
              'send', {'to': to, 'body': body}) ==
          true;
    } catch (_) {}
    if (!sent) {
      // Fallback: open the SMS app prefilled so the message still goes out.
      try {
        await launchUrl(
            Uri(scheme: 'sms', path: to, queryParameters: {'body': body}),
            mode: LaunchMode.externalApplication);
      } catch (_) {}
    }
    LocalNotifs.show(
        sent ? 'SOS sent' : 'SOS needs one more tap',
        sent
            ? 'Your location went to $to by SMS.'
            : 'Auto-send failed — your SMS app was opened, press send.');
  }
}
