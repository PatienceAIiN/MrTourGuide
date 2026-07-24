import 'package:flutter/foundation.dart';

/// Broadcasts tab switches so pages can tidy themselves (clear inputs,
/// dismiss keyboards) the moment the user swipes or taps away.
class TabEvents {
  static final ValueNotifier<int> changed = ValueNotifier(0);
}

/// Fired when a push says new content landed (video / GuideVibe / community)
/// — listening screens refresh THEMSELVES instantly, no manual pull needed.
class ContentEvents {
  static final ValueNotifier<int> refresh = ValueNotifier(0);
  static void ping() => refresh.value++;
}
