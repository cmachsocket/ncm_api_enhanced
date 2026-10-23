// SPDX-License-Identifier: MIT
//
// Unit tests for the NDJSON protocol dispatcher.
//
// `dispatchNdjson` is the state machine shared by the desktop and mobile
// bridges: it turns parsed frames into pending-request completions, bridge
// events, or fatal signals.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ncm_api_enhanced/src/bridge.dart';
import 'package:ncm_api_enhanced/src/ndjson.dart';

void main() {
  late PendingTable pending;
  late StreamController<Map<String, dynamic>> events;
  late List<Map<String, dynamic>> collected;
  late List<({String message, Object? cause})> fatals;

  setUp(() {
    pending = PendingTable();
    // A synchronous controller makes the assertions deterministic: every
    // `add` is delivered before the call returns.
    events = StreamController<Map<String, dynamic>>(sync: true);
    collected = <Map<String, dynamic>>[];
    fatals = <({String message, Object? cause})>[];
    events.stream.listen(collected.add);
  });

  tearDown(() => events.close());

  void dispatch(Map<String, dynamic> frame) {
    dispatchNdjson(
      events: <NdjsonEvent>[NdjsonEvent.ok(frame)],
      pending: pending,
      eventsCtl: events,
      onFatal: (String message, Object? cause) {
        fatals.add((message: message, cause: cause));
      },
    );
  }

  group('successful responses', () {
    test('completes the pending request with the result', () async {
      final entry = pending.create('album');

      dispatch(<String, dynamic>{
        'id': entry.id,
        'ok': true,
        'result': <String, dynamic>{
          'body': <String, dynamic>{'code': 200},
        },
      });

      await expectLater(
        entry.completer.future,
        completion(
          isA<Map<String, dynamic>>().having(
            (r) => r['body'],
            'body',
            <String, dynamic>{'code': 200},
          ),
        ),
      );
      expect(pending.size(), 0);
    });

    test('does not emit a bridge event', () {
      final entry = pending.create('album');

      dispatch(<String, dynamic>{
        'id': entry.id,
        'ok': true,
        'result': <String, dynamic>{},
      });

      expect(collected, isEmpty);
      expect(fatals, isEmpty);
    });
  });

  group('failed responses', () {
    test('completes the pending request with a BridgeError', () async {
      final entry = pending.create('album');

      final check = expectLater(
        entry.completer.future,
        throwsA(isA<BridgeError>().having((e) => e.message, 'message', 'boom')),
      );

      dispatch(<String, dynamic>{
        'id': entry.id,
        'ok': false,
        'error': <String, dynamic>{'message': 'boom', 'stack': 'stack-trace'},
      });

      await check;
    });

    test('carries the remote stack trace', () async {
      final entry = pending.create('album');

      final check = expectLater(
        entry.completer.future,
        throwsA(
          isA<BridgeError>()
              .having((e) => e.message, 'message', 'boom')
              .having(
                (e) => e.stackTrace.toString(),
                'stackTrace',
                contains('stack-trace'),
              ),
        ),
      );

      dispatch(<String, dynamic>{
        'id': entry.id,
        'ok': false,
        'error': <String, dynamic>{'message': 'boom', 'stack': 'stack-trace'},
      });

      await check;
    });

    test('falls back to "unknown" when the message is missing', () async {
      final entry = pending.create('album');

      final check = expectLater(
        entry.completer.future,
        throwsA(
          isA<BridgeError>().having((e) => e.message, 'message', 'unknown'),
        ),
      );

      dispatch(<String, dynamic>{
        'id': entry.id,
        'ok': false,
        'error': <String, dynamic>{'stack': 'stack-trace'},
      });

      await check;
    });

    test('falls back to "unknown" when the error is not a map', () async {
      final entry = pending.create('album');

      final check = expectLater(
        entry.completer.future,
        throwsA(
          isA<BridgeError>().having((e) => e.message, 'message', 'unknown'),
        ),
      );

      dispatch(<String, dynamic>{'id': entry.id, 'ok': false, 'error': 'oops'});

      await check;
    });
  });

  group('orphan responses', () {
    test('logs an orphan_response and keeps the bridge alive', () {
      dispatch(<String, dynamic>{
        'id': 987654,
        'ok': true,
        'result': <String, dynamic>{},
      });

      expect(collected, hasLength(1));
      expect(collected.single['event'], 'log');
      final data = collected.single['data']! as Map<String, dynamic>;
      expect(data['level'], 'orphan_response');
      expect(data['id'], 987654);
      expect(fatals, isEmpty);
    });

    test('does not consume an unrelated pending request', () {
      final entry = pending.create('album');

      dispatch(<String, dynamic>{
        'id': entry.id + 1000,
        'ok': true,
        'result': <String, dynamic>{},
      });

      expect(pending.size(), 1);
      expect(entry.completer.isCompleted, isFalse);
    });
  });

  group('malformed frames', () {
    test('a non-int id is fatal', () {
      dispatch(<String, dynamic>{
        'id': 'not-an-int',
        'ok': true,
        'result': <String, dynamic>{},
      });

      expect(fatals, hasLength(1));
      expect(fatals.single.message, 'response with non-int id');
      expect(fatals.single.cause, 'not-an-int');
    });

    test('a parse error is logged but not fatal', () {
      dispatchNdjson(
        events: <NdjsonEvent>[
          NdjsonEvent.err(FormatException('invalid JSON: boom')),
        ],
        pending: pending,
        eventsCtl: events,
        onFatal: (String message, Object? cause) {
          fatals.add((message: message, cause: cause));
        },
      );

      expect(fatals, isEmpty);
      expect(collected, hasLength(1));
      expect(collected.single['event'], 'log');
      final data = collected.single['data']! as Map<String, dynamic>;
      expect(data['level'], 'parse_error');
      expect(data['error'], contains('invalid JSON'));
    });

    test('a frame without id and without event is logged', () {
      dispatch(<String, dynamic>{'unexpected': true});

      expect(collected, hasLength(1));
      expect(collected.single['event'], 'log');
      final data = collected.single['data']! as Map<String, dynamic>;
      expect(data['level'], 'unknown_frame');
      expect(data['payload'], <String, dynamic>{'unexpected': true});
    });
  });

  group('server-pushed events', () {
    test('forwards the frame verbatim', () {
      dispatch(<String, dynamic>{
        'event': 'log',
        'data': <String, dynamic>{'level': 'stderr', 'line': 'hello'},
      });

      expect(collected, hasLength(1));
      expect(collected.single['event'], 'log');
      expect(collected.single['data'], <String, dynamic>{
        'level': 'stderr',
        'line': 'hello',
      });
      expect(fatals, isEmpty);
    });

    test('a fatal frame is forwarded and reported as fatal', () {
      dispatch(<String, dynamic>{
        'event': 'fatal',
        'data': <String, dynamic>{'message': 'node crashed'},
      });

      expect(collected, hasLength(1));
      expect(collected.single['event'], 'fatal');
      expect(fatals, hasLength(1));
      expect(fatals.single.message, 'node fatal');
      expect(fatals.single.cause, <String, dynamic>{'message': 'node crashed'});
    });

    test('the ready frame is forwarded without being fatal', () {
      dispatch(<String, dynamic>{
        'event': 'ready',
        'data': <String, dynamic>{'pid': 42},
      });

      expect(collected, hasLength(1));
      expect(collected.single['event'], 'ready');
      expect(fatals, isEmpty);
    });
  });

  group('batches', () {
    test('processes every frame of a batch in order', () async {
      final first = pending.create('album');
      final second = pending.create('search');

      final checks = <Future<void>>[
        expectLater(
          first.completer.future,
          completion(<String, dynamic>{'n': 1}),
        ),
        expectLater(
          second.completer.future,
          completion(<String, dynamic>{'n': 2}),
        ),
      ];

      dispatchNdjson(
        events: <NdjsonEvent>[
          NdjsonEvent.ok(<String, dynamic>{
            'id': first.id,
            'ok': true,
            'result': <String, dynamic>{'n': 1},
          }),
          NdjsonEvent.ok(<String, dynamic>{
            'event': 'ready',
            'data': <String, dynamic>{'pid': 1},
          }),
          NdjsonEvent.ok(<String, dynamic>{
            'id': second.id,
            'ok': true,
            'result': <String, dynamic>{'n': 2},
          }),
        ],
        pending: pending,
        eventsCtl: events,
        onFatal: (String message, Object? cause) {
          fatals.add((message: message, cause: cause));
        },
      );

      await Future.wait(checks);

      expect(collected, hasLength(1));
      expect(collected.single['event'], 'ready');
      expect(pending.size(), 0);
    });
  });
}
