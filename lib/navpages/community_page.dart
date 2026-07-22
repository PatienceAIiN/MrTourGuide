import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../constant.dart';
import '../services/api_base.dart';
import '../services/auth_api.dart';
import '../services/media_api.dart';
import '../services/community_api.dart';
import '../services/haptic_service.dart';
import '../widgets/image_viewer.dart';
import '../widgets/ux.dart';

/// Communities.
///
/// Travelers community is open to everyone; the creators community is
/// visible only to creator accounts (creators see both — enforced by the
/// backend, mirrored here). Posts support emoji reactions and city tags;
/// authors can delete their own posts.
/// Public profile card for any community member — opened by tapping a
/// username or avatar anywhere in the community.
Future<void> showUserProfileDialog(BuildContext context, int userId) async {
  Haptics.tick();
  Map<String, dynamic>? profile;
  try {
    profile = await MediaApi.publicProfile(userId);
  } catch (_) {}
  if (!context.mounted || profile == null) return;
  final p = profile;
  final isCreatorUser = p['role'] == 'creator';
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 34,
            backgroundColor: isCreatorUser ? Colors.purple : blue,
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
          const SizedBox(height: 10),
          Text(p['name'] as String,
              style:
                  const TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: (isCreatorUser ? Colors.purple : blue)
                  .withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              isCreatorUser ? '\u2726 Creator' : 'Traveler',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: isCreatorUser ? Colors.purple : blue),
            ),
          ),
          if ((p['about'] as String?)?.isNotEmpty ?? false) ...[
            const SizedBox(height: 10),
            Text(p['about'] as String,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, height: 1.45)),
          ],
          const SizedBox(height: 12),
          Text(
            "${p['uploads']} experiences \u00b7 joined "
            "${DateTime.parse(p['joined'] as String).toLocal().toString().substring(0, 10)}",
            style: const TextStyle(color: Colors.grey, fontSize: 11.5),
          ),
        ],
      ),
    ),
  );
}

class CommunityPage extends StatefulWidget {
  final void Function(int index)? onSelectTab;
  const CommunityPage({super.key, this.onSelectTab});

  @override
  State<CommunityPage> createState() => _CommunityPageState();
}

class _CommunityPageState extends State<CommunityPage> {
  String community = 'travelers';
  List<CommunityPost> posts = [];
  bool hasMore = false;
  bool loading = true;
  bool posting = false;
  String? error;
  final composer = TextEditingController();

  // Image attachment (uploaded compressed via the backend).
  Uint8List? attachedBytes;
  String? attachedName;

