// Bridge contract between Dart and the embedded node process.
//
// The wire format mirrors bridge/bridge.js:
//   Dart -> Node: {"id": <int>, "method": "<moduleFn>", "params": {...}}
//   Node -> Dart: {"id": <int>, "ok": true,  "result": ...}
//                 {"id": <int>, "ok": false, "error":  {"message": ..., "stack": ...}}
//                 {"event": "ready"|"log"|"fatal", "data": ...}
//
// Implementations: [DesktopNcmBridge] (spawn system node on Linux/macOS/Windows)
// and [MobileNcmBridge] (nodejs-mobile channel on Android/iOS).

import 'dart:async';

import 'ndjson.dart';

/// Errors surfaced from the bridge layer itself (IPC, spawn, parse failures).
/// Upstream NCM API errors come through as resolved values whose `body.code`
/// is non-200; that's expected business behavior, not a bridge error.
class BridgeError implements Exception {
  BridgeError(this.message, [this.cause, this.stackTrace]);
  final String message;
  final Object? cause;
  final StackTrace? stackTrace;

  @override
  String toString() => 'BridgeError: $message'
      '${cause == null ? '' : ' ($cause)'}';
}

/// Asynchronous IPC bridge to the embedded node-side NCM module.
///
/// Lifecycle:
///   final bridge = DesktopNcmBridge(...);
///   await bridge.start();          // spawns node, waits for "ready"
///   final r = await bridge.call('album', {'id': 12345});  // Future
///   ...
///   await bridge.shutdown();       // graceful close (or .dispose())
///
/// Concurrency: any number of [call]s may be in-flight at once. Each gets a
/// monotonically-increasing id; responses are matched by id. Node's event
/// loop dispatches upstream module functions (all return `Promise<Response>`),
/// so multiple concurrent calls from Dart run truly in parallel server-side.
abstract class NcmBridge {
  Future<void> start();
  Future<void> shutdown();

  /// Call an upstream NCM module function by its module-filename stem
  /// (e.g. `album`, `login_qr_key`, `user_account`). `params` is the same
  /// object you would pass over HTTP to the equivalent endpoint.
  Future<Map<String, dynamic>> call(String method, [Map<String, dynamic>? params]);

  /// Stream of non-request events: "ready", "log", "fatal". Useful for
  /// surfacing stderr and crash diagnostics to the UI.
  Stream<Map<String, dynamic>> get events;
}

/// Default timeout for [call]. NCM endpoints are usually <2s; 30s leaves
/// headroom for cold-cache crypto / anti-cheat fetches without leaving
/// callers hanging forever if the upstream network is down.
const Duration kDefaultCallTimeout = Duration(seconds: 30);

/// Shared request/response bookkeeping for both bridge implementations.
/// The table holds the [Completer] for the entire life of the request;
/// it is only removed when the matching response arrives or the bridge
/// is shut down.
class PendingTable {
  PendingTable();
  final Map<int, Completer<Map<String, dynamic>>> _table = {};
  final Map<int, String> _methods = {}; // for debugging

  /// Allocate an id and register a pending completer. Returns the id and
  /// the completer that will be completed when the matching response
  /// arrives.
  ({int id, Completer<Map<String, dynamic>> completer}) create(String method) {
    final id = _nextId++;
    final c = Completer<Map<String, dynamic>>();
    _table[id] = c;
    _methods[id] = method;
    return (id: id, completer: c);
  }

  /// Look up (without removing) the pending completer for [id]. Used by the
  /// dispatcher when a response arrives.
  Completer<Map<String, dynamic>>? take(int id) {
    _methods.remove(id);
    return _table.remove(id);
  }

  int size() => _table.length;

  String debugMethods() => _methods.toString();

  /// Fail all pending requests. Used on shutdown / fatal.
  void rejectAll(Object err) {
    for (final c in _table.values) {
      try {
        c.completeError(err);
      } catch (_) {
        // Completer may have been completed already; ignore.
      }
    }
    _table.clear();
    _methods.clear();
  }
}

/// Single-process id counter; the wire protocol is a single shared stream.
int _nextId = 1;

/// Helper: feed NDJSON bytes and dispatch responses/events to the right
/// places. Shared between desktop and mobile bridges.
void dispatchNdjson({
  required List<NdjsonEvent> events,
  required PendingTable pending,
  required StreamController<Map<String, dynamic>> eventsCtl,
  required void Function(String message, Object? cause) onFatal,
}) {
  for (final ev in events) {
    final m = ev.value;
    if (m == null) {
      // Parse error — bubble up as a fatal event but keep the bridge alive
      // (one bad line shouldn't kill the whole process).
      eventsCtl.add({
        'event': 'log',
        'data': {'level': 'parse_error', 'error': ev.error.toString()},
      });
      continue;
    }

    // Response to a pending request.
    if (m.containsKey('id')) {
      final id = m['id'];
      if (id is! int) {
        onFatal('response with non-int id', id);
        continue;
      }
      final completer = pending.take(id);
      if (completer == null) {
        // Either an unsolicited response (protocol bug) or arrived after
        // timeout — log and continue.
        eventsCtl.add({
          'event': 'log',
          'data': {
            'level': 'orphan_response',
            'id': id,
            'payload': m,
          },
        });
        continue;
      }
      if (m['ok'] == true) {
        completer.complete(m['result'] as Map<String, dynamic>);
      } else {
        final err = m['error'];
        final msg = err is Map ? (err['message']?.toString() ?? 'unknown') : 'unknown';
        final stack = err is Map ? err['stack']?.toString() : null;
        final e = BridgeError(msg, null, stack == null ? null : StackTrace.fromString(stack));
        completer.completeError(e);
      }
      continue;
    }

    // Server-pushed event.
    if (m.containsKey('event')) {
      eventsCtl.add(m);
      if (m['event'] == 'fatal') {
        onFatal('node fatal', m['data']);
      }
      continue;
    }

    // Unknown frame shape.
    eventsCtl.add({
      'event': 'log',
      'data': {'level': 'unknown_frame', 'payload': m},
    });
  }
}