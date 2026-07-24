import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../constant.dart';
import '../detail.dart';
import '../experience_player.dart';
import '../models/place.dart';
import '../services/auth_api.dart';
import '../services/haptic_service.dart';
import '../services/api_base.dart';
import '../services/media_api.dart';
import '../services/tab_events.dart';
import 'community_page.dart' show showUserProfileDialog;
import '../widgets/image_viewer.dart';
import '../widgets/ux.dart';
import '../widgets/youtube_player_page.dart';

/// "Feel it" tap: play the place's experience video with haptics right away;
/// only open the place page when no experience is ready yet.
Future<void> feelPlace(BuildContext context, City city) async {
  Haptics.light();
  List<VideoItem> videos = const [];
  try {
    videos = (await MediaApi.fetchVideos(city.slug, limit: 1)).videos;
  } catch (_) {}
  if (!context.mounted) return;
  if (videos.isNotEmpty) {
    Haptics.string();
    Navigator.push(
      context,
      MaterialPageRoute(
          builder: (context) => ExperiencePlayerPage(video: videos.first)),
    );
  } else {
    Navigator.push(
      context,
      MaterialPageRoute(
          builder: (context) => DetailScreen(place: Place.fromCity(city))),
    );
  }
}

/// Search: live results over cities + experience videos, recent searches
/// (each deletable), and an optional AI overview (Groq + web search via the
/// backend) controlled by the ✨ toggle.
class SearchPage extends StatefulWidget {
  final void Function(int index)? onSelectTab;

  /// When pushed as its own route (e.g. tapping a #hashtag), pre-fills and
  /// runs this query immediately.
  final String? initialQuery;
  const SearchPage({super.key, this.onSelectTab, this.initialQuery});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  static const _kRecent = 'search.recent';
  static const _kAi = 'search.ai';

  final TextEditingController query = TextEditingController();
  Timer? _debounce;
  SearchResult? result;
  bool searching = false;
  String? error;

