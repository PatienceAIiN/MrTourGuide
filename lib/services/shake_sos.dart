import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'haptic_service.dart';

/// Phone-wide shake-to-SOS.
///
/// Detection, the 5-second countdown and the auto-send all live in a native
/// foreground service (ShakeSosService), so the gesture works even when the
/// app is closed or the screen is off — Android shows a heads-up countdown
/// notification with a CANCEL action as the popup there. When the app is
/// open, this class mirrors the countdown as an in-app dialog too.
///
/// Toggles in Settings and on the Safety page both drive this one service
/// over the same preference ('hill.shake').
class ShakeSos extends ChangeNotifier {
  ShakeSos._();
  static final ShakeSos instance = ShakeSos._();

  /// Set as MaterialApp.navigatorKey — lets the mirror dialog show anywhere.
  static final navKey = GlobalKey<NavigatorState>();

  static const _svc = MethodChannel('mrtouride/shakesvc');
  static const _events = EventChannel('mrtouride/shakesvc-events');

  StreamSubscription? _evtSub;
  bool _on = false;
  bool get on => _on;
  bool _dialogUp = false;
  bool _awaitingOverlay = false;
  _ResumeWatcher? _watcher;

  Future<void> init() async {
    final p = await SharedPreferences.getInstance();
    _on = p.getBool('hill.shake') ?? false;
    if (_on) {
      // Re-assert the service (it also restarts itself after reboot).
      _svc.invokeMethod('start').catchError((_) => null);
    }
    _listen();
    _watcher ??= _ResumeWatcher(this);
    WidgetsBinding.instance.addObserver(_watcher!);
    notifyListeners();
    // Toggle was already on from an earlier build but the overlay grant is
    // still missing → nudge once so the popup can actually appear.
    if (_on) {
      Future.delayed(const Duration(seconds: 2), () async {
        try {
          final ok = await _svc.invokeMethod<bool>('overlayStatus');
          if (ok != true) await _ensureOverlay();
        } catch (_) {}
      });
    }
  }

  /// Called by the lifecycle watcher: user came back from the system
  /// settings screen — verify the grant actually happened and say so.
  Future<void> onResumed() async {
    if (!_awaitingOverlay) return;
    _awaitingOverlay = false;
    try {
      final ok = await _svc.invokeMethod<bool>('overlayStatus');
      final ctx = navKey.currentContext;
      if (ctx == null) return;
      ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(SnackBar(
          backgroundColor: ok == true ? Colors.teal : Colors.orange,
          content: Text(ok == true
              ? '✓ SOS popup can now appear over any screen.'
              : 'Overlay still off — the SOS countdown will show as a '
                  'notification instead. Enable "display over other apps" '
                  'to get the popup.')));
    } catch (_) {}
  }

