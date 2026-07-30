import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'constant.dart';
import 'services/haptic_service.dart';
import 'package:http/http.dart' as http;

import 'services/api_base.dart';
import 'services/local_notifs.dart';

/// HILL MODE — the part of the app that keeps working when the network
/// doesn't. Fully offline-capable:
///   • SOS: GPS fix (no network needed) + SMS sent DIRECTLY via the carrier
///     (SmsManager) — delivers on bare 2G signal, no data, no app-hop.
///   • Trip beacon: plan saved locally; a scheduled notification fires at
///     the deadline even if the app was killed; one tap auto-alerts the
///     contact with plan + last GPS.
///   • Survival packs: emergency numbers, fair taxi rates, altitude/health
///     and dead-zone info bundled with the app.
class HillModePage extends StatefulWidget {
  const HillModePage({super.key});
  @override
  State<HillModePage> createState() => _HillModePageState();
}

const _beaconNotifId = 7301;

class _Pack {
  final String name, taxi, tips, deadZones;
  final List<List<String>> helplines;
  final List<String> sources;
  final DateTime? updatedAt;
  const _Pack(this.name, this.taxi, this.tips, this.deadZones,
      {this.helplines = const [], this.sources = const [], this.updatedAt});

  Map<String, dynamic> toJson() => {
        'name': name, 'taxi': taxi, 'tips': tips, 'deadZones': deadZones,
        'helplines': helplines,
        'sources': sources,
        'updatedAt': updatedAt?.toIso8601String(),
      };
  static _Pack fromJson(Map<String, dynamic> j) => _Pack(
        (j['name'] ?? '') as String,
        (j['taxi'] ?? '') as String,
        (j['tips'] ?? '') as String,
        (j['deadZones'] ?? '') as String,
        helplines: [
          for (final h in (j['helplines'] as List? ?? []))
            [for (final x in (h as List)) x.toString()]
        ],
        sources: [
          for (final x in (j['sources'] as List? ?? [])) x.toString()
        ],
        updatedAt: DateTime.tryParse((j['updatedAt'] ?? '') as String),
      );
}

// First-run seeds — replaced by live packs as soon as the phone is online.
const _seedPacks = [
  _Pack(
    'Manali',
    'Bus stand → Old Manali ₹100–150 · Mall Rd → Solang ₹800–1200 rt\n'
        'Mall Rd → Rohtang ₹2500–3500 rt (union rates; agree BEFORE boarding)',
    'Altitude 2,050m — mild for most. Rohtang 3,978m: go slow, hydrate, '
        'avoid alcohol first 24h. Nearest big hospital: Mission Hospital, '
        'Manali · Civil Hospital Kullu (40km).',
    'Signal fades past Solang valley & Rohtang stretch. BSNL/Jio survive '
        'longest. Open this pack before leaving Manali town.',
  ),
  _Pack(
    'Shimla',
    'Rly stn → Mall Rd ₹150–250 · Local sightseeing day cab ₹2000–3000\n'
        'Kufri round trip ₹1000–1500 (fix at stand, not through touts)',
    'Altitude 2,276m — easy. Steep walks everywhere: seniors should use '
        'the lift near Mall Rd. IGMC hospital is central and 24×7.',
    'Coverage is decent in town; drops on Kufri–Chail forest stretches.',
  ),
];

const _helplines = [
  ('112', 'All-India Emergency'),
  ('108', 'Ambulance'),
  ('1077', 'Disaster Helpline'),
  ('1363', 'Tourist Helpline 24×7'),
];

class _HillModePageState extends State<HillModePage> {
  static const _sms = MethodChannel('mrtouride/sms');
  static const _beacon = MethodChannel('mrtouride/beacon');
  static const _bleCtl = MethodChannel('mrtouride/blesos-ctl');
  static const _bleEvents = EventChannel('mrtouride/blesos');
  StreamSubscription? _bleSub;
  int _lastBleAlertMs = 0;

  // Shake-to-SOS: three hard jolts within 1.5s fires the SOS countdown.
  StreamSubscription? _shakeSub;
  bool _shakeOn = false;
  final List<int> _jolts = [];
  bool _sosArmed = false; // countdown dialog is up

  List<_Pack> _myPacks = [];
  int _pack = 0;
  bool _fetching = false;
  final _searchCtl = TextEditingController();
  String _contact = '';
  String _plan = '';
  DateTime? _backBy;

