import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';

import 'constant.dart';
import 'services/auth_api.dart';
import 'services/guidevibe_api.dart';
import 'services/haptic_service.dart';
import 'services/location_service.dart';

/// Creator upload for GuideVibe — pick or record a vertical short, choose the
/// format (Normal / VR / MR), caption + city, preview the audio→haptics feel,
/// and publish. Mirrors the Reels design's "New reel" screen.
class GuideVibeUploadPage extends StatefulWidget {
  const GuideVibeUploadPage({super.key});

  @override
  State<GuideVibeUploadPage> createState() => _GuideVibeUploadPageState();
}

class _GuideVibeUploadPageState extends State<GuideVibeUploadPage> {
  final _caption = TextEditingController();
  final _city = TextEditingController();
  String _kind = 'normal';
  String? _path;
  VideoPlayerController? _preview;
  bool _uploading = false;
  Timer? _hapticPreview;
  int _hapticFrame = -1;

  // Optional soundtrack (royalty-free / Creative-Commons).
  MusicTrack? _music;
  double _musicStart = 0;
  double _uploadProgress = 0;

  @override
  void initState() {
    super.initState();
    LocationService.current().then((loc) {
      if (mounted && loc.$2.isNotEmpty && _city.text.isEmpty) {
        _city.text = loc.$2;
      }
    });
  }

  @override
  void dispose() {
    _caption.dispose();
    _city.dispose();
    _preview?.dispose();
    _hapticPreview?.cancel();
    super.dispose();
  }

  Future<void> _pickFromGallery() async {
    final picked = await FilePicker.platform
        .pickFiles(type: FileType.video, withData: false);
    final f = picked?.files.single;
    if (f?.path != null) _setVideo(f!.path!);
  }

  Future<void> _record() async {
    try {
      final x = await ImagePicker().pickVideo(
        source: ImageSource.camera,
        maxDuration: const Duration(seconds: 90),
      );
      if (x != null) _setVideo(x.path);
    } catch (_) {
      if (mounted) newSnackBar(context, title: 'Could not open the camera.');
    }
  }

  Future<void> _setVideo(String path) async {
    final size = await File(path).length();
    if (size > 80 * 1024 * 1024) {
      if (mounted) {
        newSnackBar(context, title: 'GuideVibe clips are limited to 80 MB.');
      }
      return;
    }
    _preview?.dispose();
    final c = VideoPlayerController.file(File(path));
    try {
      await c.initialize();
      c.setLooping(true);
      c.setVolume(0);
      await c.play();
    } catch (_) {}
    if (!mounted) {
      c.dispose();
      return;
    }
    setState(() {
      _path = path;
      _preview = c;
    });
  }

  /// A short buzzing preview of the auto feel — pulses the phone like the
  /// real thing does during playback.
  void _previewHaptics() {
    _hapticPreview?.cancel();
    var i = 0;
    // A rising-then-settling pattern so the creator feels the mapping.
    const pattern = [0.3, 0.55, 0.8, 1.0, 0.7, 0.45, 0.9, 0.6, 0.35, 0.5];
    setState(() => _hapticFrame = 0);
    _hapticPreview = Timer.periodic(const Duration(milliseconds: 260), (t) {
      if (!mounted || i >= pattern.length) {
        t.cancel();
        if (mounted) setState(() => _hapticFrame = -1);
        return;
      }
      Haptics.level(pattern[i], durationMs: 220);
      setState(() => _hapticFrame = i);
      i++;
    });
  }

