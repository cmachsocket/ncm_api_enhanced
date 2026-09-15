// lib/src/mobile_bridge.dart
//
// Mobile (Android) bridge — talks to a Kotlin shim over Flutter's
// MethodChannel + EventChannel. The Kotlin shim wraps holepunchto's
// bare-kit (Java API + libbare-kit.so) and exposes:
//
//   MethodChannel("ncm_bridge/methods")
//     "start"      → loads a bare bundle into a Worklet + opens IPC
//     "write"      → forwards a NDJSON line to the Worklet's IPC
//     "shutdown"   → terminates the Worklet
//     "isRunning"  → returns Boolean
//
//   EventChannel("ncm_bridge/events")
//     Emits one event per IPC read. Each event is a Map:
//
//       { "type": "ready" }
//       { "type": "stdout", "data": "<line>" }
//       { "type": "stderr", "data": "<line>" }
//       { "type": "fatal",  "data": "<message>" }
//
// The wire protocol on the worklet side is the same NDJSON over IPC
// that the previous nodejs-mobile design used over stdio. bridge.js
// runs unchanged; it only loses its `readline.createInterface` over
// stdin and gains a `bare.IPC.read()` loop instead. See
// assets/bridge/bridge.js for the consumer.
//
// Previous design (nodejs-mobile v18.20.4) used Dart FFI directly
// against `libnode.so` through a C++ glue library. That path is
// deprecated. See native/android/node_bridge.cpp for the tombstone
// and native/android/NcmBareBridge.kt for the Kotlin shim.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'bridge.dart';
import 'ndjson.dart';


class MobileNcmBridge implements NcmBridge {
  MobileNcmBridge({Duration callTimeout = kDefaultCallTimeout})
    : _callTimeout = callTimeout {
    _bindChannels();
  }

  final Duration _callTimeout;

  final _pending = PendingTable();

  final _stream = StreamController<Map<String, dynamic>>.broadcast();

  final _splitter = NdjsonLineSplitter();

  Completer<void>? _readyCompleter;

  bool _started = false;
  bool _shutdown = false;

  late final MethodChannel _methods;
  late final EventChannel _events;

  StreamSubscription<dynamic>? _eventSubscription;

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
  // Channel binding
  // ==========================================================================

  void _bindChannels() {
    _methods = const MethodChannel('ncm_bridge/methods');
    _events = const EventChannel('ncm_bridge/events');

    _eventSubscription = _events.receiveBroadcastStream().listen(
      _handleNativeEvent,
      onError: (Object error, StackTrace stack) {
        _log(
          'events: stream ERROR error=$error',
        );
        _handleFatal(
          BridgeError('native event stream error', error, stack),
        );
      },
      onDone: () {
        _log('events: stream DONE');
      },
      cancelOnError: false,
    );
  }

  // ==========================================================================
  // Native event handling
  // ==========================================================================

  void _handleNativeEvent(dynamic raw) {
    _log(
      'events: RECEIVE type=${raw.runtimeType} '
      'value=${_shorten(raw)}',
    );

    if (raw is! Map) {
      _log('events: INVALID message (not a Map)');
      _handleFatal(
        BridgeError('invalid native event: $raw'),
      );
      return;
    }

    final type = raw['type'];
    final data = raw['data'];

    if (type is! String) {
      _log('events: INVALID payload (type not a string)');
      _handleFatal(
        BridgeError('invalid native event payload: $raw'),
      );
      return;
    }

    switch (type) {
      case 'ready':
        _handleReady();
      case 'stdout':
        _handleStdout(data is String ? data : data?.toString() ?? '');
      case 'stderr':
        _handleStderr(data is String ? data : data?.toString() ?? '');
      case 'fatal':
        _handleFatal(
          BridgeError(
            data is String ? data : data?.toString() ?? 'native fatal',
          ),
        );
      default:
        _log('events: unknown type=$type — ignoring');
    }
  }

