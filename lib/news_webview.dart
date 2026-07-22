import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'constant.dart';

/// Ad-free in-app reader for travel news: articles open inside the app and
/// a cleanup pass strips ad iframes, banners and sticky overlays.
class NewsWebViewPage extends StatefulWidget {
  final String title;
  final String url;
  const NewsWebViewPage({super.key, required this.title, required this.url});

  @override
  State<NewsWebViewPage> createState() => _NewsWebViewPageState();
}

class _NewsWebViewPageState extends State<NewsWebViewPage> {
  late final WebViewController controller;
  int progress = 0;

  static const _adHosts = [
    'doubleclick.net',
    'googlesyndication.com',
    'adservice.google',
    'taboola.com',
    'outbrain.com',
    'criteo.com',
    'pubmatic.com',
    'adnxs.com',
    'amazon-adsystem.com',
    'moatads.com',
    'scorecardresearch.com',
  ];

  /// Removes ad slots, sticky banners and consent walls after each load.
  static const _cleanupJs = '''
    (function(){
      const kill = [
        'iframe[src*="ads"]','iframe[id*="google_ads"]',
        '[id*="google_ads"]','[class*="advert"]','[class*="ad-slot"]',
        '[class*="ad-banner"]','[class*="sticky-ad"]','[id*="taboola"]',
        '[id*="outbrain"]','[class*="taboola"]','[class*="outbrain"]',
        'ins.adsbygoogle','[class*="paywall-banner"]'
      ];
      const sweep = () => kill.forEach(sel =>
        document.querySelectorAll(sel).forEach(el => el.remove()));
      sweep();
      new MutationObserver(sweep)
        .observe(document.documentElement, {childList: true, subtree: true});
    })();
  ''';

  @override
  void initState() {
    super.initState();
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (p) {
          if (mounted) setState(() => progress = p);
        },
        onPageFinished: (_) => controller.runJavaScript(_cleanupJs),
        onNavigationRequest: (request) {
          final host = Uri.tryParse(request.url)?.host ?? '';
          // Ad-free mode: ad/tracker destinations never load.
          if (_adHosts.any(host.contains)) {
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
      ))
      ..loadRequest(Uri.parse(widget.url));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: pageBg(context),
      appBar: AppBar(
        backgroundColor: cardBg(context),
        elevation: 0,
        iconTheme: IconThemeData(color: ink(context)),
        title: Text(widget.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: ink(context), fontSize: 15)),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 14),
            child: Center(
              child: Row(
                children: [
                  Icon(Icons.shield, size: 14, color: Colors.green),
                  SizedBox(width: 4),
                  Text('Ad-free',
                      style: TextStyle(fontSize: 11.5, color: Colors.green)),
                ],
              ),
            ),
          ),
        ],
        bottom: progress < 100
            ? PreferredSize(
                preferredSize: const Size.fromHeight(2),
                child: LinearProgressIndicator(
                    value: progress / 100, minHeight: 2, color: blue),
              )
            : null,
      ),
      body: WebViewWidget(controller: controller),
    );
  }
}
