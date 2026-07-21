import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../constant.dart';
import '../services/auth_api.dart' show AuthException;
import '../services/haptic_service.dart';
import '../services/media_api.dart';
import '../widgets/ux.dart';

/// AI Itinerary planner: ask for any trip ("3 days in Rajasthan"), get a
/// web-informed day-by-day plan with photos and YouTube suggestions.
class ItineraryPage extends StatefulWidget {
  final void Function(int index)? onSelectTab;
  const ItineraryPage({super.key, this.onSelectTab});

  @override
  State<ItineraryPage> createState() => _ItineraryPageState();
}

class _ItineraryPageState extends State<ItineraryPage> {
  final prompt = TextEditingController();
  bool planning = false;
  String? error;
  String? plan;
  MediaSuggestions? media;
  String lastQuery = '';

  @override
  void dispose() {
    prompt.dispose();
    super.dispose();
  }

  Future<void> _plan([String? preset]) async {
    final q = (preset ?? prompt.text).trim();
    if (q.isEmpty || planning) return;
    if (preset != null) prompt.text = preset;
    Haptics.medium();
    setState(() {
      planning = true;
      error = null;
      plan = null;
      media = null;
      lastQuery = q;
    });
    // Visuals load in parallel with the plan.
    MediaApi.searchMedia(q).then((m) {
      if (mounted && lastQuery == q) setState(() => media = m);
    }).catchError((_) {});
    try {
      final result = await MediaApi.aiItinerary(q);
      if (!mounted || lastQuery != q) return;
      setState(() {
        plan = result;
        planning = false;
      });
      Haptics.string();
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        planning = false;
        error = e.message;
      });
    }
  }

  /// Splits the plain-text plan into intro / day cards / tips.
  List<MapEntry<String, String>> _sections() {
    final text = plan ?? '';
    final lines = text.split('\n');
    final sections = <MapEntry<String, String>>[];
    var title = '';
    var body = StringBuffer();
    void push() {
      if (title.isNotEmpty || body.isNotEmpty) {
        sections.add(MapEntry(title, body.toString().trim()));
      }
      body = StringBuffer();
    }

    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final isHeader =
          RegExp(r'^(Day \d+\s*[:\-]|Tips\s*:)', caseSensitive: false)
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: pageBg(context),
      appBar: AppBar(
        backgroundColor: cardBg(context),
        elevation: 0,
        title: Row(
          children: [
            const Icon(Icons.auto_awesome, color: Colors.purple, size: 20),
            const SizedBox(width: 8),
            Text('AI Itinerary',
                style: TextStyle(
                    color: ink(context), fontWeight: FontWeight.bold)),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 110),
        children: [
          // Prompt
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: cardBg(context),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: prompt,
                    onSubmitted: (_) => _plan(),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      hintText: 'Plan my trip… e.g. "3 days in Rajasthan"',
                      hintStyle: TextStyle(color: Colors.grey, fontSize: 14),
                    ),
                  ),
                ),
                planning
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.purple))
                    : IconButton(
                        icon: const Icon(Icons.auto_awesome,
                            color: Colors.purple),
                        onPressed: _plan,
                      ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (plan == null && !planning)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final t in const [
                  'Weekend in the Golden Triangle',
                  '3 days of temples & food',
                  'Wheelchair-friendly heritage trip',
                  'Monsoon getaway ideas',
                ])
                  ActionChip(
                    avatar: const Icon(Icons.route, size: 16, color: blue),
                    label: Text(t),
                    onPressed: () => _plan(t),
                  ),
              ],
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.all(20),
              child: Text(error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: red)),
            ),
          if (planning)
            Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                children: const [
                  CircularProgressIndicator(color: Colors.purple),
                  SizedBox(height: 12),
                  Text('Planning with live web knowledge…',
                      style: TextStyle(color: Colors.grey, fontSize: 13)),
                ],
              ),
            ),
          if (plan != null) ...[
            for (var i = 0; i < _sections().length; i++)
              Entrance(
                index: i,
                child: _sectionCard(_sections()[i], i),
              ),
            if (media?.images.isNotEmpty ?? false) ...[
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Text('Visuals',
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              ),
              SizedBox(
                height: 120,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: media!.images.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 10),
                  itemBuilder: (context, i) => ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.network(media!.images[i],
                        width: 170,
                        height: 120,
                        fit: BoxFit.cover,
                        errorBuilder: (c, e, s) => const SizedBox.shrink()),
                  ),
                ),
              ),
            ],
            if (media?.youtube.isNotEmpty ?? false) ...[
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Text('Watch before you go',
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              ),
              for (final y in media!.youtube)
                Card(
                  color: cardBg(context),
                  margin: const EdgeInsets.only(bottom: 10),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                  child: ListTile(
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.network(y.thumbnail,
                          width: 72,
                          height: 44,
                          fit: BoxFit.cover,
                          errorBuilder: (c, e, s) => const Icon(
                              Icons.smart_display,
                              color: Colors.redAccent,
                              size: 32)),
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
                    onTap: () => launchUrl(Uri.parse(y.url)),
                  ),
                ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _sectionCard(MapEntry<String, String> section, int index) {
    final isDay = section.key.toLowerCase().startsWith('day');
    final isTips = section.key.toLowerCase().startsWith('tips');
    return Card(
      color: cardBg(context),
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (section.key.isNotEmpty)
              Row(
                children: [
                  Icon(
                    isTips
                        ? Icons.lightbulb_outline
                        : isDay
                            ? Icons.route
                            : Icons.auto_awesome,
                    size: 16,
                    color: isTips ? Colors.amber.shade700 : Colors.purple,
                  ),
                  const SizedBox(width: 6),
                  Text(section.key,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 14.5)),
                ],
              ),
            if (section.key.isNotEmpty) const SizedBox(height: 6),
            Text(section.value,
                style: TextStyle(
                    fontSize: 13.5, height: 1.5, color: ink(context))),
          ],
        ),
      ),
    );
  }
}