  void _handleReady() {
    _log('READY event received');

    if (_readyCompleter == null || _readyCompleter!.isCompleted) {
      _log('READY ignored: no pending completer');
      return;
    }

    _readyCompleter!.complete();
  }

  // ==========================================================================
  // Native stdout
  // ==========================================================================

  void _handleStdout(String chunk) {
    _log(
      'STDOUT CHUNK '
      'length=${chunk.length} '
      'data=${_shorten(chunk)}',
    );

    try {
      final events = _splitter.feed(chunk);

      _log(
        'STDOUT splitter produced '
        '${events.length} event(s)',
      );

      for (final event in events) {
        _log(
          'STDOUT NDJSON EVENT '
          'value=${_shorten(event.value)} '
          'error=${event.error}',
        );

        _dispatch(event);
      }
    } catch (e, st) {
      _log(
        'STDOUT PROCESS ERROR '
        'error=$e',
      );

      _handleFatal(BridgeError('failed to process native stdout', e, st));
    }
  }

  // ==========================================================================
  // Native stderr
  // ==========================================================================

  void _handleStderr(String message) {
    _log(
      'STDERR '
      'length=${message.length} '
      'message=${_shorten(message)}',
    );

    if (_stream.isClosed) {
      _log('STDERR ignored: event stream already closed');
      return;
    }

    try {
      _stream.add({
        'event': 'log',
        'data': {'level': 'stderr', 'message': message},
      });
    } catch (e) {
      _log('STDERR add ERROR error=$e');
    }
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
      _log('START: resolving bridge root');
      final bridgeRoot = await _resolveBridgeRoot();

      _log('START: bridgeRoot=$bridgeRoot');

      // bare-kit's Worklet.start takes the bundle as inline bytes,
      // so we hand the Kotlin shim the file path and let it read
      // the .bundle off disk.
      final bundlePath = '$bridgeRoot${Platform.pathSeparator}'
          'dist${Platform.pathSeparator}ncm.bundle';

      _log('START: bundlePath=$bundlePath');

      final bundleFile = File(bundlePath);
      if (!await bundleFile.exists()) {
        throw BridgeError(
          'MobileNcmBridge: ncm.bundle not found at $bundlePath',
        );
      }

      _log('START: invoking methods.start');

      try {
        await _methods.invokeMethod<void>('start', <String, Object?>{
          'bundlePath': bundlePath,
        });
      } on PlatformException catch (e, st) {
        throw BridgeError(
          'native bridge start failed: ${e.code} ${e.message}',
          e,
          st,
        );
      }

      _log('START: methods.start returned');
    } catch (e, st) {
      _log(
        'START ERROR '
        'error=$e',
      );

      _started = false;

      if (_readyCompleter != null && !_readyCompleter!.isCompleted) {
        _readyCompleter!.completeError(
          e is BridgeError ? e : BridgeError('start() failed', e, st),
        );
      }

      rethrow;
    }

    _log('START: waiting for protocol ready event');

