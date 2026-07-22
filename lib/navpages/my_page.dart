import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../constant.dart';
import '../services/api_base.dart';
import '../main.dart';
import '../services/auth_api.dart';
import '../services/haptic_service.dart';
import '../services/media_api.dart';
import '../widgets/image_viewer.dart';
import '../widgets/ux.dart';

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
  List<SavedItinerary> itineraries = [];
  int itinPage = 0;
  static const int _itinPageSize = 3;

  /// Visuals per saved itinerary (lazy, server-cached 30 min per query).
  final Map<int, MediaSuggestions> itinMedia = {};

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    _loadItineraries();
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

  Future<void> _loadItineraries() async {
    final user = AuthApi.currentUser;
    if (user == null) return;
    try {
      final list = await MediaApi.fetchItineraries(user.id);
      if (mounted) {
        setState(() {
          itineraries = list;
          itinPage = 0;
        });
      }
    } catch (_) {}
  }

  void _loadItinMedia(SavedItinerary item) {
    if (itinMedia.containsKey(item.id)) return;
    itinMedia[item.id] = const MediaSuggestions(images: [], youtube: []);
    MediaApi.searchMedia(item.query.isEmpty ? item.title : item.query)
        .then((m) {
      if (mounted) setState(() => itinMedia[item.id] = m);
    }).catchError((_) {});
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
                          if (user != null) ...[
                            const SizedBox(height: 6),
                            InkWell(
                              onTap: _editAbout,
                              borderRadius: BorderRadius.circular(6),
                              child: Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      (user.about?.isNotEmpty ?? false)
                                          ? user.about!
                                          : 'Add a short bio\u2026',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          color: Colors.grey,
                                          fontSize: 12.5,
                                          height: 1.35),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  const Icon(Icons.edit,
                                      size: 13, color: Colors.grey),
                                ],
                              ),
                            ),
                          ],
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
            if (itineraries.isNotEmpty) ...[
              const SizedBox(height: 16),
              _itinerariesCard(),
            ],
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
                    onTap: _signOut,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.person_remove, color: red),
                    title: const Text('Delete profile',
                        style: TextStyle(color: red)),
                    subtitle: const Text(
                        'Permanently removes your account and data',
                        style: TextStyle(fontSize: 11.5, color: Colors.grey)),
                    onTap: _deleteProfile,
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

  Future<void> _signOut() async {
    final ok = await confirmDialog(
      context,
      title: 'Sign out?',
      message: 'You will return to the welcome screen.',
      confirmLabel: 'Sign out',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await AuthApi.signOut();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (context) => const HomePage()),
      (route) => false,
    );
  }

  /// Permanent account deletion: double confirmation, then the backend
  /// removes the account with its posts, saved itineraries and uploads.
  Future<void> _deleteProfile() async {
    final user = AuthApi.currentUser;
    if (user == null) return;
    final ok = await confirmDialog(
      context,
      title: 'Delete your profile?',
      message: 'This permanently deletes your account, your community posts, '
          'saved itineraries and uploads. This cannot be undone.',
      confirmLabel: 'Delete forever',
      destructive: true,
    );
    if (!ok || !mounted) return;
    // Second, explicit confirmation for an irreversible action.
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

  /// One-line teaser of what's inside a saved plan: first day titles.
  String _planPreview(String plan) {
    final days = RegExp(r'^Day \d+\s*[:\-]\s*(.+)$', multiLine: true)
        .allMatches(plan)
        .map((m) => m.group(1)!.trim())
        .toList();
    if (days.isNotEmpty) {
      final shown = days.take(3).join(' · ');
      return days.length > 3 ? '$shown …' : shown;
    }
    final flat = plan.replaceAll('\n', ' ').trim();
    return flat.length > 90 ? '${flat.substring(0, 90)}…' : flat;
  }

  /// "Saved itineraries" card: paginated visual tiles — cover photo,
  /// title, what's inside, date — with view (tap), edit and delete.
  Widget _itinerariesCard() {
    final pages = (itineraries.length / _itinPageSize).ceil();
    if (itinPage >= pages) itinPage = pages - 1;
    final start = itinPage * _itinPageSize;
    final visible = itineraries.sublist(
        start,
        (start + _itinPageSize) > itineraries.length
            ? itineraries.length
            : start + _itinPageSize);
    for (final item in visible) {
      _loadItinMedia(item);
    }
    return Card(
      color: cardBg(context),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.bookmark, color: Colors.purple, size: 18),
                const SizedBox(width: 8),
                const Text('Saved itineraries',
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                const Spacer(),
                Text('${itineraries.length}',
                    style: const TextStyle(color: Colors.grey, fontSize: 12.5)),
              ],
            ),
            const SizedBox(height: 10),
            for (final item in visible) _itinTile(item),
            if (pages > 1)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    icon: const Icon(Icons.chevron_left, size: 20),
                    onPressed: itinPage > 0
                        ? () {
                            Haptics.tick();
                            setState(() => itinPage--);
                          }
                        : null,
                  ),
                  for (var i = 0; i < pages; i++)
                    Container(
                      width: itinPage == i ? 18 : 7,
                      height: 7,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        color: itinPage == i
                            ? Colors.purple
                            : Colors.grey.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  IconButton(
                    icon: const Icon(Icons.chevron_right, size: 20),
                    onPressed: itinPage < pages - 1
                        ? () {
                            Haptics.tick();
                            setState(() => itinPage++);
                          }
                        : null,
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _itinTile(SavedItinerary item) {
    final cover = itinMedia[item.id]?.images.firstOrNull;
    final days =
        RegExp(r'^Day \d+', multiLine: true).allMatches(item.plan).length;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: pageBg(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.purple.withValues(alpha: 0.18)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _viewItinerary(item),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 4, 10),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: cover != null
                    ? Image.network(cover,
                        width: 62,
                        height: 56,
                        fit: BoxFit.cover,
                        errorBuilder: (c, e, st) => _itinCoverFallback())
                    : _itinCoverFallback(),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 14)),
                    const SizedBox(height: 3),
                    Text(_planPreview(item.plan),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 11.5, color: Colors.grey)),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        if (days > 0) ...[
                          const Icon(Icons.route,
                              size: 11, color: Colors.purple),
                          const SizedBox(width: 3),
                          Text('$days day${days == 1 ? '' : 's'}',
                              style: const TextStyle(
                                  fontSize: 10.5,
                                  color: Colors.purple,
                                  fontWeight: FontWeight.w600)),
                          const SizedBox(width: 8),
                        ],
                        Text(
                          '${item.createdAt.day}/${item.createdAt.month}/'
                          '${item.createdAt.year}',
                          style: const TextStyle(
                              fontSize: 10.5, color: Colors.grey),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Edit',
                icon: const Icon(Icons.edit_outlined, size: 17, color: blue),
                onPressed: () => _editItinerary(item),
              ),
              IconButton(
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline, size: 17, color: red),
                onPressed: () => _deleteItinerary(item),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _itinCoverFallback() => Container(
        width: 62,
        height: 56,
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: [
            Colors.purple.withValues(alpha: 0.25),
            blue.withValues(alpha: 0.25),
          ]),
        ),
        child: const Icon(Icons.route, color: Colors.purple, size: 24),
      );

  /// Full plan in a scrollable bottom sheet — day cards, photos rail and
  /// YouTube suggestions, not just text.
  void _viewItinerary(SavedItinerary item) {
    Haptics.light();
    _loadItinMedia(item);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: cardBg(context),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.93,
        builder: (context, scroll) {
          final media = itinMedia[item.id];
          return ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 30),
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                      color: Colors.grey.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(2)),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  const Icon(Icons.bookmark, color: Colors.purple, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(item.title,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 17)),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (media != null && media.images.isNotEmpty) ...[
                SizedBox(
                  height: 110,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: media.images.length,
                    separatorBuilder: (c, i) => const SizedBox(width: 10),
                    itemBuilder: (context, i) => ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.network(media.images[i],
                          width: 155,
                          height: 110,
                          fit: BoxFit.cover,
                          errorBuilder: (c, e, st) => const SizedBox.shrink()),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
              ],
              for (final section in _planSections(item.plan))
                _planSectionCard(section),
              if (media != null && media.youtube.isNotEmpty) ...[
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('Watch before you go',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 14.5)),
                ),
                for (final y in media.youtube)
                  Card(
                    color: pageBg(context),
                    margin: const EdgeInsets.only(bottom: 8),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    child: ListTile(
                      dense: true,
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Image.network(y.thumbnail,
                            width: 64,
                            height: 40,
                            fit: BoxFit.cover,
                            errorBuilder: (c, e, st) => const Icon(
                                Icons.smart_display,
                                color: Colors.redAccent,
                                size: 28)),
                      ),
                      title: Text(y.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 12.5)),
                      trailing: const Icon(Icons.open_in_new,
                          color: Colors.redAccent, size: 16),
                      onTap: () => launchUrl(Uri.parse(y.url)),
                    ),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }

  /// Splits a plain-text plan into intro / day / logistics / tips sections.
  List<MapEntry<String, String>> _planSections(String plan) {
    final sections = <MapEntry<String, String>>[];
    var title = '';
    var body = StringBuffer();
    void push() {
      if (title.isNotEmpty || body.isNotEmpty) {
        sections.add(MapEntry(title, body.toString().trim()));
      }
      body = StringBuffer();
    }

    for (final raw in plan.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final isHeader = RegExp(
              r'^(Day \d+\s*[:\-]|Tips\s*:|Getting there\s*:|Stay\s*:)',
              caseSensitive: false)
          .hasMatch(line);
      if (isHeader) {
        push();
        final split = line.indexOf(':');
        title = split > 0 ? line.substring(0, split).trim() : line;
        final rest = split > 0 ? line.substring(split + 1).trim() : '';
        if (rest.isNotEmpty) body.writeln(rest);
      } else {
        body.writeln(line);
      }
    }
    push();
    return sections;
  }

  Widget _planSectionCard(MapEntry<String, String> section) {
    final t = section.key.toLowerCase();
    final (icon, color) = t.startsWith('tips')
        ? (Icons.lightbulb_outline, Colors.amber)
        : t.startsWith('getting there')
            ? (Icons.flight_takeoff, blue)
            : t.startsWith('stay')
                ? (Icons.hotel, Colors.teal)
                : (Icons.route, Colors.purple);
    return Card(
      color: pageBg(context),
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (section.key.isNotEmpty) ...[
              Row(
                children: [
                  Icon(icon, size: 15, color: color),
                  const SizedBox(width: 6),
                  Text(section.key,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 13.5)),
                ],
              ),
              const SizedBox(height: 5),
            ],
            Text(section.value,
                style:
                    TextStyle(fontSize: 13, height: 1.5, color: ink(context))),
          ],
        ),
      ),
    );
  }

  Future<void> _editItinerary(SavedItinerary item) async {
    final user = AuthApi.currentUser;
    if (user == null) return;
    final titleCtl = TextEditingController(text: item.title);
    final planCtl = TextEditingController(text: item.plan);
    final save = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Edit itinerary'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleCtl,
                maxLength: 120,
                decoration: const InputDecoration(labelText: 'Title'),
              ),
              const SizedBox(height: 6),
              Flexible(
                child: TextField(
                  controller: planCtl,
                  maxLines: 8,
                  decoration: const InputDecoration(
                      labelText: 'Plan', alignLabelWithHint: true),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save')),
        ],
      ),
    );
    if (save != true || !mounted) return;
    final newTitle = titleCtl.text.trim();
    final newPlan = planCtl.text.trim();
    if (newTitle.isEmpty || newPlan.isEmpty) {
      newSnackBar(context, title: 'Title and plan cannot be empty.');
      return;
    }
    try {
      await MediaApi.updateItinerary(
          id: item.id, userId: user.id, title: newTitle, plan: newPlan);
      Haptics.medium();
      if (!mounted) return;
      newSnackBar(context, title: 'Itinerary updated.');
      _loadItineraries();
    } on AuthException catch (e) {
      if (mounted) newSnackBar(context, title: e.message);
    }
  }

  Future<void> _deleteItinerary(SavedItinerary item) async {
    final user = AuthApi.currentUser;
    if (user == null) return;
    final ok = await confirmDialog(
      context,
      title: 'Delete itinerary?',
      message: '"${item.title}" will be removed from your account.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok || !mounted) return;
    try {
      await MediaApi.deleteItinerary(id: item.id, userId: user.id);
      if (mounted) {
        setState(() => itineraries.removeWhere((s) => s.id == item.id));
      }
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
