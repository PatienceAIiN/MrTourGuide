import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import 'package:url_launcher/url_launcher.dart';

import '../constant.dart';
import '../services/api_base.dart';
import '../services/auth_api.dart';
import '../services/media_api.dart';
import '../services/community_api.dart';
import '../services/haptic_service.dart';
import '../services/image_tools.dart';
import '../widgets/image_viewer.dart';
import '../widgets/ux.dart';

/// Communities.
///
/// Travelers community is open to everyone; the creators community is
/// visible only to creator accounts (creators see both — enforced by the
/// backend, mirrored here). Posts support emoji reactions and city tags;
/// authors can delete their own posts.
/// Public profile card for any community member — cover photo, follow
/// button, socials (owner-controlled visibility) and stats.
Future<void> showUserProfileDialog(BuildContext context, int userId) async {
  Haptics.tick();
  Map<String, dynamic>? profile;
  try {
    profile = await MediaApi.publicProfile(userId);
  } catch (_) {}
  if (!context.mounted || profile == null) return;
  final p = profile;
  final isCreatorUser = p['role'] == 'creator';
  final accent = isCreatorUser ? Colors.purple : blue;
  var following = p['isFollowing'] == true;
  var followers = p['followers'] as int? ?? 0;
  final isMe = AuthApi.currentUser?.id == userId;
  // Owners get all fields back plus their privacy map — the card mirrors
  // exactly what OTHERS see, so a hidden field is hidden here too.
  final privacy = (p['privacy'] as Map?) ?? const {};
  bool visible(String field) => !isMe || privacy[field] == true;
  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setCard) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Cover banner with the avatar overlapping.
            SizedBox(
              height: 120,
              child: Stack(
                clipBehavior: Clip.none,
                fit: StackFit.expand,
                children: [
                  p['coverUrl'] != null
                      ? Image.network('$apiBase${p['coverUrl']}',
                          fit: BoxFit.cover,
                          errorBuilder: (c, e, s) =>
                              _profileCoverFallback(accent))
                      : _profileCoverFallback(accent),
                  Positioned(
                    bottom: -34,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: CircleAvatar(
                        radius: 37,
                        backgroundColor: Colors.white,
                        child: CircleAvatar(
                          radius: 34,
                          backgroundColor: accent,
                          backgroundImage: p['avatarUrl'] != null
                              ? NetworkImage('$apiBase${p['avatarUrl']}')
                              : null,
                          child: p['avatarUrl'] == null
                              ? Text(
                                  (p['name'] as String).isNotEmpty
                                      ? (p['name'] as String)[0].toUpperCase()
                                      : '?',
                                  style: const TextStyle(
                                      fontSize: 26,
                                      fontWeight: FontWeight.bold,
                                      color: white),
                                )
                              : null,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 40),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(
                children: [
                  Text(p['name'] as String,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 17)),
                  if (p['username'] != null)
                    Text('@${p['username']}',
                        style: const TextStyle(
                            fontSize: 12.5, color: Colors.grey)),
                  const SizedBox(height: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(isCreatorUser ? Icons.auto_awesome : Icons.luggage,
                            size: 12, color: accent),
                        const SizedBox(width: 4),
                        Text(isCreatorUser ? 'Creator' : 'Traveler',
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: accent)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _profStat('$followers', 'followers'),
                      _profStat('${p['following'] ?? 0}', 'following'),
                      _profStat('${p['uploads'] ?? 0}', 'experiences'),
                    ],
                  ),
                  if ((p['about'] as String?)?.isNotEmpty ?? false) ...[
                    const SizedBox(height: 10),
                    Text(p['about'] as String,
                        textAlign: TextAlign.center,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, height: 1.45)),
                  ],
                  // Socials & contact — only fields their owner made public.
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    alignment: WrapAlignment.center,
                    children: [
                      if (p['instagram'] != null && visible('instagram'))
                        ActionChip(
                          visualDensity: VisualDensity.compact,
                          avatar: const Icon(Icons.camera_alt,
                              size: 14, color: Colors.pink),
                          label: Text('@${p['instagram']}',
                              style: const TextStyle(fontSize: 11.5)),
                          onPressed: () => launchUrl(Uri.parse(
                              'https://instagram.com/${p['instagram']}')),
                        ),
                      if (p['phone'] != null && visible('phone'))
                        ActionChip(
                          visualDensity: VisualDensity.compact,
                          avatar: const Icon(Icons.call,
                              size: 14, color: Colors.green),
                          label: Text('${p['phone']}',
                              style: const TextStyle(fontSize: 11.5)),
                          onPressed: () =>
                              launchUrl(Uri.parse('tel:${p['phone']}')),
                        ),
                      if (p['email'] != null && visible('email'))
                        ActionChip(
                          visualDensity: VisualDensity.compact,
                          avatar: const Icon(Icons.mail,
                              size: 14, color: Colors.orange),
                          label: Text('${p['email']}',
                              style: const TextStyle(fontSize: 11.5)),
                          onPressed: () =>
                              launchUrl(Uri.parse('mailto:${p['email']}')),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  if (!isMe)
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor:
                              following ? Colors.grey.shade300 : accent,
                          foregroundColor:
                              following ? Colors.black87 : Colors.white,
                        ),
                        onPressed: () async {
                          if (AuthApi.currentUser == null) return;
                          Haptics.medium();
                          try {
                            final (now, count) =
                                await MediaApi.followUser(userId);
                            setCard(() {
                              following = now;
                              followers = count;
                            });
                          } catch (_) {}
                        },
                        icon: Icon(
                            following ? Icons.check : Icons.person_add_alt_1,
                            size: 18),
                        label: Text(following ? 'Following' : 'Follow'),
                      ),
                    ),
                  Text(
                    'joined ${DateTime.parse(p['joined'] as String).toLocal().toString().substring(0, 10)}',
                    style: const TextStyle(color: Colors.grey, fontSize: 10.5),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

Widget _profStat(String value, String label) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        children: [
          Text(value,
              style:
                  const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          Text(label,
              style: const TextStyle(fontSize: 10.5, color: Colors.grey)),
        ],
      ),
    );

Widget _profileCoverFallback(Color accent) => Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [
          accent.withValues(alpha: 0.5),
          const Color(0xFF3CEBFF).withValues(alpha: 0.4),
        ]),
      ),
    );