  bool get isCreator => AuthApi.currentUser?.isCreator ?? false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    composer.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() {
      loading = true;
      error = null;
    });
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
      String? imageUrl;
      if (attachedBytes != null) {
        imageUrl = await CommunityApi.uploadImage(
            attachedName ?? 'photo.jpg', attachedBytes!);
      }
      await CommunityApi.createPost(
          community: community, body: text, imageUrl: imageUrl);
      if (!mounted) return;
      composer.clear();
      setState(() {
        posting = false;
        attachedBytes = null;
        attachedName = null;
      });
      Haptics.medium();
      await _reload();
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() => posting = false);
      newSnackBar(context, title: e.message);
    }
  }

  Future<void> _attachImage() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    final file = picked?.files.single;
    if (file == null || file.bytes == null) return;
    if (file.bytes!.length > 5 * 1024 * 1024) {
      if (mounted) newSnackBar(context, title: 'Images are limited to 5 MB.');
      return;
    }
    setState(() {
      attachedBytes = file.bytes;
      attachedName = file.name;
    });
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
              child: Row(
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
                        hintStyle:
                            const TextStyle(color: Colors.grey, fontSize: 14),
                      ),
                    ),
                  ),
                  if (attachedBytes != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Stack(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.memory(attachedBytes!,
                                width: 40, height: 40, fit: BoxFit.cover),
                          ),
                          Positioned(
                            right: -2,
                            top: -2,
                            child: InkWell(
                              onTap: () => setState(() {
                                attachedBytes = null;
                                attachedName = null;
                              }),
                              child: const CircleAvatar(
                                radius: 8,
                                backgroundColor: Colors.black54,
                                child: Icon(Icons.close,
                                    size: 10, color: Colors.white),
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    IconButton(
                      tooltip: 'Attach image (max 5 MB, auto-compressed)',
                      icon:
                          const Icon(Icons.image_outlined, color: Colors.grey),
                      onPressed: _attachImage,
                    ),
                  posting
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: blue))
                      : IconButton(
                          icon: const Icon(Icons.send_rounded, color: blue),
                          onPressed: _post,
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
    final mine = post.authorId == AuthApi.currentUser?.id;
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
                  GestureDetector(
                    onTap: () => showUserProfileDialog(context, post.authorId),
                    child: CircleAvatar(
                      radius: 16,
                      backgroundColor: post.byCreator ? Colors.purple : blue,
                      child: Text(
                        post.authorName.isNotEmpty
                            ? post.authorName[0].toUpperCase()
                            : '?',
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
                            onTap: () =>
                                showUserProfileDialog(context, post.authorId),
                            child: Text(post.authorName,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700, fontSize: 14)),
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
                  if (post.city != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: blue.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text('📍 ${post.city}',
                          style: const TextStyle(
                              fontSize: 10.5, color: Color(0xFF1E319D))),
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
              Text(post.body,
                  style: const TextStyle(fontSize: 14, height: 1.45)),
              if (post.absoluteImageUrl != null) ...[
                const SizedBox(height: 10),
                GestureDetector(
                  onTap: () => showImageViewer(context, post.absoluteImageUrl!,
                      caption: post.authorName),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.network(
                      post.absoluteImageUrl!,
                      height: 180,
                      width: double.infinity,
                      fit: BoxFit.cover,
                      errorBuilder: (c, e, s) => const SizedBox.shrink(),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 10),
              // Reactions + replies
              Wrap(
                spacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (final emoji in CommunityApi.emojis)
                    _reactionChip(post, emoji),
                  InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => _openPost(post),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.mode_comment_outlined,
                              size: 15, color: Colors.grey),
                          const SizedBox(width: 4),
                          Text('${post.replyCount}',
                              style: const TextStyle(
                                  fontSize: 12.5, color: Colors.grey)),
                        ],
                      ),
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

  Widget _reactionChip(CommunityPost post, String emoji) {
    final count = post.reactions[emoji] ?? 0;
    final mine = post.myReactions.contains(emoji);
    if (count == 0 && !mine) {
      // Ghost chip: shown small so any reaction is one tap away.
      return InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _toggleReaction(post, emoji),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          child: Opacity(
              opacity: 0.35,
              child: Text(emoji, style: const TextStyle(fontSize: 14))),
        ),
      );
    }
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => _toggleReaction(post, emoji),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(
          color: mine
              ? blue.withValues(alpha: 0.14)
              : Colors.black.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: mine ? blue : Colors.transparent, width: 1),
        ),
        child: Text('$emoji $count',
            style: TextStyle(
                fontSize: 12.5,
                fontWeight: mine ? FontWeight.w700 : FontWeight.w400)),
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
      await CommunityApi.addReply(post.id, text);
      replyCtl.clear();
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
                  if (post.absoluteImageUrl != null) ...[
                    const SizedBox(height: 12),
                    GestureDetector(
                      onTap: () => showImageViewer(
                          context, post.absoluteImageUrl!,
                          caption: post.authorName),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: Image.network(
                          post.absoluteImageUrl!,
                          width: double.infinity,
                          fit: BoxFit.cover,
                          errorBuilder: (c, e, s) => const SizedBox.shrink(),
                        ),
                      ),
                    ),
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
                    for (final reply in replies) _replyTile(reply),
                  const SizedBox(height: 12),
                ],
              ),
            ),
            // Reply composer
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 6, 14, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
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
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: blue))
                        : IconButton(
                            icon: const Icon(Icons.send_rounded, color: blue),
                            onPressed: _send,
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

  Widget _replyTile(CommunityReply reply) {
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
