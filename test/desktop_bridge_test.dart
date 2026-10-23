// SPDX-License-Identifier: MIT
//
// Tests for `DesktopNcmBridge`.
//
// The happy path is exercised against a scripted stand-in for the real
// `bundle.js`: the bridge only speaks NDJSON over stdin/stdout, so a tiny
// Node script is enough to drive every protocol path deterministically and
// without touching the network.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ncm_api_enhanced/ncm_api_enhanced.dart';

/// A stand-in for `bundle.js` that announces readiness and echoes every
/// request back as a successful response.
const String _echoBridge = r'''
'use strict'
process.stdout.write(
  JSON.stringify({event: 'ready', data: {pid: process.pid, node: process.version}}) + '\n',
)
let buf = ''
process.stdin.on('data', (chunk) => {
  buf += chunk.toString()
  let idx
  while ((idx = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, idx)
    buf = buf.slice(idx + 1)
    if (!line.trim()) continue
    const req = JSON.parse(line)
    process.stdout.write(
      JSON.stringify({
        id: req.id,
        ok: true,
        result: {echo: req.method, params: req.params},
      }) + '\n',
    )
  }
})
''';

/// A stand-in that announces readiness and then never answers.
const String _silentBridge = r'''
'use strict'
process.stdout.write(
  JSON.stringify({event: 'ready', data: {pid: process.pid, node: process.version}}) + '\n',
)
process.stdin.resume()
''';

/// A stand-in that announces readiness and exits as soon as it gets a
/// request, simulating a crashing Node process.
const String _crashingBridge = r'''
'use strict'
process.stdout.write(
  JSON.stringify({event: 'ready', data: {pid: process.pid, node: process.version}}) + '\n',
)
let buf = ''
process.stdin.on('data', (chunk) => {
  buf += chunk.toString()
  if (buf.includes('\n')) process.exit(3)
})
''';

