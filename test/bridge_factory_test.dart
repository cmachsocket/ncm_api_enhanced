// SPDX-License-Identifier: MIT
//
// Unit tests for the platform-aware bridge factory.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ncm_api_enhanced/ncm_api_enhanced.dart';

import 'support/fake_bridge.dart';

void main() {
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    NcmBridgeFactory.reset();
  });

  group('override', () {
    test('use() pins a specific bridge implementation', () {
      final fake = FakeNcmBridge();
      NcmBridgeFactory.use(() => fake);

      expect(NcmBridgeFactory.build(), same(fake));
    });

    test('build() calls the pinned builder on every invocation', () {
      var builds = 0;
      NcmBridgeFactory.use(() {
        builds++;
        return FakeNcmBridge();
      });

      NcmBridgeFactory.build();
      NcmBridgeFactory.build();

      expect(builds, 2);
    });

    test('reset() restores the platform default', () {
      final fake = FakeNcmBridge();
      NcmBridgeFactory.use(() => fake);
      NcmBridgeFactory.reset();

      debugDefaultTargetPlatformOverride = TargetPlatform.linux;

      expect(NcmBridgeFactory.build(), isA<DesktopNcmBridge>());
    });
  });

  group('platform selection', () {
    test('builds a desktop bridge on Linux, macOS and Windows', () {
      for (final platform in <TargetPlatform>[
        TargetPlatform.linux,
        TargetPlatform.macOS,
        TargetPlatform.windows,
      ]) {
        debugDefaultTargetPlatformOverride = platform;

        expect(
          NcmBridgeFactory.build(),
          isA<DesktopNcmBridge>(),
          reason: '$platform must use the desktop bridge',
        );
      }
    });

    test('builds a mobile bridge on Android and iOS', () {
      for (final platform in <TargetPlatform>[
        TargetPlatform.android,
        TargetPlatform.iOS,
      ]) {
        debugDefaultTargetPlatformOverride = platform;

        // MobileNcmBridge opens `libncm_node_bridge.so` from its constructor,
        // and that library only exists on a real device. The load failure is
        // therefore proof that the factory picked the mobile implementation
        // instead of falling back to the desktop one.
        Object? thrown;
        try {
          NcmBridgeFactory.build();
        } catch (error) {
          thrown = error;
        }

        expect(
          thrown,
          isNotNull,
          reason:
              '$platform must not build a '
              'desktop bridge',
        );
        expect(
          '$thrown',
          contains('libncm_node_bridge.so'),
          reason: '$platform must try to load the native bridge',
        );
      }
    });

    test('rejects Fuchsia', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.fuchsia;

      expect(() => NcmBridgeFactory.build(), throwsA(isA<UnsupportedError>()));
    });
  });

  group('NcmApi default bridge', () {
    test('uses the factory when no bridge is injected', () {
      final fake = FakeNcmBridge();
      NcmBridgeFactory.use(() => fake);

      expect(NcmApi().bridge, same(fake));
    });

    test('uses the injected bridge when one is given', () {
      final fake = FakeNcmBridge();
      NcmBridgeFactory.use(() => FakeNcmBridge());

      expect(NcmApi(bridge: fake).bridge, same(fake));
    });
  });
}
