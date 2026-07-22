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

  /// Neutralizes ad slots without ever deleting page containers: elements
  /// are hidden (not removed), and anything carrying real text content is
  /// left alone — so article layouts never collapse to a blank page.
  static const _cleanupJs = '''
    (function(){
      const sel = [
        'iframe[src*="doubleclick"]','iframe[src*="adsystem"]',
        'iframe[src*="googlesyndication"]','ins.adsbygoogle',
        '[id^="div-gpt-ad"]','[id^="google_ads"]','[data-ad-slot]',
        '[id^="taboola-"]','[class^="taboola"]','[id^="outbrain"]'
      ];
      const sweep = () => sel.forEach(q =>
        document.querySelectorAll(q).forEach(el => {
          // Never touch anything that carries real content.
          if ((el.innerText || '').length > 200) return;
          if (el === document.body || el === document.documentElement) return;
          el.style.setProperty('display', 'none', 'important');
        }));
      sweep();
      let pending = false;
      new MutationObserver(() => {
        if (pending) return;
        pending = true;
        setTimeout(() => { pending = false; sweep(); }, 500);
      }).observe(document.body || document.documentElement,
          {childList: true, subtree: true});
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