bool _nodeAvailable() {
  try {
    return Process.runSync('node', <String>['--version']).exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// Writes [script] as `bundle.js` into a fresh temporary directory, next to
/// the `xhr-sync-worker.js` stub the bridge requires.
Directory _createBridgeRoot(String script) {
  final dir = Directory.systemTemp.createTempSync('ncm_test_bridge_');
  File(
    '${dir.path}${Platform.pathSeparator}bundle.js',
  ).writeAsStringSync(script);
  File(
    '${dir.path}${Platform.pathSeparator}xhr-sync-worker.js',
  ).writeAsStringSync('// test stub\n');
  return dir;
}

/// Locates the real bundled bridge, if the package assets were built.
String? _realBridgeRoot() {
  final fromEnv = Platform.environment['NCM_BRIDGE_ROOT'];
  if (fromEnv != null && fromEnv.isNotEmpty) {
    return fromEnv;
  }

  for (final candidate in <String>[
    'assets${Platform.pathSeparator}bridge${Platform.pathSeparator}dist',
  ]) {
    final dir = Directory(candidate);
    final bundle = File('${dir.path}${Platform.pathSeparator}bundle.js');
    if (bundle.existsSync()) {
      return dir.absolute.path;
    }
  }

  return null;
}

void main() {
  final hasNode = _nodeAvailable();

  // The groups below spawn a real Node process, so they are skipped when
  // Node.js is not installed.
  final nodeSkip = hasNode ? null : 'node is not installed';

  group('lifecycle guards', () {
    test('call() before start() throws a StateError', () {
      final bridge = DesktopNcmBridge();

      expect(
        () => bridge.call('album'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('call() before start()'),
          ),
        ),
      );
    });

    test('shutdown() before start() is a no-op', () async {
      final bridge = DesktopNcmBridge();

      await bridge.shutdown();

      expect(() => bridge.call('album'), throwsA(isA<StateError>()));
    });
  });

  group('bridge root validation', () {
    test('start() fails when bundle.js is missing', () async {
      final root = Directory.systemTemp.createTempSync('ncm_test_empty_');
      addTearDown(() => root.deleteSync(recursive: true));

      final bridge = DesktopNcmBridge(bridgeRoot: root.path);

      await expectLater(
        bridge.start(),
        throwsA(
          isA<BridgeError>().having(
            (e) => e.message,
            'message',
            contains('bundle.js not found'),
          ),
        ),
      );
    });

    test('start() fails when xhr-sync-worker.js is missing', () async {
      final root = Directory.systemTemp.createTempSync('ncm_test_partial_');
      File(
        '${root.path}${Platform.pathSeparator}bundle.js',
      ).writeAsStringSync('// stub\n');
      addTearDown(() => root.deleteSync(recursive: true));

      final bridge = DesktopNcmBridge(bridgeRoot: root.path);

      await expectLater(
        bridge.start(),
        throwsA(
          isA<BridgeError>().having(
            (e) => e.message,
            'message',
            contains('xhr-sync-worker.js not found'),
          ),
        ),
      );
    });

    test('a failed start leaves the bridge unusable', () async {
      final root = Directory.systemTemp.createTempSync('ncm_test_empty_');
      addTearDown(() => root.deleteSync(recursive: true));

      final bridge = DesktopNcmBridge(bridgeRoot: root.path);

      await expectLater(bridge.start(), throwsA(isA<BridgeError>()));

      expect(() => bridge.call('album'), throwsA(isA<StateError>()));
    });

    test('start() fails when the node executable does not exist', () async {
      final root = _createBridgeRoot(_echoBridge);
      addTearDown(() => root.deleteSync(recursive: true));

      final bridge = DesktopNcmBridge(
        bridgeRoot: root.path,
        nodeExecutable: 'ncm-no-such-node-executable',
      );

      await expectLater(bridge.start(), throwsA(isA<ProcessException>()));
    });
  });

  group('protocol', () {
    late Directory root;

    setUp(() {
      root = _createBridgeRoot(_echoBridge);
    });

    tearDown(() {
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    });

    test('start() emits a ready event', () async {
      final bridge = DesktopNcmBridge(bridgeRoot: root.path);

      final ready = Completer<Map<String, dynamic>>();
      final subscription = bridge.events.listen((event) {
        if (event['event'] == 'ready' && !ready.isCompleted) {
          ready.complete(event);
        }
      });
      addTearDown(subscription.cancel);

      await bridge.start();
      addTearDown(bridge.shutdown);

      final event = await ready.future.timeout(const Duration(seconds: 5));
      expect(event['event'], 'ready');
    });

    test('start() is idempotent', () async {
      final bridge = DesktopNcmBridge(bridgeRoot: root.path);

      var readyCount = 0;
      final subscription = bridge.events.listen((event) {
        if (event['event'] == 'ready') {
          readyCount++;
        }
      });
      addTearDown(subscription.cancel);

      await bridge.start();
      await bridge.start();
      addTearDown(bridge.shutdown);

      expect(readyCount, 1);
    });

    test('a call round-trips through the node process', () async {
      final bridge = DesktopNcmBridge(bridgeRoot: root.path);
      await bridge.start();
      addTearDown(bridge.shutdown);

      final result = await bridge.call('album', <String, dynamic>{'id': 12345});

      expect(result['echo'], 'album');
      expect(result['params'], <String, dynamic>{'id': 12345});
    });

    test('concurrent calls are matched to their own request', () async {
      final bridge = DesktopNcmBridge(bridgeRoot: root.path);
      await bridge.start();
      addTearDown(bridge.shutdown);

      final results = await Future.wait(<Future<Map<String, dynamic>>>[
        bridge.call('album', <String, dynamic>{'n': 1}),
        bridge.call('search', <String, dynamic>{'n': 2}),
        bridge.call('banner', <String, dynamic>{'n': 3}),
      ]);

      expect(results[0]['echo'], 'album');
      expect(results[0]['params'], <String, dynamic>{'n': 1});
      expect(results[1]['echo'], 'search');
      expect(results[1]['params'], <String, dynamic>{'n': 2});
      expect(results[2]['echo'], 'banner');
      expect(results[2]['params'], <String, dynamic>{'n': 3});
    });

    test('call() after shutdown throws a StateError', () async {
      final bridge = DesktopNcmBridge(bridgeRoot: root.path);
      await bridge.start();
      await bridge.shutdown();

      expect(() => bridge.call('album'), throwsA(isA<StateError>()));
    });

    test('shutdown() closes the event stream', () async {
      final bridge = DesktopNcmBridge(bridgeRoot: root.path);
      await bridge.start();

      final done = Completer<void>();
      final subscription = bridge.events.listen(
        (_) {},
        onDone: () {
          if (!done.isCompleted) {
            done.complete();
          }
        },
      );
      addTearDown(subscription.cancel);

      await bridge.shutdown();

      await done.future.timeout(const Duration(seconds: 5));
    });
  }, skip: nodeSkip);

  group('timeouts', () {
    test('a call that is never answered times out', () async {
      final root = _createBridgeRoot(_silentBridge);
      addTearDown(() => root.deleteSync(recursive: true));

      final bridge = DesktopNcmBridge(
        bridgeRoot: root.path,
        callTimeout: const Duration(milliseconds: 150),
      );
      await bridge.start();
      addTearDown(bridge.shutdown);

      await expectLater(
        bridge.call('album', <String, dynamic>{'id': 1}),
        throwsA(
          isA<TimeoutException>().having(
            (e) => e.message,
            'message',
            allOf(startsWith('NCM call "album"'), contains('exceeded')),
          ),
        ),
      );
    });
  }, skip: nodeSkip);

  group('node crashes', () {
    test('pending calls are rejected and a fatal event is emitted', () async {
      final root = _createBridgeRoot(_crashingBridge);
      addTearDown(() => root.deleteSync(recursive: true));

      final bridge = DesktopNcmBridge(bridgeRoot: root.path);
      await bridge.start();

      final fatal = Completer<Map<String, dynamic>>();
      final done = Completer<void>();
      final subscription = bridge.events.listen(
        (event) {
          if (event['event'] == 'fatal' && !fatal.isCompleted) {
            fatal.complete(event);
          }
        },
        onDone: () {
          if (!done.isCompleted) {
            done.complete();
          }
        },
      );
      addTearDown(subscription.cancel);

      final call = expectLater(
        bridge.call('album', <String, dynamic>{'id': 1}),
        throwsA(
          isA<BridgeError>().having(
            (e) => e.message,
            'message',
            contains('node bridge exited'),
          ),
        ),
      );

      await call;
      await fatal.future.timeout(const Duration(seconds: 5));
      await done.future.timeout(const Duration(seconds: 5));
    });
  }, skip: nodeSkip);

  group('real bundled bridge', () {
    final realRoot = _realBridgeRoot();

    test('starts and rejects an unknown module', () async {
      if (!hasNode || realRoot == null) {
        markTestSkipped(
          'Needs node and the bundled bridge assets; run '
          '`tool/refresh_bridge.sh` first.',
        );
        return;
      }

      final bridge = DesktopNcmBridge(bridgeRoot: realRoot);
      await bridge.start();
      addTearDown(bridge.shutdown);

      await expectLater(
        bridge.call('definitely_not_an_upstream_module'),
        throwsA(
          isA<BridgeError>().having(
            (e) => e.message,
            'message',
            contains('unknown method'),
          ),
        ),
      );
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
