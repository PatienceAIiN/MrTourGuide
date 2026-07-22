import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../constant.dart';
import '../services/auth_api.dart';
import '../services/haptic_service.dart';
import '../services/media_api.dart';
import '../services/tab_events.dart';
import '../widgets/image_viewer.dart';
import '../widgets/ux.dart';
import 'search_page.dart' show feelPlace;

/// AI Itinerary planner: ask for any trip ("3 days in Rajasthan"), get a
/// web-informed day-by-day plan — with flights/trains, stays, photos,
/// YouTube suggestions, matching on-platform experiences, and a save button
/// that keeps plans under your account.
class ItineraryPage extends StatefulWidget {
  final void Function(int index)? onSelectTab;
  const ItineraryPage({super.key, this.onSelectTab});

  @override
  State<ItineraryPage> createState() => _ItineraryPageState();
}

class _ItineraryPageState extends State<ItineraryPage> {
  static const _kChats = 'ai.chats';

  final prompt = TextEditingController();
  final followUp = TextEditingController();
  bool planning = false;
  String? error;
  ItineraryResult? result;
  MediaSuggestions? media;
  String lastQuery = '';

  /// The running conversation: {'role': 'user'|'assistant', 'content': ...}.
  final List<Map<String, String>> chat = [];
  String chatId = '';

  /// Past conversations, saved on this device — reopen and keep asking.
  List<Map<String, dynamic>> chatHistory = [];

  List<SavedItinerary> saved = [];
  bool savedLoading = false;
  bool saving = false;
  bool justSaved = false;

  @override
  void initState() {
    super.initState();
    _loadSaved();
    _loadChatHistory();
    TabEvents.changed.addListener(_onTabChanged);
  }

  void _onTabChanged() {
    // Leaving the tab clears pending input (the conversation stays).
    if (mounted && followUp.text.isNotEmpty) followUp.clear();
    if (mounted && result == null && prompt.text.isNotEmpty) prompt.clear();
  }

  @override
  void dispose() {
    TabEvents.changed.removeListener(_onTabChanged);
    prompt.dispose();
    followUp.dispose();
    super.dispose();
  }

