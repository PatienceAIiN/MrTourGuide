import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'api_base.dart';
import 'app_info.dart';
import 'auth_api.dart';

/// Ships uncaught Dart/Flutter errors to the backend, which emails the dev
/// inbox — throttled on both sides so a crash loop can't flood anything.
class CrashReporter {
  static DateTime _lastSent = DateTime.fromMillisecondsSinceEpoch(0);

  static void install() {
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      report(details.exceptionAsString(), details.stack?.toString() ?? '');
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      report(error.toString(), stack.toString());
      return true; // handled: keep the app alive where possible
    };
  }

  static Future<void> report(String error, String stack) async {
    // Client throttle: at most one report per 2 minutes.
    if (DateTime.now().difference(_lastSent) < const Duration(minutes: 2)) {
      return;
    }
    _lastSent = DateTime.now();
    try {
      await http
          .post(
            Uri.parse('$apiBase/crash-report'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'error': error.length > 800 ? error.substring(0, 800) : error,
              'stack': stack.length > 6000 ? stack.substring(0, 6000) : stack,
              'version': '$appVersion+$appBuildNumber',
              'userId': AuthApi.currentUser?.id,
            }),
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // Reporting must never cause more errors.
    }
  }
}