class CommunityPage extends StatefulWidget {
  final void Function(int index)? onSelectTab;
  const CommunityPage({super.key, this.onSelectTab});

  @override
  State<CommunityPage> createState() => _CommunityPageState();
}

class _CommunityPageState extends State<CommunityPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  String community = 'travelers';
  List<CommunityPost> posts = [];
  bool hasMore = false;
  bool loading = true;
  bool posting = false;
  String? error;
  final composer = TextEditingController();

  // Attachments: up to 10 images (compressed client + server side) and
  // 2 videos (streamed, size-capped, re-encoded on the server).
  final List<_Attachment> attached = [];

  int get _attachedImages => attached.where((a) => !a.isVideo).length;
  int get _attachedVideos => attached.where((a) => a.isVideo).length;

  bool get isCreator => AuthApi.currentUser?.isCreator ?? false;

  Timer? _feedTimer;

  @override
  void initState() {
    super.initState();
    _reload();
    // Live feed: quiet refresh every 45s — new posts just appear, no
    // manual pull needed (single cheap request, free-tier friendly).
    _feedTimer = Timer.periodic(const Duration(seconds: 45), (_) {
      if (mounted) _reload(silent: true);
    });
  }

  @override
  void dispose() {
    _feedTimer?.cancel();
    composer.dispose();
    super.dispose();
  }

  Future<void> _reload({bool silent = false}) async {
    if (!silent) {
      setState(() {
        loading = true;
        error = null;
      });
    }
    try {
      final (list, more) = await CommunityApi.fetchPosts(community);
      if (!mounted) return;
      setState(() {
        posts = list;
        hasMore = more;
        loading = false;
      });
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = e.message;
      });
    }
  }

  Future<void> _loadMore() async {
    try {
      final (list, more) =
          await CommunityApi.fetchPosts(community, offset: posts.length);
      if (!mounted) return;
      setState(() {
        posts.addAll(list);
        hasMore = more;
      });
    } on AuthException catch (e) {
      if (mounted) newSnackBar(context, title: e.message);
    }
  }

  Future<void> _post() async {
    final text = composer.text.trim();
    if (text.isEmpty) return;
    if (AuthApi.currentUser == null) {
      newSnackBar(context, title: 'Sign in to post.');
      return;
    }
    setState(() => posting = true);
    try {
      final media = <PostMedia>[];
      for (final a in attached) {
        if (a.isVideo) {
          media.add(await CommunityApi.uploadVideo(a.path!));
        } else {
          final url =
              await CommunityApi.uploadImage(a.name ?? 'photo.png', a.bytes!);
          media.add(PostMedia(type: 'image', url: url));
        }
      }
      await CommunityApi.createPost(
          community: community, body: text, media: media);
      if (!mounted) return;
      composer.clear();
      setState(() {
        posting = false;
        attached.clear();
      });
      Haptics.medium();
      await _reload();
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() => posting = false);
      newSnackBar(context, title: e.message);
    }
  }

  Future<void> _attachImages() async {
    if (_attachedImages >= 10) {
      newSnackBar(context, title: 'Up to 10 images per post.');
      return;
    }
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
      allowMultiple: true,
    );
    if (picked == null) return;
    var skipped = 0;
    for (final file in picked.files) {
      if (_attachedImages >= 10) {
        skipped++;
        continue;
      }
      if (file.bytes == null || file.bytes!.length > 5 * 1024 * 1024) {
        skipped++;
        continue;
      }
      final clean = await normalizeImage(file.bytes!, maxWidth: 1280);
      attached.add(_Attachment.image(clean));
    }
    if (mounted) {
      setState(() {});
      if (skipped > 0) {
        newSnackBar(context,
            title: '$skipped skipped — max 10 images, 5 MB each.');
      }
    }
  }

  Future<void> _attachVideo() async {
    if (_attachedVideos >= 2) {
      newSnackBar(context, title: 'Up to 2 videos per post.');
      return;
    }
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.video,
      withData: false,
    );
    final file = picked?.files.single;
    if (file == null || file.path == null) return;
    if (file.size > 25 * 1024 * 1024) {
      if (mounted) {
        newSnackBar(context, title: 'Post videos are limited to 25 MB.');
      }
      return;
    }
    setState(() => attached.add(_Attachment.video(file.path!, file.name)));
  }

  Future<void> _toggleReaction(CommunityPost post, String emoji) async {
    if (AuthApi.currentUser == null) {
      newSnackBar(context, title: 'Sign in to react.');
      return;
    }
    Haptics.tick();
    // Optimistic update, server settles on reload.
    setState(() {
      final mine = post.myReactions.contains(emoji);
      if (mine) {
        post.myReactions.remove(emoji);
        post.reactions[emoji] = (post.reactions[emoji] ?? 1) - 1;
        if (post.reactions[emoji]! <= 0) post.reactions.remove(emoji);
      } else {
        post.myReactions.add(emoji);
        post.reactions[emoji] = (post.reactions[emoji] ?? 0) + 1;
      }
    });
    try {
      await CommunityApi.react(post.id, emoji);
    } on AuthException catch (e) {
      if (mounted) {
        newSnackBar(context, title: e.message);
        _reload();
      }
    }
  }

  /// The resharer adds/edits their comment on a reshare.
  Future<void> _editReshareComment(CommunityPost post) async {
    final ctl = TextEditingController(text: post.reshareComment ?? '');
    final save = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Your comment'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          maxLength: 300,
          maxLines: 3,
          decoration:
              const InputDecoration(hintText: 'Say why you are sharing this…'),
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
    try {
      await CommunityApi.setReshareComment(post.id, ctl.text.trim());
      Haptics.medium();
      await _reload();
    } on AuthException catch (e) {
      if (mounted) newSnackBar(context, title: e.message);
    }
  }

  Future<void> _reshare(CommunityPost post) async {
    if (AuthApi.currentUser == null) {
      newSnackBar(context, title: 'Sign in to reshare.');
      return;
    }
    Haptics.medium();
    try {
      await CommunityApi.reshare(post.id);
      if (!mounted) return;
      newSnackBar(context,
          title: 'Reshared — ${post.authorName} gets the credit.');
      await _reload();
    } on AuthException catch (e) {
      if (mounted) newSnackBar(context, title: e.message);
    }
  }

  Future<void> _delete(CommunityPost post) async {
    final ok = await confirmDialog(
      context,
      title: 'Delete post?',
      message: 'This removes your post for everyone.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok) return;
    try {
      await CommunityApi.deletePost(post.id);
      if (mounted) setState(() => posts.removeWhere((p) => p.id == post.id));
    } on AuthException catch (e) {
      if (mounted) newSnackBar(context, title: e.message);
    }
  }

  String _timeAgo(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'now';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    if (d.inHours < 24) return '${d.inHours}h';
    return '${d.inDays}d';
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // keep this tab alive across switches
    return Scaffold(
      backgroundColor: pageBg(context),
      appBar: AppBar(
        backgroundColor: cardBg(context),
        elevation: 0,
        title: Text('Community',
            style: TextStyle(color: ink(context), fontWeight: FontWeight.bold)),
      ),
      body: Column(
        children: [
          // Creators see both feeds; travelers only theirs.
          if (isCreator)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                      value: 'travelers',
                      icon: Icon(Icons.travel_explore, size: 18),
                      label: Text('Travelers')),
                  ButtonSegment(
                      value: 'creators',
                      icon: Icon(Icons.video_camera_back, size: 18),
                      label: Text('Creators')),
                ],
                selected: {community},
                onSelectionChanged: (s) {
                  Haptics.tick();
                  setState(() => community = s.first);
                  _reload();
                },
              ),
            ),
          // Composer
          Padding(
            padding: const EdgeInsets.all(16),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: cardBg(context),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          scrollPadding: const EdgeInsets.only(bottom: 180),
                          controller: composer,
                          maxLength: 1000,
                          decoration: InputDecoration(
                            border: InputBorder.none,
                            counterText: '',
                            hintText: community == 'creators'
                                ? 'Share tips with fellow creators...'
                                : 'Share how it felt...',
                            hintStyle: const TextStyle(
                                color: Colors.grey, fontSize: 14),
                          ),
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Add photos (up to 10, 5 MB each)',
                        icon: const Icon(Icons.image_outlined,
                            color: Colors.grey),
                        onPressed: _attachImages,
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Add a video (up to 2, 25 MB each)',
                        icon: const Icon(Icons.videocam_outlined,
                            color: Colors.grey),
                        onPressed: _attachVideo,
                      ),
                      posting
                          ? SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: brandInk(context)))
                          : IconButton(
                              icon: Icon(Icons.send_rounded,
                                  color: brandInk(context)),
                              onPressed: _post,
                            ),
                    ],
                  ),
                  if (attached.isNotEmpty)
                    SizedBox(
                      height: 56,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.only(bottom: 8),
                        itemCount: attached.length,
                        separatorBuilder: (context, i) =>
                            const SizedBox(width: 6),
                        itemBuilder: (context, i) {
                          final a = attached[i];
                          return Stack(
                            clipBehavior: Clip.none,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: a.isVideo
                                    ? Container(
                                        width: 48,
                                        height: 48,
                                        color: Colors.black87,
                                        child: const Icon(Icons.play_circle,
                                            color: Colors.white, size: 22),
                                      )
                                    : Image.memory(a.bytes!,
                                        width: 48,
                                        height: 48,
                                        fit: BoxFit.cover),
                              ),
                              Positioned(
                                right: -5,
                                top: -5,
                                child: InkWell(
                                  onTap: () =>
                                      setState(() => attached.removeAt(i)),
                                  child: const CircleAvatar(
                                    radius: 9,
                                    backgroundColor: Colors.black54,
                                    child: Icon(Icons.close,
                                        size: 11, color: Colors.white),
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _reload,
              child: loading
                  ? const Center(child: CircularProgressIndicator(color: blue))
                  : error != null
                      ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(error!,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(color: red)),
                            ),
                          ],
                        )
                      : ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 110),
                          children: [
                            if (posts.isEmpty)
                              const Padding(
                                padding: EdgeInsets.all(32),
                                child: Center(
                                  child: Text(
                                      'No posts yet — start the conversation!',
                                      style: TextStyle(color: Colors.grey)),
                                ),
                              ),
                            for (var i = 0; i < posts.length; i++)
                              Entrance(index: i, child: _postCard(posts[i])),
                            if (hasMore)
                              OutlinedButton.icon(
                                onPressed: _loadMore,
                                icon: const Icon(Icons.expand_more),
                                label: const Text('Load more'),
                              ),
                          ],
                        ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _postCard(CommunityPost post) {
    final isReshare = post.resharedBy != null;
    // A reshare belongs to the resharer's card; the original is embedded.
    final headName = isReshare ? post.resharedBy! : post.authorName;
    final headId = isReshare ? (post.resharedById ?? -1) : post.authorId;
    final headCreator =
        isReshare ? post.resharedByRole == 'creator' : post.byCreator;
    final mine = headId == AuthApi.currentUser?.id ||
        (!isReshare && post.authorId == AuthApi.currentUser?.id);
    return Springy(
      haptic: 'light',
      onTap: () => _openPost(post),
      child: Card(
        color: cardBg(context),
        margin: const EdgeInsets.only(bottom: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (isReshare) ...[
                    // Compact share line — "↻ Name shared this · 2h".
                    const Icon(Icons.repeat, size: 15, color: Colors.grey),
                    const SizedBox(width: 6),
                    Expanded(
                      child: GestureDetector(
                        onTap: () => headId > 0
                            ? showUserProfileDialog(context, headId)
                            : null,
                        child: Text.rich(
                          TextSpan(
                            text: headName,
                            style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                                color: ink(context)),
                            children: [
                              TextSpan(
                                text:
                                    ' shared this · ${_timeAgo(post.createdAt)}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w400,
                                    color: Colors.grey),
                              ),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    if (mine) ...[
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Edit comment',
                        icon: Icon(Icons.edit_outlined,
                            size: 17, color: brandInk(context)),
                        onPressed: () => _editReshareComment(post),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Delete reshare',
                        icon: const Icon(Icons.delete_outline,
                            size: 17, color: Colors.grey),
                        onPressed: () => _delete(post),
                      ),
                    ],
                  ] else ...[
                    GestureDetector(
                      onTap: () => headId > 0
                          ? showUserProfileDialog(context, headId)
                          : null,
                      child: CircleAvatar(
                        radius: 16,
                        backgroundColor: headCreator ? Colors.purple : blue,
                        child: Text(
                          headName.isNotEmpty ? headName[0].toUpperCase() : '?',
                          style: const TextStyle(
                              color: white,
                              fontSize: 14,
                              fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Row(
                        children: [
                          Flexible(
                            child: GestureDetector(
                              onTap: () => headId > 0
                                  ? showUserProfileDialog(context, headId)
                                  : null,
                              child: Text(headName,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 14)),
                            ),
                          ),
                          if (post.byCreator) ...[
                            const SizedBox(width: 5),
                            const Text('✦',
                                style: TextStyle(
                                    color: Colors.purple, fontSize: 13)),
                          ],
                          const SizedBox(width: 8),
                          Text(_timeAgo(post.createdAt),
                              style: const TextStyle(
                                  color: Colors.grey, fontSize: 11)),
                        ],
                      ),
                    ),
                  ],
                  if (post.city != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: brandInk(context).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text('📍 ${post.city}',
                          style: TextStyle(
                              fontSize: 10.5, color: brandInk(context))),
                    ),
                  if (!mine)
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: 'Reshare',
                      icon: const Icon(Icons.repeat,
                          size: 18, color: Colors.teal),
                      onPressed: () => _reshare(post),
                    ),
                  if (mine)
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: 'Delete',
                      icon: const Icon(Icons.delete_outline,
                          size: 18, color: Colors.grey),
                      onPressed: () => _delete(post),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              if (isReshare && (post.reshareComment?.isNotEmpty ?? false)) ...[
                Text(post.reshareComment!,
                    style: const TextStyle(fontSize: 14, height: 1.45)),
                const SizedBox(height: 10),
              ],
              if (isReshare)
                // The original post, embedded — tap opens it like any post.
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: pageBg(context),
                    borderRadius: BorderRadius.circular(10),
                    border:
                        Border.all(color: Colors.grey.withValues(alpha: 0.25)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      GestureDetector(
                        onTap: () =>
                            showUserProfileDialog(context, post.authorId),
                        child: Row(
                          children: [
                            CircleAvatar(
                              radius: 12,
                              backgroundColor:
                                  post.byCreator ? Colors.purple : blue,
                              child: Text(
                                post.authorName.isNotEmpty
                                    ? post.authorName[0].toUpperCase()
                                    : '?',
                                style: const TextStyle(
                                    color: white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text.rich(
                                TextSpan(
                                  text: post.authorName,
                                  style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 13.5,
                                      color: ink(context)),
                                  children: const [],
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (post.byCreator)
                              const Padding(
                                padding: EdgeInsets.only(left: 4),
                                child: Text('✦',
                                    style: TextStyle(
                                        color: Colors.purple, fontSize: 11)),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(post.body,
                          style: const TextStyle(fontSize: 13, height: 1.4)),
                      if (post.media.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        _MediaCarousel(
                            post: post, height: 140, compact: true),
                      ],
                    ],
                  ),
                )
              else ...[
                Text(post.body,
                    style: const TextStyle(fontSize: 14, height: 1.45)),
                if (post.media.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  _MediaCarousel(post: post, height: 200),
                ],
              ],
              const SizedBox(height: 8),
              // Facebook-style: summary line, thin divider, action row.
              // Tap React toggles ❤️; long-press summons the animated picker.
              _reactionSummary(post),
              Divider(height: 12, color: Colors.grey.withValues(alpha: 0.2)),
              Row(
                children: [
                  Expanded(child: _reactButton(post)),
                  Expanded(
                    child: _actionButton(
                      icon: Icons.mode_comment_outlined,
                      label: 'Comment',
                      onTap: () => _openPost(post),
                    ),
                  ),
                  Expanded(
                    child: _actionButton(
                      icon: Icons.share_outlined,
                      label: 'Share',
                      onTap: () => _sharePost(post),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Overlapping emoji cluster + totals, like Facebook's summary strip.
  Widget _reactionSummary(CommunityPost post) {
    final entries = post.reactions.entries.where((e) => e.value > 0).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final total = entries.fold<int>(0, (n, e) => n + e.value);
    if (total == 0 && post.replyCount == 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          if (total > 0) ...[
            SizedBox(
              width: 14.0 * entries.take(3).length + 8,
              height: 20,
              child: Stack(
                children: [
                  for (var i = 0; i < entries.length && i < 3; i++)
                    Positioned(
                      left: i * 14.0,
                      child: Container(
                        padding: const EdgeInsets.all(1),
                        decoration: BoxDecoration(
                          color: cardBg(context),
                          shape: BoxShape.circle,
                        ),
                        child: Text(entries[i].key,
                            style: const TextStyle(fontSize: 12)),
                      ),
                    ),
                ],
              ),
            ),
            Text('$total',
                style: const TextStyle(fontSize: 12.5, color: Colors.grey)),
          ],
          const Spacer(),
          if (post.replyCount > 0)
            Text(
                '${post.replyCount} '
                '${post.replyCount == 1 ? 'reply' : 'replies'}',
                style: const TextStyle(fontSize: 12.5, color: Colors.grey)),
        ],
      ),
    );
  }

  /// The React button reflects my current reaction (emoji + bold blue);
  /// tap toggles ❤️, long-press opens the full picker.
  Widget _reactButton(CommunityPost post) {
    final mine = post.myReactions.isNotEmpty ? post.myReactions.first : null;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => _toggleReaction(post, mine ?? '❤️'),
      onLongPress: () => _showReactionPicker(post),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            mine != null
                ? Text(mine, style: const TextStyle(fontSize: 15))
                : const Icon(Icons.favorite_border,
                    size: 17, color: Colors.grey),
            const SizedBox(width: 5),
            Text(
              mine != null ? 'Reacted' : 'React',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: mine != null ? FontWeight.w700 : FontWeight.w500,
                color: mine != null ? brandInk(context) : Colors.grey,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _actionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 17, color: Colors.grey),
            const SizedBox(width: 5),
            Text(label,
                style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: Colors.grey)),
          ],
        ),
      ),
    );
  }

  /// Share the public browser view of a post (works without the app).
  Future<void> _sharePost(CommunityPost post) async {
    Haptics.tick();
    final preview = post.body.length > 80
        ? '${post.body.substring(0, 80)}…'
        : post.body;
    await SharePlus.instance.share(ShareParams(
      subject: '${post.authorName} on Mr.Tour Guide',
      text: '$preview\n\n${CommunityApi.shareUrl(post.id)}',
    ));
  }

  /// Full post in a pop-up modal: image, reactions, replies (add + delete).
  void _openPost(CommunityPost post) {
    Haptics.string();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: _PostModal(
          post: post,
          onChanged: () {
            if (mounted) setState(() {});
          },
          onDeletePost: () async {
            Navigator.pop(context);
            await _delete(post);
          },
          toggleReaction: _toggleReaction,
          timeAgo: _timeAgo,
        ),
      ),
    );
  }

  /// Facebook-style reaction picker: long-press summons a floating bar of
  /// emojis that pop in one by one; tapping sets the reaction.
  Future<void> _showReactionPicker(CommunityPost post) async {
    Haptics.medium();
    final picked = await showDialog<String>(
      context: context,
      barrierColor: Colors.black26,
      builder: (context) => Center(
        child: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: cardBg(context),
              borderRadius: BorderRadius.circular(30),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < CommunityApi.emojis.length; i++)
                  TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: 1),
                    duration: Duration(milliseconds: 220 + i * 70),
                    curve: Curves.easeOutBack,
                    builder: (context, v, child) => Transform.scale(
                      scale: v.clamp(0.0, 1.2),
                      child: child,
                    ),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () {
                        Haptics.level(0.6);
                        Navigator.pop(context, CommunityApi.emojis[i]);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 7),
                        child: Text(
                          CommunityApi.emojis[i],
                          style: TextStyle(
                            fontSize: post.myReactions
                                    .contains(CommunityApi.emojis[i])
                                ? 34
                                : 28,
                          ),
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
    if (picked != null && mounted) _toggleReaction(post, picked);
  }

}

/// A pending composer attachment: an in-memory compressed image, or a video
/// referenced by its on-device file path (streamed at post time).
class _Attachment {
  final Uint8List? bytes; // images only
  final String? path; // videos only
  final String? name;
  final bool isVideo;

  _Attachment.image(this.bytes)
      : path = null,
        name = 'photo.png',
        isVideo = false;
  _Attachment.video(this.path, this.name)
      : bytes = null,
        isVideo = true;
}

/// Swipeable media gallery for a post: images open full-screen, videos play
/// inline inside the card. A dot row + counter shows position when >1.
class _MediaCarousel extends StatefulWidget {
  final CommunityPost post;
  final double height;
  final bool compact;

  const _MediaCarousel({
    required this.post,
    required this.height,
    this.compact = false,
  });

  @override
  State<_MediaCarousel> createState() => _MediaCarouselState();
}

class _MediaCarouselState extends State<_MediaCarousel> {
  final _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = widget.post.media;
    final radius = BorderRadius.circular(widget.compact ? 10 : 12);
    return Column(
      children: [
        ClipRRect(
          borderRadius: radius,
          child: SizedBox(
            height: widget.height,
            width: double.infinity,
            child: media.length == 1
                ? _slide(media.first)
                : PageView.builder(
                    controller: _controller,
                    itemCount: media.length,
                    onPageChanged: (i) => setState(() => _page = i),
                    itemBuilder: (context, i) => _slide(media[i]),
                  ),
          ),
        ),
        if (media.length > 1) ...[
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < media.length; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  width: i == _page ? 16 : 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: i == _page
                        ? blue
                        : Colors.grey.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _slide(PostMedia m) {
    if (m.isVideo) {
      return _InlineVideo(media: m);
    }
    return GestureDetector(
      onTap: () => showImageViewer(context, m.absoluteUrl,
          caption: widget.post.authorName),
      child: Image.network(
        m.absoluteUrl,
        fit: BoxFit.cover,
        errorBuilder: (c, e, s) => Container(
          color: Colors.grey.withValues(alpha: 0.15),
          child: const Icon(Icons.broken_image_outlined, color: Colors.grey),
        ),
      ),
    );
  }
}

/// Video that plays inline inside the post card. Loads on first tap so the
/// feed stays cheap (only a poster frame until the user chooses to watch).
class _InlineVideo extends StatefulWidget {
  final PostMedia media;
  const _InlineVideo({required this.media});

  @override
  State<_InlineVideo> createState() => _InlineVideoState();
}

class _InlineVideoState extends State<_InlineVideo> {
  VideoPlayerController? _controller;
  bool _loading = false;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (_loading || _controller != null) return;
    setState(() => _loading = true);
    final c = VideoPlayerController.networkUrl(Uri.parse(widget.media.absoluteUrl));
    try {
      await c.initialize();
      c.setLooping(true);
      await c.play();
      if (!mounted) {
        c.dispose();
        return;
      }
      setState(() {
        _controller = c;
        _loading = false;
      });
    } catch (_) {
      c.dispose();
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    if (c != null && c.value.isInitialized) {
      return GestureDetector(
        onTap: () => setState(
            () => c.value.isPlaying ? c.pause() : c.play()),
        child: Stack(
          alignment: Alignment.center,
          fit: StackFit.expand,
          children: [
            FittedBox(
              fit: BoxFit.cover,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: c.value.size.width,
                height: c.value.size.height,
                child: VideoPlayer(c),
              ),
            ),
            ValueListenableBuilder(
              valueListenable: c,
              builder: (context, value, child) => value.isPlaying
                  ? const SizedBox.shrink()
                  : Container(
                      color: Colors.black26,
                      child: const Icon(Icons.play_arrow,
                          color: Colors.white, size: 48),
                    ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: VideoProgressIndicator(c,
                  allowScrubbing: true,
                  colors: const VideoProgressColors(playedColor: blue)),
            ),
          ],
        ),
      );
    }
    // Not yet playing: poster frame (if any) + a big play affordance.
    return GestureDetector(
      onTap: _start,
      child: Stack(
        alignment: Alignment.center,
        fit: StackFit.expand,
        children: [
          if (widget.media.absoluteThumb != null)
            Image.network(widget.media.absoluteThumb!,
                fit: BoxFit.cover,
                errorBuilder: (c, e, s) => Container(color: Colors.black87))
          else
            Container(color: Colors.black87),
          Container(
            decoration: const BoxDecoration(
              color: Colors.black38,
              shape: BoxShape.circle,
            ),
            padding: const EdgeInsets.all(8),
            child: _loading
                ? const SizedBox(
                    width: 32,
                    height: 32,
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 3))
                : const Icon(Icons.play_arrow,
                    color: Colors.white, size: 40),
          ),
        ],
      ),
    );
  }
}

/// Pop-up modal for a single post: full content, reactions, and the reply
/// thread (add a reply, delete your own).
class _PostModal extends StatefulWidget {
  final CommunityPost post;
  final VoidCallback onChanged;
  final Future<void> Function() onDeletePost;
  final Future<void> Function(CommunityPost, String) toggleReaction;
  final String Function(DateTime) timeAgo;

  const _PostModal({
    required this.post,
    required this.onChanged,
    required this.onDeletePost,
    required this.toggleReaction,
    required this.timeAgo,
  });

  @override
  State<_PostModal> createState() => _PostModalState();
}

class _PostModalState extends State<_PostModal> {
  List<CommunityReply> replies = [];

  /// Reply being answered (threading); null = replying to the post.
  CommunityReply? replyingTo;
  bool loading = true;
  bool sending = false;
  final replyCtl = TextEditingController();

  CommunityPost get post => widget.post;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    replyCtl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final list = await CommunityApi.fetchReplies(post.id);
      if (!mounted) return;
      setState(() {
        replies = list;
        post.replyCount = list.length;
        loading = false;
      });
      widget.onChanged();
    } on AuthException {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _send() async {
    final text = replyCtl.text.trim();
    if (text.isEmpty || sending) return;
    if (AuthApi.currentUser == null) {
      newSnackBar(context, title: 'Sign in to reply.');
      return;
    }
    setState(() => sending = true);
    try {
      await CommunityApi.addReply(post.id, text, parentReplyId: replyingTo?.id);
      replyCtl.clear();
      replyingTo = null;
      Haptics.medium();
      await _load();
    } on AuthException catch (e) {
      if (mounted) newSnackBar(context, title: e.message);
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  Future<void> _deleteReply(CommunityReply reply) async {
    final ok = await confirmDialog(
      context,
      title: 'Delete reply?',
      message: 'This removes your reply for everyone.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok) return;
    try {
      await CommunityApi.deleteReply(reply.id);
      await _load();
    } on AuthException catch (e) {
      if (mounted) newSnackBar(context, title: e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mine = post.authorId == AuthApi.currentUser?.id;
    return DraggableScrollableSheet(
      initialChildSize: 0.8,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scroll) => Container(
        decoration: BoxDecoration(
          color: cardBg(context),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 44,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Expanded(
              child: ListView(
                controller: scroll,
                padding: const EdgeInsets.all(18),
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 18,
                        backgroundColor: post.byCreator ? Colors.purple : blue,
                        child: Text(
                          post.authorName.isNotEmpty
                              ? post.authorName[0].toUpperCase()
                              : '?',
                          style: const TextStyle(
                              color: white, fontWeight: FontWeight.bold),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              Flexible(
                                child: GestureDetector(
                                  onTap: () => showUserProfileDialog(
                                      context, post.authorId),
                                  child: Text(post.authorName,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w700)),
                                ),
                              ),
                              if (post.byCreator)
                                const Padding(
                                  padding: EdgeInsets.only(left: 5),
                                  child: Text('✦',
                                      style: TextStyle(color: Colors.purple)),
                                ),
                            ]),
                            Text(
                              '${widget.timeAgo(post.createdAt)}'
                              '${post.city != null ? ' · ${post.city}' : ''}',
                              style: const TextStyle(
                                  fontSize: 11, color: Colors.grey),
                            ),
                          ],
                        ),
                      ),
                      if (mine)
                        IconButton(
                          tooltip: 'Delete post',
                          icon: const Icon(Icons.delete_outline,
                              color: Colors.grey),
                          onPressed: widget.onDeletePost,
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(post.body,
                      style: const TextStyle(fontSize: 15, height: 1.5)),
                  if (post.media.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _MediaCarousel(post: post, height: 240),
                  ],
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final emoji in CommunityApi.emojis)
                        InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: () async {
                            await widget.toggleReaction(post, emoji);
                            if (mounted) setState(() {});
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: post.myReactions.contains(emoji)
                                  ? blue.withValues(alpha: 0.14)
                                  : Colors.grey.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Text('$emoji ${post.reactions[emoji] ?? 0}',
                                style: const TextStyle(fontSize: 13)),
                          ),
                        ),
                    ],
                  ),
                  const Divider(height: 30),
                  Text('Replies (${replies.length})',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15)),
                  const SizedBox(height: 10),
                  if (loading)
                    const Center(
                        child: Padding(
                      padding: EdgeInsets.all(16),
                      child: CircularProgressIndicator(color: blue),
                    ))
                  else if (replies.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 14),
                      child: Text('No replies yet — be the first!',
                          style: TextStyle(color: Colors.grey)),
                    )
                  else
                    // Threads: top-level replies with their answers nested.
                    for (final reply in replies)
                      if (reply.parentReplyId == null) ...[
                        _replyTile(reply),
                        for (final child in replies)
                          if (child.parentReplyId == reply.id)
                            Padding(
                              padding: const EdgeInsets.only(left: 34),
                              child: _replyTile(child, inThread: true),
                            ),
                      ],
                  const SizedBox(height: 12),
                ],
              ),
            ),
            // Reply composer
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 6, 14, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (replyingTo != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Row(
                          children: [
                            const Icon(Icons.subdirectory_arrow_right,
                                size: 14, color: Colors.teal),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                  'Replying to ${replyingTo!.authorName}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 11.5,
                                      color: Colors.teal,
                                      fontWeight: FontWeight.w600)),
                            ),
                            InkWell(
                              onTap: () => setState(() => replyingTo = null),
                              child: const Icon(Icons.close,
                                  size: 15, color: Colors.grey),
                            ),
                          ],
                        ),
                      ),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            key: const ValueKey('replyField'),
                            controller: replyCtl,
                            scrollPadding: const EdgeInsets.only(bottom: 180),
                            maxLength: 500,
                            onSubmitted: (_) => _send(),
                            decoration: InputDecoration(
                              counterText: '',
                              hintText: 'Write a reply...',
                              isDense: true,
                              filled: true,
                              fillColor: pageBg(context),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: BorderSide.none,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        sending
                            ? SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: brandInk(context)))
                            : IconButton(
                                icon: Icon(Icons.send_rounded,
                                    color: brandInk(context)),
                                onPressed: _send,
                              ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _replyTile(CommunityReply reply, {bool inThread = false}) {
    final mine = reply.authorId == AuthApi.currentUser?.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 13,
            backgroundColor: reply.byCreator ? Colors.purple : blue,
            child: Text(
              reply.authorName.isNotEmpty
                  ? reply.authorName[0].toUpperCase()
                  : '?',
              style: const TextStyle(
                  color: white, fontSize: 11, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: GestureDetector(
                        onTap: () =>
                            showUserProfileDialog(context, reply.authorId),
                        child: Text(reply.authorName,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 13)),
                      ),
                    ),
                    if (reply.byCreator)
                      const Padding(
                        padding: EdgeInsets.only(left: 4),
                        child: Text('✦',
                            style:
                                TextStyle(color: Colors.purple, fontSize: 11)),
                      ),
                    const SizedBox(width: 6),
                    Text(widget.timeAgo(reply.createdAt),
                        style: const TextStyle(
                            fontSize: 10.5, color: Colors.grey)),
                  ],
                ),
                Text(reply.body,
                    style: const TextStyle(fontSize: 13.5, height: 1.4)),
                if (!inThread)
                  InkWell(
                    onTap: () => setState(() => replyingTo = reply),
                    child: const Padding(
                      padding: EdgeInsets.only(top: 3),
                      child: Text('Reply',
                          style: TextStyle(
                              fontSize: 11,
                              color: Colors.teal,
                              fontWeight: FontWeight.w700)),
                    ),
                  ),
              ],
            ),
          ),
          if (mine)
            InkWell(
              onTap: () => _deleteReply(reply),
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.delete_outline, size: 16, color: Colors.grey),
              ),
            ),
        ],
      ),
    );
  }
}
