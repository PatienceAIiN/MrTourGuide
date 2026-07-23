import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:mrtouride/constant.dart';
import 'package:mrtouride/login.dart';
import 'package:mrtouride/navpages/main_page.dart';
import 'package:mrtouride/services/auth_api.dart';
import 'package:mrtouride/services/media_api.dart';
import 'package:mrtouride/services/push_service.dart';
import 'package:mrtouride/services/settings_service.dart';
import 'package:mrtouride/signup.dart';
import 'package:url_launcher/url_launcher.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SettingsService.instance.load();
  PushService.init(); // fire-and-forget: push must never block startup
  runApp(ListenableBuilder(
    listenable: SettingsService.instance,
    builder: (context, _) => MaterialApp(
      debugShowCheckedModeBanner: false,
      // Material 3 expressive: brand-seeded dynamic color scheme, rounded
      // shapes — plus Apple-style slide (iOS push/pop with parallax +
      // swipe-back) on every route transition, on all platforms.
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1E319D),
          secondary: const Color(0xFF3CEBFF),
          tertiary: const Color(0xFF9C27B0),
        ),
        splashFactory: InkSparkle.splashFactory, // expressive ripple
        cardTheme: const CardThemeData(
          elevation: 1,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(16)),
          ),
        ),
        chipTheme: ChipThemeData(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
        ),
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: {
            TargetPlatform.android: CupertinoPageTransitionsBuilder(),
            TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
            TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
            TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
            TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
            TargetPlatform.fuchsia: CupertinoPageTransitionsBuilder(),
          },
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1E319D),
          brightness: Brightness.dark,
          secondary: const Color(0xFF3CEBFF),
          tertiary: const Color(0xFF9C27B0),
        ),
        scaffoldBackgroundColor: const Color(0xFF101012),
        splashFactory: InkSparkle.splashFactory,
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: {
            TargetPlatform.android: CupertinoPageTransitionsBuilder(),
            TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
            TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
            TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
            TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
            TargetPlatform.fuchsia: CupertinoPageTransitionsBuilder(),
          },
        ),
      ),
      themeMode: SettingsService.instance.themeMode,
      home: const HomePage(),
    ),
  ));
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // Welcome carousel: city covers flip through; asset art until they load.
  List<String> covers = [];
  int coverIndex = 0;
  Timer? _flip;

  // The animated headline cycles slowly through short 2-3 word phrases.
  static const _welcomePhrases = [
    'Exploring Together',
    'Feel the World',
    'Go Anywhere',
    'Touch the Journey',
    'Travel by Feel',
    'Anywhere, Together',
    'Windows to the World',
    'Feel Every Place',
  ];
  int _phraseIndex = 0;
  Timer? _phraseTimer;

  @override
  void initState() {
    super.initState();
    // Persistent login: an existing session skips the welcome screen.
    AuthApi.restoreSession().then((user) {
      if (user != null && mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (context) => MainPage()),
          (route) => false,
        );
      }
    });
    MediaApi.fetchCities().then((cities) {
      if (!mounted) return;
      setState(() {
        covers = [
          for (final c in cities)
            if (c.absoluteCoverUrl != null) c.absoluteCoverUrl!
        ];
      });
      _flip = Timer.periodic(const Duration(seconds: 3), (_) {
        if (mounted && covers.length > 1) {
          setState(() => coverIndex = (coverIndex + 1) % covers.length);
        }
      });
    }).catchError((_) {});
    // Slow, calm cadence between phrases.
    _phraseTimer = Timer.periodic(const Duration(milliseconds: 4500), (_) {
      if (mounted) {
        setState(() =>
            _phraseIndex = (_phraseIndex + 1) % _welcomePhrases.length);
      }
    });
  }

  @override
  void dispose() {
    _flip?.cancel();
    _phraseTimer?.cancel();
    super.dispose();
  }

  /// 3D horizontal flip between covers.
  Widget _flipCarousel(double height) {
    final child = covers.isEmpty
        ? Container(
            key: const ValueKey('asset'),
            decoration: const BoxDecoration(
                image:
                    DecorationImage(image: AssetImage('assets/image/bg.png'))),
          )
        : ClipRRect(
            key: ValueKey(coverIndex),
            borderRadius: BorderRadius.circular(24),
            child: Image.network(
              covers[coverIndex],
              fit: BoxFit.cover,
              width: double.infinity,
              errorBuilder: (c, e, s) => Container(color: Colors.black12),
            ),
          );
    return SizedBox(
      height: height,
      width: double.infinity,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 650),
        switchInCurve: Curves.easeOutBack,
        transitionBuilder: (widget, animation) => AnimatedBuilder(
          animation: animation,
          child: widget,
          builder: (context, w) => Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..setEntry(3, 2, 0.0012)
              ..rotateY((1 - animation.value) * 1.5708),
            child: w,
          ),
        ),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Container(
                width: double.infinity,
                padding: EdgeInsets.symmetric(horizontal: 30, vertical: 50),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: <Widget>[
                    _flipCarousel(MediaQuery.of(context).size.height / 2.5),
                    Column(
                      children: <Widget>[
                        // Animated headline: cycles slowly through short
                        // phrases with a gentle slide + fade.
                        SizedBox(
                          height: 44,
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 700),
                            switchInCurve: Curves.easeOutCubic,
                            switchOutCurve: Curves.easeInCubic,
                            transitionBuilder: (child, animation) =>
                                FadeTransition(
                              opacity: animation,
                              child: SlideTransition(
                                position: Tween<Offset>(
                                  begin: const Offset(0, 0.25),
                                  end: Offset.zero,
                                ).animate(animation),
                                child: child,
                              ),
                            ),
                            child: Text(
                              _welcomePhrases[_phraseIndex],
                              key: ValueKey(_phraseIndex),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontFamily: 'Inter',
                                fontSize: 30,
                                color: ink(context),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        // Single line summarizing the whole idea.
                        Text(
                          "Feel the world from home — for everyone.",
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.grey[700],
                            fontSize: 14.5,
                          ),
                        ),
                      ],
                    ),
                    Column(
                      children: <Widget>[
                        MaterialButton(
                          minWidth: double.infinity,
                          height: 60,
                          onPressed: () {
                            Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (context) => LoginPage()));
                          },
                          //defining shape
                          shape: RoundedRectangleBorder(
                              side: BorderSide(color: ink(context)),
                              borderRadius: BorderRadius.circular(50)),
                          child: Text(
                            "Login",
                            style: TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 18),
                          ),
                        ),
                        SizedBox(height: 20),
                        MaterialButton(
                          minWidth: double.infinity,
                          height: 60,
                          onPressed: () {
                            Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (context) => SingUpPage()));
                          },
                          color: Color(0xFF052933),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(50)),
                          child: Text(
                            "Sign Up",
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                            ),
                          ),
                        ),
                      ],
                    ),
                    // Footer pinned to the bottom of the screen.
                    const _ProductLine(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "MrTour Guide · A product of PatienceAI" — taps through to patienceai.in.
class _ProductLine extends StatelessWidget {
  const _ProductLine();

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => launchUrl(Uri.parse('https://patienceai.in')),
      child: Text.rich(
        TextSpan(
          text: 'MrTour Guide · A product of ',
          style: const TextStyle(color: Colors.grey, fontSize: 12.5),
          children: [
            TextSpan(
              text: 'PatienceAI',
              style: TextStyle(
                color: const Color(0xFF1E319D),
                fontWeight: FontWeight.w700,
                decoration: TextDecoration.underline,
                decorationColor: const Color(0xFF1E319D).withValues(alpha: .4),
              ),
            ),
          ],
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}
