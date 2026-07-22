import 'package:flutter/foundation.dart';

/// Broadcasts tab switches so pages can tidy themselves (clear inputs,
/// dismiss keyboards) the moment the user swipes or taps away.
class TabEvents {
  static final ValueNotifier<int> changed = ValueNotifier(0);
}
