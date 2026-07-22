import 'package:flutter/material.dart';

import '../constant.dart';
import '../news_webview.dart';
import '../services/haptic_service.dart';
import '../services/media_api.dart';

/// Travel news rail: cover image + headline cards. Tapping opens the
/// article in the in-app ad-blocked reader.
List<Widget> newsSection(BuildContext context, List<NewsItem> news) {
  if (news.isEmpty) return const [];
  return [
    Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 10),
      child: Row(
        children: [
          const Icon(Icons.newspaper, size: 17, color: Colors.teal),
          const SizedBox(width: 6),
          Text('Travel news & precautions',
              style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14.5,
                  color: ink(context))),
        ],
      ),
    ),
    SizedBox(
      height: 190,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: news.length,
        separatorBuilder: (c, i) => const SizedBox(width: 10),
        itemBuilder: (context, i) => _NewsCard(item: news[i]),
      ),
    ),
  ];
}

class _NewsCard extends StatelessWidget {
  final NewsItem item;
  const _NewsCard({required this.item});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
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
        width: 220,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: cardBg(context),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.teal.withValues(alpha: 0.2)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Cover
            SizedBox(
              height: 100,
              width: double.infinity,
              child: item.image != null
                  ? Image.network(
                      item.image!,
                      fit: BoxFit.cover,
                      errorBuilder: (c, e, s) => _coverFallback(),
                    )
                  : _coverFallback(),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
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
                              height: 1.3)),
                    ),
                    Row(
                      children: [
                        const Icon(Icons.public, size: 11, color: Colors.grey),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(item.source,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 10.5, color: Colors.grey)),
                        ),
                        const Icon(Icons.chevron_right,
                            size: 14, color: Colors.teal),
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

  Widget _coverFallback() => Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: [
            Colors.teal.withValues(alpha: 0.3),
            blue.withValues(alpha: 0.3),
          ]),
        ),
        child: const Center(
            child: Icon(Icons.travel_explore, color: Colors.white70, size: 30)),
      );
}
