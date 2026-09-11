// Mobile bridge implementation: talks to libnode embedded inside the Flutter
// app on Android/iOS.
//
// Protocol with the native side (the Kotlin/Swift code that links
// nodejs-mobile v18.20.4):
//
//   method channel: "ncm_api_enhanced/bridge"
//   - "start": arguments: { "channel": "ncm" }, returns: { "ready": true }
//   - "call":  arguments: { "id": int, "method": string, "params": map },
//              returns: void (response comes on EventChannel "ncm_api_enhanced/events")
//   - "shutdown": arguments: {}, returns: void
//
//   event channel: "ncm_api_enhanced/events"
//     emits one event per NDJSON object emitted by the node-side bridge.js,
//     already parsed into a Map.
//
// NOTE: This file ships the Dart side of the contract. The native side
// (Android: a FlutterPlugin that JNI-loads libnode.so from
// jniLibs/<abi>/libnode.so and runs our bridge.js; iOS: a FlutterPlugin that
// links NodeMobile.xcframework and runs bridge.js) is not part of this
// package — see docs/mobile_native_setup.md for the required pieces.

import 'dart:async';

import 'package:flutter/services.dart';

import 'bridge.dart';
import 'ndjson.dart';

class MobileNcmBridge implements NcmBridge {
  MobileNcmBridge({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
    Duration callTimeout = kDefaultCallTimeout,
  }) : _method = methodChannel ?? const MethodChannel(channelName),
       _events = eventChannel ?? const EventChannel(eventChannelName),
       // ignore: prefer_initializing_formals
       _callTimeout = callTimeout;

  static const String channelName = 'ncm_api_enhanced/bridge';
  static const String eventChannelName = 'ncm_api_enhanced/events';

  final MethodChannel _method;
  final EventChannel _events;
  final Duration _callTimeout;

  final _pending = PendingTable();
  final _stream = StreamController<Map<String, dynamic>>.broadcast();
  StreamSubscription<dynamic>? _sub;
  final _splitter = NdjsonLineSplitter();
  Completer<void>? _readyCompleter;

  @override
  Stream<Map<String, dynamic>> get events => _stream.stream;

  @override
  Future<void> start() async {
    _readyCompleter = Completer<void>();

    _sub = _events.receiveBroadcastStream().listen(
      (raw) {
        // Native side gives us the JSON string already produced by bridge.js.
        // Re-feed through the NDJSON splitter to handle line framing the same
        // way the desktop side does (so a single event payload carrying many
        // lines still parses correctly).
        final chunk = raw is String ? raw : raw.toString();
        final events = _splitter.feed(chunk);
        for (final ev in events) {
          _dispatch(ev);
        }
      },
      onError: (e, st) {
        _readyCompleter?.completeError(
          BridgeError('event channel error', e, st),
        );
        _pending.rejectAll(BridgeError('event channel closed', e, st));
      },
      onDone: () {
        for (final ev in _splitter.flush()) {
          _dispatch(ev);
        }
        _readyCompleter?.completeError(
          BridgeError('event channel closed before ready'),
        );
        _pending.rejectAll(BridgeError('event channel closed'));
      },
    );

    try {
      final result = await _method.invokeMapMethod<String, dynamic>('start', {
        'channel': 'ncm',
      });
      final ready = result != null && result['ready'] == true;
      if (!ready) {
        throw BridgeError(
          'native bridge start did not return ready=true: $result',
        );
      }
    } catch (e, st) {
      _readyCompleter?.completeError(BridgeError('start() failed', e, st));
      rethrow;
    }

    // The native side is expected to send {"event":"ready"} via the event
    // channel as soon as bridge.js finishes loading. Wait for it.
    return _readyCompleter!.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        throw BridgeError('native bridge did not become ready within 30s');
      },
    );
  }

  void _dispatch(NdjsonEvent ev) {
    dispatchNdjson(
      events: [ev],
      pending: _pending,
      eventsCtl: _stream,
      onFatal: (msg, cause) {
        _pending.rejectAll(BridgeError('node fatal: $msg', cause));
      },
    );

    // If we just got the first "ready" event, mark the bridge as ready.
    final m = ev.value;
    if (m != null &&
        m['event'] == 'ready' &&
        _readyCompleter != null &&
        !_readyCompleter!.isCompleted) {
      _readyCompleter!.complete();
    }
  }

  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic>? params,
  ]) async {
    if (_readyCompleter == null || !_readyCompleter!.isCompleted) {
      throw StateError('MobileNcmBridge: call() before ready');
    }

    final entry = _pending.create(method);
    final id = entry.id;
    final completer = entry.completer;

    try {
      // Fire-and-forget: native side will not return a value, it will push
      // the response back through the event channel.
      await _method.invokeMethod<void>('call', {
        'id': id,
        'method': method,
        'params': params ?? <String, dynamic>{},
      });
    } on PlatformException catch (e, st) {
      _pending.take(id);
      completer.completeError(BridgeError('native call failed', e, st));
      return completer.future;
    }

    return completer.future.timeout(
      _callTimeout,
      onTimeout: () {
        _pending.take(id);
        throw TimeoutException(
          'NCM call "$method" (id=$id) exceeded ${_callTimeout.inSeconds}s',
          _callTimeout,
        );
      },
    );
  }

  @override
  Future<void> shutdown() async {
    try {
      await _method.invokeMethod<void>('shutdown');
    } catch (_) {
      // Bridge may already be gone; that's fine.
    }
    await _sub?.cancel();
    _sub = null;
    _pending.rejectAll(BridgeError('bridge shut down'));
    if (!_stream.isClosed) await _stream.close();
  }
}
