// lib/src/mobile_bridge.dart
//
// Mobile (Android / iOS) bridge — drives a Bare Kit worklet through
// the `bare_flutter` plugin.
//
// Responsibilities
// ----------------
//   1. Load the pre-packed Bare bundle from Flutter assets.
//   2. Start a BareWorklet.
//   3. Read/write raw Bare IPC bytes.
//   4. Frame/de-frame NDJSON.
//   5. Resolve the bridge start Future when the JS bridge emits
//      { "event": "ready", ... }.
//   6. Match RPC responses to PendingTable entries.
//   7. Forward asynchronous bridge events to `events`.
//
// The native Bare Kit runtime itself is provided by bare_flutter.
// This package does NOT own libbare-kit.so or Bare Kit prebuilds.
//
// Protocol
// --------
// Request:
//
//   {"id":1,"method":"foo","params":{...}}\n
//
// Response:
//
//   {"id":1,"ok":true,"result":{...}}\n
//
// Error:
//
//   {"id":1,"ok":false,"error":{"message":"..."}}\n
//
// Event:
//
//   {"event":"ready","data":{...}}\n
//
// Lifecycle
// ---------
//
//   start()
//       -> load ncm.bundle
//       -> BareWorklet.start()
//       -> subscribe to IPC
//       -> wait for {event:"ready"}
//       -> complete start()
//
//   call()
//       -> require ready
//       -> write one NDJSON request
//       -> wait for matching response
//
//   shutdown()
//       -> terminate worklet
//       -> reject pending calls
//       -> close streams

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bare_flutter/bare_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'bridge.dart';
import 'ndjson.dart';

// ============================================================================
// Mobile bridge
// ============================================================================

class MobileNcmBridge implements NcmBridge {
  MobileNcmBridge({Duration callTimeout = kDefaultCallTimeout})
    : _callTimeout = callTimeout;

  final Duration _callTimeout;

  // --------------------------------------------------------------------------
  // RPC state
  // --------------------------------------------------------------------------

  final PendingTable _pending = PendingTable();

  // --------------------------------------------------------------------------
  // Event stream
  // --------------------------------------------------------------------------

  final StreamController<Map<String, dynamic>> _stream =
      StreamController<Map<String, dynamic>>.broadcast();

  // --------------------------------------------------------------------------
  // NDJSON framing
  // --------------------------------------------------------------------------

  final NdjsonLineSplitter _splitter = NdjsonLineSplitter();

  // --------------------------------------------------------------------------
  // Lifecycle state
  // --------------------------------------------------------------------------

  Completer<void>? _readyCompleter;

  bool _started = false;
  bool _shutdown = false;

  // --------------------------------------------------------------------------
  // Bare state
  // --------------------------------------------------------------------------

  BareWorklet? _worklet;

  StreamSubscription<Uint8List>? _incoming;
  StreamSubscription<BareWorkletExit>? _exitSubscription;

  // ==========================================================================
  // Public API
  // ==========================================================================

  @override
  Stream<Map<String, dynamic>> get events => _stream.stream;

  // ==========================================================================
  // Logging
  // ==========================================================================

  void _log(String message) {
    debugPrint('[NcmBridge] $message');
  }

  String _shorten(Object? value, [int maxLength = 1000]) {
    final text = value.toString();

    if (text.length <= maxLength) {
      return text;
    }

    return '${text.substring(0, maxLength)}…';
  }

  // ==========================================================================
  // start
  // ==========================================================================

