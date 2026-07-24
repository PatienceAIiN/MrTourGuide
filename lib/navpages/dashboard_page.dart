import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart' as ap;
import 'package:geolocator/geolocator.dart';
import 'package:record/record.dart';
import 'package:video_player/video_player.dart';

import '../constant.dart';
import '../experience_player.dart';
import '../fine_tune_page.dart';
import '../guidevibe_page.dart';
import '../services/auth_api.dart';
import '../services/haptic_service.dart';
import '../services/image_tools.dart';
import '../services/media_api.dart';
import '../services/tab_events.dart';
import '../widgets/ux.dart';

/// Experience-video dashboard.
///
/// Travelers browse and play city experiences; creators additionally upload
/// (stored in a local folder for now — Cloudflare R2 later) and tune each
/// video's feel/sound configuration. New uploads show "Processing" while the
/// ML pipeline trims/enhances and generates the haptic track, then flip to
/// ready automatically.
class DashboardPage extends StatefulWidget {
  final void Function(int index)? onSelectTab;
  const DashboardPage({super.key, this.onSelectTab});

  static const int pageSize = 2;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  List<City> cities = [];
  String? selectedCity;
  final List<VideoItem> videos = [];
  bool hasMore = false;
  bool loadingCities = true;
  bool loadingVideos = false;
  bool uploading = false;
  String? error;
  Timer? _pollTimer;

  /// 'mine' shows own uploads (any status), 'catalog' the public feed.
  /// Creators land on their studio; travelers land on the catalog but can
  /// switch to manage their own uploads too.
  String studioFeed =
      (AuthApi.currentUser?.isCreator ?? false) ? 'mine' : 'catalog';

  bool get _mineMode => AuthApi.currentUser != null && studioFeed == 'mine';

  Timer? _syncTimer;

  @override
  void initState() {
    super.initState();
    _loadCities();
    // Realtime feel: quiet resync every 45s — new uploads and counts just
    // appear, no pull-to-refresh needed (catalog GETs are edge-cached).
    _syncTimer = Timer.periodic(const Duration(seconds: 45), (_) {
      if (mounted) _silentSync();
    });
    TabEvents.changed.addListener(_onTabChanged);
    // Push-driven instant refresh (new video ready, new place...).
    ContentEvents.refresh.addListener(_onContentPing);
  }

  void _onTabChanged() {
    // Landing on this tab always shows the freshest catalog.
    if (mounted && TabEvents.changed.value == 1) _silentSync();
  }

  Future<void> _silentSync() async {
    try {
      final result = await MediaApi.fetchCities(
          mine: AuthApi.currentUser?.isCreator ?? false);
      if (!mounted) return;
      setState(() {
        cities = result;
        error = null; // fresh data — retire any stale failure banner
      });
      final city = selectedCity;
      if (city == null) return;
      final page = await MediaApi.fetchVideos(city,
          offset: 0, limit: videos.length.clamp(2, 50), mine: _mineMode);
      if (!mounted) return;
      setState(() {
        videos
          ..clear()
          ..addAll(page.videos);
        hasMore = page.hasMore;
      });
      _managePolling();
    } catch (_) {}
  }

  void _onContentPing() {
    if (mounted) _silentSync();
  }

  @override
  void dispose() {
    ContentEvents.refresh.removeListener(_onContentPing);
    TabEvents.changed.removeListener(_onTabChanged);
    _syncTimer?.cancel();
    _pollTimer?.cancel();
    super.dispose();
  }

