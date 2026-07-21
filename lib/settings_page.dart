import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'constant.dart';
import 'main.dart';
import 'services/api_base.dart';
import 'services/app_info.dart';
import 'services/auth_api.dart';
import 'services/haptic_service.dart';
import 'services/settings_service.dart';
import 'services/update_service.dart';
import 'widgets/feedback_dialog.dart';
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
              subtitle: const Text('Easier on the eyes at night'),
              value: s.darkMode,
              activeThumbColor: blue,
              onChanged: (v) => _update(() => s.darkMode = v),
            ),
          ]),
          _section('Feel', [
            SwitchListTile(
              secondary: const Icon(Icons.vibration, color: Colors.purple),
              title: const Text('Haptics'),
              subtitle: const Text('Feel every experience through your phone'),
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
              subtitle: const Text(
                  'Buttons and cards respond with graded vibration — like a '
                  'plucked string'),
              value: s.uiHaptics,
              activeThumbColor: blue,
              onChanged: (v) => _update(() => s.uiHaptics = v),
            ),
          ]),
          _section('Sound & playback', [
            SwitchListTile(
              secondary: const Icon(Icons.volume_up, color: blue),
              title: const Text('Sound'),
              subtitle: const Text('Play experience audio by default'),
              value: s.sound,
              activeThumbColor: blue,
              onChanged: (v) => _update(() => s.sound = v),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.play_circle, color: blue),
              title: const Text('Autoplay'),
              subtitle: const Text('Start playing as soon as you open'),
              value: s.autoplay,
              activeThumbColor: blue,
              onChanged: (v) => _update(() => s.autoplay = v),
            ),
          ]),
          _section('Accessibility', [
            SwitchListTile(
              secondary:
                  const Icon(Icons.accessibility_new, color: Colors.green),
              title: const Text('Reduce motion'),
              subtitle:
                  const Text('Minimize animations for a calmer experience'),
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
              leading: const Icon(Icons.logout, color: red),
              title: const Text('Log out', style: TextStyle(color: red)),
              onTap: _logout,
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
      final go = await confirmDialog(
        context,
        title: 'Update available',
        message: 'v${info.version} (build ${info.buildNumber})\n${info.notes}'
            '\n\nDownload now? Old builds are cleaned up automatically '
            'after install.',
        confirmLabel: 'Download',
      );
      if (go && mounted) {
        launchUrl(Uri.parse(info.apkAvailable ? info.absoluteApkUrl : apiBase));
      }
    }
  }

  Future<void> _logout() async {
    final ok = await confirmDialog(
      context,
      title: 'Log out?',
      message: 'You will return to the welcome screen.',
      confirmLabel: 'Log out',
      destructive: true,
    );
    if (!ok || !mounted) return;
    AuthApi.currentUser = null;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (context) => const HomePage()),
      (route) => false,
    );
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