  List<String> recent = [];
  bool aiEnabled = false;
  AiOverview? ai;
  bool aiLoading = false;
  bool aiSaving = false;
  bool aiSaved = false;
  MediaSuggestions? media;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    final q = widget.initialQuery;
    if (q != null && q.trim().isNotEmpty) {
      query.text = q.trim();
      WidgetsBinding.instance.addPostFrameCallback((_) => _search(q.trim()));
    }
    // Leaving the tab clears the field and results automatically.
    TabEvents.changed.addListener(_onTabChanged);
  }

  void _onTabChanged() {
    if (!mounted || query.text.isEmpty) return;
    query.clear();
    _search('');
  }

  Future<void> _loadPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        recent = prefs.getStringList(_kRecent) ?? [];
        aiEnabled = prefs.getBool(_kAi) ?? false;
      });
    } catch (_) {}
  }

  Future<void> _saveRecent(String term) async {
    recent.remove(term);
    recent.insert(0, term);
    if (recent.length > 8) recent = recent.sublist(0, 8);
    setState(() {});
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kRecent, recent);
    } catch (_) {}
  }

  Future<void> _deleteRecent(String term) async {
    setState(() => recent.remove(term));
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kRecent, recent);
    } catch (_) {}
  }

  Future<void> _setAi(bool v) async {
    setState(() => aiEnabled = v);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kAi, v);
    } catch (_) {}
    // Enabling mid-search: fetch the overview for the current query.
    final q = query.text.trim();
    if (v && q.isNotEmpty) _fetchAi(q);
    if (!v) setState(() => ai = null);
  }

  @override
  void dispose() {
    TabEvents.changed.removeListener(_onTabChanged);
    _debounce?.cancel();
    query.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    setState(() {}); // clear icon tracks typing instantly
    _debounce?.cancel();
    // Typing runs only the regular search — the AI answer costs seconds and
    // tokens, so it fires ONLY on Enter (or a tapped suggestion/chip).
    _debounce = Timer(
        const Duration(milliseconds: 350), () => _search(text, runAi: false));
  }

  Future<void> _search(String text, {bool runAi = true}) async {
    final q = text.trim();
    if (q.isEmpty) {
      setState(() {
        result = null;
        error = null;
        searching = false;
        ai = null;
        media = null;
      });
      return;
    }
    setState(() {
      searching = true;
      error = null;
    });
    if (aiEnabled && runAi) _fetchAi(q);
    // Photos + YouTube suggestions load in parallel, never block results.
    MediaApi.searchMedia(q).then((m) {
      if (mounted && query.text.trim() == q) setState(() => media = m);
    }).catchError((_) {});
    try {
      final r = await MediaApi.search(q);
      if (!mounted) return;
      // Ignore stale responses typed-over since.
      if (query.text.trim() != q) return;
      setState(() {
        result = r;
        searching = false;
      });
      _saveRecent(q);
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        searching = false;
        error = e.message;
      });
    }
  }

  Future<void> _fetchAi(String q) async {
    setState(() {
      aiLoading = true;
      ai = null;
      aiSaved = false;
    });
    try {
      final overview = await MediaApi.aiSearch(q);
      if (!mounted || query.text.trim() != q) return;
      setState(() {
        ai = overview;
        aiLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => aiLoading = false);
    }
  }

  void _runTerm(String term) {
    query.text = term;
    _search(term);
  }

  /// "Save as itinerary": keeps the AI answer under the user's account,
  /// visible later in the Planner tab.
  Future<void> _saveAi() async {
    final user = AuthApi.currentUser;
    final overview = ai;
    if (overview == null || aiSaving || aiSaved) return;
    if (user == null) {
      newSnackBar(context, title: 'Sign in to save itineraries.');
      return;
    }
    final q = query.text.trim();
    setState(() => aiSaving = true);
    try {
      final title = q.length > 60 ? '${q.substring(0, 57)}...' : q;
      await MediaApi.saveItinerary(
          userId: user.id, title: title, query: q, plan: overview.overview);
      Haptics.medium();
      if (!mounted) return;
      setState(() {
        aiSaving = false;
        aiSaved = true;
      });
      newSnackBar(context, title: 'Saved — find it in the Planner tab.');
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() => aiSaving = false);
      newSnackBar(context, title: e.message);
    }
  }

  /// Strip stray markdown; normalize bullets so cards read cleanly.
  String _tidyAi(String raw) => raw
      .replaceAll(RegExp(r'[*_#`]+'), '')
      .replaceAll(RegExp(r'^\s*[-•]\s*', multiLine: true), '•  ')
      .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
      .trim();

  /// Break the AI answer into labelled sections (Getting there, Stay,
  /// Highlights, Tips, Best time…) with a lead paragraph for anything
  /// before the first header — mirrors the itinerary planner's layout.
  List<MapEntry<String, String>> _aiSections() {
    final text = _tidyAi(ai!.overview);
    final sections = <MapEntry<String, String>>[];
    var title = '';
    var body = StringBuffer();
    void push() {
      if (title.isNotEmpty || body.toString().trim().isNotEmpty) {
        sections.add(MapEntry(title, body.toString().trim()));
      }
      body = StringBuffer();
    }

    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      // A header is a short label line ending in ':' (with little/no text
      // after it), e.g. "Getting there:", "Highlights:", "Best time to go:".
      final m = RegExp(r'^([A-Z][A-Za-z /&]{2,28}):\s*(.*)$').firstMatch(line);
      if (m != null && (m.group(2)!.isEmpty || m.group(1)!.length <= 22)) {
        push();
        title = m.group(1)!.trim();
        if (m.group(2)!.isNotEmpty) body.writeln(m.group(2));
      } else {
        body.writeln(line);
      }
    }
    push();
    return sections;
  }

  (IconData, Color) _aiSectionStyle(String title) {
    final t = title.toLowerCase();
    if (t.contains('getting') || t.contains('reach') || t.contains('transport')) {
      return (Icons.flight_takeoff, blue);
    }
    if (t.contains('stay') || t.contains('hotel') || t.contains('where to')) {
      return (Icons.hotel, Colors.teal);
    }
    if (t.contains('tip') || t.contains('know')) {
      return (Icons.lightbulb_outline, Colors.amber);
    }
    if (t.contains('time') || t.contains('season') || t.contains('weather')) {
      return (Icons.wb_sunny_outlined, Colors.orange);
    }
    if (t.contains('eat') || t.contains('food')) {
      return (Icons.restaurant, Colors.redAccent);
    }
    if (t.contains('cost') || t.contains('budget') || t.contains('price')) {
      return (Icons.payments_outlined, Colors.green);
    }
    if (t.contains('highlight') || t.contains('see') || t.contains('do')) {
      return (Icons.star_outline, Colors.purple);
    }
    return (Icons.auto_awesome, Colors.purple);
  }

  List<Widget> _aiBody() {
    final sections = _aiSections();
    if (sections.isEmpty) {
      return [
        Text(_tidyAi(ai!.overview),
            style: TextStyle(fontSize: 13.5, height: 1.5, color: ink(context)))
      ];
    }
    final widgets = <Widget>[];
    for (final s in sections) {
      if (s.key.isEmpty) {
        // Lead paragraph — no card, just the intro text.
        widgets.add(Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(s.value,
              style:
                  TextStyle(fontSize: 13.5, height: 1.5, color: ink(context))),
        ));
        continue;
      }
      final (icon, color) = _aiSectionStyle(s.key);
      widgets.add(Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: cardBg(context),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 15, color: color),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(s.key,
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          color: ink(context))),
                ),
              ],
            ),
            if (s.value.isNotEmpty) ...[
              const SizedBox(height: 5),
              Text(s.value,
                  style: TextStyle(
                      fontSize: 12.8, height: 1.5, color: inkSoft(context))),
            ],
          ],
        ),
      ));
    }
    return widgets;
  }

  /// Matching on-platform experiences under the AI answer — visuals,
  /// details and a redirect straight into the place page.
  List<Widget> _aiPlaces() {
    final places = ai?.places ?? const <City>[];
    if (places.isEmpty) return const [];
    return [
      const Padding(
        padding: EdgeInsets.only(top: 12, bottom: 4),
        child: Text('Feel it on Mr.TourGuide',
            style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 12.5,
                color: Colors.purple)),
      ),
      for (final city in places)
        Card(
          color: cardBg(context),
          margin: const EdgeInsets.only(top: 6),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: ListTile(
            dense: true,
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: city.absoluteCoverUrl != null
                  ? Image.network(city.absoluteCoverUrl!,
                      width: 56,
                      height: 42,
                      fit: BoxFit.cover,
                      errorBuilder: (c, e, s) =>
                          const Icon(Icons.place, color: blue, size: 28))
                  : const Icon(Icons.place, color: blue, size: 28),
            ),
            title: Text(city.name,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(
              '${city.location.isEmpty ? 'Experiences' : city.location}'
              '${city.ratingCount > 0 ? ' · ★ ${city.rating.toStringAsFixed(1)}' : ''}'
              ' · ${city.videoCount} experience'
              '${city.videoCount == 1 ? '' : 's'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11.5, color: Colors.grey),
            ),
            trailing: const Icon(Icons.play_circle_fill, color: blue, size: 26),
            onTap: () => feelPlace(context, city),
          ),
        ),
    ];
  }

  String _formatSize(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // keep this tab alive across switches
    return Scaffold(
      backgroundColor: pageBg(context),
      appBar: AppBar(
        backgroundColor: cardBg(context),
        elevation: 0,
        iconTheme: IconThemeData(color: ink(context)),
        title: Text('Search',
            style: TextStyle(color: ink(context), fontWeight: FontWeight.bold)),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: cardBg(context),
                borderRadius: BorderRadius.circular(15),
              ),
              child: TextField(
                controller: query,
                onChanged: _onChanged,
                onSubmitted: _search,
                autofocus: false,
                decoration: InputDecoration(
                  border: InputBorder.none,
                  // The wrapping container is the visual — don't double-fill.
                  filled: false,
                  prefixIcon: const Icon(Icons.search, color: Colors.black87),
                  suffixIcon: query.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () {
                            query.clear();
                            _search('');
                          },
                        ),
                  hintText: aiEnabled
                      ? 'Ask anything — AI overview + results'
                      : 'Search places, experiences or people',
                  hintStyle: const TextStyle(color: Colors.grey, fontSize: 15),
                ),
              ),
            ),
          ),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    final r = result;
    if (r == null && !searching && error == null) return _idle();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 110),
      children: [
        if (aiEnabled) _aiCard(),
        if (error != null)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: red)),
          )
        else if (searching)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator(color: blue)),
          )
        else if (r != null && r.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(
                child: Text('No matches found.',
                    style: TextStyle(color: Colors.grey))),
          )
        else if (r != null) ...[
          if (r.cities.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Cities',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            ),
            Wrap(
              spacing: 8,
              children: [
                for (final city in r.cities)
                  ActionChip(
                    avatar:
                        const Icon(Icons.location_on, size: 18, color: blue),
                    label: Text('${city.name} (${city.videoCount})'),
                    onPressed: () => widget.onSelectTab?.call(1),
                  ),
              ],
            ),
          ],
          if (r.users.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('People',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            ),
            for (final u in r.users)
              Card(
                color: cardBg(context),
                margin: const EdgeInsets.only(bottom: 8),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                child: ListTile(
                  dense: true,
                  leading: CircleAvatar(
                    radius: 16,
                    backgroundColor: u.role == 'creator' ? Colors.purple : blue,
                    backgroundImage: u.avatarUrl != null
                        ? CachedNetworkImageProvider('$apiBase${u.avatarUrl}')
                        : null,
                    child: u.avatarUrl == null
                        ? Text(
                            u.name.isNotEmpty ? u.name[0].toUpperCase() : '?',
                            style: const TextStyle(
                                color: white,
                                fontSize: 13,
                                fontWeight: FontWeight.bold))
                        : null,
                  ),
                  title: Text(u.name,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(
                    '${u.username != null ? '@${u.username} · ' : ''}'
                    '${u.role} · ${u.followers} follower'
                    '${u.followers == 1 ? '' : 's'}',
                    style: const TextStyle(fontSize: 11.5, color: Colors.grey),
                  ),
                  trailing: const Icon(Icons.chevron_right, color: blue),
                  onTap: () => showUserProfileDialog(context, u.id),
                ),
              ),
          ],
          if (r.videos.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('On MrTouride · feel it',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            ),
            for (final video in r.videos)
              Card(
                color: cardBg(context),
                margin: const EdgeInsets.only(bottom: 10),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                child: ListTile(
                  leading:
                      const Icon(Icons.play_circle_fill, color: blue, size: 36),
                  title: Text(video.title,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(
                    '${video.city[0].toUpperCase()}${video.city.substring(1)}'
                    ' · ${_formatSize(video.sizeBytes)}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  trailing: const Icon(Icons.chevron_right, color: blue),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => ExperiencePlayerPage(video: video),
                    ),
                  ),
                ),
              ),
          ],
          ..._mediaSections(),
        ],
      ],
    );
  }

  /// Photos rail + YouTube suggestion cards for the current query.
  List<Widget> _mediaSections() {
    final m = media;
    if (m == null || m.isEmpty) return const [];
    return [
      if (m.images.isNotEmpty) ...[
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text('Photos',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        ),
        SizedBox(
          height: 120,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: m.images.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (context, i) => GestureDetector(
              onTap: () =>
                  showImageViewer(context, m.images[i], caption: query.text),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.network(
                  m.images[i],
                  width: 170,
                  height: 120,
                  fit: BoxFit.cover,
                  errorBuilder: (c, e, s) => const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
      ],
      if (m.youtube.isNotEmpty) ...[
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text('From YouTube',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        ),
        for (final y in m.youtube)
          Card(
            color: cardBg(context),
            margin: const EdgeInsets.only(bottom: 10),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            child: ListTile(
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  y.thumbnail,
                  width: 72,
                  height: 44,
                  fit: BoxFit.cover,
                  errorBuilder: (c, e, s) => const Icon(Icons.smart_display,
                      color: Colors.redAccent, size: 32),
                ),
              ),
              title: Text(y.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 13.5)),
              subtitle: const Text('YouTube',
                  style: TextStyle(fontSize: 11, color: Colors.grey)),
              trailing: const Icon(Icons.open_in_new,
                  color: Colors.redAccent, size: 18),
              onTap: () => YoutubePlayerPage.videoIdOf(y.url) != null
                  ? Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (context) => YoutubePlayerPage(
                              title: y.title, url: y.url)))
                  : launchUrl(Uri.parse(y.url)),
            ),
          ),
      ],
    ];
  }

  /// Empty state: recent searches (deletable) + quick suggestions.
  Widget _idle() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 110),
      children: [
        if (recent.isNotEmpty) ...[
          Row(
            children: [
              const Text('Recent searches',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              const Spacer(),
              TextButton(
                onPressed: () async {
                  setState(() => recent = []);
                  try {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setStringList(_kRecent, []);
                  } catch (_) {}
                },
                child: const Text('Clear all', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          for (var i = 0; i < recent.length; i++)
            Entrance(
              index: i,
              child: Card(
                color: cardBg(context),
                margin: const EdgeInsets.only(bottom: 8),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                child: ListTile(
                  dense: true,
                  leading:
                      const Icon(Icons.history, color: Colors.grey, size: 20),
                  title: Text(recent[i]),
                  trailing: IconButton(
                    tooltip: 'Remove',
                    icon: const Icon(Icons.close, size: 18, color: Colors.grey),
                    onPressed: () => _deleteRecent(recent[i]),
                  ),
                  onTap: () => _runTerm(recent[i]),
                ),
              ),
            ),
          const SizedBox(height: 18),
        ],
        Row(
          children: [
            const Text('Try searching',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            const Spacer(),
            // AI toggle: off = classic search, on = adds the AI overview.
            const Icon(Icons.auto_awesome, size: 16, color: Colors.purple),
            const SizedBox(width: 4),
            Text('AI', style: TextStyle(color: ink(context), fontSize: 14)),
            Switch(
              value: aiEnabled,
              activeThumbColor: Colors.purple,
              onChanged: _setAi,
            ),
          ],
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final term in const [
              'sunrise',
              'temple',
              'heritage',
              'mountains',
              'beach'
            ])
              ActionChip(
                avatar: const Icon(Icons.search, size: 16, color: blue),
                label: Text(term),
                onPressed: () => _runTerm(term),
              ),
          ],
        ),
        if (aiEnabled)
          const Padding(
            padding: EdgeInsets.only(top: 18),
            child: Text(
              'AI is on — every search adds a minimal AI overview with '
              'live web knowledge.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ),
      ],
    );
  }

  Widget _aiCard() {
    if (!aiLoading && ai == null) {
      // AI is on but hasn't been asked yet — invite the Enter press instead
      // of showing nothing.
      if (aiEnabled && query.text.trim().isNotEmpty) {
        return Container(
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.purple.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.purple.withValues(alpha: 0.25)),
          ),
          child: InkWell(
            onTap: () => _search(query.text),
            child: Row(
              children: [
                const Icon(Icons.auto_awesome, size: 15, color: Colors.purple),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Press Enter ↵ (or tap here) to ask AI',
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: ink(context))),
                ),
              ],
            ),
          ),
        );
      }
      return const SizedBox.shrink();
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Colors.purple.withValues(alpha: 0.08),
            lightBlue.withValues(alpha: 0.10),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.purple.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_awesome, size: 15, color: Colors.purple),
              const SizedBox(width: 6),
              const Text('AI overview',
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      color: Colors.purple)),
              const Spacer(),
              if (ai != null)
                aiSaving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.purple))
                    : InkWell(
                        onTap: aiSaved ? null : _saveAi,
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Row(
                            children: [
                              Icon(
                                  aiSaved
                                      ? Icons.bookmark_added
                                      : Icons.bookmark_add_outlined,
                                  size: 16,
                                  color: Colors.purple),
                              const SizedBox(width: 4),
                              Text(aiSaved ? 'Saved' : 'Save',
                                  style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.purple)),
                            ],
                          ),
                        ),
                      ),
            ],
          ),
          const SizedBox(height: 8),
          if (aiLoading)
            const Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.purple),
                ),
                SizedBox(width: 10),
                Text('Searching the web...',
                    style: TextStyle(color: Colors.grey, fontSize: 13)),
              ],
            )
          else ...[
            ..._aiBody(),
            ..._aiPlaces(),
          ],
        ],
      ),
    );
  }
}