  Future<void> _loadChatHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kChats);
      if (raw == null || !mounted) return;
      setState(() =>
          chatHistory = (jsonDecode(raw) as List).cast<Map<String, dynamic>>());
    } catch (_) {}
  }

  /// Persist the running conversation after every exchange (device-local —
  /// nothing extra hits the server).
  Future<void> _saveChat() async {
    if (chat.isEmpty || chatId.isEmpty) return;
    final firstUser = chat.firstWhere((m) => m['role'] == 'user',
        orElse: () => const {'content': 'Trip plan'});
    final session = {
      'id': chatId,
      'title': firstUser['content'],
      'updatedAt': DateTime.now().toIso8601String(),
      'messages': chat,
    };
    chatHistory.removeWhere((c) => c['id'] == chatId);
    chatHistory.insert(0, session);
    if (chatHistory.length > 20) chatHistory = chatHistory.sublist(0, 20);
    if (mounted) setState(() {});
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kChats, jsonEncode(chatHistory));
    } catch (_) {}
  }

  Future<void> _deleteChat(String id) async {
    setState(() => chatHistory.removeWhere((c) => c['id'] == id));
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kChats, jsonEncode(chatHistory));
    } catch (_) {}
  }

  /// Reopen a past conversation and keep asking follow-ups.
  void _openChat(Map<String, dynamic> session) {
    Haptics.light();
    final messages = (session['messages'] as List)
        .map((m) => Map<String, String>.from(m as Map))
        .toList();
    final lastAssistant = messages.lastWhere((m) => m['role'] == 'assistant',
        orElse: () => const {'content': ''});
    final firstUser = messages.firstWhere((m) => m['role'] == 'user',
        orElse: () => const {'content': ''});
    setState(() {
      chat
        ..clear()
        ..addAll(messages);
      chatId = session['id'] as String;
      lastQuery = firstUser['content'] ?? '';
      prompt.text = lastQuery;
      result = ItineraryResult(plan: lastAssistant['content'] ?? '');
      media = null;
      error = null;
      justSaved = false;
    });
    if (lastQuery.isNotEmpty) {
      MediaApi.searchMedia(lastQuery).then((m) {
        if (mounted) setState(() => media = m);
      }).catchError((_) {});
    }
  }

  /// Ask a follow-up in the same conversation — add, reduce, change anything.
  Future<void> _askFollowUp([String? preset]) async {
    final q = (preset ?? followUp.text).trim();
    if (q.isEmpty || planning || result == null) return;
    Haptics.medium();
    followUp.clear();
    final history = List<Map<String, String>>.from(chat);
    setState(() {
      planning = true;
      error = null;
      justSaved = false;
    });
    try {
      final r = await MediaApi.aiItinerary(q, history: history);
      if (!mounted) return;
      chat
        ..add({'role': 'user', 'content': q})
        ..add({'role': 'assistant', 'content': r.plan});
      setState(() {
        result = r;
        planning = false;
      });
      Haptics.string();
      _saveChat();
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        planning = false;
        error = e.message;
      });
    }
  }

  Future<void> _loadSaved() async {
    final user = AuthApi.currentUser;
    if (user == null) return;
    setState(() => savedLoading = true);
    try {
      final list = await MediaApi.fetchItineraries(user.id);
      if (mounted) setState(() => saved = list);
    } catch (_) {}
    if (mounted) setState(() => savedLoading = false);
  }

  Future<void> _plan([String? preset]) async {
    final q = (preset ?? prompt.text).trim();
    if (q.isEmpty || planning) return;
    if (preset != null) prompt.text = preset;
    Haptics.medium();
    chat.clear();
    chatId = DateTime.now().millisecondsSinceEpoch.toString();
    setState(() {
      planning = true;
      error = null;
      result = null;
      media = null;
      justSaved = false;
      lastQuery = q;
    });
    // Visuals load in parallel with the plan.
    MediaApi.searchMedia(q).then((m) {
      if (mounted && lastQuery == q) setState(() => media = m);
    }).catchError((_) {});
    try {
      final r = await MediaApi.aiItinerary(q);
      if (!mounted || lastQuery != q) return;
      chat
        ..add({'role': 'user', 'content': q})
        ..add({'role': 'assistant', 'content': r.plan});
      setState(() {
        result = r;
        planning = false;
      });
      // Visuals re-target the actual matched place — never random images.
      if (r.places.isNotEmpty) {
        MediaApi.searchMedia(
                '${r.places.first.name} ${r.places.first.location}')
            .then((m) {
          if (mounted && lastQuery == q) setState(() => media = m);
        }).catchError((_) {});
      }
      Haptics.string();
      _saveChat();
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        planning = false;
        error = e.message;
      });
    }
  }

  Future<void> _save() async {
    final user = AuthApi.currentUser;
    final r = result;
    if (r == null || saving || justSaved) return;
    if (user == null) {
      newSnackBar(context, title: 'Sign in to save itineraries.');
      return;
    }
    setState(() => saving = true);
    try {
      final title = lastQuery.length > 60
          ? '${lastQuery.substring(0, 57)}...'
          : lastQuery;
      await MediaApi.saveItinerary(
          userId: user.id, title: title, query: lastQuery, plan: r.plan);
      Haptics.medium();
      if (!mounted) return;
      setState(() {
        saving = false;
        justSaved = true;
      });
      newSnackBar(context, title: 'Saved to your itineraries.');
      _loadSaved();
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() => saving = false);
      newSnackBar(context, title: e.message);
    }
  }

  Future<void> _deleteSaved(SavedItinerary item) async {
    final user = AuthApi.currentUser;
    if (user == null) return;
    final ok = await confirmDialog(
      context,
      title: 'Delete itinerary?',
      message: '"${item.title}" will be removed from your account.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok) return;
    try {
      await MediaApi.deleteItinerary(id: item.id, userId: user.id);
      if (mounted) setState(() => saved.removeWhere((s) => s.id == item.id));
    } on AuthException catch (e) {
      if (mounted) newSnackBar(context, title: e.message);
    }
  }

  /// Wipes the current conversation and inputs — back to the clean page
  /// with saved plans and chat history.
  void _clearConversation() {
    Haptics.tick();
    prompt.clear();
    followUp.clear();
    chat.clear();
    setState(() {
      result = null;
      media = null;
      error = null;
      lastQuery = '';
      chatId = '';
      justSaved = false;
      planning = false;
    });
  }

  void _openSaved(SavedItinerary item) {
    Haptics.light();
    prompt.text = item.query.isEmpty ? item.title : item.query;
    chat
      ..clear()
      ..add({'role': 'user', 'content': prompt.text})
      ..add({'role': 'assistant', 'content': item.plan});
    chatId = 'saved-${item.id}';
    setState(() {
      lastQuery = prompt.text;
      result = ItineraryResult(plan: item.plan);
      media = null;
      error = null;
      justSaved = true; // already in the saved list
    });
    MediaApi.searchMedia(lastQuery).then((m) {
      if (mounted) setState(() => media = m);
    }).catchError((_) {});
  }

  /// Strips stray markdown and normalizes bullets so cards read cleanly.
  String _tidy(String raw) => raw
      .replaceAll(RegExp(r'[*_#`]+'), '')
      .replaceAll(RegExp(r'^\s*[-•]\s*', multiLine: true), '•  ')
      .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
      .trim();

  /// Splits the plain-text plan into intro / day / logistics / tips sections.
  List<MapEntry<String, String>> _sections() {
    final text = _tidy(result?.plan ?? '');
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
    // A short plan with no headers still deserves a proper day card.
    if (sections.length == 1 && sections.first.key.isEmpty) {
      return [MapEntry('Day 1', sections.first.value)];
    }
    return sections;
  }

  (IconData, Color) _sectionStyle(String title) {
    final t = title.toLowerCase();
    if (t.startsWith('tips')) return (Icons.lightbulb_outline, Colors.amber);
    if (t.startsWith('getting there')) return (Icons.flight_takeoff, blue);
    if (t.startsWith('stay')) return (Icons.hotel, Colors.teal);
    if (t.startsWith('day')) return (Icons.route, Colors.purple);
    return (Icons.auto_awesome, Colors.purple);
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
        actions: [
          if (result != null || prompt.text.isNotEmpty)
            IconButton(
              tooltip: 'Clear conversation',
              icon: Icon(Icons.close, color: ink(context)),
              onPressed: _clearConversation,
            ),
        ],
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
                    scrollPadding: const EdgeInsets.only(bottom: 180),
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
          if (result == null && !planning) ...[
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
            ..._savedSection(),
            ..._chatHistorySection(),
          ],
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
          if (result != null) ...[
            // Save under the account, right where the plan starts.
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(lastQuery,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 15)),
                  ),
                  saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.purple))
                      : TextButton.icon(
                          onPressed: justSaved ? null : _save,
                          icon: Icon(
                              justSaved
                                  ? Icons.bookmark_added
                                  : Icons.bookmark_add_outlined,
                              size: 18),
                          label: Text(justSaved ? 'Saved' : 'Save'),
                        ),
                ],
              ),
            ),
            if (chat.length > 2) _conversationTrail(),
            for (var i = 0; i < _sections().length; i++)
              Entrance(index: i, child: _sectionCard(_sections()[i])),
            _followUpComposer(),
            ..._placesSection(result!.places),
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

  /// Saved plans under the account — reopen with a tap, delete with the bin.
  List<Widget> _savedSection() {
    if (AuthApi.currentUser == null) return const [];
    if (!savedLoading && saved.isEmpty) return const [];
    return [
      const Padding(
        padding: EdgeInsets.only(top: 18, bottom: 8),
        child: Text('Saved itineraries',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
      ),
      if (savedLoading)
        const Padding(
          padding: EdgeInsets.all(12),
          child: Center(
              child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.purple))),
        ),
      for (var i = 0; i < saved.length; i++)
        Entrance(
          index: i,
          child: Card(
            color: cardBg(context),
            margin: const EdgeInsets.only(bottom: 8),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: ListTile(
              dense: true,
              leading:
                  const Icon(Icons.bookmark, color: Colors.purple, size: 20),
              title: Text(saved[i].title,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                '${saved[i].createdAt.day}/${saved[i].createdAt.month}/'
                '${saved[i].createdAt.year}',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
              trailing: IconButton(
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline,
                    size: 18, color: Colors.grey),
                onPressed: () => _deleteSaved(saved[i]),
              ),
              onTap: () => _openSaved(saved[i]),
            ),
          ),
        ),
    ];
  }

  /// Matching experiences on the platform — full cards that redirect into
  /// the place page (details, weather, videos, MR/VR).
  List<Widget> _placesSection(List<City> places) {
    if (places.isEmpty) return const [];
    return [
      const Padding(
        padding: EdgeInsets.symmetric(vertical: 10),
        child: Text('Feel it on Mr.TourGuide',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
      ),
      for (final city in places)
        Card(
          color: cardBg(context),
          margin: const EdgeInsets.only(bottom: 10),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          child: ListTile(
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: city.absoluteCoverUrl != null
                  ? Image.network(city.absoluteCoverUrl!,
                      width: 64,
                      height: 48,
                      fit: BoxFit.cover,
                      errorBuilder: (c, e, s) =>
                          const Icon(Icons.place, color: blue, size: 32))
                  : const Icon(Icons.place, color: blue, size: 32),
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
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            trailing: const Icon(Icons.play_circle_fill, color: blue, size: 26),
            onTap: () => feelPlace(context, city),
          ),
        ),
    ];
  }

  /// Breadcrumb of the conversation so far — what you asked, in order.
  Widget _conversationTrail() {
    final asks = [
      for (final m in chat)
        if (m['role'] == 'user') m['content'] ?? ''
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (var i = 0; i < asks.length; i++) ...[
            if (i > 0)
              const Icon(Icons.arrow_forward, size: 12, color: Colors.grey),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.purple
                    .withValues(alpha: i == asks.length - 1 ? 0.16 : 0.08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                asks[i].length > 34 ? '${asks[i].substring(0, 32)}…' : asks[i],
                style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: i == asks.length - 1
                        ? FontWeight.w700
                        : FontWeight.w500,
                    color: Colors.purple),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Continue the chat: ask to add, reduce or change anything in the plan.
  Widget _followUpComposer() {
    return Container(
      margin: const EdgeInsets.only(top: 4, bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [
          Colors.purple.withValues(alpha: 0.07),
          lightBlue.withValues(alpha: 0.09),
        ]),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.purple.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.forum, size: 15, color: Colors.purple),
              SizedBox(width: 6),
              Text('Continue the chat',
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      color: Colors.purple)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: followUp,
                  scrollPadding: const EdgeInsets.only(bottom: 200),
                  onSubmitted: (_) => _askFollowUp(),
                  decoration: const InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: 'Add, reduce or ask anything about this plan…',
                    hintStyle: TextStyle(color: Colors.grey, fontSize: 13),
                  ),
                ),
              ),
              planning
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.purple))
                  : IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.send,
                          size: 18, color: Colors.purple),
                      onPressed: _askFollowUp,
                    ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final t in const [
                'Add one more day',
                'Make it budget-friendly',
                'Wheelchair friendly',
                'Add food stops',
              ])
                ActionChip(
                  visualDensity: VisualDensity.compact,
                  labelStyle: const TextStyle(fontSize: 11.5),
                  label: Text(t),
                  onPressed: planning ? null : () => _askFollowUp(t),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// Recent AI conversations saved on this device — tap to continue.
  List<Widget> _chatHistorySection() {
    if (chatHistory.isEmpty) return const [];
    return [
      const Padding(
        padding: EdgeInsets.only(top: 18, bottom: 8),
        child: Text('Recent AI chats',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
      ),
      for (var i = 0; i < chatHistory.length && i < 8; i++)
        Entrance(
          index: i,
          child: Card(
            color: cardBg(context),
            margin: const EdgeInsets.only(bottom: 8),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.forum, color: Colors.purple, size: 20),
              title: Text('${chatHistory[i]['title']}',
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                '${((chatHistory[i]['messages'] as List).length / 2).floor()} '
                'exchange${(chatHistory[i]['messages'] as List).length > 2 ? 's' : ''}'
                ' · ${(chatHistory[i]['updatedAt'] as String).substring(0, 10)}',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
              trailing: IconButton(
                tooltip: 'Delete',
                icon: const Icon(Icons.close, size: 16, color: Colors.grey),
                onPressed: () => _deleteChat(chatHistory[i]['id'] as String),
              ),
              onTap: () => _openChat(chatHistory[i]),
            ),
          ),
        ),
    ];
  }

  Widget _sectionCard(MapEntry<String, String> section) {
    final (icon, color) = _sectionStyle(section.key);
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
                  Icon(icon, size: 16, color: color),
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
