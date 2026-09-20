// Verify README examples actually work.
//
// Run:
//   NCM_BRIDGE_ROOT=$PWD/assets/bridge/dist flutter test test/readme_verify_test.dart

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ncm_api_enhanced/ncm_api_enhanced.dart';

void main() {
  final root = Platform.environment['NCM_BRIDGE_ROOT'];
  if (root == null || root.isEmpty) {
    test('README verify', () {
      markTestSkipped('NCM_BRIDGE_ROOT not set');
    });
    return;
  }

  late NcmApi api;
  setUp(() async {
    api = NcmApi(bridge: DesktopNcmBridge(bridgeRoot: root));
    await api.start();
  });
  tearDown(() async => api.shutdown());

  test('README v1: api.call with snake_case method names', () async {
    final banner = await api.call('banner');
    expect(banner['body']['code'], 200);

    final me = await api.call('user_account');
    expect(me['body']['code'], 200);

    final qr = await api.call('login_qr_create', {'type': 1});
    expect(qr.containsKey('body'), isTrue);
  });

  test('Verify: api.call with camelCase method names throws', () {
    expect(
      () => api.call('userAccount'),
      throwsA(isA<ArgumentError>()),
      reason:
          'method names are snake_case upstream names, not Dart identifiers',
    );
  });
}