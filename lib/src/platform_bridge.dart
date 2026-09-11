// Platform-aware bridge factory. Picks [DesktopNcmBridge] (Linux/macOS/Windows)
// or [MobileNcmBridge] (Android/iOS) based on [defaultTargetPlatform].
//
// To override (e.g. for desktop-on-a-mobile-emulator debugging):
//   NcmBridgeFactory.use(DesktopNcmBridge(...));
// before constructing the [NcmApi].

import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;

import 'bridge.dart';
import 'desktop_bridge.dart';
import 'mobile_bridge.dart';

typedef NcmBridgeBuilder = NcmBridge Function();

class NcmBridgeFactory {
  NcmBridgeFactory._();

  static NcmBridgeBuilder? _override;

  /// Pin a specific bridge implementation (typically for tests).
  static void use(NcmBridgeBuilder builder) => _override = builder;

  /// Reset any pinned builder.
  static void reset() => _override = null;

  static NcmBridge build() {
    final o = _override;
    if (o != null) return o();

    // Exhaustiveness: every defined TargetPlatform is handled below. If
    // Flutter adds a new platform, the analyzer will flag the missing case.
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
        return MobileNcmBridge();
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        return DesktopNcmBridge();
      case TargetPlatform.fuchsia:
        throw UnsupportedError(
          'ncm_api_enhanced: Fuchsia is not supported (no libnode build).',
        );
    }
  }
}