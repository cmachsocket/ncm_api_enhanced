// SPDX-License-Identifier: MIT
//
// Unit tests for the shared request/response bookkeeping.

import 'package:flutter_test/flutter_test.dart';
import 'package:ncm_api_enhanced/src/bridge.dart';

void main() {
  group('PendingTable.create', () {
    test('allocates strictly increasing ids', () {
      final pending = PendingTable();

      final first = pending.create('album');
      final second = pending.create('search');
      final third = pending.create('banner');

      expect(first.id, lessThan(second.id));
      expect(second.id, lessThan(third.id));
    });

    test('registers the completer so size() reflects it', () {
      final pending = PendingTable();

      expect(pending.size(), 0);

      pending.create('album');
      pending.create('search');

      expect(pending.size(), 2);
    });

    test('returns a fresh, incomplete completer', () {
      final pending = PendingTable();

      final entry = pending.create('album');

      expect(entry.completer.isCompleted, isFalse);
      expect(pending.take(entry.id), same(entry.completer));
    });
  });

  group('PendingTable.take', () {
    test('returns the completer and removes the entry', () {
      final pending = PendingTable();
      final entry = pending.create('album');

      final taken = pending.take(entry.id);

      expect(taken, same(entry.completer));
      expect(pending.size(), 0);
    });

    test('returns null for an unknown id', () {
      final pending = PendingTable();

      expect(pending.take(123456), isNull);
    });

    test('returns null the second time the same id is taken', () {
      final pending = PendingTable();
      final entry = pending.create('album');

      expect(pending.take(entry.id), isNotNull);
      expect(pending.take(entry.id), isNull);
    });
  });

  group('PendingTable.rejectAll', () {
    test('fails every pending request and empties the table', () async {
      final pending = PendingTable();
      final a = pending.create('album');
      final b = pending.create('search');

      // Register the error expectations before failing the requests so the
      // rejections are always handled.
      final checks = <Future<void>>[
        expectLater(
          a.completer.future,
          throwsA(
            isA<BridgeError>().having(
              (e) => e.message,
              'message',
              'bridge shut down',
            ),
          ),
        ),
        expectLater(b.completer.future, throwsA(isA<BridgeError>())),
      ];

      pending.rejectAll(BridgeError('bridge shut down'));

      await Future.wait(checks);

      expect(pending.size(), 0);
      expect(a.completer.isCompleted, isTrue);
      expect(b.completer.isCompleted, isTrue);
    });

    test('is a no-op on an empty table', () {
      final pending = PendingTable();

      pending.rejectAll(BridgeError('bridge shut down'));

      expect(pending.size(), 0);
    });

    test('ignores requests that were already completed', () {
      final pending = PendingTable();
      final entry = pending.create('album');

      entry.completer.complete(<String, dynamic>{'ok': true});

      // Must not throw even though the completer is already completed.
      pending.rejectAll(BridgeError('bridge shut down'));

      expect(pending.size(), 0);
      expect(entry.completer.isCompleted, isTrue);
    });
  });

  group('PendingTable.debugMethods', () {
    test('lists the methods of the pending requests', () {
      final pending = PendingTable();

      pending.create('album');
      pending.create('search');

      final debug = pending.debugMethods();

      expect(debug, contains('album'));
      expect(debug, contains('search'));
    });

    test('drops methods once the entry is taken', () {
      final pending = PendingTable();
      final entry = pending.create('album');

      pending.take(entry.id);

      expect(pending.debugMethods(), isNot(contains('album')));
    });
  });
}
