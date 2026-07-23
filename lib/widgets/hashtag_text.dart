import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../constant.dart';
import '../navpages/search_page.dart';

/// Renders text with #hashtags highlighted and tappable. Tapping a tag opens
/// Search pre-filled with that tag — a lightweight, system-wide hashtag
/// recognition used in captions, posts and comments.
class HashtagText extends StatefulWidget {
  final String text;
  final TextStyle? style;

  /// Colour for the hashtags themselves (defaults to the brand accent).
  final Color? tagColor;
  final int? maxLines;
  final TextOverflow overflow;

  const HashtagText(
    this.text, {
    super.key,
    this.style,
    this.tagColor,
    this.maxLines,
    this.overflow = TextOverflow.clip,
  });

  /// The hashtags found in [text] (without the leading #), lowercased.
  static List<String> tagsIn(String text) => _tagPattern
      .allMatches(text)
      .map((m) => m.group(1)!.toLowerCase())
      .toSet()
      .toList();

  @override
  State<HashtagText> createState() => _HashtagTextState();
}

// A hashtag: # followed by a letter, then letters/digits/underscores.
final RegExp _tagPattern = RegExp(r'#([A-Za-z][\w]{0,49})');

class _HashtagTextState extends State<HashtagText> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  void _openTag(String tag) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SearchPage(initialQuery: tag)),
    );
  }

  @override
  Widget build(BuildContext context) {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();

    final base = widget.style ?? DefaultTextStyle.of(context).style;
    final tagStyle = base.copyWith(
      color: widget.tagColor ?? brandInk(context),
      fontWeight: FontWeight.w700,
    );

    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in _tagPattern.allMatches(widget.text)) {
      if (m.start > last) {
        spans.add(TextSpan(text: widget.text.substring(last, m.start)));
      }
      final tag = m.group(1)!;
      final rec = TapGestureRecognizer()..onTap = () => _openTag(tag);
      _recognizers.add(rec);
      spans.add(TextSpan(text: '#$tag', style: tagStyle, recognizer: rec));
      last = m.end;
    }
    if (last < widget.text.length) {
      spans.add(TextSpan(text: widget.text.substring(last)));
    }

    return Text.rich(
      TextSpan(style: base, children: spans),
      maxLines: widget.maxLines,
      overflow: widget.overflow,
    );
  }
}
