// Minimal NDJSON line splitter used by NcmBridge.
//
// Stdout from the node bridge is a stream of `\n`-separated JSON objects. We
// turn it into a Stream<Map> the bridge can `listen` on. Lines that fail to
// parse are forwarded as a `_ParseError` record so the bridge can surface
// them instead of silently dropping data.

import 'dart:convert';

/// Parsed NDJSON object, or an error record when a line failed to decode.
class NdjsonEvent {
  NdjsonEvent.ok(this.value) : error = null;
  NdjsonEvent.err(this.error) : value = null;
  final Map<String, dynamic>? value;
  final Object? error;
}

class NdjsonLineSplitter {
  NdjsonLineSplitter();

  String _buf = '';

  /// Feed arbitrary chunks of bytes. Emits zero or more parsed events.
  /// Handles split chunks where a `\n` lands across two feeds.
  List<NdjsonEvent> feed(String chunk) {
    final out = <NdjsonEvent>[];
    _buf += chunk;
    var idx = _buf.indexOf('\n');
    while (idx >= 0) {
      final line = _buf.substring(0, idx);
      _buf = _buf.substring(idx + 1);
      if (line.isNotEmpty) {
        try {
          final decoded = jsonDecode(line);
          if (decoded is Map<String, dynamic>) {
            out.add(NdjsonEvent.ok(decoded));
          } else {
            out.add(NdjsonEvent.err(FormatException(
              'expected JSON object, got ${decoded.runtimeType}',
            )));
          }
        } catch (e) {
          out.add(NdjsonEvent.err(FormatException('invalid JSON: $e')));
        }
      }
      idx = _buf.indexOf('\n');
    }
    return out;
  }

  /// Discard any pending partial line. Call on stream close to surface a
  /// trailing line without newline (rare; signals premature close).
  List<NdjsonEvent> flush() {
    if (_buf.isEmpty) return const [];
    final line = _buf;
    _buf = '';
    try {
      return [NdjsonEvent.ok(jsonDecode(line) as Map<String, dynamic>)];
    } catch (e) {
      return [NdjsonEvent.err(FormatException('invalid JSON: $e'))];
    }
  }
}