  @override
  Future<void> start() async {
    _log(
      'START ENTER '
      'started=$_started '
      'shutdown=$_shutdown',
    );

    // ------------------------------------------------------------------------
    // Cannot restart after shutdown.
    // ------------------------------------------------------------------------

    if (_shutdown) {
      _log('START REJECTED: already shutdown');

      throw StateError('MobileNcmBridge: bridge has already been shut down');
    }

    // ------------------------------------------------------------------------
    // Already starting / already started.
    //
    // Multiple callers may call start() concurrently. They should all wait
    // for the same ready Future instead of creating multiple BareWorklets.
    // ------------------------------------------------------------------------

    if (_started) {
      _log(
        'START: already started, '
        'waiting for existing ready',
      );

      final ready = _readyCompleter;

      if (ready == null) {
        throw StateError('MobileNcmBridge: invalid start state');
      }

      try {
        await ready.future.timeout(
          const Duration(seconds: 30),
          onTimeout: () {
            _log('START: existing ready TIMEOUT');

            throw BridgeError('native bridge did not become ready within 30s');
          },
        );

        _log('START: existing ready COMPLETE');

        return;
      } catch (e) {
        _log(
          'START: existing ready ERROR '
          'error=$e',
        );

        rethrow;
      }
    }

    // ------------------------------------------------------------------------
    // Initialize startup state.
    // ------------------------------------------------------------------------

    _started = true;
    _readyCompleter = Completer<void>();

    _log('START: state initialized');

    try {
      // ======================================================================
      // Load bundle
      // ======================================================================

      _log('START: loading ncm.bundle from assets');

      final data = await rootBundle.load(
        'packages/ncm_api_enhanced/assets/bridge/dist/ncm.bundle',
      );

      _log('START: bundle bytes=${data.lengthInBytes}');

      final source = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );

      // ======================================================================
      // Start BareWorklet
      // ======================================================================

      _log('START: starting BareWorklet');

      final worklet = await BareWorklet.start(
        filename: '/ncm.bundle',
        source: source,
        options: BareWorkletOptions(memoryLimitBytes: 24 * 1024 * 1024),
      );

      _worklet = worklet;

      _log(
        'START: BareWorklet.start() COMPLETE '
        'state=${worklet.state}',
      );

      // ======================================================================
      // Subscribe to IPC BEFORE waiting for ready.
      // ======================================================================

      _incoming = worklet.ipc.incoming.listen(
        _handleIncoming,
        onError: (Object error, StackTrace stack) {
          _log(
            'IPC INCOMING ERROR '
            'error=$error',
          );

          _handleFatal(
            BridgeError('native IPC incoming stream failed', error, stack),
          );
        },
        cancelOnError: false,
      );

      _exitSubscription = worklet.onExit.listen(_handleExit);

      _log('START: IPC listeners attached');

      _log(
        'START: BareWorklet running, '
        'waiting for ready event',
      );

      // ======================================================================
      // Wait for JS-side ready event.
      // ======================================================================

      final ready = _readyCompleter!;

      try {
        await ready.future.timeout(
          const Duration(seconds: 30),
          onTimeout: () {
            _log('START: READY TIMEOUT');

            throw BridgeError('native bridge did not become ready within 30s');
          },
        );
      } catch (e) {
        _log(
          'START: READY ERROR '
          'error=$e',
        );

        // If ready failed because the worklet died or another fatal error
        // occurred, clean up the partially initialized bridge.
        if (!_shutdown) {
          await _cleanupAfterStartFailure();
        }

        rethrow;
      }

      _log('START: READY COMPLETE');
    } catch (e, st) {
      _log(
        'START ERROR '
        'error=$e',
      );

      // ----------------------------------------------------------------------
      // If this wasn't already handled by _handleFatal(), complete the
      // startup Future with the error.
      // ----------------------------------------------------------------------

      final ready = _readyCompleter;

      if (ready != null && !ready.isCompleted) {
        ready.completeError(
          e is BridgeError ? e : BridgeError('start() failed', e, st),
        );
      }

      // ----------------------------------------------------------------------
      // Reset startup state so a caller can potentially retry, unless the
      // bridge was explicitly shut down.
      // ----------------------------------------------------------------------

      if (!_shutdown) {
        await _cleanupAfterStartFailure();
      }

      rethrow;
    }
  }

  // ==========================================================================
  // IPC incoming
  // ==========================================================================
  //
  // Bare IPC gives us raw Uint8List chunks.
  //
  // NdjsonLineSplitter handles:
  //
  //   chunk A = '{"id":1,"ok":'
  //   chunk B = 'true}\n'
  //
  // as one logical JSON line.
  // ==========================================================================

  void _handleIncoming(Uint8List chunk) {
    _log(
      'INCOMING '
      'length=${chunk.length}',
    );

    if (chunk.isEmpty) {
      _log('INCOMING ignored: empty chunk');

      return;
    }

    try {
      final text = utf8.decode(chunk, allowMalformed: true);

      final events = _splitter.feed(text);

      _log('INCOMING parsed events=${events.length}');

      for (final event in events) {
        _log(
          'INCOMING NDJSON '
          'value=${_shorten(event.value)} '
          'error=${event.error}',
        );

        _dispatch(event);
      }
    } catch (e, st) {
      _log(
        'INCOMING PROCESS ERROR '
        'error=$e',
      );

      _handleFatal(BridgeError('failed to process native IPC data', e, st));
    }
  }

  // ==========================================================================
  // Worklet exit
  // ==========================================================================

  void _handleExit(BareWorkletExit exit) {
    _log(
      'WORKLET EXIT '
      'reason=${exit.reason}',
    );

    if (_shutdown) {
      _log('WORKLET EXIT ignored: shutdown in progress');

      return;
    }

    if (!_started) {
      _log('WORKLET EXIT ignored: bridge not started');

      return;
    }

    _handleFatal(BridgeError('worklet exited unexpectedly: ${exit.reason}'));
  }

  // ==========================================================================
  // NDJSON dispatch
  // ==========================================================================

  void _dispatch(NdjsonEvent event) {
    _log(
      'DISPATCH '
      'value=${_shorten(event.value)} '
      'error=${event.error}',
    );

    // ------------------------------------------------------------------------
    // Parser error
    // ------------------------------------------------------------------------

    if (event.error != null) {
      _handleFatal(BridgeError('NDJSON parse error: ${event.error}'));

      return;
    }

    // ------------------------------------------------------------------------
    // Null event
    // ------------------------------------------------------------------------

    final value = event.value;

    if (value == null) {
      _log('DISPATCH ignored: null event');

      return;
    }

    // =========================================================================
    // RPC response
    // =========================================================================

    final id = value['id'];

    if (id is int) {
      final completer = _pending.take(id);

      if (completer == null) {
        _log('DISPATCH: no pending request for id=$id');

        return;
      }

      final ok = value['ok'];

      if (ok == true) {
        final result = value['result'];

        final normalizedResult = result is Map<String, dynamic>
            ? result
            : <String, dynamic>{'value': result};

        _log(
          'DISPATCH RPC SUCCESS '
          'id=$id '
          'result=${_shorten(normalizedResult)}',
        );

        if (!completer.isCompleted) {
          completer.complete(normalizedResult);
        }
      } else {
        final error = value['error'];

        final message = error is Map
            ? error['message']?.toString() ?? error.toString()
            : error?.toString() ?? 'unknown NCM error';

        final bridgeError = BridgeError('NCM call failed: $message');

        _log(
          'DISPATCH RPC ERROR '
          'id=$id '
          'error=$bridgeError',
        );

        if (!completer.isCompleted) {
          completer.completeError(bridgeError);
        }
      }

      return;
    }

    // =========================================================================
    // Asynchronous event
    // =========================================================================

    final eventName = value['event'];

    // -------------------------------------------------------------------------
    // IMPORTANT:
    //
    // `BareWorklet.start()` only starts the native Bare runtime.
    //
    // Our MobileNcmBridge.start() additionally waits for the JS bridge's
    // explicit `{event:"ready"}` message.
    //
    // Therefore this event MUST complete `_readyCompleter`.
    // -------------------------------------------------------------------------

    if (eventName == 'ready') {
      _log('DISPATCH: READY event received');

      final ready = _readyCompleter;

      if (ready == null) {
        _log(
          'DISPATCH: READY ignored '
          '(no ready completer)',
        );
      } else if (ready.isCompleted) {
        _log(
          'DISPATCH: READY ignored '
          '(already completed)',
        );
      } else {
        ready.complete();

        _log('DISPATCH: READY COMPLETED');
      }
    }

    // -------------------------------------------------------------------------
    // Fatal event emitted by bridge.js itself.
    //
    // We still forward it through events, but also reject the startup / RPC
    // state because a JS-side fatal event means the bridge cannot be trusted.
    // -------------------------------------------------------------------------

    if (eventName == 'fatal') {
      _log('DISPATCH: FATAL event received');

      final data = value['data'];

      final message = data is Map
          ? data['message']?.toString() ?? data.toString()
          : data?.toString() ?? 'unknown bridge fatal error';

      _handleFatal(BridgeError('bridge reported fatal error: $message'));

      return;
    }

    // -------------------------------------------------------------------------
    // Normal asynchronous event.
    // -------------------------------------------------------------------------

    if (!_stream.isClosed) {
      _stream.add(value);
    }
  }

  // ==========================================================================
  // Fatal
  // ==========================================================================

  void _handleFatal(Object error) {
    _log(
      'FATAL '
      'error=$error',
    );

    final bridgeError = error is BridgeError
        ? error
        : BridgeError('bridge fatal', error);

    // ------------------------------------------------------------------------
    // Release start().
    // ------------------------------------------------------------------------

    final ready = _readyCompleter;

    if (ready != null && !ready.isCompleted) {
      ready.completeError(bridgeError);

      _log('FATAL: ready completer rejected');
    }

    // ------------------------------------------------------------------------
    // Reject every pending RPC.
    // ------------------------------------------------------------------------

    final pendingCount = _pending.size();

    if (pendingCount > 0) {
      _log(
        'FATAL: rejecting pending '
        'count=$pendingCount',
      );

      _pending.rejectAll(bridgeError);
    }

    // ------------------------------------------------------------------------
    // Forward fatal event to existing consumers.
    // ------------------------------------------------------------------------

    if (!_stream.isClosed) {
      _stream.add({
        'event': 'fatal',
        'data': {'message': bridgeError.toString()},
      });
    }
  }

  // ==========================================================================
  // call
  // ==========================================================================

  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic>? params,
  ]) async {
    _log(
      'CALL ENTER '
      'method=$method '
      'params=${_shorten(params)}',
    );

    // ------------------------------------------------------------------------
    // Bridge must have been started.
    // ------------------------------------------------------------------------

    final ready = _readyCompleter;

    if (!_started || ready == null || !ready.isCompleted) {
      _log(
        'CALL REJECTED: bridge not ready '
        'method=$method',
      );

      throw StateError('MobileNcmBridge: call() before ready');
    }

    // ------------------------------------------------------------------------
    // Bridge must not be shut down.
    // ------------------------------------------------------------------------

    if (_shutdown) {
      _log(
        'CALL REJECTED: bridge shutdown '
        'method=$method',
      );

      throw StateError('MobileNcmBridge: call() after shutdown');
    }

    // ------------------------------------------------------------------------
    // Worklet must exist and still be running.
    // ------------------------------------------------------------------------

    final worklet = _worklet;

    if (worklet == null) {
      _log(
        'CALL REJECTED: worklet null '
        'method=$method',
      );

      throw BridgeError('native Bare worklet is not running');
    }

    if (worklet.state == BareWorkletState.terminated) {
      _log(
        'CALL REJECTED: worklet terminated '
        'method=$method',
      );

      throw BridgeError('native Bare worklet is not running');
    }

    // =========================================================================
    // Create pending RPC
    // =========================================================================

    final entry = _pending.create(method);

    final id = entry.id;
    final completer = entry.completer;

    _log(
      'CALL CREATED '
      'id=$id '
      'method=$method '
      'pending=${_pending.size()}',
    );

    // =========================================================================
    // Encode request
    // =========================================================================

    final payload = jsonEncode({
      'id': id,
      'method': method,
      'params': params ?? <String, dynamic>{},
    });

    final bytes = utf8.encode('$payload\n');

    _log(
      'CALL REQUEST '
      'id=$id '
      'method=$method '
      'bytes=${bytes.length} '
      'payload=${_shorten(payload)}',
    );

    // =========================================================================
    // Write request
    // =========================================================================

    try {
      await worklet.ipc.write(Uint8List.fromList(bytes));
    } catch (e, st) {
      _pending.take(id);

      final error = BridgeError(
        'native IPC write failed for "$method" '
        '(id=$id)',
        e,
        st,
      );

      _log(
        'CALL WRITE ERROR '
        'id=$id '
        'method=$method '
        'error=$error',
      );

      if (!completer.isCompleted) {
        completer.completeError(error);
      }

      return completer.future;
    }

    // =========================================================================
    // Wait for response
    // =========================================================================

    try {
      final result = await completer.future.timeout(
        _callTimeout,
        onTimeout: () {
          _log(
            'CALL TIMEOUT '
            'id=$id '
            'method=$method '
            'pending=${_pending.size()}',
          );

          _pending.take(id);

          throw TimeoutException(
            'NCM call "$method" (id=$id) exceeded '
            '${_callTimeout.inSeconds}s',
            _callTimeout,
          );
        },
      );

      _log(
        'CALL COMPLETE '
        'id=$id '
        'method=$method '
        'result=${_shorten(result)} '
        'pending=${_pending.size()}',
      );

      return result;
    } catch (e) {
      _log(
        'CALL ERROR '
        'id=$id '
        'method=$method '
        'error=$e '
        'pending=${_pending.size()}',
      );

      rethrow;
    }
  }

  // ==========================================================================
  // Shutdown
  // ==========================================================================

  @override
  Future<void> shutdown() async {
    _log(
      'SHUTDOWN ENTER '
      'started=$_started '
      'shutdown=$_shutdown '
      'pending=${_pending.size()}',
    );

    if (_shutdown) {
      _log('SHUTDOWN: already shutdown');

      return;
    }

    _shutdown = true;

    // =========================================================================
    // Reject startup waiter first.
    // =========================================================================

    final ready = _readyCompleter;

    if (ready != null && !ready.isCompleted) {
      ready.completeError(
        BridgeError('bridge shut down before becoming ready'),
      );
    }

    // =========================================================================
    // Terminate worklet.
    // =========================================================================

    try {
      _log('SHUTDOWN: terminating worklet');

      await _worklet?.terminate();

      _log('SHUTDOWN: worklet terminated');
    } catch (e) {
      _log(
        'SHUTDOWN: terminate failed '
        'error=$e',
      );
    }

    _worklet = null;

    // =========================================================================
    // Cancel subscriptions.
    // =========================================================================

    try {
      await _incoming?.cancel();
    } catch (e) {
      _log(
        'SHUTDOWN: incoming cancel failed '
        'error=$e',
      );
    }

    _incoming = null;

    try {
      await _exitSubscription?.cancel();
    } catch (e) {
      _log(
        'SHUTDOWN: exit subscription cancel failed '
        'error=$e',
      );
    }

    _exitSubscription = null;

    // =========================================================================
    // Flush NDJSON splitter.
    //
    // Do this before closing the event stream. Normally there should be
    // nothing left, but keeping this preserves the original bridge behavior.
    // =========================================================================

    try {
      final events = _splitter.flush();

      _log(
        'SHUTDOWN: splitter.flush '
        'events=${events.length}',
      );

      for (final event in events) {
        _dispatch(event);
      }
    } catch (e) {
      _log(
        'SHUTDOWN: splitter flush failed '
        'error=$e',
      );
    }

    // =========================================================================
    // Reject pending calls.
    // =========================================================================

    final pendingCount = _pending.size();

    _log(
      'SHUTDOWN: rejecting pending '
      'count=$pendingCount',
    );

    _pending.rejectAll(BridgeError('bridge shut down'));

    // =========================================================================
    // Close event stream.
    // =========================================================================

    if (!_stream.isClosed) {
      await _stream.close();
    }

    _started = false;

    _log('SHUTDOWN EXIT');
  }

  // ==========================================================================
  // Cleanup after start failure
  // ==========================================================================

  Future<void> _cleanupAfterStartFailure() async {
    _log('START FAILURE CLEANUP ENTER');

    // ------------------------------------------------------------------------
    // Terminate worklet.
    // ------------------------------------------------------------------------

    try {
      await _worklet?.terminate();
    } catch (e) {
      _log(
        'START FAILURE CLEANUP: terminate failed '
        'error=$e',
      );
    }

    _worklet = null;

    // ------------------------------------------------------------------------
    // Cancel incoming subscription.
    // ------------------------------------------------------------------------

    try {
      await _incoming?.cancel();
    } catch (e) {
      _log(
        'START FAILURE CLEANUP: incoming cancel failed '
        'error=$e',
      );
    }

    _incoming = null;

    // ------------------------------------------------------------------------
    // Cancel exit subscription.
    // ------------------------------------------------------------------------

    try {
      await _exitSubscription?.cancel();
    } catch (e) {
      _log(
        'START FAILURE CLEANUP: exit cancel failed '
        'error=$e',
      );
    }

    _exitSubscription = null;

    // ------------------------------------------------------------------------
    // Reject pending RPCs.
    // ------------------------------------------------------------------------

    if (_pending.size() > 0) {
      _pending.rejectAll(BridgeError('bridge start failed'));
    }

    // ------------------------------------------------------------------------
    // Reset state.
    //
    // Do NOT set _shutdown here. A startup failure should not permanently
    // destroy the bridge object.
    // ------------------------------------------------------------------------

    _started = false;

    _log('START FAILURE CLEANUP EXIT');
  }
}
