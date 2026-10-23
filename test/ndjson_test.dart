// SPDX-License-Identifier: MIT
//
// Unit tests for the NDJSON line splitter.

import 'package:flutter_test/flutter_test.dart';
import 'package:ncm_api_enhanced/src/ndjson.dart';

void main() {
  group('NdjsonLineSplitter.feed', () {
    test('parses a single complete line', () {
      final splitter = NdjsonLineSplitter();

      final events = splitter.feed('{"id":1,"ok":true}\n');

      expect(events, hasLength(1));
      expect(events.single.value, <String, dynamic>{'id': 1, 'ok': true});
      expect(events.single.error, isNull);
    });

    test('parses several lines delivered in one chunk', () {
      final splitter = NdjsonLineSplitter();

      final events = splitter.feed('{"id":1}\n{"id":2}\n{"id":3}\n');

      expect(events, hasLength(3));
      expect(events.map((e) => e.value!['id']).toList(), <int>[1, 2, 3]);
    });

    test('reassembles a line split across two chunks', () {
      final splitter = NdjsonLineSplitter();

      expect(splitter.feed('{"id":'), isEmpty);
      expect(splitter.feed('42}\n'), hasLength(1));
      expect(splitter.feed('{"id":42}\n'), hasLength(1));
    });

    test('reassembles a line split at the newline itself', () {
      final splitter = NdjsonLineSplitter();

      expect(splitter.feed('{"id":42}'), isEmpty);
      expect(splitter.feed('\n'), hasLength(1));
      expect(splitter.feed('{"id":42}\n'), hasLength(1));
    });

    test('skips blank lines', () {
      final splitter = NdjsonLineSplitter();

      final events = splitter.feed('\n\n{"id":1}\n\n');

      expect(events, hasLength(1));
      expect(events.single.value!['id'], 1);
    });

    test('reports invalid JSON as a FormatException', () {
      final splitter = NdjsonLineSplitter();

      final events = splitter.feed('{not json}\n');

      expect(events, hasLength(1));
      expect(events.single.value, isNull);
      expect(events.single.error, isA<FormatException>());
      expect(events.single.error.toString(), contains('invalid JSON'));
    });

    test('reports valid JSON that is not an object', () {
      final splitter = NdjsonLineSplitter();

      final events = splitter.feed('123\n');

      expect(events, hasLength(1));
      expect(events.single.value, isNull);
      expect(
        events.single.error.toString(),
        contains('expected JSON object, got int'),
      );
    });

    test('reports a JSON array as a non-object', () {
      final splitter = NdjsonLineSplitter();

      final events = splitter.feed('[1,2,3]\n');

      expect(events, hasLength(1));
      expect(events.single.value, isNull);
      expect(events.single.error.toString(), contains('expected JSON object'));
    });

    test('keeps parsing after a bad line', () {
      final splitter = NdjsonLineSplitter();

      final events = splitter.feed('{bad}\n{"id":9}\n');

      expect(events, hasLength(2));
      expect(events.first.error, isNotNull);
      expect(events.last.value!['id'], 9);
    });
  });

  group('NdjsonLineSplitter.flush', () {
    test('returns nothing when the buffer is empty', () {
      final splitter = NdjsonLineSplitter();

      expect(splitter.flush(), isEmpty);
    });

    test('returns nothing when the last line was already terminated', () {
      final splitter = NdjsonLineSplitter();

      splitter.feed('{"id":1}\n');

      expect(splitter.flush(), isEmpty);
    });

    test('surfaces a trailing line without a newline', () {
      final splitter = NdjsonLineSplitter();

      splitter.feed('{"id":1}');

      final events = splitter.flush();

      expect(events, hasLength(1));
      expect(events.single.value!['id'], 1);
    });

    test('surfaces a trailing invalid line as an error', () {
      final splitter = NdjsonLineSplitter();

      splitter.feed('{bad');

      final events = splitter.flush();

      expect(events, hasLength(1));
      expect(events.single.value, isNull);
      expect(events.single.error, isA<FormatException>());
    });

    test('surfaces a trailing non-object JSON as an error', () {
      final splitter = NdjsonLineSplitter();

      splitter.feed('123');

      final events = splitter.flush();

      expect(events, hasLength(1));
      expect(events.single.value, isNull);
      expect(events.single.error, isA<FormatException>());
    });

    test('empties the buffer so a second flush yields nothing', () {
      final splitter = NdjsonLineSplitter();

      splitter.feed('{"id":1}');

      expect(splitter.flush(), hasLength(1));
      expect(splitter.flush(), isEmpty);
    });
  });
}