  Future<void> _post() async {
    if (_path == null) {
      newSnackBar(context, title: 'Pick or record a video first.');
      return;
    }
    if (AuthApi.currentUser == null) {
      newSnackBar(context, title: 'Sign in to post.');
      return;
    }
    setState(() {
      _uploading = true;
      _uploadProgress = 0;
    });
    try {
      await GuideVibeApi.upload(
        filePath: _path!,
        caption: _caption.text.trim(),
        city: _city.text.trim(),
        kind: _kind,
        musicUrl: _music?.audio,
        musicStart: _musicStart,
        onProgress: (p) {
          if (mounted) setState(() => _uploadProgress = p);
        },
      );
      if (!mounted) return;
      Haptics.medium();
      newSnackBar(context,
          title: 'GuideVibe shared — processing the feel now.');
      Navigator.pop(context, true);
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() => _uploading = false);
      newSnackBar(context, title: e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: pageBg(context),
      appBar: AppBar(
        backgroundColor: cardBg(context),
        elevation: 0,
        title: Text('New GuideVibe',
            style: TextStyle(
                color: ink(context), fontWeight: FontWeight.bold)),
        iconTheme: IconThemeData(color: ink(context)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 40),
        children: [
          _dropZone(),
          const SizedBox(height: 18),
          _label('Video format'),
          const SizedBox(height: 7),
          Row(
            children: [
              _formatChip('normal', 'Normal', Icons.crop_portrait),
              const SizedBox(width: 8),
              _formatChip('vr', 'VR', Icons.view_in_ar),
              const SizedBox(width: 8),
              _formatChip('mr', 'MR', Icons.blur_on),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'VR/MR uploads get the immersive icon on the feed and run the '
              'audio→haptics feel while viewers watch.',
              style: TextStyle(fontSize: 11.5, color: inkSoft(context)),
            ),
          ),
          const SizedBox(height: 18),
          _label('Caption'),
          const SizedBox(height: 7),
          TextField(
            controller: _caption,
            maxLength: 400,
            maxLines: 3,
            style: TextStyle(color: ink(context)),
            decoration: _inputDecoration('Where did this take you?'),
          ),
          const SizedBox(height: 8),
          _label('City'),
          const SizedBox(height: 7),
          TextField(
            controller: _city,
            style: TextStyle(color: ink(context)),
            decoration: _inputDecoration('e.g. Jaipur'),
          ),
          const SizedBox(height: 18),
          _label('Music (optional)'),
          const SizedBox(height: 7),
          _musicSection(),
          const SizedBox(height: 18),
          _hapticsCard(),
          const SizedBox(height: 22),
          _uploading
              ? _uploadingButton()
              : ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: blue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _post,
                  child: const Text('Share GuideVibe',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w800)),
                ),
        ],
      ),
    );
  }

  Widget _dropZone() {
    final c = _preview;
    if (c != null && c.value.isInitialized) {
      return Center(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            height: 320,
            child: AspectRatio(
              aspectRatio: c.value.aspectRatio == 0 ? 9 / 16 : c.value.aspectRatio,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  VideoPlayer(c),
                  Positioned(
                    right: 8,
                    top: 8,
                    child: Material(
                      color: Colors.black54,
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () {
                          _preview?.dispose();
                          setState(() {
                            _preview = null;
                            _path = null;
                          });
                        },
                        child: const Padding(
                          padding: EdgeInsets.all(6),
                          child: Icon(Icons.close,
                              color: Colors.white, size: 18),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return Container(
      height: 280,
      decoration: BoxDecoration(
        border: Border.all(color: inkSoft(context), width: 1.5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.movie_creation_outlined,
              size: 42, color: inkSoft(context)),
          const SizedBox(height: 10),
          Text('Add a vertical video',
              style: TextStyle(
                  color: ink(context),
                  fontSize: 14,
                  fontWeight: FontWeight.w700)),
          Text('mp4 · mov · 9:16 · up to 90s',
              style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: inkSoft(context))),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: _pickFromGallery,
                style: OutlinedButton.styleFrom(
                    foregroundColor: brandInk(context)),
                icon: const Icon(Icons.photo_library_outlined, size: 18),
                label: const Text('Gallery'),
              ),
              const SizedBox(width: 10),
              ElevatedButton.icon(
                onPressed: _record,
                style: ElevatedButton.styleFrom(
                    backgroundColor: blue, foregroundColor: Colors.white),
                icon: const Icon(Icons.videocam, size: 18),
                label: const Text('Record'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _formatChip(String value, String label, IconData icon) {
    final sel = _kind == value;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _kind = value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 11),
          decoration: BoxDecoration(
            color: sel ? blue : cardBg(context),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: sel ? blue : Colors.grey.withValues(alpha: 0.3)),
          ),
          child: Column(
            children: [
              Icon(icon,
                  size: 18, color: sel ? Colors.white : inkSoft(context)),
              const SizedBox(height: 4),
              Text(label,
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: sel ? Colors.white : ink(context))),
            ],
          ),
        ),
      ),
    );
  }

  /// Upload button in progress: a real-time completion bar + percent. The
  /// upload keeps running in the background if the app is switched away.
  Widget _uploadingButton() {
    final pct = (_uploadProgress * 100).round();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: blue,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Uploading…',
                  style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 14)),
              Text('$pct%',
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 14)),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _uploadProgress <= 0 ? null : _uploadProgress,
              minHeight: 6,
              backgroundColor: Colors.white24,
              valueColor: const AlwaysStoppedAnimation(Color(0xFF3CEBFF)),
            ),
          ),
          const SizedBox(height: 8),
          const Text('You can switch apps — it keeps uploading in the '
              'background.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, fontSize: 11)),
        ],
      ),
    );
  }

  int get _videoSeconds =>
      _preview?.value.duration.inSeconds.clamp(1, 600) ?? 15;

  Future<void> _pickMusic() async {
    final picked = await showModalBottomSheet<MusicTrack>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _MusicPickerSheet(),
    );
    if (picked != null && mounted) {
      setState(() {
        _music = picked;
        _musicStart = 0;
      });
    }
  }

  Widget _musicSection() {
    final m = _music;
    if (m == null) {
      return OutlinedButton.icon(
        onPressed: _pickMusic,
        style: OutlinedButton.styleFrom(
          foregroundColor: brandInk(context),
          minimumSize: const Size(double.infinity, 48),
          side: BorderSide(color: Colors.grey.withValues(alpha: 0.3)),
        ),
        icon: const Icon(Icons.library_music_outlined, size: 18),
        label: const Text('Add a song'),
      );
    }
    // How far the start point can slide: track length minus the clip length.
    final maxStart = (m.duration - _videoSeconds).clamp(0, m.duration).toDouble();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.withValues(alpha: 0.3)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: m.image.isNotEmpty
                    ? Image.network(m.image,
                        width: 40,
                        height: 40,
                        fit: BoxFit.cover,
                        errorBuilder: (c, e, s) => _musicIcon())
                    : _musicIcon(),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(m.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: ink(context),
                            fontWeight: FontWeight.w700,
                            fontSize: 13.5)),
                    Text(m.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: inkSoft(context), fontSize: 11.5)),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => setState(() => _music = null),
              ),
            ],
          ),
          if (maxStart > 0) ...[
            const SizedBox(height: 4),
            Text('Start at ${_musicStart.round()}s',
                style: TextStyle(color: inkSoft(context), fontSize: 12)),
            Slider(
              value: _musicStart.clamp(0, maxStart),
              max: maxStart,
              divisions: maxStart.round().clamp(1, 120),
              activeColor: blue,
              onChanged: (v) => setState(() => _musicStart = v),
            ),
          ],
          Text(
            'The chosen ${_videoSeconds}s plays over your clip, and the feel '
            'follows the song.',
            style: TextStyle(color: inkSoft(context), fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _musicIcon() => Container(
        width: 40,
        height: 40,
        color: blue.withValues(alpha: 0.12),
        child: Icon(Icons.music_note, color: brandInk(context), size: 20),
      );

  Widget _hapticsCard() => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.withValues(alpha: 0.3)),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.graphic_eq, size: 18, color: brandInk(context)),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Audio → Haptics',
                          style: TextStyle(
                              color: ink(context),
                              fontWeight: FontWeight.w800,
                              fontSize: 13)),
                      Text('Auto — maps a feel to every frame from the audio',
                          style: TextStyle(
                              color: inkSoft(context), fontSize: 11.5)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // A little equalizer preview that lights up during the preview.
            SizedBox(
              height: 46,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var i = 0; i < 10; i++)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          height: 10.0 + (i % 5) * 7 + (_hapticFrame == i ? 12 : 0),
                          decoration: BoxDecoration(
                            color: _hapticFrame == i
                                ? blue
                                : brandInk(context).withValues(alpha: 0.35),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _previewHaptics,
              style:
                  OutlinedButton.styleFrom(foregroundColor: brandInk(context)),
              icon: const Icon(Icons.play_arrow, size: 18),
              label: const Text('Preview the feel'),
            ),
          ],
        ),
      );

  Widget _label(String text) => Text(
        text.toUpperCase(),
        style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.5,
            color: inkSoft(context)),
      );

  InputDecoration _inputDecoration(String hint) => InputDecoration(
        hintText: hint,
        counterText: '',
        filled: true,
        fillColor: cardBg(context),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.grey.withValues(alpha: 0.3))),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.grey.withValues(alpha: 0.3))),
      );
}

