import 'package:flutter/material.dart';
import 'package:mrtouride/ar_view.dart';
import 'package:mrtouride/constant.dart';
import 'package:mrtouride/home_page.dart';
import 'package:mrtouride/navpages/community_page.dart';
import 'package:mrtouride/navpages/dashboard_page.dart';
import 'package:mrtouride/navpages/my_page.dart';
import 'package:mrtouride/navpages/search_page.dart';
import 'package:mrtouride/services/api_base.dart';
import 'package:mrtouride/services/settings_service.dart';
import 'package:mrtouride/services/update_service.dart';
import 'package:mrtouride/settings_page.dart';
import 'package:mrtouride/widgets/bottom_nav.dart';
import 'package:mrtouride/widgets/ux.dart';
import 'package:url_launcher/url_launcher.dart';

class MainPage extends StatefulWidget {
  @override
  _MainPageState createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  late final PageController _pageController;
  int currentIndex = 0;

  late final List<Widget> pages = [
    HomeScreen(onSelectTab: onTap),
    DashboardPage(onSelectTab: onTap),
    CommunityPage(onSelectTab: onTap),
    SearchPage(onSelectTab: onTap),
    MyPage(onSelectTab: onTap),
  ];

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    SettingsService.instance.load();
    _checkForUpdate();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  /// iOS-like slide between tabs (also swipeable).
  void onTap(int index) {
    final reduce = SettingsService.instance.reduceMotion;
    if (reduce) {
      _pageController.jumpToPage(index);
    } else {
      _pageController.animateToPage(
        index,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    }
    setState(() => currentIndex = index);
  }

  /// Silent OTA check on entry; only interrupts when a newer build exists.
  Future<void> _checkForUpdate() async {
    final info = await UpdateService.check();
    if (info == null || !info.isNewer || !mounted) return;
    final go = await confirmDialog(
      context,
      title: 'Update available',
      message: 'MrTouride v${info.version} (build ${info.buildNumber}) is '
          'out.\n${info.notes}\n\nDownload now? Old builds are cleaned up '
          'automatically after install.',
      confirmLabel: 'Download',
      cancelLabel: 'Later',
    );
    if (go && mounted) {
      launchUrl(Uri.parse(info.apkAvailable ? info.absoluteApkUrl : apiBase));
    }
  }

  @override
  Widget build(BuildContext context) {
    // Back button: return to the Home tab first; only exit from Home.
    return PopScope(
      canPop: currentIndex == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) onTap(0);
      },
      child: Scaffold(
        backgroundColor: pageBg(context),
        extendBody: true, // content flows under the floating bar
        body: PageView(
          controller: _pageController,
          onPageChanged: (i) => setState(() => currentIndex = i),
          children: pages,
        ),
        bottomNavigationBar: AppBottomNav(
          currentIndex: currentIndex,
          onSelectTab: onTap,
          entries: [
            const NavEntry(
                icon: Icons.home_rounded, label: 'Home', tabIndex: 0),
            const NavEntry(
                icon: Icons.video_library_rounded,
                label: 'Explore',
                tabIndex: 1),
            const NavEntry(
                icon: Icons.forum_rounded, label: 'Community', tabIndex: 2),
            const NavEntry(
                icon: Icons.person_rounded, label: 'Profile', tabIndex: 4),
            NavEntry(
              icon: Icons.view_in_ar_rounded,
              label: 'MR/VR',
              color: Colors.purple,
              action: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const ArViewPage()),
              ),
            ),
            // Feedback, updates and log out live inside Settings now.
            NavEntry(
              icon: Icons.tune_rounded,
              label: 'Settings',
              action: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const SettingsPage()),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