  /// Confirmation popup shown when the user flips the toggle ON. Returns
  /// true only when they explicitly tap Enable.
  Future<bool> confirmEnable(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        icon: const Icon(Icons.vibration_rounded, color: Colors.red, size: 40),
        title: const Text('Enable Shake for SOS?'),
        content: const Text(
            'Shake your phone hard 3 times — anywhere, even with the app '
            'closed — and after a 5-second cancel window your live location '
            'auto-sends by SMS to your Safety contact.\n\n'
            'A small ongoing notification keeps it active (Android '
            'requirement).',
            textAlign: TextAlign.center),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          OutlinedButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Not now')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.teal),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Enable')),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> set(bool on) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('hill.shake', on);
    _on = on;
    try {
      if (on) {
        // Someone in trouble can't grant dialogs — everything the killed-app
        // emergency path needs is set up NOW, at enable time: the contact
        // number, SMS + location permissions, then "display over other
        // apps" so the countdown popup can appear over any screen.
        await _ensureContact();
        await _svc.invokeMethod('ensurePerms');
        await _ensureOverlay();
        await _svc.invokeMethod('start');
      } else {
        await _svc.invokeMethod('stop');
      }
    } catch (_) {}
    notifyListeners();
  }

  /// Without a saved contact the SOS falls back to 112 — fine as a last
  /// resort, but the user should choose. Ask right at enable time.
  Future<void> _ensureContact() async {
    final p = await SharedPreferences.getInstance();
    if ((p.getString('hill.contact') ?? '').trim().isNotEmpty) return;
    final ctx = navKey.currentContext;
    if (ctx == null) return;
    final ctl = TextEditingController();
    final saved = await showDialog<bool>(
      // ignore: use_build_context_synchronously
      context: ctx,
      builder: (c) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        icon: const Icon(Icons.contact_phone_rounded,
            color: Colors.teal, size: 36),
        title: const Text('Who should the SOS go to?'),
        content: TextField(
          controller: ctl,
          keyboardType: TextInputType.phone,
          autofocus: true,
          decoration: const InputDecoration(
              labelText: 'Emergency contact number',
              border: OutlineInputBorder()),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          OutlinedButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Use 112')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.teal),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Save')),
        ],
      ),
    );
    if (saved == true && ctl.text.trim().isNotEmpty) {
      await p.setString('hill.contact', ctl.text.trim());
    }
  }

  Future<void> _ensureOverlay() async {
    try {
      final ok = await _svc.invokeMethod<bool>('overlayStatus');
      if (ok == true) return;
      final ctx = navKey.currentContext;
      if (ctx == null) return;
      final go = await showDialog<bool>(
        // ignore: use_build_context_synchronously
        context: ctx,
        builder: (c) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          icon: const Icon(Icons.picture_in_picture_alt_rounded,
              color: Colors.teal, size: 36),
          title: const Text('Show SOS popup everywhere'),
          content: const Text(
              'For the 5-second cancel popup to appear over ANY screen, '
              'Android needs one switch turned on.\n\n'
              'On the next screen:\n'
              'turn ON "Allow display over other apps", then come back.',
              textAlign: TextAlign.left),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            OutlinedButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('Skip')),
            FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.teal),
                onPressed: () => Navigator.pop(c, true),
                child: const Text('Open the switch')),
          ],
        ),
      );
      if (go == true) {
        _awaitingOverlay = true; // verified + reported on resume
        await _svc.invokeMethod('requestOverlay');
      }
    } catch (_) {}
  }

  // ── In-app countdown mirror ─────────────────────────────────────────────
  void _listen() {
    _evtSub ??= _events.receiveBroadcastStream().listen((e) {
      if (e is! Map) return;
      switch (e['evt']) {
        case 'triggered':
          _showMirror();
        case 'cancelled':
        case 'sending':
        case 'sent':
        case 'failed':
          _closeMirror();
      }
    }, onError: (_) {});
  }

  void _showMirror() {
    final ctx = navKey.currentContext;
    if (ctx == null || _dialogUp) return;
    _dialogUp = true;
    Haptics.heavy();
    showDialog(
      context: ctx,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        icon: const Icon(Icons.vibration_rounded, color: Colors.red, size: 40),
        title: const Text('Sending SOS in 5s…'),
        content: const Text('Shake detected. Cancel if this was accidental.',
            textAlign: TextAlign.center),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.teal),
              onPressed: () {
                _svc.invokeMethod('cancel').catchError((_) => null);
                Navigator.pop(c);
              },
              child: const Text('Cancel')),
        ],
      ),
    ).whenComplete(() => _dialogUp = false);
  }

  void _closeMirror() {
    if (!_dialogUp) return;
    final nav = navKey.currentState;
    if (nav != null && nav.canPop()) nav.pop();
    _dialogUp = false;
  }
}

/// Watches for the app resuming (back from the system settings screen) so
/// the overlay grant can be verified and reported honestly.
class _ResumeWatcher with WidgetsBindingObserver {
  _ResumeWatcher(this.svc);
  final ShakeSos svc;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) svc.onResumed();
  }
}