  /// While any visible video is still processing, poll so the "Processing"
  /// chip flips to ready without manual refreshes.
  void _managePolling() {
    final anyProcessing = videos.any((v) => v.isProcessing);
    if (anyProcessing && _pollTimer == null) {
      _pollTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
        final shown = videos.length;
        final city = selectedCity;
        if (city == null) return;
        try {
          final page = await MediaApi.fetchVideos(city,
              offset: 0, limit: shown.clamp(1, 50), mine: _mineMode);
          if (!mounted) return;
          setState(() {
            videos
              ..clear()
              ..addAll(page.videos);
          });
          _managePolling();
        } catch (_) {}
      });
    } else if (!anyProcessing) {
      _pollTimer?.cancel();
      _pollTimer = null;
    }
  }

  Future<void> _loadCities() async {
    setState(() {
      loadingCities = true;
      error = null;
    });
    try {
      final result = await MediaApi.fetchCities(
          mine: AuthApi.currentUser?.isCreator ?? false);
      if (!mounted) return;
      setState(() {
        cities = result;
        loadingCities = false;
        selectedCity ??= result.isNotEmpty ? result.first.slug : null;
      });
      if (selectedCity != null) await _reloadVideos();
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        loadingCities = false;
        error = e.message;
      });
    }
  }

  Future<void> _reloadVideos() async {
    videos.clear();
    hasMore = false;
    await _loadMore();
  }

  Future<void> _loadMore() async {
    final city = selectedCity;
    if (city == null || loadingVideos) return;
    setState(() {
      loadingVideos = true;
      error = null;
    });
    try {
      final page = await MediaApi.fetchVideos(
        city,
        offset: videos.length,
        limit: DashboardPage.pageSize,
        mine: _mineMode,
      );
      if (!mounted) return;
      setState(() {
        videos.addAll(page.videos);
        hasMore = page.hasMore;
        loadingVideos = false;
      });
      _managePolling();
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        loadingVideos = false;
        error = e.message;
      });
    }
  }

  /// The creator handbook: how Normal / VR / MR uploads are processed.
  Future<void> _creatorGuide() {
    Haptics.tick();
    Widget row(IconData icon, Color color, String title, String body) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10)),
                child: Icon(icon, size: 18, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 13.5)),
                    const SizedBox(height: 2),
                    Text(body,
                        style: const TextStyle(
                            fontSize: 12, height: 1.45, color: Colors.grey)),
                  ],
                ),
              ),
            ],
          ),
        );
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: cardBg(context),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        maxChildSize: 0.93,
        builder: (context, scroll) => ListView(
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
            const Text('Creator guide',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
            const SizedBox(height: 4),
            const Text(
              'How your uploads become experiences people can feel.',
              style: TextStyle(fontSize: 12.5, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            row(
                Icons.smart_display,
                blue,
                'Normal video',
                'Any standard capture (MP4, MOV, MKV... up to 95 MB). It is '
                    'trimmed, enhanced and published with a feel track built '
                    'from its sound.'),
            row(
                Icons.vrpano,
                Colors.purple,
                'VR 360\u00b0',
                'Record or export in equirectangular 360\u00b0 \u2014 the '
                    'frame must be about twice as wide as tall (2:1). Flat '
                    'videos are rejected at upload so viewers never get a '
                    'broken VR experience.'),
            row(
                Icons.view_in_ar,
                Colors.deepPurple,
                'MR',
                'Mixed-reality captures follow the same 360\u00b0 rule. '
                    'Pair the place with a 3D model (via the web studio) for '
                    'the full MR/VR page experience.'),
            row(
                Icons.waves,
                Colors.purpleAccent,
                'Feel (haptics)',
                'During processing we analyse the audio \u2014 music, wind, '
                    'crowd, ambience \u2014 and turn its energy into a '
                    'second-by-second vibration track. Quiet moments feel '
                    'light, loud ones heavy.'),
            row(
                Icons.equalizer,
                Colors.purple,
                'Per-frame fine-tuning',
                'After processing, tap the equalizer icon on your video to '
                    'open the feel studio: drag each second\u2019s bar to '
                    'sculpt exactly how it vibrates. Preview live while '
                    'playing, then save.'),
            row(
                Icons.image_outlined,
                Colors.teal,
                'Thumbnails & covers',
                'A poster frame is auto-picked; set your own (like YouTube '
                    'Studio) from the publish window or the image icon on '
                    'the card. Place covers power the home carousel.'),
            row(
                Icons.add_location_alt,
                Colors.orange,
                'Places & location',
                'Enroll new places with the "Add place" chip. Tag each '
                    'upload with country/state/city \u2014 location '
                    'searches then surface your experience.'),
            row(
                Icons.play_circle_outline_rounded,
                const Color(0xFFFF4D5E),
                'GuideVibe shorts',
                'Vertical short clips, max 1 minute and 20 MB (MP4, MOV or '
                    'WebM). Add a caption, city, VR/MR tag and an optional '
                    'music clip \u2014 we mux it in, build the feel track '
                    'and publish to the swipe feed. Find GuideVibe in the '
                    'switch above (My uploads \u00b7 Catalog \u00b7 '
                    'GuideVibe).'),
            row(
                Icons.lock_clock,
                Colors.grey,
                'Limits',
                'Experience uploads are video-only, max 95 MB; community '
                    'post videos up to 80 MB; GuideVibe shorts up to 20 MB '
                    'and 1 minute. Processing takes under a minute. Your '
                    'uploads stay yours \u2014 only you can rename, '
                    'configure, fine-tune or delete them.'),
          ],
        ),
      ),
    );
  }

  Future<void> _upload() async {
    // Empty catalog is fine: the publish sheet enrolls the place from the
    // City field, so the very first upload can create the first place.
    final city = selectedCity ?? '';
    if (uploading) return;

    // Mobile streams straight from disk (large videos never sit in RAM);
    // web needs the bytes.
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.video,
      withData: kIsWeb,
    );
    final file = picked?.files.single;
    if (file == null || (kIsWeb ? file.bytes == null : file.path == null)) {
      return;
    }
    if (!mounted) return;
    const videoExts = {
      'mp4',
      'mov',
      'm4v',
      'mkv',
      'webm',
      'avi',
      '3gp',
      '3g2',
      'mts',
      'm2ts'
    };
    final ext = file.name.split('.').last.toLowerCase();
    if (!videoExts.contains(ext)) {
      newSnackBar(context,
          title: 'Only video files can be published (MP4, MOV, MKV...).');
      return;
    }
    if (file.size > 95 * 1024 * 1024) {
      newSnackBar(context,
          title: 'Videos over 95 MB cannot pass the CDN yet — please trim '
              'or compress and try again.');
      return;
    }

    await _uploadControlSheet(city, file.name,
        bytes: file.bytes, path: file.path, sizeBytes: file.size);
  }

  /// A platform place whose name matches the typed city (case-insensitive).
  City? _knownPlace(String name) {
    final n = name.trim().toLowerCase();
    if (n.isEmpty) return null;
    for (final c in cities) {
      if (c.name.toLowerCase() == n || c.slug == n.replaceAll(' ', '-')) {
        return c;
      }
    }
    return null;
  }

  /// GPS → (country, state, city) via the backend's reverse geocoder.
  /// Every value stays editable — auto-fill, correct manually.
  Future<(String, String, String)?> _fetchDeviceLocation() async {
    if (kIsWeb) return null;
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.low, timeLimit: Duration(seconds: 10)),
      );
      return await MediaApi.geoReverse(pos.latitude, pos.longitude);
    } catch (_) {
      return null;
    }
  }

  /// True when the picked video is an immersive capture: VR/MR needs an
  /// equirectangular 360° frame, which is (about) twice as wide as tall.
  Future<bool> _probeImmersive({Uint8List? bytes, String? path}) async {
    if (kIsWeb) return true; // probing needs a file; web is dev-only
    File? tmp;
    VideoPlayerController? probe;
    try {
      var target = path;
      if (target == null) {
        tmp = File('${Directory.systemTemp.path}/'
            'mrt_probe_${DateTime.now().millisecondsSinceEpoch}.mp4');
        await tmp.writeAsBytes(bytes!);
        target = tmp.path;
      }
      probe = VideoPlayerController.file(File(target));
      await probe.initialize().timeout(const Duration(seconds: 12));
      final size = probe.value.size;
      if (size.width <= 0 || size.height <= 0) return false;
      final ratio = size.width / size.height;
      return ratio >= 1.85 && ratio <= 2.15;
    } catch (_) {
      return false;
    } finally {
      await probe?.dispose();
      try {
        await tmp?.delete();
      } catch (_) {}
    }
  }

  Future<void> _notImmersiveDialog() => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          icon: const Icon(Icons.vrpano, color: Colors.purple, size: 36),
          title: const Text('Not VR/MR compatible'),
          content: const Text(
            'This video is not compatible for a VR/MR experience — it is a '
            'flat capture, not a 360° one. Record or export in '
            'equirectangular 360° format (2:1) and try again, or publish it '
            'as a Normal experience.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, height: 1.5),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Got it'),
            ),
          ],
        ),
      );

  /// Per-frame controls popup shown at publish time: the creator shapes
  /// the starting feel here; the frame-by-frame studio (equalizer icon)
  /// unlocks the full timeline once processing finishes.
  Future<ExperienceConfig?> _perFrameControlsDialog(ExperienceConfig config) {
    var working = config;
    return showDialog<ExperienceConfig>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDlg) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          title: const Row(
            children: [
              Icon(Icons.tune, color: Colors.purple, size: 20),
              SizedBox(width: 8),
              Text('Per-frame controls', style: TextStyle(fontSize: 16)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Set the base feel now; after processing, tap the equalizer '
                'icon on the video to sculpt every second on the timeline.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.waves, color: Colors.purple),
                title: const Text('Base feel intensity'),
                subtitle: Slider(
                  value: working.intensity,
                  divisions: 10,
                  label: '${(working.intensity * 100).round()}%',
                  activeColor: Colors.purpleAccent,
                  onChanged: (v) {
                    if ((v * 10).round() != (working.intensity * 10).round()) {
                      Haptics.level(v);
                    }
                    setDlg(() => working = working.copyWith(intensity: v));
                  },
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Haptics'),
                value: working.haptics,
                onChanged: (v) =>
                    setDlg(() => working = working.copyWith(haptics: v)),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Sound'),
                value: working.sound,
                onChanged: (v) =>
                    setDlg(() => working = working.copyWith(sound: v)),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(context, working),
                child: const Text('Apply')),
          ],
        ),
      ),
    );
  }

  /// The publish control window: everything about the experience is set
  /// here before upload — title, video type (Normal / VR 360° / MR), feel
  /// mapping (auto ML track or per-frame fine-tuning), feel intensity and
  /// playback defaults.
  Future<void> _uploadControlSheet(
    String city,
    String filename, {
    Uint8List? bytes,
    String? path,
    required int sizeBytes,
  }) async {
    final titleCtl = TextEditingController(
      text: filename.replaceAll(RegExp(r'\.[^.]+$'), '').replaceAll('_', ' '),
    );
    var config = const ExperienceConfig();
    var busy = false;
    double uploadPct = 0;
    bool? immersiveOk; // probed once, on first VR/MR selection
    var probing = false;
    Uint8List? thumbBytes;
    String thumbName = '';
    var targetCity = city; // creator picks the destination in the sheet
    final cityCtl = TextEditingController();
    final stateCtl = TextEditingController();
    final countryCtl = TextEditingController();
    // Location defaults follow the chosen place's catalog line.
    void prefillLocation(String slug) {
      if (slug.isEmpty) {
        countryCtl.text = 'India';
        return;
      }
      final parts = cities
          .firstWhere((c) => c.slug == slug,
              orElse: () => City(slug: slug, name: slug, videoCount: 0))
          .location
          .split(',');
      cityCtl.text = parts.isNotEmpty ? parts.first.trim() : '';
      stateCtl.text = parts.length > 1 ? parts[1].trim() : '';
      countryCtl.text = parts.length > 2 ? parts[2].trim() : 'India';
    }

    prefillLocation(targetCity);
    final sizeMb = (sizeBytes / (1024 * 1024)).toStringAsFixed(1);
    var locating = false;
    // Optional soundtrack: pick a track or record a voice-over, then align
    // and balance it — the backend muxes it into the video while processing.
    Uint8List? audioBytes;
    var audioName = '';
    var audioMode = 'mix';
    double audioOffset = 0;
    double origVol = 1;
    double audioVol = 1;
    var recording = false;
    final recorder = AudioRecorder();
    final audioPreview = ap.AudioPlayer();
    var previewing = false;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: cardBg(context),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheet) => ConstrainedBox(
          // Never taller than the screen — the content scrolls instead of
          // pushing the sheet out of view.
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(sheetContext).size.height * 0.88),
          child: Padding(
            padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 14,
                bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 20),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
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
                  const Row(
                    children: [
                      Icon(Icons.cloud_upload, color: blue, size: 20),
                      SizedBox(width: 8),
                      Text('Publish experience',
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 16)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text('$filename · $sizeMb MB',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.grey, fontSize: 12)),
                  const SizedBox(height: 14),
                  TextField(
                    controller: titleCtl,
                    scrollPadding: const EdgeInsets.only(bottom: 200),
                    decoration: const InputDecoration(
                      labelText: 'Experience title',
                      hintText: 'e.g. Taj Mahal Sunrise',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text('Video type',
                      style:
                          TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                  const SizedBox(height: 8),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                          value: 'normal',
                          icon: Icon(Icons.smart_display, size: 16),
                          label: Text('Normal')),
                      ButtonSegment(
                          value: 'vr',
                          icon: Icon(Icons.vrpano, size: 16),
                          label: Text('VR 360°')),
                      ButtonSegment(
                          value: 'mr',
                          icon: Icon(Icons.view_in_ar, size: 16),
                          label: Text('MR')),
                    ],
                    selected: {config.kind},
                    onSelectionChanged: (s) async {
                      final kind = s.first;
                      if (kind != 'normal') {
                        // Gate VR/MR behind a real 360° compatibility check.
                        if (immersiveOk == null) {
                          setSheet(() => probing = true);
                          immersiveOk =
                              await _probeImmersive(bytes: bytes, path: path);
                          setSheet(() => probing = false);
                        }
                        if (immersiveOk != true) {
                          Haptics.heavy();
                          await _notImmersiveDialog();
                          return; // stays on the current type
                        }
                      }
                      Haptics.tick();
                      setSheet(() => config = config.copyWith(kind: kind));
                    },
                  ),
                  if (probing)
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Row(
                        children: [
                          SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(strokeWidth: 2)),
                          SizedBox(width: 8),
                          Text('Checking 360° compatibility…',
                              style: TextStyle(
                                  fontSize: 11.5, color: Colors.grey)),
                        ],
                      ),
                    ),
                  const SizedBox(height: 16),
                  const Text('Feel mapping',
                      style:
                          TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      ChoiceChip(
                        avatar: const Icon(Icons.auto_awesome, size: 15),
                        label: const Text('Auto (ML haptic track)'),
                        selected: config.feelMode == 'auto',
                        onSelected: (_) {
                          Haptics.tick();
                          setSheet(
                              () => config = config.copyWith(feelMode: 'auto'));
                        },
                      ),
                      ChoiceChip(
                        avatar: const Icon(Icons.tune, size: 15),
                        label: const Text('Per-frame (fine control)'),
                        selected: config.feelMode == 'perframe',
                        onSelected: (_) async {
                          Haptics.tick();
                          setSheet(() =>
                              config = config.copyWith(feelMode: 'perframe'));
                          // The controls, right here in a popup.
                          final updated = await _perFrameControlsDialog(config);
                          if (updated != null) {
                            setSheet(() => config = updated);
                          }
                        },
                      ),
                    ],
                  ),
                  if (config.feelMode == 'perframe')
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text(
                        'After processing, open Experience settings on the video '
                        'to fine-tune the feel frame by frame.',
                        style: TextStyle(color: Colors.grey, fontSize: 11.5),
                      ),
                    ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Text('Location',
                          style: TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 13)),
                      const Spacer(),
                      locating
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : TextButton.icon(
                              style: TextButton.styleFrom(
                                  visualDensity: VisualDensity.compact),
                              icon: const Icon(Icons.my_location, size: 14),
                              label: const Text('Use my location',
                                  style: TextStyle(fontSize: 11.5)),
                              onPressed: () async {
                                setSheet(() => locating = true);
                                final loc = await _fetchDeviceLocation();
                                setSheet(() => locating = false);
                                if (loc == null) {
                                  if (context.mounted) {
                                    newSnackBar(context,
                                        title: 'Could not get your location — '
                                            'fill it in manually.');
                                  }
                                  return;
                                }
                                setSheet(() {
                                  if (loc.$1.isNotEmpty) {
                                    countryCtl.text = loc.$1;
                                  }
                                  if (loc.$2.isNotEmpty) stateCtl.text = loc.$2;
                                  if (loc.$3.isNotEmpty) cityCtl.text = loc.$3;
                                });
                              },
                            ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: countryCtl,
                          scrollPadding: const EdgeInsets.only(bottom: 200),
                          decoration: const InputDecoration(
                              labelText: 'Country',
                              isDense: true,
                              border: OutlineInputBorder()),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: cityCtl,
                          scrollPadding: const EdgeInsets.only(bottom: 200),
                          onChanged: (v) {
                            // Typing a known place re-syncs its country so
                            // the config never keeps stale location data.
                            final match = _knownPlace(v);
                            if (match != null) {
                              final parts = match.location.split(',');
                              if (parts.length > 1) {
                                countryCtl.text = parts.last.trim();
                              }
                            }
                            setSheet(() {});
                          },
                          decoration: const InputDecoration(
                              labelText: 'City',
                              isDense: true,
                              border: OutlineInputBorder()),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  const Text(
                    'Searches for this state or country will surface the '
                    'experience.',
                    style: TextStyle(color: Colors.grey, fontSize: 11),
                  ),
                  const SizedBox(height: 16),
                  const Text('Thumbnail',
                      style:
                          TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: thumbBytes != null
                            ? Image.memory(thumbBytes!,
                                width: 96, height: 56, fit: BoxFit.cover)
                            : Container(
                                width: 96,
                                height: 56,
                                color: Colors.grey.withValues(alpha: 0.18),
                                child: const Icon(Icons.image_outlined,
                                    color: Colors.grey),
                              ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            OutlinedButton.icon(
                              icon: const Icon(Icons.add_photo_alternate,
                                  size: 16),
                              label: Text(thumbBytes == null
                                  ? 'Custom thumbnail'
                                  : 'Change'),
                              onPressed: () async {
                                final img = await FilePicker.platform.pickFiles(
                                    type: FileType.image, withData: true);
                                final f = img?.files.single;
                                if (f == null || f.bytes == null) return;
                                if (f.bytes!.length > 5 * 1024 * 1024) {
                                  newSnackBar(context,
                                      title: 'Thumbnails are limited to 5 MB.');
                                  return;
                                }
                                final clean = await normalizeImage(f.bytes!);
                                setSheet(() {
                                  thumbBytes = clean;
                                  thumbName = 'thumb.png';
                                });
                              },
                            ),
                            Text(
                              thumbBytes == null
                                  ? 'Auto: a frame is picked from the video.'
                                  : thumbName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 11, color: Colors.grey),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.waves, color: Colors.purple),
                    title: const Text('Feel intensity'),
                    subtitle: Slider(
                      value: config.intensity,
                      divisions: 10,
                      label: '${(config.intensity * 100).round()}%',
                      activeColor: Colors.purpleAccent,
                      onChanged: (v) {
                        if ((v * 10).round() !=
                            (config.intensity * 10).round()) {
                          Haptics.level(v);
                        }
                        setSheet(() => config = config.copyWith(intensity: v));
                      },
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Haptics (real feel)'),
                    secondary:
                        const Icon(Icons.vibration, color: Colors.purple),
                    value: config.haptics,
                    activeThumbColor: blue,
                    onChanged: (v) =>
                        setSheet(() => config = config.copyWith(haptics: v)),
                  ),
                  const SizedBox(height: 16),
                  const Text('Soundtrack (optional)',
                      style:
                          TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.library_music, size: 17),
                          label: const Text('Add audio',
                              style: TextStyle(fontSize: 12.5)),
                          onPressed: () async {
                            try {
                              final picked =
                                  await FilePicker.platform.pickFiles(
                                type: FileType.audio,
                                withData: true,
                              );
                              final f = picked?.files.single;
                              if (f?.bytes == null) return;
                              if (f!.bytes!.length > 10 * 1024 * 1024) {
                                if (context.mounted) {
                                  newSnackBar(context,
                                      title: 'Audio is limited to 10 MB.');
                                }
                                return;
                              }
                              setSheet(() {
                                audioBytes = f.bytes;
                                audioName = f.name;
                              });
                            } catch (_) {}
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: Icon(recording ? Icons.stop : Icons.mic,
                              size: 17,
                              color: recording ? Colors.red : null),
                          label: Text(recording ? 'Stop' : 'Record voice',
                              style: TextStyle(
                                  fontSize: 12.5,
                                  color: recording ? Colors.red : null)),
                          onPressed: () async {
                            if (recording) {
                              final p = await recorder.stop();
                              if (p == null) {
                                setSheet(() => recording = false);
                                return;
                              }
                              final rec = await File(p).readAsBytes();
                              setSheet(() {
                                recording = false;
                                if (rec.length <= 10 * 1024 * 1024) {
                                  audioBytes = rec;
                                  audioName = 'voice-over.m4a';
                                }
                              });
                              if (rec.length > 10 * 1024 * 1024 &&
                                  context.mounted) {
                                newSnackBar(context,
                                    title:
                                        'Recording exceeded 10 MB — try a shorter take.');
                              }
                              return;
                            }
                            if (!await recorder.hasPermission()) {
                              if (context.mounted) {
                                newSnackBar(context,
                                    title:
                                        'Microphone permission is needed to record.');
                              }
                              return;
                            }
                            final path =
                                '${Directory.systemTemp.path}/mrt_vo_${DateTime.now().millisecondsSinceEpoch}.m4a';
                            await recorder.start(
                                const RecordConfig(
                                    encoder: AudioEncoder.aacLc),
                                path: path);
                            setSheet(() => recording = true);
                          },
                        ),
                      ),
                    ],
                  ),
                  if (audioBytes != null) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: Icon(
                              previewing
                                  ? Icons.stop_circle
                                  : Icons.play_circle,
                              color: blue),
                          onPressed: () async {
                            if (previewing) {
                              await audioPreview.stop();
                              setSheet(() => previewing = false);
                            } else {
                              await audioPreview
                                  .play(ap.BytesSource(audioBytes!));
                              setSheet(() => previewing = true);
                              audioPreview.onPlayerComplete.first.then((_) {
                                previewing = false;
                                try {
                                  setSheet(() {});
                                } catch (_) {}
                              });
                            }
                          },
                        ),
                        Expanded(
                          child: Text(
                            '$audioName · ${(audioBytes!.length / (1024 * 1024)).toStringAsFixed(1)} MB',
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.close, size: 17),
                          onPressed: () async {
                            await audioPreview.stop();
                            setSheet(() {
                              audioBytes = null;
                              audioName = '';
                              previewing = false;
                            });
                          },
                        ),
                      ],
                    ),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(
                            value: 'mix',
                            icon: Icon(Icons.multitrack_audio, size: 15),
                            label: Text('Mix over original')),
                        ButtonSegment(
                            value: 'replace',
                            icon: Icon(Icons.swap_horiz, size: 15),
                            label: Text('Replace audio')),
                      ],
                      selected: {audioMode},
                      onSelectionChanged: (v) =>
                          setSheet(() => audioMode = v.first),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        const SizedBox(
                            width: 86,
                            child: Text('Starts at',
                                style: TextStyle(fontSize: 12))),
                        Expanded(
                          child: Slider(
                            value: audioOffset,
                            max: 60,
                            divisions: 60,
                            label: '${audioOffset.round()}s',
                            onChanged: (v) =>
                                setSheet(() => audioOffset = v),
                          ),
                        ),
                        SizedBox(
                            width: 34,
                            child: Text('${audioOffset.round()}s',
                                style: const TextStyle(fontSize: 12))),
                      ],
                    ),
                    if (audioMode == 'mix') ...[
                      Row(
                        children: [
                          const SizedBox(
                              width: 86,
                              child: Text('Original vol',
                                  style: TextStyle(fontSize: 12))),
                          Expanded(
                            child: Slider(
                              value: origVol,
                              max: 1.5,
                              divisions: 15,
                              label: '${(origVol * 100).round()}%',
                              onChanged: (v) => setSheet(() => origVol = v),
                            ),
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          const SizedBox(
                              width: 86,
                              child: Text('Added vol',
                                  style: TextStyle(fontSize: 12))),
                          Expanded(
                            child: Slider(
                              value: audioVol,
                              max: 1.5,
                              divisions: 15,
                              label: '${(audioVol * 100).round()}%',
                              onChanged: (v) => setSheet(() => audioVol = v),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                  const SizedBox(height: 6),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Sound experience'),
                    secondary: const Icon(Icons.volume_up, color: blue),
                    value: config.sound,
                    activeThumbColor: blue,
                    onChanged: (v) =>
                        setSheet(() => config = config.copyWith(sound: v)),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Autoplay for viewers'),
                    secondary: const Icon(Icons.play_circle, color: blue),
                    value: config.autoplay,
                    activeThumbColor: blue,
                    onChanged: (v) =>
                        setSheet(() => config = config.copyWith(autoplay: v)),
                  ),
                  const SizedBox(height: 10),
                  LoadingButton(
                    busy: busy,
                    // Live percentage straight from the transfer engine.
                    label: busy
                        ? (uploadPct >= 0.99
                            ? 'Processing…'
                            : 'Uploading ${(uploadPct * 100).round()}%')
                        : 'Upload & publish',
                    icon: Icons.cloud_upload,
                    onPressed: () async {
                      final title = titleCtl.text.trim();
                      if (title.isEmpty) {
                        newSnackBar(context, title: 'Give the video a title.');
                        return;
                      }
                      final placeName = cityCtl.text.trim();
                      if (placeName.isEmpty) {
                        newSnackBar(context,
                            title: 'Set the city — it decides where this '
                                'experience lives.');
                        return;
                      }
                      setSheet(() => busy = true);
                      setState(() => uploading = true);
                      config = config.copyWith(
                        country: countryCtl.text.trim(),
                        state: stateCtl.text.trim(),
                        cityName: placeName,
                      );
                      // Resolve the destination in realtime: an existing
                      // place matches by name; a new one enrolls now.
                      final known = _knownPlace(placeName);
                      if (known != null) {
                        targetCity = known.slug;
                      } else {
                        try {
                          await MediaApi.addCity(
                            name: placeName,
                            location: [
                              placeName,
                              if (stateCtl.text.trim().isNotEmpty)
                                stateCtl.text.trim(),
                              if (countryCtl.text.trim().isNotEmpty)
                                countryCtl.text.trim(),
                            ].join(', '),
                          );
                          await _loadCities();
                          targetCity =
                              _knownPlace(placeName)?.slug ?? targetCity;
                        } on AuthException catch (e) {
                          setSheet(() => busy = false);
                          setState(() => uploading = false);
                          newSnackBar(context, title: e.message);
                          return;
                        }
                      }
                      try {
                        // Soundtrack goes up first (small) so the video
                        // upload can reference it for the server-side mux.
                        String? audioId;
                        if (audioBytes != null) {
                          audioId = await MediaApi.uploadVideoAudio(
                              filename: audioName.isEmpty
                                  ? 'audio.m4a'
                                  : audioName,
                              bytes: audioBytes!);
                        }
                        final video = await MediaApi.uploadVideo(
                          city: targetCity,
                          title: title,
                          filename: filename,
                          bytes: bytes,
                          filePath: path,
                          audioId: audioId,
                          audioOffset: audioOffset,
                          audioMode: audioMode,
                          origVol: origVol,
                          audioVol: audioVol,
                          onProgress: (p) =>
                              setSheet(() => uploadPct = p),
                        );
                        // Apply the creator's control settings right away.
                        try {
                          await MediaApi.updateConfig(video.id, config);
                        } catch (_) {}
                        if (thumbBytes != null) {
                          try {
                            await MediaApi.uploadThumbnail(
                                videoId: video.id,
                                filename: thumbName,
                                bytes: thumbBytes!);
                          } catch (_) {}
                        }
                        if (!mounted) return;
                        setState(() {
                          uploading = false;
                          // Show the fresh upload IMMEDIATELY with its
                          // "Processing" chip — no waiting on a refetch.
                          selectedCity = targetCity;
                          videos.removeWhere((v) => v.id == video.id);
                          videos.insert(0, video);
                        });
                        _managePolling();
                        if (sheetContext.mounted) Navigator.pop(sheetContext);
                        newSnackBar(context,
                            title: 'Uploaded! Processing feel & sound for '
                                '"$title"...');
                        await _loadCities(); // refresh counts + list
                      } on AuthException catch (e) {
                        if (!mounted) return;
                        setState(() => uploading = false);
                        setSheet(() => busy = false);
                        newSnackBar(context, title: e.message);
                      }
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    try {
      await recorder.stop();
    } catch (_) {}
    recorder.dispose();
    audioPreview.dispose();
    if (mounted && uploading) setState(() => uploading = false);
  }

  /// Creator: per-video experience configuration sheet.
  Future<void> _configSheet(VideoItem video) async {
    var config = video.config;
    var saving = false;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => Padding(
          padding: const EdgeInsets.all(20),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Experience settings — ${video.title}',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 4),
                const Text(
                  'Defaults viewers get for this video (their own settings '
                  'still override).',
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
                const SizedBox(height: 10),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                        value: 'normal',
                        icon: Icon(Icons.smart_display, size: 16),
                        label: Text('Normal')),
                    ButtonSegment(
                        value: 'vr',
                        icon: Icon(Icons.vrpano, size: 16),
                        label: Text('VR 360°')),
                    ButtonSegment(
                        value: 'mr',
                        icon: Icon(Icons.view_in_ar, size: 16),
                        label: Text('MR')),
                  ],
                  selected: {config.kind},
                  onSelectionChanged: (s) {
                    Haptics.tick();
                    setSheet(() => config = config.copyWith(kind: s.first));
                  },
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      avatar: const Icon(Icons.auto_awesome, size: 15),
                      label: const Text('Auto feel'),
                      selected: config.feelMode == 'auto',
                      onSelected: (_) => setSheet(
                          () => config = config.copyWith(feelMode: 'auto')),
                    ),
                    ChoiceChip(
                      avatar: const Icon(Icons.tune, size: 15),
                      label: const Text('Per-frame feel'),
                      selected: config.feelMode == 'perframe',
                      onSelected: (_) => setSheet(
                          () => config = config.copyWith(feelMode: 'perframe')),
                    ),
                  ],
                ),
                SwitchListTile(
                  title: const Text('Autoplay for viewers'),
                  secondary: const Icon(Icons.play_circle, color: blue),
                  value: config.autoplay,
                  activeThumbColor: blue,
                  onChanged: (v) =>
                      setSheet(() => config = config.copyWith(autoplay: v)),
                ),
                SwitchListTile(
                  title: const Text('Haptics (real feel)'),
                  secondary: const Icon(Icons.vibration, color: Colors.purple),
                  value: config.haptics,
                  activeThumbColor: blue,
                  onChanged: (v) =>
                      setSheet(() => config = config.copyWith(haptics: v)),
                ),
                SwitchListTile(
                  title: const Text('Sound experience'),
                  secondary: const Icon(Icons.volume_up, color: blue),
                  value: config.sound,
                  activeThumbColor: blue,
                  onChanged: (v) =>
                      setSheet(() => config = config.copyWith(sound: v)),
                ),
                ListTile(
                  leading: const Icon(Icons.waves, color: Colors.purple),
                  title: const Text('Feel intensity'),
                  subtitle: Slider(
                    value: config.intensity,
                    divisions: 10,
                    label: '${(config.intensity * 100).round()}%',
                    activeColor: Colors.purpleAccent,
                    onChanged: (v) {
                      if ((v * 10).round() != (config.intensity * 10).round()) {
                        Haptics.level(v);
                      }
                      setSheet(() => config = config.copyWith(intensity: v));
                    },
                  ),
                ),
                const SizedBox(height: 8),
                LoadingButton(
                  busy: saving,
                  label: 'Save configuration',
                  icon: Icons.save,
                  onPressed: () async {
                    setSheet(() => saving = true);
                    try {
                      final updated =
                          await MediaApi.updateConfig(video.id, config);
                      if (!context.mounted) return;
                      Navigator.pop(context);
                      final i = videos.indexWhere((v) => v.id == updated.id);
                      if (i >= 0) setState(() => videos[i] = updated);
                      newSnackBar(this.context,
                          title: 'Saved experience settings.');
                    } on AuthException catch (e) {
                      setSheet(() => saving = false);
                      if (context.mounted) {
                        newSnackBar(context, title: e.message);
                      }
                    }
                  },
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Creator enrolls a new place — it appears for everyone immediately.
  Future<void> _addPlace() async {
    final nameCtl = TextEditingController();
    final locCtl = TextEditingController();
    final descCtl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Add a place'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtl,
                autofocus: true,
                maxLength: 60,
                decoration: const InputDecoration(
                    labelText: 'Place name', hintText: 'e.g. Sun Temple'),
              ),
              TextField(
                controller: locCtl,
                decoration: const InputDecoration(
                    labelText: 'Location', hintText: 'City, State, Country'),
              ),
              TextField(
                controller: descCtl,
                maxLines: 2,
                decoration:
                    const InputDecoration(labelText: 'Short description'),
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
              child: const Text('Add place')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (nameCtl.text.trim().isEmpty) {
      newSnackBar(context, title: 'Give the place a name.');
      return;
    }
    try {
      await MediaApi.addCity(
        name: nameCtl.text.trim(),
        location: locCtl.text.trim(),
        description: descCtl.text.trim(),
      );
      Haptics.medium();
      if (!mounted) return;
      newSnackBar(context, title: '"${nameCtl.text.trim()}" is live!');
      await _loadCities();
    } on AuthException catch (e) {
      if (mounted) newSnackBar(context, title: e.message);
    }
  }

  /// Creator swaps an owned video's thumbnail (YouTube-Studio style).
  Future<void> _changeThumbnail(VideoItem video) async {
    final picked = await FilePicker.platform
        .pickFiles(type: FileType.image, withData: true);
    final file = picked?.files.single;
    if (file == null || file.bytes == null || !mounted) return;
    if (file.bytes!.length > 5 * 1024 * 1024) {
      newSnackBar(context, title: 'Thumbnails are limited to 5 MB.');
      return;
    }
    try {
      final clean = await normalizeImage(file.bytes!);
      final updated = await MediaApi.uploadThumbnail(
          videoId: video.id, filename: 'thumb.png', bytes: clean);
      if (!mounted) return;
      final i = videos.indexWhere((v) => v.id == updated.id);
      if (i >= 0) setState(() => videos[i] = updated);
      newSnackBar(context, title: 'Thumbnail updated.');
    } on AuthException catch (e) {
      if (mounted) newSnackBar(context, title: e.message);
    }
  }

  Future<void> _changeCover() async {
    final city = selectedCity;
    if (city == null) return;
    final picked = await FilePicker.platform
        .pickFiles(type: FileType.image, withData: true);
    final file = picked?.files.single;
    if (file == null || file.bytes == null || !mounted) return;
    try {
      final clean = await normalizeImage(file.bytes!);
      await MediaApi.uploadCityCover(
          city: city, filename: 'cover.png', bytes: clean);
      if (!mounted) return;
      newSnackBar(context, title: 'New cover live for ${_cityName(city)}.');
      await _loadCities();
    } on AuthException catch (e) {
      if (mounted) newSnackBar(context, title: e.message);
    }
  }

  Future<void> _renameVideo(VideoItem video) async {
    final controller = TextEditingController(text: video.title);
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Rename experience'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Rename')),
        ],
      ),
    );
    if (title == null || title.isEmpty || title == video.title) return;
    try {
      final updated = await showBusyWhile(
          context, MediaApi.renameVideo(video.id, title),
          label: 'Saving…');
      if (!mounted) return;
      final i = videos.indexWhere((v) => v.id == updated.id);
      if (i >= 0) setState(() => videos[i] = updated);
      newSnackBar(context, title: 'Renamed to "$title".');
    } on AuthException catch (e) {
      if (mounted) newSnackBar(context, title: e.message);
    }
  }

  Future<void> _deleteVideo(VideoItem video) async {
    final ok = await confirmDialog(
      context,
      title: 'Delete "${video.title}"?',
      message: 'This removes the experience for everyone. It cannot be undone.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok) return;
    try {
      await showBusyWhile(context, MediaApi.deleteVideo(video.id),
          label: 'Deleting…');
      if (!mounted) return;
      // Instant: drop the row locally, then refresh lists in the background.
      setState(() => videos.removeWhere((v) => v.id == video.id));
      newSnackBar(context, title: 'Deleted "${video.title}".');
      unawaited(_silentSync());
    } on AuthException catch (e) {
      if (mounted) newSnackBar(context, title: e.message);
    }
  }

  /// Owner-only place management (long-press on your place's chip):
  /// edit details, refresh the cover image, or delete the place.
  Future<void> _managePlace(City city) async {
    Haptics.tick();
    // The sheet opens for every place; the actions unlock only for the
    // creator who added it — everyone else sees them disabled.
    final canManage =
        city.ownerId != null && city.ownerId == AuthApi.currentUser?.id;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: cardBg(context),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                  color: Colors.grey.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2)),
            ),
            if (!canManage)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                child: Row(
                  children: [
                    const Icon(Icons.lock_outline,
                        size: 15, color: Colors.grey),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Only the creator who added "${city.name}" can '
                        'manage it.',
                        style:
                            const TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ),
                  ],
                ),
              ),
            ListTile(
              enabled: canManage,
              leading: Icon(Icons.edit_location_alt,
                  color: canManage ? blue : Colors.grey),
              title: Text('Edit "${city.name}"'),
              subtitle: const Text('Name, location, description'),
              onTap: () {
                Navigator.pop(sheetCtx);
                _editPlaceDialog(city);
              },
            ),
            ListTile(
              enabled: canManage,
              leading: Icon(Icons.image,
                  color: canManage ? Colors.teal : Colors.grey),
              title: const Text('Refresh cover image'),
              subtitle: const Text('Fetch a fresh high-res photo'),
              onTap: () async {
                Navigator.pop(sheetCtx);
                try {
                  await showBusyWhile(
                      context,
                      MediaApi.editCity(city.slug, refreshCover: true),
                      label: 'Refreshing…');
                  if (!mounted) return;
                  newSnackBar(context,
                      title: 'Fetching a new cover — it appears shortly.');
                  unawaited(_silentSync());
                } on AuthException catch (e) {
                  if (mounted) newSnackBar(context, title: e.message);
                }
              },
            ),
            ListTile(
              enabled: canManage,
              leading: Icon(Icons.delete_outline,
                  color: canManage ? red : Colors.grey),
              title: Text('Delete place',
                  style: TextStyle(color: canManage ? red : Colors.grey)),
              subtitle:
                  const Text('Removes the place and all its experiences'),
              onTap: () async {
                Navigator.pop(sheetCtx);
                final ok = await confirmDialog(
                  context,
                  title: 'Delete "${city.name}"?',
                  message: 'This removes the place, its experiences, ratings '
                      'and comments for everyone. It cannot be undone.',
                  confirmLabel: 'Delete',
                  destructive: true,
                );
                if (!ok) return;
                try {
                  await showBusyWhile(
                      context, MediaApi.removeCity(city.slug),
                      label: 'Deleting…');
                  if (!mounted) return;
                  setState(() {
                    cities.removeWhere((c) => c.slug == city.slug);
                    if (selectedCity == city.slug) {
                      selectedCity =
                          cities.isNotEmpty ? cities.first.slug : null;
                      videos.clear();
                    }
                  });
                  newSnackBar(context, title: 'Deleted "${city.name}".');
                  unawaited(_silentSync());
                } on AuthException catch (e) {
                  if (mounted) newSnackBar(context, title: e.message);
                }
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _editPlaceDialog(City city) async {
    final nameCtl = TextEditingController(text: city.name);
    final locCtl = TextEditingController(text: city.location);
    final descCtl = TextEditingController(text: city.description);
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text('Edit ${city.name}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtl,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: locCtl,
              decoration: const InputDecoration(
                  labelText: 'Location (city, state, country)'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: descCtl,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'Description'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved != true) return;
    try {
      await showBusyWhile(
        context,
        MediaApi.editCity(
          city.slug,
          name: nameCtl.text.trim(),
          location: locCtl.text.trim(),
          description: descCtl.text.trim(),
        ),
        label: 'Saving…',
      );
      if (!mounted) return;
      newSnackBar(context, title: 'Place updated.');
      unawaited(_silentSync());
    } on AuthException catch (e) {
      if (mounted) newSnackBar(context, title: e.message);
    }
  }

  Widget _videoIconBox(bool processing) => Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: processing
                ? [Colors.grey, Colors.blueGrey]
                : [const Color(0xFF0F6E84), const Color(0xFF3CEBFF)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: processing
            ? const Padding(
                padding: EdgeInsets.all(13),
                child:
                    CircularProgressIndicator(color: white, strokeWidth: 2.5),
              )
            : const Icon(Icons.play_arrow, color: white, size: 30),
      );

  String _cityName(String slug) => cities
      .firstWhere((c) => c.slug == slug,
          orElse: () => City(slug: slug, name: slug, videoCount: 0))
      .name;

  String _formatSize(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }

  /// My uploads ⇄ Catalog (⇄ GuideVibe for creators). Selecting GuideVibe
  /// swaps the whole studio body for the GuideVibe creator page — this
  /// replaces the old navbar entry for creators.
  Widget _studioSwitch(bool isCreator) {
    return SegmentedButton<String>(
      segments: [
        const ButtonSegment(
            value: 'mine',
            icon: Icon(Icons.video_settings, size: 17),
            label: Text('My uploads')),
        const ButtonSegment(
            value: 'catalog',
            icon: Icon(Icons.public, size: 17),
            label: Text('Catalog')),
        if (isCreator)
          const ButtonSegment(
              value: 'guidevibe',
              icon: Icon(Icons.play_circle_outline_rounded, size: 17),
              label: Text('GuideVibe')),
      ],
      selected: {studioFeed},
      onSelectionChanged: (s) {
        setState(() => studioFeed = s.first);
        if (s.first != 'guidevibe') _reloadVideos();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // keep this tab alive across switches
    final isCreator = AuthApi.currentUser?.isCreator ?? false;
    // GuideVibe mode: the creator GuideVibe studio, embedded as-is.
    if (isCreator && studioFeed == 'guidevibe') {
      return Scaffold(
        backgroundColor: pageBg(context),
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: _studioSwitch(isCreator),
              ),
              Expanded(child: GuideVibePage(onSelectTab: widget.onSelectTab)),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: pageBg(context),
      appBar: AppBar(
        backgroundColor: cardBg(context),
        elevation: 0,
        iconTheme: IconThemeData(color: ink(context)),
        title: Text(
            (AuthApi.currentUser?.isCreator ?? false)
                ? 'Creator Studio'
                : 'Explore Experiences',
            style: TextStyle(color: ink(context), fontWeight: FontWeight.bold)),
        actions: [
          if (AuthApi.currentUser?.isCreator ?? false)
            IconButton(
              tooltip: 'Creator guide',
              icon: Icon(Icons.info_outline, color: ink(context)),
              onPressed: _creatorGuide,
            ),
        ],
      ),
      // Creators publish; travelers just experience.
      // Lifted above the floating bottom navbar so it is never hidden.
      floatingActionButton: AuthApi.currentUser == null
          ? null
          : Padding(
              padding: const EdgeInsets.only(bottom: 86),
              child: FloatingActionButton.extended(
                onPressed: uploading ? null : _upload,
                icon: uploading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            color: white, strokeWidth: 2),
                      )
                    : const Icon(Icons.upload),
                label: Text(uploading ? 'Uploading...' : 'Upload video'),
              ),
            ),
      body: RefreshIndicator(
        onRefresh: _loadCities,
        child: loadingCities
            ? const Center(child: CircularProgressIndicator(color: blue))
            : ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                children: [
                  if (error != null)
                    Card(
                      color: red.withValues(alpha: 0.1),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(error!, style: const TextStyle(color: red)),
                      ),
                    ),
                  if (AuthApi.currentUser != null) ...[
                    _studioSwitch(isCreator),
                    const SizedBox(height: 12),
                  ],
                  // City selector
                  SizedBox(
                    height: 44,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (final city in cities)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            // Long-press any place for the manage sheet;
                            // the controls inside enable only for its owner.
                            child: GestureDetector(
                              onLongPress: () => _managePlace(city),
                              child: ChoiceChip(
                                label:
                                    Text('${city.name} (${city.videoCount})'),
                                selected: selectedCity == city.slug,
                                selectedColor: blue,
                                labelStyle: TextStyle(
                                  color: selectedCity == city.slug
                                      ? white
                                      : ink(context),
                                ),
                                onSelected: (_) {
                                  setState(() => selectedCity = city.slug);
                                  _reloadVideos();
                                },
                              ),
                            ),
                          ),
                        if (isCreator) ...[
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ActionChip(
                              avatar: const Icon(Icons.add_location_alt,
                                  size: 17, color: Colors.purple),
                              label: const Text('Add place'),
                              onPressed: _addPlace,
                            ),
                          ),
                          ActionChip(
                            avatar: Icon(Icons.image_outlined,
                                size: 17, color: brandInk(context)),
                            label: const Text('Change cover'),
                            onPressed: _changeCover,
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Video list
                  if (videos.isEmpty && !loadingVideos)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 40),
                      child: Center(
                        child: Text(
                          isCreator
                              ? 'No experience videos yet.\nUpload the first one!'
                              : 'No experience videos here yet.\nCheck back soon!',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.grey),
                        ),
                      ),
                    ),
                  for (var i = 0; i < videos.length; i++)
                    Entrance(index: i, child: _videoCard(videos[i], isCreator)),
                  if (loadingVideos)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child:
                          Center(child: CircularProgressIndicator(color: blue)),
                    ),
                  if (hasMore && !loadingVideos)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: OutlinedButton.icon(
                        onPressed: _loadMore,
                        icon: const Icon(Icons.expand_more),
                        label: const Text('Load more'),
                      ),
                    ),
                  const SizedBox(height: 72), // keep FAB clear of last card
                ],
              ),
      ),
    );
  }

  Widget _videoCard(VideoItem video, bool isCreator) {
    final processing = video.isProcessing;
    return Card(
      color: cardBg(context),
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: video.absoluteThumbUrl != null
            ? ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.network(
                  video.absoluteThumbUrl!,
                  width: 56,
                  height: 48,
                  fit: BoxFit.cover,
                  errorBuilder: (c, e, s) => _videoIconBox(processing),
                ),
              )
            : _videoIconBox(processing),
        title: Text(
          video.title,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '${_formatSize(video.sizeBytes)} · '
                '${video.uploadedAt.toLocal().toString().substring(0, 16)}',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              _badge(
                processing
                    ? 'ML processing...'
                    : (video.hapticsReady
                        ? 'Haptics ready'
                        : 'Haptics pending'),
                processing
                    ? Colors.blue
                    : (video.hapticsReady ? Colors.green : Colors.orange),
              ),
            ],
          ),
        ),
        trailing: _mineMode
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Rename',
                    icon: const Icon(Icons.edit_outlined, color: blue),
                    onPressed: () => _renameVideo(video),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Experience settings',
                    icon: const Icon(Icons.tune, color: blue),
                    onPressed: () => _configSheet(video),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Change thumbnail',
                    icon: const Icon(Icons.image_outlined, color: blue),
                    onPressed: () => _changeThumbnail(video),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Fine-tune feel',
                    icon: const Icon(Icons.equalizer, color: Colors.purple),
                    onPressed: video.isProcessing
                        ? null
                        : () {
                            Haptics.light();
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (context) =>
                                      FineTunePage(video: video)),
                            );
                          },
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Delete upload',
                    icon: const Icon(Icons.delete_outline, color: red),
                    onPressed: () => _deleteVideo(video),
                  ),
                ],
              )
            : const Icon(Icons.chevron_right, color: blue),
        onTap: processing
            ? () => newSnackBar(context,
                title: 'Still processing — feel & sound almost ready!')
            : () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => ExperiencePlayerPage(video: video),
                  ),
                );
              },
      ),
    );
  }

  Widget _badge(String text, MaterialColor color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 11, color: color.shade700),
      ),
    );
  }
}
