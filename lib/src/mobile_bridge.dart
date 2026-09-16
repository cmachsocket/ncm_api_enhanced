// lib/src/mobile_bridge.dart
//
// Mobile (Android / iOS) bridge — drives a Bare Kit worklet through
// the `bare_flutter` plugin (https://pub.dev/packages/bare_flutter).
//
// Why bare_flutter
// ----------------
//
// The previous design hand-rolled a MethodChannel + EventChannel shim
// over Kotlin / Objective-C, plus a Flutter plugin module, a Dart
// build hook, and a pile of Gradle glue to download + verify the
// bare-kit prebuilds.zip. bare_flutter does all of that for us and
// is the upstream-blessed way to embed Bare on Android / iOS.
//
// What this file owns
// -------------------
//
//   1. Read the bare bundle from a Flutter asset (rootBundle).
//   2. Spin up a BareWorklet that hosts the bundle source.
//   3. Speak NDJSON to the worklet over the binary IPC stream that
//      bare_flutter exposes as `BareIpc.incoming` / `BareIpc.write`.
//      The wire format matches the desktop / esbuild path byte for
//      byte so bridge.js can run unchanged on every platform.
//   4. Translate the IPC byte stream into the existing
//      `events` stream + `call()` Future shape that NcmBridge
//      consumers already speak.
//
// Lifecycle:
//
//   start()      — loads ncm.bundle from assets, instantiates the
//                  worklet, waits for the first `{event:"ready"}`
//                  NDJSON line, then resolves.
//   call(name)   — writes one NDJSON request line, awaits the
//                  matching response line.
//   shutdown()   — terminates the worklet.
//   events       — broadcast stream of `{event, data}` messages
//                  from the worklet (ready / log / fatal).
//
// NB: bare_flutter exposes IPC as raw byte streams, not as JSON
// frames. We frame / deframe NDJSON here; bridge.js uses
// `Bare.IPC` end-to-end so it stays unchanged from the desktop
// path.

