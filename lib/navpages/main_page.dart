import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mrtouride/ar_view.dart';
import 'package:mrtouride/constant.dart';
import 'package:mrtouride/home_page.dart';
import 'package:mrtouride/navpages/community_page.dart';
import 'package:mrtouride/navpages/itinerary_page.dart';
import 'package:mrtouride/navpages/dashboard_page.dart';
import 'package:mrtouride/navpages/my_page.dart';
import 'package:mrtouride/navpages/search_page.dart';
import 'package:mrtouride/services/api_base.dart';
import 'package:mrtouride/services/auth_api.dart';
import 'package:mrtouride/services/notification_service.dart';
import 'package:mrtouride/services/settings_service.dart';
import 'package:mrtouride/services/update_service.dart';
import 'package:mrtouride/settings_page.dart';
import 'package:mrtouride/widgets/bottom_nav.dart';
import 'package:mrtouride/widgets/content_toast.dart';
import 'package:mrtouride/widgets/update_flow.dart';
import 'package:mrtouride/widgets/ux.dart';
import 'package:url_launcher/url_launcher.dart';

class MainPage extends StatefulWidget {
  @override
  _MainPageState createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  late final PageController _pageController;
  int currentIndex = 0;
  bool hasNewContent = false;
  Timer? _newContentTimer;

  late final List<Widget> pages = [
    HomeScreen(onSelectTab: onTap),
    DashboardPage(onSelectTab: onTap),
    CommunityPage(onSelectTab: onTap),
    SearchPage(onSelectTab: onTap),
    MyPage(onSelectTab: onTap),
    ItineraryPage(onSelectTab: onTap),
  ];

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    SettingsService.instance.load();
    _checkForUpdate();
    // New-content notifications: on entry + a gentle 90s cadence.
    _checkNewContent();
    // 5-minute cadence — friendly to the free-tier VM.
    _newContentTimer =
        Timer.periodic(const Duration(minutes: 5), (_) => _checkNewContent());
  }

  Future<void> _checkNewContent() async {
    final fresh = await NotificationService.check();
    if (fresh == null || !mounted) return;
    setState(() => hasNewContent = true);
    ContentToast.show(
      context,
      message: fresh.headline,
      onOpen: () {
        NotificationService.markSeen();
        setState(() => hasNewContent = false);
        onTap(1); // Explore
      },
    );
  }

  @override
  void dispose() {
    _newContentTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  /// iOS-like slide between tabs (also swipeable).
  void onTap(int index) {
    if (index == 1 && hasNewContent) {
      NotificationService.markSeen();
      setState(() => hasNewContent = false);
    }
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
  /// The whole update happens in-app: download with progress, then an
  /// install prompt once the new build is ready.
  Future<void> _checkForUpdate() async {
    final info = await UpdateService.check();
    if (info == null || !info.isNewer || !mounted) return;
    await runUpdateFlow(context, info);
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
            NavEntry(
                icon: (AuthApi.currentUser?.isCreator ?? false)
                    ? Icons.video_settings_rounded
                    : Icons.video_library_rounded,
                label: (AuthApi.currentUser?.isCreator ?? false)
                    ? 'Studio'
                    : 'Explore',
                tabIndex: 1,
                badge: hasNewContent),
            const NavEntry(
                icon: Icons.route_rounded, label: 'Planner', tabIndex: 5),
            NavEntry(
              icon: Icons.view_in_ar_rounded,
              label: 'MR/VR',
              color: Colors.purple,
              action: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const ArViewPage()),
              ),
            ),
            const NavEntry(
                icon: Icons.forum_rounded, label: 'Community', tabIndex: 2),
            NavEntry(
              icon: Icons.tune_rounded,
              label: 'Settings',
              action: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const SettingsPage()),
              ),
            ),
            const NavEntry(
                icon: Icons.person_rounded, label: 'Profile', tabIndex: 4),
          ],
        ),
      ),
    );
  }
}
