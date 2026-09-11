// SPDX-License-Identifier: MIT
//
// End-to-end bridge protocol smoke test.
//
// Run from the package root:
//   NCM_BRIDGE_ROOT=$PWD/bridge flutter test test/bridge_smoke_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ncm_api_enhanced/ncm_api_enhanced.dart';

void main() {
  final root = Platform.environment['NCM_BRIDGE_ROOT'];
  if (root == null || root.isEmpty) {
    test('bridge smoke', () {
      markTestSkipped(
        'NCM_BRIDGE_ROOT not set. Run '
        '`tool/refresh_bridge.sh` first.',
      );
    });
    return;
  }

  // Note: we don't call TestWidgetsFlutterBinding.ensureInitialized()
  // here because this test does not exercise any Flutter widgets, and
  // initializing the binding seems to block Process.start in the
  // flutter_test harness.
  late NcmApi api;
  setUp(() async {
    api = NcmApi(bridge: DesktopNcmBridge(bridgeRoot: root));
    await api.start();
  });

  tearDown(() async {
    await api.shutdown();
  });

  test('5 concurrent banner calls run in parallel', () async {
    final sw = Stopwatch()..start();
    final results = await Future.wait([
      api.call('banner', <String, dynamic>{}),
      api.call('banner', <String, dynamic>{}),
      api.call('banner', <String, dynamic>{}),
      api.call('banner', <String, dynamic>{}),
      api.call('banner', <String, dynamic>{}),
    ]);
    sw.stop();
    for (final r in results) {
      final body = r['body'] as Map<String, dynamic>;
      expect(body['code'], 200);
    }
    // ignore: avoid_print
    print('5 concurrent banner calls: ${sw.elapsedMilliseconds}ms');
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('unknown method rejected at facade layer', () {
    // NcmApi validates method names against the upstream whitelist before
    // hitting the bridge, so an unknown name throws ArgumentError (not
    // BridgeError).
    expect(
      () => api.call('definitely_not_a_method', <String, dynamic>{}),
      throwsA(isA<ArgumentError>()),
    );
  });
}