import 'dart:async';
import 'dart:convert';

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

  final _pending = PendingTable();
  final _stream = StreamController<Map<String, dynamic>>.broadcast();
  final _splitter = NdjsonLineSplitter();

  Completer<void>? _readyCompleter;

  bool _started = false;
  bool _shutdown = false;

  BareWorklet? _worklet;
  StreamSubscription<Uint8List>? _incoming;

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
    if (text.length <= maxLength) return text;
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

    if (_shutdown) {
      _log('START REJECTED: already shutdown');
      throw StateError('MobileNcmBridge: bridge has already been shut down');
    }

    if (_started) {
      _log('START: already started, waiting for existing ready');
      final ready = _readyCompleter;
      if (ready == null) {
        throw StateError('MobileNcmBridge: invalid start state');
      }
      return ready.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          _log('START: existing ready TIMEOUT');
          throw BridgeError('native bridge did not become ready within 30s');
        },
      );
    }

    _started = true;
    _readyCompleter = Completer<void>();
    _log('START: state initialized');

    try {
      _log('START: loading ncm.bundle from assets');
      final data = await rootBundle.load(
        'packages/ncm_api_enhanced/assets/bridge/dist/ncm.bundle',
      );

      _log('START: bundle bytes=${data.lengthInBytes}');

      _log('START: starting BareWorklet');
      final worklet = await BareWorklet.start(
        filename: '/ncm.bundle',
        source: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        options: BareWorkletOptions(memoryLimitBytes: 24 * 1024 * 1024),
      );

      _worklet = worklet;

      _incoming = worklet.ipc.incoming.listen(_handleIncoming);
      worklet.onExit.listen(_handleExit);

      _log('START: BareWorklet running, waiting for ready event');
    } catch (e, st) {
      _log('START ERROR error=$e');

      _started = false;

      if (_readyCompleter != null && !_readyCompleter!.isCompleted) {
        _readyCompleter!.completeError(
          e is BridgeError ? e : BridgeError('start() failed', e, st),
        );
      }

      rethrow;
    }

    return _readyCompleter!.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _log('START: READY TIMEOUT');
        throw BridgeError('native bridge did not become ready within 30s');
      },
    );
  }

  // ==========================================================================
  // IPC incoming — frame NDJSON over the byte stream.
  // ==========================================================================

  void _handleIncoming(Uint8List chunk) {
    _log('INCOMING length=${chunk.length}');

    try {
      final events = _splitter.feed(utf8.decode(chunk, allowMalformed: true));

      for (final event in events) {
        _log(
          'INCOMING NDJSON '
          'value=${_shorten(event.value)} '
          'error=${event.error}',
        );

        _dispatch(event);
      }
    } catch (e, st) {
      _log('INCOMING PROCESS ERROR error=$e');
      _handleFatal(BridgeError('failed to process native stdout', e, st));
    }
  }

  void _handleExit(BareWorkletExit exit) {
    _log('WORKLET EXIT reason=${exit.reason}');

    if (_started && !_shutdown) {
      _handleFatal(BridgeError('worklet exited unexpectedly: ${exit.reason}'));
    }
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

    if (event.error != null) {
      _handleFatal(BridgeError('NDJSON parse error: ${event.error}'));
      return;
    }

    final value = event.value;
    if (value == null) {
      _log('DISPATCH ignored: null event');
      return;
    }

    //
    // value is Map<String, dynamic> by the NdjsonEvent.value type
    // contract; the runtime guard below is for narrowing.
    //

    final id = value['id'];

    if (id is int) {
      final completer = _pending.take(id);
      if (completer == null) return;

      final ok = value['ok'];

      if (ok == true) {
        final result = value['result'];
        completer.complete(
          result is Map<String, dynamic> ? result : {'value': result},
        );
      } else {
        final error = value['error'];
        completer.completeError(
          BridgeError(
            'NCM call failed: ${error is Map ? error['message'] : error}',
          ),
        );
      }
      return;
    }

    _stream.add(value);
  }

  // ==========================================================================
  // Fatal
  // ==========================================================================

  void _handleFatal(Object error) {
    _log('FATAL error=$error');

    if (_readyCompleter != null && !_readyCompleter!.isCompleted) {
      _readyCompleter!.completeError(error);
    }

    _pending.rejectAll(
      error is BridgeError ? error : BridgeError('bridge fatal', error),
    );

    if (!_stream.isClosed) {
      _stream.add({
        'event': 'fatal',
        'data': {'message': error.toString()},
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

    final ready = _readyCompleter;
    if (ready == null || !ready.isCompleted) {
      _log('CALL REJECTED: bridge not ready method=$method');
      throw StateError('MobileNcmBridge: call() before ready');
    }

    if (_shutdown) {
      _log('CALL REJECTED: bridge shutdown method=$method');
      throw StateError('MobileNcmBridge: call() after shutdown');
    }

    final worklet = _worklet;
    if (worklet == null || worklet.state == BareWorkletState.terminated) {
      _log('CALL REJECTED: worklet not running method=$method');
      throw BridgeError('native Bare worklet is not running');
    }

    final entry = _pending.create(method);
    final id = entry.id;
    final completer = entry.completer;

    _log(
      'CALL CREATED '
      'id=$id '
      'method=$method '
      'pending=${_pending.size()}',
    );

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

    try {
      _log('SHUTDOWN: terminating worklet');
      await _worklet?.terminate();
      _log('SHUTDOWN: worklet terminated');
    } catch (e) {
      _log('SHUTDOWN: terminate failed error=$e');
    }

    try {
      final events = _splitter.flush();
      _log('SHUTDOWN: splitter.flush events=${events.length}');
      for (final event in events) {
        _dispatch(event);
      }
    } catch (e) {
      _log('SHUTDOWN: splitter flush failed error=$e');
    }

    _log('SHUTDOWN: rejecting pending count=${_pending.size()}');
    _pending.rejectAll(BridgeError('bridge shut down'));

    await _incoming?.cancel();
    _incoming = null;

    if (!_stream.isClosed) {
      await _stream.close();
    }

    _started = false;

    _log('SHUTDOWN EXIT');
  }
}