  @override
  void initState() {
    super.initState();
    _load();
    // Listen for nearby BLE SOS packets while Hill Mode is open — if a
    // phone with no signal broadcasts an SOS, this one hears it.
    _bleSub = _bleEvents.receiveBroadcastStream().listen((e) {
      if (e is! Map) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastBleAlertMs < 60000) return; // don't spam
      _lastBleAlertMs = now;
      final lat = e['lat'], lon = e['lon'];
      LocalNotifs.show('SOS nearby!',
          'Someone close by needs help. Location: '
          'https://maps.google.com/?q=$lat,$lon');
      if (mounted) {
        showDialog(
          context: context,
          builder: (c) => AlertDialog(
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20)),
            icon: const Icon(Icons.emergency_share_rounded,
                color: Colors.red, size: 40),
            title: const Text('SOS received nearby'),
            content: const Text(
                'A phone near you is broadcasting an SOS over Bluetooth. '
                'If you have signal, forward it — you may be their only link.',
                textAlign: TextAlign.center),
            actionsAlignment: MainAxisAlignment.center,
            actions: [
              OutlinedButton(
                  onPressed: () => Navigator.pop(c),
                  child: const Text('Dismiss')),
              FilledButton(
                  style:
                      FilledButton.styleFrom(backgroundColor: Colors.red),
                  onPressed: () {
                    Navigator.pop(c);
                    launchUrl(Uri.parse('https://maps.google.com/?q=$lat,$lon'),
                        mode: LaunchMode.externalApplication);
                  },
                  child: const Text('View location')),
            ],
          ),
        );
      }
    }, onError: (_) {});
  }

  @override
  void dispose() {
    _bleSub?.cancel();
    _shakeSub?.cancel();
    _bleCtl.invokeMethod('stopAdvertise').catchError((_) => null);
    super.dispose();
  }

  // ── Shake-to-SOS ───────────────────────────────────────────────────────
  // Three hard jolts inside 1.5s → a 5-second countdown → auto-send. The
  // countdown exists so an accidental shake can be cancelled; if the phone
  // is dropped in a real emergency the SOS still goes out by itself.
  Future<void> _setShake(bool on) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('hill.shake', on);
    _shakeSub?.cancel();
    _shakeSub = null;
    if (on) {
      _shakeSub = accelerometerEventStream().listen((e) {
        final g =
            (e.x * e.x + e.y * e.y + e.z * e.z) / 96.2; // 1.0 ≈ gravity
        if (g < 3.2) return; // hard jolt only
        final now = DateTime.now().millisecondsSinceEpoch;
        _jolts.removeWhere((t) => now - t > 1500);
        if (_jolts.isNotEmpty && now - _jolts.last < 180) return; // debounce
        _jolts.add(now);
        if (_jolts.length >= 3 && !_sosArmed) {
          _jolts.clear();
          _shakeCountdown();
        }
      });
    }
    if (mounted) setState(() => _shakeOn = on);
  }

  Future<void> _shakeCountdown() async {
    if (_sosArmed || !mounted) return;
    _sosArmed = true;
    Haptics.heavy();
    var left = 5;
    Timer? tick;
    final cancelled = await showDialog<bool>(
      context: context,
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
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          icon: const Icon(Icons.vibration_rounded, color: Colors.red, size: 40),
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
    _sosArmed = false;
    if (cancelled == true || !mounted) return;
    await _fireSos(silent: true);
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      _contact = p.getString('hill.contact') ?? '';
      _plan = p.getString('hill.plan') ?? '';
      final t = p.getInt('hill.backBy');
      _backBy = t == null ? null : DateTime.fromMillisecondsSinceEpoch(t);
      final raw = p.getString('hill.packs');
      _myPacks = raw == null
          ? List.of(_seedPacks)
          : [for (final j in jsonDecode(raw) as List) _Pack.fromJson(j)];
      if (_pack >= _myPacks.length) _pack = 0;
      _shakeOn = p.getBool('hill.shake') ?? false;
    });
    if (_shakeOn) _setShake(true);
    _refreshStale();
  }

  Future<void> _persistPacks() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
        'hill.packs', jsonEncode([for (final k in _myPacks) k.toJson()]));
  }

  Future<_Pack?> _fetchPack(String place) async {
    try {
      final r = await http
          .get(Uri.parse(
              '$apiBase/hillmode/pack?place=${Uri.encodeComponent(place)}'))
          .timeout(const Duration(seconds: 80));
      if (r.statusCode != 200) return null;
      return _Pack.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Silently re-fetch saved packs older than 7 days (or seeds) when online.
  Future<void> _refreshStale() async {
    var changed = false;
    for (var i = 0; i < _myPacks.length; i++) {
      final k = _myPacks[i];
      final stale = k.updatedAt == null ||
          DateTime.now().difference(k.updatedAt!) > const Duration(days: 7);
      if (!stale) continue;
      final fresh = await _fetchPack(k.name);
      if (fresh != null) { _myPacks[i] = fresh; changed = true; }
    }
    if (changed) { await _persistPacks(); if (mounted) setState(() {}); }
  }

  /// Fetch a pack (typed or GPS-detected), preview it in a modal, save on tap.
  Future<void> _getPack({String? place}) async {
    var query = place ?? _searchCtl.text.trim();
    if (query.isEmpty) return;
    Haptics.light();
    setState(() => _fetching = true);
    final pack = await _fetchPack(query);
    if (!mounted) return;
    setState(() => _fetching = false);
    if (pack == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Couldn\'t fetch that pack — check your connection and try again.')));
      return;
    }
    _searchCtl.clear();
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (c) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
        child: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                  child: Container(
                      width: 36, height: 4,
                      decoration: BoxDecoration(
                          color: Colors.grey.withValues(alpha: .4),
                          borderRadius: BorderRadius.circular(2)))),
              const SizedBox(height: 14),
              Row(children: [
                const Icon(Icons.hiking_rounded, color: Colors.teal),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(pack.name,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 18))),
              ]),
              const SizedBox(height: 10),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(children: [
                    _info(Icons.local_taxi_rounded, 'Fair taxi rates',
                        pack.taxi),
                    _info(Icons.favorite_rounded, 'Altitude & health',
                        pack.tips),
                    _info(Icons.signal_cellular_off_rounded,
                        'Signal dead zones', pack.deadZones),
                    if (pack.helplines.isNotEmpty)
                      _info(Icons.call_rounded, 'Local helplines', [
                        for (final h in pack.helplines)
                          '${h.first} — ${h.length > 1 ? h[1] : ''}'
                      ].join('\n')),
                  ]),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                      backgroundColor: Colors.teal,
                      padding: const EdgeInsets.symmetric(vertical: 14)),
                  icon: const Icon(Icons.download_rounded),
                  label: const Text('Save for offline',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  onPressed: () {
                    Haptics.medium();
                    final i = _myPacks
                        .indexWhere((k) => k.name.toLowerCase() ==
                            pack.name.toLowerCase());
                    if (i >= 0) {
                      _myPacks[i] = pack;
                    } else {
                      _myPacks.add(pack);
                    }
                    _pack = i >= 0 ? i : _myPacks.length - 1;
                    _persistPacks();
                    Navigator.pop(c);
                    setState(() {});
                  },
                ),
              ),
            ]),
      ),
    );
  }

  /// Shown BEFORE first SOS/beacon use while SMS isn't granted yet —
  /// explains the one-time Android unlock so auto-send works when needed.
  Future<void> _smsSetupGuide() async {
    try {
      final status = await _sms.invokeMethod<String>('status');
      if (status == 'granted' || !mounted) return;
      await showDialog(
        context: context,
        builder: (c) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          icon: const Icon(Icons.sms_rounded, color: Colors.teal, size: 36),
          title: const Text('One-time SMS setup'),
          content: const Text(
              'For SOS to send automatically, allow SMS once.\n\n'
              'When Android asks, tap Allow.\n\n'
              'If Android says "restricted setting":\n'
              '1. Open the app\'s settings (button below)\n'
              '2. Tap the ⋮ menu (top-right)\n'
              '3. "Allow restricted settings"\n'
              '4. Permissions → SMS → Allow'),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            OutlinedButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('Continue')),
            FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.teal),
                onPressed: () {
                  _sms.invokeMethod('openSettings');
                  Navigator.pop(c);
                },
                child: const Text('Open settings')),
          ],
        ),
      );
    } catch (_) {}
  }

  Future<Position?> _gps() async {
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) return null;
      return await Geolocator.getCurrentPosition(
              locationSettings:
                  const LocationSettings(accuracy: LocationAccuracy.high))
          .timeout(const Duration(seconds: 12),
              onTimeout: () async =>
                  (await Geolocator.getLastKnownPosition())!);
    } catch (_) {
      return Geolocator.getLastKnownPosition();
    }
  }

  /// Send DIRECTLY via the carrier (SmsManager). If the permission was
  /// denied with "don't ask again", guides the user to app settings; as a
  /// last resort opens the SMS app prefilled so the message still goes out.
  Future<bool> _sendSms(String to, String body) async {
    try {
      final ok =
          await _sms.invokeMethod<bool>('send', {'to': to, 'body': body});
      if (ok == true) return true;
      final status = await _sms.invokeMethod<String>('status');
      if (status == 'blocked' && mounted) {
        final open = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20)),
            icon: const Icon(Icons.sms_failed_rounded,
                color: Colors.red, size: 36),
            title: const Text('Unlock SMS permission'),
            content: const Text(
                'Android blocks SMS for apps installed outside Play Store '
                'until you unlock it once:\n\n'
                '1. Open the app\'s settings page (button below)\n'
                '2. Tap the ⋮ menu (top-right)\n'
                '3. Tap "Allow restricted settings"\n'
                '4. Then Permissions → SMS → Allow',
                textAlign: TextAlign.left),
            actionsAlignment: MainAxisAlignment.center,
            actions: [
              OutlinedButton(
                  onPressed: () => Navigator.pop(c, false),
                  child: const Text('Not now')),
              FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: Colors.teal),
                  onPressed: () => Navigator.pop(c, true),
                  child: const Text('Open settings')),
            ],
          ),
        );
        if (open == true) await _sms.invokeMethod('openSettings');
      }
    } catch (_) {}
    await launchUrl(
        Uri(scheme: 'sms', path: to, queryParameters: {'body': body}),
        mode: LaunchMode.externalApplication);
    return false;
  }

  /// Full guide — every detail lives here, not scattered on the page.
  void _showGuide() {
    Haptics.light();
    showDialog(
      context: context,
      builder: (c) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(children: [
                    Icon(Icons.terrain_rounded, color: Colors.teal),
                    SizedBox(width: 8),
                    Text('How Tour Mode works',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 17)),
                  ]),
                  const SizedBox(height: 14),
                  _guideRow(Icons.wifi_off_rounded, 'Works offline',
                      'Everything here runs without internet. SOS and alerts '
                      'go as SMS through your carrier — they deliver on bare '
                      '2G signal with zero data.'),
                  _guideRow(Icons.sos_rounded, 'SOS',
                      'One tap auto-sends your live GPS location to your '
                      'saved contact (or 112). Grant the SMS permission once '
                      'when asked so it can send by itself.'),
                  _guideRow(Icons.podcasts_rounded, 'Trip beacon',
                      'Save where you\'re going and when you\'ll be back. At '
                      'the deadline you get a reminder; 15 minutes later, if '
                      'you haven\'t checked in, your contact is alerted '
                      'AUTOMATICALLY with your plan and last location — even '
                      'if the app is closed or the phone restarted.'),
                  _guideRow(Icons.hiking_rounded, 'Survival packs',
                      'Search any place or tap the location button. Packs '
                      'hold fair taxi rates, altitude & health info and '
                      'signal dead zones. Save them for offline; they '
                      'refresh weekly. Rates are indicative — always confirm '
                      'before boarding.'),
                  _guideRow(Icons.call_rounded, 'Emergency numbers',
                      'National numbers are official (112, 108, 1077, 1363). '
                      'Numbers inside packs are checked against official '
                      'government sources.'),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                        style: FilledButton.styleFrom(
                            backgroundColor: Colors.teal),
                        onPressed: () => Navigator.pop(c),
                        child: const Text('Got it')),
                  ),
                ]),
          ),
        ),
      ),
    );
  }

  Widget _guideRow(IconData ic, String title, String body) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(ic, size: 18, color: Colors.teal),
          const SizedBox(width: 10),
          Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(title,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 13.5)),
                Text(body,
                    style: TextStyle(
                        fontSize: 12.5, height: 1.4,
                        color: ink(context).withValues(alpha: .7))),
              ])),
        ]),
      );

  String _locLink(Position? pos) => pos == null
      ? 'location unavailable'
      : 'https://maps.google.com/?q=${pos.latitude},${pos.longitude}';

  // ── SOS ────────────────────────────────────────────────────────────────
  Future<void> _sos() async {
    Haptics.heavy();
    await _smsSetupGuide();
    if (!mounted) return;
    final to = _contact.isNotEmpty ? _contact : '112';
    final posF = _gps(); // fix GPS while the user confirms
    final send = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        icon: const Icon(Icons.sos_rounded, color: Colors.red, size: 40),
        title: const Text('Send SOS now?'),
        content: Text(
            'An SMS with your live location is sent automatically to '
            '${_contact.isNotEmpty ? _contact : 'emergency services (112)'} '
            'through your carrier — it works even when data is dead.',
            textAlign: TextAlign.center),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          OutlinedButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('SEND SOS')),
        ],
      ),
    );
    if (send != true || !mounted) return;
    await _fireSos(pos: await posF);
  }

  /// Actually send the SOS. [silent] skips the confirm (shake path already
  /// gave a cancellable countdown).
  Future<void> _fireSos({Position? pos, bool silent = false}) async {
    final to = _contact.isNotEmpty ? _contact : '112';
    pos ??= await _gps();
    // Also shout over Bluetooth so nearby app users can relay when there
    // is no tower at all.
    if (pos != null) {
      _bleCtl.invokeMethod('advertise',
          {'lat': pos.latitude, 'lon': pos.longitude}).catchError((_) => null);
    }
    final sent = await _sendSms(to,
        'SOS — I need help. My location: ${_locLink(pos)} (Mr.Tour Guide Tour Mode)');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: sent ? Colors.teal : null,
        content: Text(sent
            ? '✓ SOS delivered to $to with your location.'
            : 'Opened your SMS app — press send to deliver.')));
  }

  // ── Trip beacon ────────────────────────────────────────────────────────
  Future<void> _beaconSheet() async {
    Haptics.light();
    await _smsSetupGuide();
    if (!mounted) return;
    final planCtl = TextEditingController(text: _plan);
    final contactCtl = TextEditingController(text: _contact);
    DateTime? backBy = _backBy;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (c) => StatefulBuilder(
        builder: (c, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(
              20, 16, 20, MediaQuery.of(c).viewInsets.bottom + 24),
          child: Column(mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                    child: Container(
                        width: 36, height: 4,
                        decoration: BoxDecoration(
                            color: Colors.grey.withValues(alpha: .4),
                            borderRadius: BorderRadius.circular(2)))),
                const SizedBox(height: 16),
                const Row(children: [
                  Icon(Icons.podcasts_rounded, color: Colors.teal),
                  SizedBox(width: 8),
                  Text('Set trip beacon',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 17)),
                ]),
                const SizedBox(height: 6),
                const SizedBox(height: 14),
                TextField(
                    controller: planCtl,
                    decoration: const InputDecoration(
                        labelText: 'Where are you going?',
                        hintText: 'e.g. Kasol → Tosh trek',
                        border: OutlineInputBorder())),
                const SizedBox(height: 10),
                TextField(
                    controller: contactCtl,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                        labelText: 'Emergency contact number',
                        border: OutlineInputBorder())),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  icon: const Icon(Icons.schedule_rounded, size: 18),
                  label: Text(backBy == null
                      ? 'Expected back by…'
                      : 'Back by ${TimeOfDay.fromDateTime(backBy!).format(c)}'),
                  onPressed: () async {
                    final t = await showTimePicker(
                        context: c, initialTime: TimeOfDay.now());
                    if (t == null) return;
                    final now = DateTime.now();
                    var dt = DateTime(
                        now.year, now.month, now.day, t.hour, t.minute);
                    if (dt.isBefore(now)) dt = dt.add(const Duration(days: 1));
                    setSheet(() => backBy = dt);
                  },
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                        backgroundColor: Colors.teal,
                        padding: const EdgeInsets.symmetric(vertical: 14)),
                    onPressed: () async {
                      if (planCtl.text.trim().isEmpty || backBy == null) return;
                      final p = await SharedPreferences.getInstance();
                      _plan = planCtl.text.trim();
                      _contact = contactCtl.text.trim();
                      _backBy = backBy;
                      await p.setString('hill.plan', _plan);
                      await p.setString('hill.contact', _contact);
                      await p.setInt(
                          'hill.backBy', _backBy!.millisecondsSinceEpoch);
                      // Process-independent safety net: exact AlarmManager
                      // alarms fire even if the app is killed — reminder at
                      // the deadline, AUTO-SMS alert 15 min later, and both
                      // re-arm after a phone reboot.
                      try {
                        await _beacon.invokeMethod('arm',
                            {'at': _backBy!.millisecondsSinceEpoch});
                      } catch (_) {}
                      await LocalNotifsSchedule.scheduleAt(
                          _beaconNotifId,
                          'Are you back safe?',
                          'Trip beacon: "$_plan". Open Hill Mode to check in '
                              '— otherwise your contact is alerted '
                              'automatically in 15 min.',
                          _backBy!);
                      Haptics.medium();
                      if (c.mounted) Navigator.pop(c);
                      if (mounted) setState(() {});
                    },
                    child: const Text('Set beacon',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ]),
        ),
      ),
    );
  }

  Future<void> _checkIn() async {
    Haptics.medium();
    try { await _beacon.invokeMethod('cancel'); } catch (_) {}
    await LocalNotifsSchedule.cancelId(_beaconNotifId);
    final p = await SharedPreferences.getInstance();
    await p.remove('hill.plan');
    await p.remove('hill.backBy');
    setState(() { _plan = ''; _backBy = null; });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          backgroundColor: Colors.teal,
          content: Text('Checked in — beacon cleared. Welcome back!')));
    }
  }

  Future<void> _alertContact() async {
    if (_contact.isEmpty) return;
    Haptics.heavy();
    final confirm = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        icon: const Icon(Icons.campaign_rounded, color: Colors.red, size: 36),
        title: const Text('Alert your contact?'),
        content: Text('Auto-sends an SMS to $_contact with your plan and '
            'current location.', textAlign: TextAlign.center),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          OutlinedButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Send alert')),
        ],
      ),
    );
    if (confirm != true) return;
    final pos = await _gps();
    final sent = await _sendSms(_contact,
        'ALERT: I have not checked in from my trip: "$_plan". '
        'Last location: ${_locLink(pos)} — Mr.Tour Guide Hill Mode');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: sent ? Colors.teal : null,
        content: Text(sent
            ? 'Alert sent to $_contact.'
            : 'Opened your SMS app — press send to deliver.')));
  }

  // ── UI ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final pack = _myPacks.isEmpty ? _seedPacks[0] : _myPacks[_pack];
    return Scaffold(
      appBar: AppBar(
        title: const Row(children: [
          Icon(Icons.terrain_rounded, color: Colors.teal),
          SizedBox(width: 8),
          Text('Tour Mode'),
        ]),
        actions: [
          IconButton(
              tooltip: 'How it works',
              onPressed: _showGuide,
              icon: const Icon(Icons.info_outline_rounded)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Survival pack (primary content — searchable, saved offline) ──
          Row(children: [
            const Text('Survival pack',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const Spacer(),
            if (_fetching)
              const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.teal)),
          ]),
          const SizedBox(height: 8),
          TextField(
            controller: _searchCtl,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _getPack(),
            decoration: InputDecoration(
              hintText: 'Search any place — Leh, Munnar, Bali…',
              isDense: true,
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              suffixIcon: IconButton(
                  tooltip: 'Fetch pack',
                  onPressed: _fetching ? null : _getPack,
                  icon: const Icon(Icons.download_rounded, size: 20)),
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (var i = 0; i < _myPacks.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: InputChip(
                      label: Text(_myPacks[i].name),
                      selected: _pack == i,
                      selectedColor: Colors.teal,
                      labelStyle: TextStyle(
                          color: _pack == i ? Colors.white : ink(context)),
                      onSelected: (_) {
                        Haptics.tick();
                        setState(() => _pack = i);
                      },
                      onDeleted: _myPacks.length > 1
                          ? () {
                              setState(() {
                                _myPacks.removeAt(i);
                                if (_pack >= _myPacks.length) {
                                  _pack = _myPacks.length - 1;
                                }
                              });
                              _persistPacks();
                            }
                          : null,
                      deleteIconColor: _pack == i ? Colors.white70 : null,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          _info(Icons.local_taxi_rounded, 'Fair taxi rates', pack.taxi),
          _info(Icons.favorite_rounded, 'Altitude & health', pack.tips),
          _info(Icons.signal_cellular_off_rounded, 'Signal dead zones',
              pack.deadZones),
          if (pack.sources.isNotEmpty)
            _info(Icons.verified_rounded, 'Verified sources',
                pack.sources.join('\n')),
          if (pack.updatedAt != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                  'Updated ${DateTime.now().difference(pack.updatedAt!).inDays} day(s) ago — refreshes weekly.',
                  style: TextStyle(
                      fontSize: 11, color: ink(context).withValues(alpha: .45))),
            ),
          const SizedBox(height: 20),

          // SOS
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                  backgroundColor: Colors.red,
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16))),
              onPressed: _sos,
              icon: const Icon(Icons.sos_rounded, size: 26),
              label: const Text('SOS',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
          ),
          const SizedBox(height: 10),
          Card(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: SwitchListTile(
              value: _shakeOn,
              onChanged: (v) {
                Haptics.tick();
                _setShake(v);
              },
              activeThumbColor: Colors.teal,
              secondary:
                  const Icon(Icons.vibration_rounded, color: Colors.red),
              title: const Text('Shake for SOS',
                  style:
                      TextStyle(fontWeight: FontWeight.bold, fontSize: 14.5)),
              subtitle: const Text('Shake hard 3× — 5s to cancel'),
            ),
          ),
          const SizedBox(height: 10),
          Card(
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16)),
            child: ExpansionTile(
              shape: const Border(),
              leading: const Icon(Icons.call_rounded, color: Colors.red),
              title: const Text('Emergency contacts',
                  style: TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 14.5)),
              children: [
                for (final h in _helplines)
                  ListTile(
                    dense: true,
                    leading: Text(h.$1,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 15)),
                    title: Text(h.$2, style: const TextStyle(fontSize: 13)),
                    trailing: const Icon(Icons.call_rounded,
                        size: 18, color: Colors.teal),
                    onTap: () => launchUrl(Uri(scheme: 'tel', path: h.$1)),
                  ),
                for (final h in (_myPacks.isEmpty
                        ? const <List<String>>[]
                        : _myPacks[_pack].helplines))
                  ListTile(
                    dense: true,
                    leading: Text(h.first,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 15)),
                    title: Text(h.length > 1 ? h[1] : 'Local helpline',
                        style: const TextStyle(fontSize: 13)),
                    subtitle: Text(_myPacks[_pack].name,
                        style: const TextStyle(fontSize: 11)),
                    trailing: const Icon(Icons.call_rounded,
                        size: 18, color: Colors.teal),
                    onTap: () => launchUrl(Uri(scheme: 'tel', path: h.first)),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 18),

          // Trip beacon card
          Card(
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: _plan.isNotEmpty && _backBy != null
                  ? Column(crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          const Icon(Icons.podcasts_rounded,
                              color: Colors.teal),
                          const SizedBox(width: 8),
                          const Text('Beacon active',
                              style: TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 16)),
                          const Spacer(),
                          Text(
                              'back by ${TimeOfDay.fromDateTime(_backBy!).format(context)}',
                              style: const TextStyle(
                                  color: Colors.teal,
                                  fontWeight: FontWeight.w600)),
                        ]),
                        const SizedBox(height: 6),
                        Text('"$_plan"',
                            style: TextStyle(
                                color: ink(context).withValues(alpha: .75))),
                        const SizedBox(height: 12),
                        Row(children: [
                          Expanded(
                              child: FilledButton(
                                  style: FilledButton.styleFrom(
                                      backgroundColor: Colors.teal),
                                  onPressed: _checkIn,
                                  child: const Text('I\'m back safe'))),
                          const SizedBox(width: 10),
                          Expanded(
                              child: OutlinedButton(
                                  style: OutlinedButton.styleFrom(
                                      foregroundColor: Colors.red),
                                  onPressed: _alertContact,
                                  child: const Text('Alert contact'))),
                        ]),
                      ])
                  : ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading:
                          const Icon(Icons.podcasts_rounded, color: Colors.teal),
                      title: const Text('Trip beacon',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: const Text('Check-in safety net'),
                      trailing: FilledButton(
                          style: FilledButton.styleFrom(
                              backgroundColor: Colors.teal),
                          onPressed: _beaconSheet,
                          child: const Text('Set up')),
                    ),
            ),
          ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }

  Widget _info(IconData ic, String title, String body) => Card(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(ic, size: 18, color: Colors.teal),
              const SizedBox(width: 8),
              Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            ]),
            const SizedBox(height: 6),
            Text(body, style: const TextStyle(fontSize: 13, height: 1.45)),
          ]),
        ),
      );
}
