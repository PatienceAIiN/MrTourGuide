import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../constant.dart';
import '../services/api_base.dart';
import '../main.dart';
import '../services/auth_api.dart';
import '../services/media_api.dart';

/// Profile tab: account info, experience-library stats, sign out.
class MyPage extends StatefulWidget {
  final void Function(int index)? onSelectTab;
  const MyPage({super.key, this.onSelectTab});

  @override
  State<MyPage> createState() => _MyPageState();
}

class _MyPageState extends State<MyPage> {
  List<City>? cities;
  String? error;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    try {
      final result = await MediaApi.fetchCities();
      if (!mounted) return;
      setState(() {
        cities = result;
        error = null;
      });
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() => error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = AuthApi.currentUser;
    final totalVideos =
        cities?.fold<int>(0, (sum, c) => sum + c.videoCount) ?? 0;

    return Scaffold(
      backgroundColor: pageBg(context),
      appBar: AppBar(
        backgroundColor: cardBg(context),
        elevation: 0,
        iconTheme: IconThemeData(color: ink(context)),
        title: Text('My Profile',
            style: TextStyle(color: ink(context), fontWeight: FontWeight.bold)),
      ),
      body: RefreshIndicator(
        onRefresh: _loadStats,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              color: cardBg(context),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    Stack(
                      children: [
                        CircleAvatar(
                          radius: 32,
                          backgroundColor: blue,
                          backgroundImage: user?.avatarUrl != null
                              ? NetworkImage('$apiBase${user!.avatarUrl}')
                              : null,
                          child: user?.avatarUrl == null
                              ? Text(
                                  (user?.name.isNotEmpty ?? false)
                                      ? user!.name[0].toUpperCase()
                                      : '?',
                                  style: const TextStyle(
                                      fontSize: 28,
                                      fontWeight: FontWeight.bold,
                                      color: white),
                                )
                              : null,
                        ),
                        if (user != null)
                          Positioned(
                            right: -2,
                            bottom: -2,
                            child: InkWell(
                              onTap: _changeAvatar,
                              customBorder: const CircleBorder(),
                              child: Container(
                                padding: const EdgeInsets.all(5),
                                decoration: BoxDecoration(
                                  color: cardBg(context),
                                  shape: BoxShape.circle,
                                  border: Border.all(color: blue, width: 1.5),
                                ),
                                child: const Icon(Icons.photo_camera,
                                    size: 14, color: blue),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            user?.name ?? 'Guest',
                            style: const TextStyle(
                                fontSize: 20, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            user?.email ?? 'Not signed in',
                            style: const TextStyle(
                                color: Colors.grey, fontSize: 14),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (error != null)
              Card(
                color: red.withValues(alpha: 0.1),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(error!, style: const TextStyle(color: red)),
                ),
              )
            else
              Row(
                children: [
                  _statCard('Cities', '${cities?.length ?? '—'}',
                      Icons.location_city),
                  const SizedBox(width: 12),
                  _statCard(
                      'Experience videos', '$totalVideos', Icons.video_library),
                ],
              ),
            const SizedBox(height: 16),
            Card(
              color: cardBg(context),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.video_library, color: blue),
                    title: const Text('Open Experience Dashboard'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => widget.onSelectTab?.call(1),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.logout, color: red),
                    title: const Text('Sign out', style: TextStyle(color: red)),
                    onTap: () {
                      AuthApi.currentUser = null;
                      Navigator.of(context).pushAndRemoveUntil(
                        MaterialPageRoute(
                            builder: (context) => const HomePage()),
                        (route) => false,
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _changeAvatar() async {
    final picked = await FilePicker.platform
        .pickFiles(type: FileType.image, withData: true);
    final file = picked?.files.single;
    if (file == null || file.bytes == null || !mounted) return;
    if (file.bytes!.length > 5 * 1024 * 1024) {
      newSnackBar(context, title: 'Profile pictures are limited to 5 MB.');
      return;
    }
    try {
      final url = await MediaApi.uploadAvatar(file.name, file.bytes!);
      if (!mounted) return;
      setState(() => AuthApi.currentUser?.avatarUrl = url);
      newSnackBar(context, title: 'Profile picture updated.');
    } on AuthException catch (e) {
      if (mounted) newSnackBar(context, title: e.message);
    }
  }

  Future<void> _editAbout() async {
    final controller =
        TextEditingController(text: AuthApi.currentUser?.about ?? '');
    final about = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('About you'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 300,
          maxLines: 3,
          decoration: const InputDecoration(
              hintText: 'A short bio shown on your profile…'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    if (about == null || !mounted) return;
    try {
      await MediaApi.updateAbout(about);
      if (!mounted) return;
      setState(() => AuthApi.currentUser?.about = about);
      newSnackBar(context, title: 'Bio saved.');
    } on AuthException catch (e) {
      if (mounted) newSnackBar(context, title: e.message);
    }
  }

  Widget _statCard(String label, String value, IconData icon) {
    return Expanded(
      child: Card(
        color: cardBg(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Icon(icon, color: blue, size: 28),
              const SizedBox(height: 8),
              Text(value,
                  style: const TextStyle(
                      fontSize: 22, fontWeight: FontWeight.bold)),
              Text(label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.grey, fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }
}