    return _readyCompleter!.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _log('START: READY TIMEOUT');
        throw BridgeError('native bridge did not become ready within 30s');
      },
    );
  }

  // ==========================================================================
  // Flutter assets
  // ==========================================================================

  Future<String> _resolveBridgeRoot() async {
    const explicitRoot = String.fromEnvironment('NCM_BRIDGE_ROOT');
    if (explicitRoot.isNotEmpty) {
      return explicitRoot;
    }

    // Try the host app's data dir first (Android usually extracts
    // bundled assets there on first run).
    final candidate = await _tryResolveBridgeRootFromDataDir();
    if (candidate != null) return candidate;

    throw BridgeError(
      'MobileNcmBridge: could not resolve bridge root. '
      'Set NCM_BRIDGE_ROOT or ensure the host app extracted the '
      'assets/bridge/ asset bundle before calling start().',
    );
  }

  Future<String?> _tryResolveBridgeRootFromDataDir() async {
    // The host app is expected to copy the bridge assets to its
    // filesDir at startup. We probe well-known layouts.
    try {
      final dir = await _hostAppDataDir();
      if (dir == null) return null;

      // Mirror the layout under <filesDir> that Kotlin
      // (NcmBareBridge.kt::extractBridgeAssets) writes the bundle to.
      //
      // The APK path is:
      //   assets/flutter_assets/packages/<pkg>/assets/bridge/dist/ncm.bundle
      // (verified with `unzip -l app-arm64-v8a-release.apk | grep ncm.bundle`).
      //
      // Kotlin extracts AssetManager entries (which live under
      // flutter_assets/) to <filesDir>, so the on-disk layout is:
      //   <filesDir>/flutter_assets/packages/<pkg>/assets/bridge/dist/ncm.bundle
      //
      // The bridgeRoot we return here is the directory containing
      // `dist/`, i.e. `<filesDir>/flutter_assets/packages/<pkg>/assets/bridge`.
      // Everything else (bundle.js, xhr-sync-worker.js, data/, …) lives
      // alongside dist/ under that same root.
      //
      // We probe the package-prefixed path first (the one Kotlin
      // actually writes to). The other candidates are kept as a
      // belt-and-braces fallback for old build outputs that did not
      // yet mirror the APK's `packages/<pkg>/` prefix.
      final candidates = <String>[
        '$dir${Platform.pathSeparator}flutter_assets'
            '${Platform.pathSeparator}packages'
            '${Platform.pathSeparator}ncm_api_enhanced'
            '${Platform.pathSeparator}assets${Platform.pathSeparator}bridge',
        '$dir${Platform.pathSeparator}flutter_assets'
            '${Platform.pathSeparator}assets${Platform.pathSeparator}bridge',
        '$dir${Platform.pathSeparator}assets${Platform.pathSeparator}bridge',
        '$dir${Platform.pathSeparator}bridge',
      ];

      for (final path in candidates) {
        final probe = File(
          '$path${Platform.pathSeparator}dist${Platform.pathSeparator}'
          'ncm.bundle',
        );
        if (await probe.exists()) {
          return path;
        }
      }
    } catch (e) {
      _log('resolveBridgeRoot: probe failed error=$e');
    }

    return null;
  }

  Future<Directory?> _hostAppDataDir() async {
    // Try a MethodChannel first so the host app can hand us the
    // exact filesDir without us hard-coding a path.
    try {
      final path = await _methods.invokeMethod<String>('dataDir');
      if (path != null && path.isNotEmpty) {
        return Directory(path);
      }
    } on MissingPluginException {
      // Fall through to the platform path guess.
    } catch (e) {
      _log('dataDir: MethodChannel failed error=$e');
    }

    return null;
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

    // value is Map<String, dynamic> by the NdjsonEvent.value type
    // contract; the runtime guard below is for narrowing.

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

    // Event-style messages (no id) come from bridge.js — pass
    // them through to the consumer's event stream.

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

    final running = await _methods.invokeMethod<bool>('isRunning');
    _log('CALL: native running=$running method=$method');

    if (running != true) {
      _log('CALL REJECTED: Worklet not running method=$method');
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
      await _methods.invokeMethod<void>('write', <String, Object?>{
        'bytes': bytes,
      });
    } on PlatformException catch (e, st) {
      _pending.take(id);
      final error = BridgeError(
        'native IPC write failed for "$method" '
        '(id=$id, code=${e.code}): ${e.message}',
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
    } catch (e, st) {
      _pending.take(id);
      final error = BridgeError('native call failed', e, st);
      _log(
        'CALL EXCEPTION '
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
      _log('SHUTDOWN: invoking methods.shutdown');
      await _methods.invokeMethod<void>('shutdown');
      _log('SHUTDOWN: methods.shutdown returned');
    } catch (e) {
      _log('SHUTDOWN: methods.shutdown failed error=$e');
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

    await _eventSubscription?.cancel();
    _eventSubscription = null;

    if (!_stream.isClosed) {
      await _stream.close();
    }

    _started = false;

    _log('SHUTDOWN EXIT');
  }
}
