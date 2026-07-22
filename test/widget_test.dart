// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mrtouride/login.dart';
import 'package:mrtouride/main.dart';
import 'package:mrtouride/navpages/dashboard_page.dart';
import 'package:mrtouride/navpages/itinerary_page.dart';
import 'package:mrtouride/navpages/main_page.dart';
import 'package:mrtouride/navpages/my_page.dart';
import 'package:mrtouride/navpages/search_page.dart';
import 'package:mrtouride/signup.dart';
import 'package:mrtouride/widgets/content_toast.dart';
import 'package:mrtouride/widgets/bottom_nav.dart';

void main() {
  // Any RenderFlex overflow thrown during layout fails these tests, so they
  // double as regression tests for the scroll fixes on all three pages.
  testWidgets('Landing page shows Login and Sign Up',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: HomePage()));

    expect(find.text('Login'), findsOneWidget);
    expect(find.text('Sign Up'), findsOneWidget);
  });

  testWidgets('Login page renders without overflow',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginPage()));

    expect(find.text('Sign In'), findsOneWidget);
  });

  testWidgets('Signup page renders and scrolls to the Sign Up button',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: SingUpPage()));

    // The page is taller than the viewport; the button must be reachable
    // by scrolling.
    await tester.ensureVisible(find.text('Sign Up'));
    // The artwork floats forever, so settle-forever would time out — a
    // fixed pump is enough for the scroll to finish.
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Sign Up'), findsOneWidget);
  });

  testWidgets('Dashboard renders and degrades gracefully when backend is down',
      (WidgetTester tester) async {
    // The test environment blocks HTTP, mimicking an unreachable backend:
    // the page must show its error card instead of crashing.
    await tester.pumpWidget(const MaterialApp(home: DashboardPage()));
    await tester.pumpAndSettle();

    expect(find.text('Explore Experiences'), findsOneWidget);
    expect(
        find.textContaining('Cannot reach the media server'), findsOneWidget);
  });

  testWidgets('Search page searches and shows result state',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: SearchPage()));

    await tester.enterText(find.byType(TextField), 'taj');
    // Debounce (350 ms) then the (blocked) request resolves to the error state.
    await tester.pumpAndSettle(const Duration(milliseconds: 400));

    expect(
        find.textContaining('Cannot reach the media server'), findsOneWidget);
  });

  testWidgets('AI Itinerary page renders prompt, quick chips and plans',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: ItineraryPage()));
    await tester.pumpAndSettle();

    expect(find.text('AI Itinerary'), findsOneWidget);
    expect(find.text('Weekend in the Golden Triangle'), findsOneWidget);

    // Ask for a plan; network is blocked in tests, so it lands on the
    // error state instead of a plan — but the flow must not crash.
    await tester.enterText(find.byType(TextField), '3 days in Rajasthan');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  });

  testWidgets('My Profile page renders account card',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: MyPage()));
    await tester.pumpAndSettle();

    expect(find.text('My Profile'), findsOneWidget);
    expect(find.text('Guest'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
  });

  testWidgets('Bottom nav shows merged entries and slides between tabs',
      (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: MainPage()));
    await tester.pumpAndSettle();

    // Merged navbar: tabs + global actions in one scrollable, centered bar.
    // (Feedback, updates and log out live inside Settings.)
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Explore'), findsOneWidget);
    expect(find.text('MR/VR'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AppBottomNav),
        matching: find.text('Settings'),
      ),
      findsOneWidget,
    );

    // Switch to Community via the bar — page slides in.
    await tester.tap(find.descendant(
      of: find.byType(AppBottomNav),
      matching: find.text('Community'),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Share how it felt...'), findsOneWidget);
  });

  testWidgets('Login page has password eye toggle and Google sign-in',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginPage()));

    expect(find.byIcon(Icons.visibility), findsOneWidget);
    expect(find.text('Sign in with Google'), findsOneWidget);

    // Toggle visibility.
    await tester.tap(find.byIcon(Icons.visibility));
    await tester.pump();
    expect(find.byIcon(Icons.visibility_off), findsOneWidget);
  });

  testWidgets('Signup page has role choice, eye toggle and Google signup',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: SingUpPage()));

    expect(find.text('Traveler'), findsOneWidget);
    expect(find.text('Creator'), findsOneWidget);
    expect(find.byIcon(Icons.visibility), findsOneWidget);
    await tester.ensureVisible(find.text('Sign up with Google'));
    expect(find.text('Sign up with Google'), findsOneWidget);
  });

  testWidgets('New-content toast shows, opens Explore, and dismisses',
      (WidgetTester tester) async {
    var opened = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => ContentToast.show(
                context,
                message: '2 new experiences · Golden Temple Evening…',
                onOpen: () => opened = true,
              ),
              child: const Text('fire'),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('fire'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('2 new experiences'), findsOneWidget);

    // The capsule's tap action opens Explore and dismisses the toast.
    // (Invoked directly — hit-testing through BackdropFilter is unreliable
    // in the test harness, but the wiring is what matters here.)
    final capsule = tester.widget<InkWell>(
      find
          .ancestor(
            of: find.textContaining('2 new experiences'),
            matching: find.byType(InkWell),
          )
          .first,
    );
    capsule.onTap!();
    await tester.pump(const Duration(milliseconds: 100));
    expect(opened, isTrue);
    expect(find.textContaining('2 new experiences'), findsNothing);
    await tester.pump(const Duration(seconds: 8)); // drain auto-dismiss timer
  });
}