/// Search + preview royalty-free tracks; returns the chosen [MusicTrack].
class _MusicPickerSheet extends StatefulWidget {
  const _MusicPickerSheet();

  @override
  State<_MusicPickerSheet> createState() => _MusicPickerSheetState();
}

class _MusicPickerSheetState extends State<_MusicPickerSheet> {
  final _query = TextEditingController();
  final _player = AudioPlayer();
  Timer? _debounce;
  List<MusicTrack> _results = [];
  bool _loading = true;
  String? _error;
  String? _previewingId;

  @override
  void initState() {
    super.initState();
    _search(''); // popular tracks to start
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    _player.dispose();
    super.dispose();
  }

  void _onChanged(String s) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () => _search(s));
  }

  Future<void> _search(String q) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await GuideVibeApi.searchMusic(q.trim());
      if (!mounted) return;
      setState(() {
        _results = list;
        _loading = false;
        if (list.isEmpty) {
          _error = 'No tracks found. The music library may not be enabled yet.';
        }
      });
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    }
  }

  Future<void> _togglePreview(MusicTrack t) async {
    if (_previewingId == t.id) {
      await _player.stop();
      setState(() => _previewingId = null);
      return;
    }
    setState(() => _previewingId = t.id);
    try {
      await _player.stop();
      await _player.play(UrlSource(t.audio));
      _player.onPlayerComplete.listen((_) {
        if (mounted) setState(() => _previewingId = null);
      });
    } catch (_) {
      if (mounted) setState(() => _previewingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: DraggableScrollableSheet(
        initialChildSize: 0.8,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scroll) => Container(
          decoration: BoxDecoration(
            color: cardBg(context),
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                    color: Colors.grey.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
                child: TextField(
                  controller: _query,
                  autofocus: true,
                  onChanged: _onChanged,
                  style: TextStyle(color: ink(context)),
                  decoration: InputDecoration(
                    hintText: 'Search songs (e.g. lofi, cinematic, sitar)…',
                    prefixIcon: const Icon(Icons.search),
                    filled: true,
                    fillColor: pageBg(context),
                    contentPadding: const EdgeInsets.symmetric(vertical: 4),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(999),
                        borderSide: BorderSide.none),
                  ),
                ),
              ),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _error != null
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(_error!,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: inkSoft(context))),
                            ),
                          )
                        : ListView.builder(
                            controller: scroll,
                            itemCount: _results.length,
                            itemBuilder: (context, i) {
                              final t = _results[i];
                              final playing = _previewingId == t.id;
                              return ListTile(
                                leading: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: t.image.isNotEmpty
                                      ? Image.network(t.image,
                                          width: 46,
                                          height: 46,
                                          fit: BoxFit.cover,
                                          errorBuilder: (c, e, s) =>
                                              _ph())
                                      : _ph(),
                                ),
                                title: Text(t.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style:
                                        const TextStyle(fontWeight: FontWeight.w600)),
                                subtitle: Text('${t.artist} · ${t.duration}s',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: Icon(playing
                                          ? Icons.stop_circle
                                          : Icons.play_circle_outline),
                                      color: brandInk(context),
                                      onPressed: () => _togglePreview(t),
                                    ),
                                    FilledButton(
                                      style: FilledButton.styleFrom(
                                          backgroundColor: blue,
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 12),
                                          visualDensity: VisualDensity.compact),
                                      onPressed: () =>
                                          Navigator.pop(context, t),
                                      child: const Text('Use'),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
              ),
              Padding(
                padding: const EdgeInsets.all(10),
                child: Text(
                  '30-second previews · Hindi & global songs.',
                  style: TextStyle(color: inkSoft(context), fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _ph() => Container(
        width: 46,
        height: 46,
        color: blue.withValues(alpha: 0.12),
        child: Icon(Icons.music_note, color: brandInk(context), size: 20),
      );
}
