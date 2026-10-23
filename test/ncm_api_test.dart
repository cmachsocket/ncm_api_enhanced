// SPDX-License-Identifier: MIT
//
// Unit tests for the `NcmApi` facade.
//
// The facade is the public entry point of the package: it validates module
// names against the upstream whitelist and forwards calls to the bridge.

import 'package:flutter_test/flutter_test.dart';
import 'package:ncm_api_enhanced/ncm_api_enhanced.dart';

import 'support/fake_bridge.dart';

void main() {
  late FakeNcmBridge bridge;
  late NcmApi api;

  setUp(() {
    bridge = FakeNcmBridge();
    api = NcmApi(bridge: bridge);
  });

  group('call', () {
    test('forwards the module name and the params', () async {
      await api.call('album', <String, dynamic>{'id': 12345});

      expect(bridge.methods, <String>['album']);
      expect(bridge.paramLog.single, <String, dynamic>{'id': 12345});
    });

    test('forwards null params when none are given', () async {
      await api.call('banner');

      expect(bridge.methods, <String>['banner']);
      expect(bridge.paramLog.single, isNull);
    });

    test('returns the bridge response unchanged', () async {
      final response = <String, dynamic>{
        'status': 200,
        'body': <String, dynamic>{'code': 200},
        'cookie': <String>['MUSIC_U=...'],
      };
      final scoped = NcmApi(
        bridge: FakeNcmBridge(
          responses: <String, Map<String, dynamic>>{'album': response},
        ),
      );

      await expectLater(scoped.call('album'), completion(response));
    });

    test('propagates bridge failures', () async {
      final scoped = NcmApi(
        bridge: FakeNcmBridge(error: BridgeError('node died')),
      );

      await expectLater(
        scoped.call('album'),
        throwsA(
          isA<BridgeError>().having((e) => e.message, 'message', 'node died'),
        ),
      );
    });

    test('rejects unknown module names before touching the bridge', () {
      expect(
        () => api.call('definitely_not_a_module'),
        throwsA(isA<ArgumentError>()),
      );
      expect(bridge.methods, isEmpty);
    });

    test('rejects unknown module names even with params', () {
      expect(
        () => api.call('definitely_not_a_module', <String, dynamic>{}),
        throwsA(isA<ArgumentError>()),
      );
      expect(bridge.methods, isEmpty);
    });

    test('accepts every documented upstream module name', () async {
      const modules = <String>[
        'activate_init_profile',
        'album',
        'banner',
        'digitalAlbum_detail',
        'login_qr_create',
        'lyric',
        'rep_ugc_user_collect-vip',
        'search',
        'song_url',
        'user_account',
        'yunbei_today',
      ];

      for (final module in modules) {
        await api.call(module, <String, dynamic>{'id': 1});
      }

      expect(bridge.methods, modules);
    });
  });

  group('dynamic dispatch', () {
    test('forwards a positional map argument', () async {
      final dynamic dynamicApi = api;

      await dynamicApi.album(<String, dynamic>{'id': 42});

      expect(bridge.methods, <String>['album']);
      expect(bridge.paramLog.single, <String, dynamic>{'id': 42});
    });

    test('forwards named arguments using their identifier names', () async {
      final dynamic dynamicApi = api;

      await dynamicApi.album(id: 42, limit: 10);

      expect(bridge.methods, <String>['album']);
      expect(bridge.paramLog.single, <String, dynamic>{'id': 42, 'limit': 10});
    });

    test('forwards null params when called without arguments', () async {
      final dynamic dynamicApi = api;

      await dynamicApi.banner();

      expect(bridge.methods, <String>['banner']);
      expect(bridge.paramLog.single, isNull);
    });

    test('merges positional and named arguments', () async {
      final dynamic dynamicApi = api;

      await dynamicApi.album(<String, dynamic>{'id': 1}, limit: 10);

      expect(bridge.paramLog.single, <String, dynamic>{'id': 1, 'limit': 10});
    });

    test('rejects unknown module names', () {
      final dynamic dynamicApi = api;

      expect(
        () => dynamicApi.definitelyNotAModule(),
        throwsA(isA<ArgumentError>()),
      );
      expect(bridge.methods, isEmpty);
    });

    test('rejects a positional argument that is not a map', () {
      final dynamic dynamicApi = api;

      expect(() => dynamicApi.album(42), throwsA(isA<ArgumentError>()));
      expect(bridge.methods, isEmpty);
    });

    test('does not intercept Object protocol members', () {
      final dynamic dynamicApi = api;

      // `toJson` / `toJsonString` are not declared on NcmApi, so they reach
      // noSuchMethod and must fall through to Object's implementation.
      expect(() => dynamicApi.toJson(), throwsA(isA<NoSuchMethodError>()));
      expect(
        () => dynamicApi.toJsonString(),
        throwsA(isA<NoSuchMethodError>()),
      );
      expect(bridge.methods, isEmpty);
    });

    test('keeps the ordinary Object protocol intact', () {
      expect(api.toString(), isA<String>());
      expect(api.hashCode, isA<int>());
      expect(api == api, isTrue);
    });
  });

  group('lifecycle', () {
    test('start delegates to the bridge', () async {
      await api.start();

      expect(bridge.startCount, 1);
    });

    test('shutdown delegates to the bridge', () async {
      await api.shutdown();

      expect(bridge.shutdownCount, 1);
    });

    test('exposes the injected bridge', () {
      expect(api.bridge, same(bridge));
    });

    test('forwards bridge events', () async {
      final events = <Map<String, dynamic>>[];
      final subscription = api.bridgeEvents.listen(events.add);
      addTearDown(subscription.cancel);

      bridge.emit(<String, dynamic>{
        'event': 'log',
        'data': <String, dynamic>{'level': 'stderr', 'line': 'hello'},
      });

      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events.single['event'], 'log');
    });
  });
}
