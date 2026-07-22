import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:video_player/video_player.dart';

import '../constant.dart';
import '../experience_player.dart';
import '../news_webview.dart';
import '../services/auth_api.dart';
import '../services/haptic_service.dart';
import '../services/media_api.dart';
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

class _DashboardPageState extends State<DashboardPage> {
  List<City> cities = [];
  List<NewsItem> news = [];
  String? selectedCity;
  final List<VideoItem> videos = [];
  bool hasMore = false;
  bool loadingCities = true;
  bool loadingVideos = false;
  bool uploading = false;
  String? error;
  Timer? _pollTimer;

  /// Creator studio: 'mine' shows own uploads (any status), 'catalog' the
  /// public feed. Travelers always see the catalog.
  String studioFeed = 'mine';

  bool get _mineMode =>
      (AuthApi.currentUser?.isCreator ?? false) && studioFeed == 'mine';

  @override
  void initState() {
    super.initState();
    _loadCities();
    // Travel news: precautions, advisories, fresh ideas (server-cached 1h).
    MediaApi.fetchNews().then((items) {
      if (mounted) setState(() => news = items);
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  /// While any visible video is still processing, poll so the "Processing"
  /// chip flips to ready without manual refreshes.
  void _managePolling() {
    final anyProcessing = videos.any((v) => v.isProcessing);
    if (anyProcessing && _pollTimer == null) {
      _pollTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
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

  Future<void> _upload() async {
    final city = selectedCity;
    if (city == null || uploading) return;

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
              style: FilledButton.styleFrom(backgroundColor: Colors.purple),
              onPressed: () => Navigator.pop(context),
              child: const Text('Got it'),
            ),
          ],
        ),
      );

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
    bool? immersiveOk; // probed once, on first VR/MR selection
    var probing = false;
    Uint8List? thumbBytes;
    String thumbName = '';
    // Location defaults from the city's catalog line ("Jaipur, Rajasthan").
    final cityLoc = cities
        .firstWhere((c) => c.slug == city,
            orElse: () => City(slug: city, name: city, videoCount: 0))
        .location
        .split(',');
    final cityCtl = TextEditingController(
        text: cityLoc.isNotEmpty ? cityLoc.first.trim() : '');
    final stateCtl = TextEditingController(
        text: cityLoc.length > 1 ? cityLoc[1].trim() : '');
    final countryCtl = TextEditingController(
        text: cityLoc.length > 2 ? cityLoc[2].trim() : 'India');
    final sizeMb = (sizeBytes / (1024 * 1024)).toStringAsFixed(1);
    var locating = false;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: cardBg(context),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheet) => Padding(
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
                Row(
                  children: [
                    const Icon(Icons.cloud_upload, color: blue, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('Publish to ${_cityName(city)}',
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 16)),
                    ),
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
                            style:
                                TextStyle(fontSize: 11.5, color: Colors.grey)),
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
                      onSelected: (_) {
                        Haptics.tick();
                        setSheet(() =>
                            config = config.copyWith(feelMode: 'perframe'));
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
                        controller: stateCtl,
                        scrollPadding: const EdgeInsets.only(bottom: 200),
                        decoration: const InputDecoration(
                            labelText: 'State',
                            isDense: true,
                            border: OutlineInputBorder()),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: cityCtl,
                        scrollPadding: const EdgeInsets.only(bottom: 200),
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
                            icon:
                                const Icon(Icons.add_photo_alternate, size: 16),
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
                              setSheet(() {
                                thumbBytes = f.bytes;
                                thumbName = f.name;
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
                      if ((v * 10).round() != (config.intensity * 10).round()) {
                        Haptics.level(v);
                      }
                      setSheet(() => config = config.copyWith(intensity: v));
                    },
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Haptics (real feel)'),
                  secondary: const Icon(Icons.vibration, color: Colors.purple),
                  value: config.haptics,
                  activeThumbColor: blue,
                  onChanged: (v) =>
                      setSheet(() => config = config.copyWith(haptics: v)),
                ),
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
                  label: 'Upload & publish',
                  icon: Icons.cloud_upload,
                  onPressed: () async {
                    final title = titleCtl.text.trim();
                    if (title.isEmpty) {
                      newSnackBar(context, title: 'Give the video a title.');
                      return;
                    }
                    setSheet(() => busy = true);
                    setState(() => uploading = true);
                    config = config.copyWith(
                      country: countryCtl.text.trim(),
                      state: stateCtl.text.trim(),
                      cityName: cityCtl.text.trim(),
                    );
                    try {
                      final video = await MediaApi.uploadVideo(
                        city: city,
                        title: title,
                        filename: filename,
                        bytes: bytes,
                        filePath: path,
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
                      setState(() => uploading = false);
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
    );
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
      final updated = await MediaApi.uploadThumbnail(
          videoId: video.id, filename: file.name, bytes: file.bytes!);
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
      await MediaApi.uploadCityCover(
          city: city, filename: file.name, bytes: file.bytes!);
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
      final updated = await MediaApi.renameVideo(video.id, title);
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
      await MediaApi.deleteVideo(video.id);
      if (!mounted) return;
      newSnackBar(context, title: 'Deleted "${video.title}".');
      await _loadCities();
    } on AuthException catch (e) {
      if (mounted) newSnackBar(context, title: e.message);
    }
  }

  Widget _newsCard(NewsItem item) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () {
        Haptics.light();
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) =>
                NewsWebViewPage(title: item.source, url: item.url),
          ),
        );
      },
      child: Container(
        width: 230,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: cardBg(context),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.teal.withValues(alpha: 0.25)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(item.title,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 12.5,
                      height: 1.35)),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(Icons.public, size: 11, color: Colors.grey),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(item.source,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          const TextStyle(fontSize: 10.5, color: Colors.grey)),
                ),
                const Icon(Icons.chevron_right, size: 14, color: Colors.teal),
              ],
            ),
          ],
        ),
      ),
    );
  }

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

  @override
  Widget build(BuildContext context) {
    final isCreator = AuthApi.currentUser?.isCreator ?? false;
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
      ),
      // Creators publish; travelers just experience.
      // Lifted above the floating bottom navbar so it is never hidden.
      floatingActionButton: (selectedCity == null || !isCreator)
          ? null
          : Padding(
              padding: const EdgeInsets.only(bottom: 86),
              child: FloatingActionButton.extended(
                onPressed: uploading ? null : _upload,
                backgroundColor: blue,
                foregroundColor: white,
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
                  if (isCreator) ...[
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(
                            value: 'mine',
                            icon: Icon(Icons.video_settings, size: 17),
                            label: Text('My uploads')),
                        ButtonSegment(
                            value: 'catalog',
                            icon: Icon(Icons.public, size: 17),
                            label: Text('Catalog')),
                      ],
                      selected: {studioFeed},
                      onSelectionChanged: (s) {
                        setState(() => studioFeed = s.first);
                        _reloadVideos();
                      },
                    ),
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
                            child: ChoiceChip(
                              label: Text('${city.name} (${city.videoCount})'),
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
                            avatar: const Icon(Icons.image_outlined,
                                size: 17, color: blue),
                            label: const Text('Change cover'),
                            onPressed: _changeCover,
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (news.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          const Icon(Icons.newspaper,
                              size: 17, color: Colors.teal),
                          const SizedBox(width: 6),
                          Text('Travel news & precautions',
                              style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14.5,
                                  color: ink(context))),
                          const Spacer(),
                          const Row(
                            children: [
                              Icon(Icons.shield, size: 12, color: Colors.green),
                              SizedBox(width: 3),
                              Text('Ad-free reader',
                                  style: TextStyle(
                                      fontSize: 10.5, color: Colors.green)),
                            ],
                          ),
                        ],
                      ),
                    ),
                    SizedBox(
                      height: 116,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: news.length,
                        separatorBuilder: (c, i) => const SizedBox(width: 10),
                        itemBuilder: (context, i) => _newsCard(news[i]),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
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
        leading: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: processing
                  ? [Colors.grey, Colors.blueGrey]
                  : [const Color(0xFF1E319D), const Color(0xFF3CEBFF)],
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
        ),
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
        trailing: isCreator && _mineMode
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
