import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'constant.dart';
import 'main.dart';
import 'services/api_base.dart';
import 'services/app_info.dart';
import 'services/auth_api.dart';
import 'services/haptic_service.dart';
import 'services/local_notifs.dart';
import 'services/media_api.dart';
import 'services/settings_service.dart';
import 'services/update_service.dart';
import 'widgets/feedback_dialog.dart';
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
                    if ((v * 10).round() != (s.intensity * 10).round()) {
                      Haptics.level(v); // feel each level as you scrub
                    }
                    _update(() => s.intensity = v);
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
          _section('Account', [
            ListTile(
              leading: const Icon(Icons.person_remove, color: red),
              title: const Text('Delete profile', style: TextStyle(color: red)),
              subtitle: const Text('Permanently removes your account and data',
                  style: TextStyle(fontSize: 11.5, color: Colors.grey)),
              onTap: _deleteProfile,
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

  Future<void> _checkForUpdate() async {
    final info = await UpdateService.check();
    if (!mounted) return;
    if (info == null) {
      newSnackBar(context, title: 'Could not check for updates.');
    } else if (!info.isNewer) {
      newSnackBar(context, title: 'You are on the latest version.');
    } else {
      await runUpdateFlow(context, info);
    }
  }

  /// Permanent account deletion: double confirmation, then the backend
  /// removes the account with its posts, itineraries and uploads.
  Future<void> _deleteProfile() async {
    final user = AuthApi.currentUser;
    if (user == null) {
      newSnackBar(context, title: 'Sign in first.');
      return;
    }
    final ok = await confirmDialog(
      context,
      title: 'Delete your profile?',
      message: 'This permanently deletes your account, your community posts, '
          'saved itineraries and uploads. This cannot be undone.',
      confirmLabel: 'Delete forever',
      destructive: true,
    );
    if (!ok || !mounted) return;
    final really = await confirmDialog(
      context,
      title: 'Are you absolutely sure?',
      message: 'Your account "${user.name}" will be gone for good.',
      confirmLabel: 'Yes, delete',
      destructive: true,
    );
    if (!really || !mounted) return;
    try {
      await MediaApi.deleteAccount(user.id);
      await AuthApi.signOut();
      if (!mounted) return;
      newSnackBar(context, title: 'Your profile has been deleted.');
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (context) => const HomePage()),
        (route) => false,
      );
    } on AuthException catch (e) {
      if (mounted) newSnackBar(context, title: e.message);
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
