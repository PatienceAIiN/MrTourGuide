import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'constant.dart';
import 'ar_view.dart';
import 'main.dart';
import 'services/api_base.dart';
import 'services/app_info.dart';
import 'services/auth_api.dart';
import 'services/haptic_service.dart';
import 'services/local_notifs.dart';
import 'navpages/my_page.dart';
import 'services/api_base.dart';
import 'services/media_api.dart';
import 'services/push_service.dart';
import 'services/settings_service.dart';
import 'services/update_service.dart';
import 'widgets/feedback_dialog.dart';
import 'widgets/legal_sheet.dart';
import 'widgets/update_flow.dart';
import 'widgets/ux.dart';

/// Tailor-your-experience settings (persisted on this device).
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final s = SettingsService.instance;

  @override
  void initState() {
    super.initState();
    s.load().then((_) {
      if (mounted) setState(() {});
    });
  }

  void _update(void Function() change) {
    setState(change);
    s.save();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: pageBg(context),
      appBar: AppBar(
        backgroundColor: cardBg(context),
        elevation: 0,
        iconTheme: IconThemeData(color: ink(context)),
        title: Text('Experience Settings',
            style: TextStyle(color: ink(context), fontWeight: FontWeight.bold)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Profile lives here now — tap for the full profile in a modal.
          Card(
            color: cardBg(context),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: ListTile(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              leading: CircleAvatar(
                radius: 24,
                backgroundColor: blue,
                backgroundImage: AuthApi.currentUser?.avatarUrl != null
                    ? CachedNetworkImageProvider(
                        '$apiBase${AuthApi.currentUser!.avatarUrl}')
                    : null,
                child: AuthApi.currentUser?.avatarUrl == null
                    ? Text(
                        (AuthApi.currentUser?.name.isNotEmpty ?? false)
                            ? AuthApi.currentUser!.name[0].toUpperCase()
                            : '?',
                        style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: white),
                      )
                    : null,
              ),
              title: Text(AuthApi.currentUser?.name ?? 'Guest',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 16)),
              subtitle: Text(AuthApi.currentUser?.email ?? 'Not signed in',
                  style: const TextStyle(fontSize: 12.5, color: Colors.grey)),
              trailing: const Icon(Icons.chevron_right, color: blue),
              onTap: _openProfileModal,
            ),
          ),
          const SizedBox(height: 16),
          _section('Appearance', [
            SwitchListTile(
              secondary: Icon(s.darkMode ? Icons.dark_mode : Icons.light_mode,
                  color: Colors.indigo),
              title: const Text('Dark theme'),
              value: s.darkMode,
              activeThumbColor: blue,
              onChanged: (v) => _update(() => s.darkMode = v),
            ),
          ]),
          _section('Feel', [
            SwitchListTile(
              secondary: const Icon(Icons.vibration, color: Colors.purple),
              title: const Text('Haptics'),
              value: s.haptics,
              activeThumbColor: blue,
              onChanged: (v) => _update(() => s.haptics = v),
            ),
            if (s.haptics)
              ListTile(
                leading: const Icon(Icons.waves, color: Colors.purple),
                title: const Text('Feel intensity'),
                subtitle: Slider(
                  value: s.intensity,
                  divisions: 10,
                  label: '${(s.intensity * 100).round()}%',
                  activeColor: Colors.purpleAccent,
                  onChanged: (v) {
                    final changed =
                        (v * 10).round() != (s.intensity * 10).round();
                    // Set first so the buzz uses the new strength — like the
                    // Android volume slider, higher = stronger as you drag.
                    _update(() => s.intensity = v);
                    if (changed) Haptics.level(1.0);
                  },
                ),
              ),
            SwitchListTile(
              secondary: const Icon(Icons.touch_app, color: Colors.purple),
              title: const Text('UI touch feedback'),
              value: s.uiHaptics,
              activeThumbColor: blue,
              onChanged: (v) => _update(() => s.uiHaptics = v),
            ),
          ]),
          _section('Sound & playback', [
            SwitchListTile(
              secondary: const Icon(Icons.volume_up, color: blue),
              title: const Text('Sound'),
              value: s.sound,
              activeThumbColor: blue,
              onChanged: (v) => _update(() => s.sound = v),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.play_circle, color: blue),
              title: const Text('Autoplay'),
              value: s.autoplay,
              activeThumbColor: blue,
              onChanged: (v) => _update(() => s.autoplay = v),
            ),
          ]),
          _section('Notifications', [
            SwitchListTile(
              secondary:
                  const Icon(Icons.notifications_active, color: Colors.orange),
              title: const Text('New content alerts'),
              value: s.notifications,
              activeThumbColor: blue,
              onChanged: (v) {
                _update(() => s.notifications = v);
                if (v) {
                  // Prove it works the moment they switch it on.
                  LocalNotifs.show(
                      'Notifications active 🔔',
                      'You will now hear about new experiences, replies '
                          'and updates.');
                }
              },
            ),
            SwitchListTile(
              secondary: const Icon(Icons.my_location, color: Colors.teal),
              title: const Text('My location only'),
              value: s.locationNotifs,
              activeThumbColor: blue,
              onChanged: (v) async {
                if (v) {
                  // Explain the trade-off before narrowing their alerts.
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18)),
                      icon: const Icon(Icons.my_location,
                          color: Colors.teal, size: 34),
                      title: const Text('Only your location?'),
                      content: const Text(
                        'You will get new-experience alerts only for your '
                        'current city. Alerts from every other place stay '
                        'silent.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 13.5, height: 1.5),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Deny'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('OK'),
                        ),
                      ],
                    ),
                  );
                  if (ok != true) return;
                }
                _update(() => s.locationNotifs = v);
                // Tell the server so targeting changes immediately.
                PushService.refreshRegistration();
              },
            ),
          ]),
          _section('Immersive', [
            ListTile(
              leading:
                  const Icon(Icons.view_in_ar_rounded, color: Colors.purple),
              title: const Text('MR / VR mode'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                // Confirm before the immersive hand-off.
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18)),
                    icon: const Icon(Icons.view_in_ar_rounded,
                        color: Colors.purple, size: 34),
                    title: const Text('Enter MR / VR?'),
                    content: const Text(
                      'Step inside places in mixed / virtual reality. '
                      'Works best with a headset or Google Cardboard.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13.5, height: 1.5),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Deny'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('OK'),
                      ),
                    ],
                  ),
                );
                if (ok == true && context.mounted) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (context) => const ArViewPage()),
                  );
                }
              },
            ),
          ]),
          _section('Accessibility', [
            SwitchListTile(
              secondary:
                  const Icon(Icons.accessibility_new, color: Colors.green),
              title: const Text('Reduce motion'),
              value: s.reduceMotion,
              activeThumbColor: blue,
              onChanged: (v) => _update(() => s.reduceMotion = v),
            ),
          ]),
          _section('Legal', [
            ListTile(
              leading: const Icon(Icons.policy_outlined, color: blue),
              title: const Text('Terms & Privacy'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showLegalSheet(context),
            ),
          ]),
          _section('Feedback & updates', [
            ListTile(
              leading: const Icon(Icons.feedback_outlined, color: Colors.teal),
              title: const Text('Share feedback'),
              subtitle: const Text('Tell us how MrTouride feels'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showFeedbackDialog(context),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.system_update, color: Colors.indigo),
              title: const Text('Check for updates'),
              subtitle: Text('You are on v$appVersion (build $appBuildNumber)'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _checkForUpdate,
            ),
          ]),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Your settings always win over a video\'s creator defaults — '
              'the experience adapts to you.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  /// The full profile — everything as before — inside a popup modal.
  void _openProfileModal() {
    Haptics.light();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.92,
        maxChildSize: 0.96,
        minChildSize: 0.5,
        builder: (context, scroll) => ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          child: const MyPage(),
        ),
      ),
    ).then((_) {
      if (mounted) setState(() {}); // avatar/name may have changed
    });
  }

  Future<void> _checkForUpdate() async {
    final info = await showBusyWhile(context, UpdateService.check(),
        label: 'Checking…');
    if (!mounted) return;
    if (info == null) {
      newSnackBar(context, title: 'Could not check for updates.');
    } else if (info.isNewer) {
      // Update available → the update flow (its sheet shows what's new).
      await runUpdateFlow(context, info);
    } else {
      // Already current → show THIS version's changelog instead of a bare
      // "you're up to date" snackbar.
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          icon: const Icon(Icons.verified, color: Colors.green, size: 34),
          title: Text("You're up to date — v$appVersion"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("What's new in this version",
                  style:
                      TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: SingleChildScrollView(
                  child: Text(
                    info.notes.isEmpty
                        ? 'General fixes and improvements.'
                        : info.notes,
                    style: const TextStyle(fontSize: 13, height: 1.5),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  Widget _section(String title, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 8, bottom: 8),
            child: Text(title,
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          ),
          Card(
            color: cardBg(context),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Column(children: children),
          ),
        ],
      ),
    );
  }
}
