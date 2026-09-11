import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

import 'bridge.dart';
import 'ndjson.dart';

// ============================================================================
// Native API
// ============================================================================

typedef _InitializeDartApiNative = IntPtr Function(Pointer<Void> data);

typedef _InitializeDartApiDart = int Function(Pointer<Void> data);

typedef _SetDartPortNative = Void Function(Int64 port);

typedef _SetDartPortDart = void Function(int port);

typedef _StartNative = Int32 Function(Int32 argc, Pointer<Pointer<Utf8>> argv);

typedef _StartDart = int Function(int argc, Pointer<Pointer<Utf8>> argv);

typedef _WriteStdinNative = Int32 Function(Pointer<Uint8> data, IntPtr length);

typedef _WriteStdinDart = int Function(Pointer<Uint8> data, int length);

typedef _RequestShutdownNative = Void Function();

typedef _RequestShutdownDart = void Function();

typedef _IsRunningNative = Int32 Function();

typedef _IsRunningDart = int Function();

// ============================================================================
// Native message
// ============================================================================
//
// Native side posts:
//
//     [ "stdout", "<text>" ]
//
// or:
//
//     [ "stderr", "<text>" ]
//
// ============================================================================

class _NativeMessage {
  const _NativeMessage(this.type, this.data);

  final String type;
  final String data;
}

// ============================================================================
// Mobile bridge
// ============================================================================

class MobileNcmBridge implements NcmBridge {
  MobileNcmBridge({Duration callTimeout = kDefaultCallTimeout})
    : _callTimeout = callTimeout {
    _loadNative();
  }

  final Duration _callTimeout;

  late final DynamicLibrary _library;

  late final _InitializeDartApiDart _initializeDartApi;

  late final _SetDartPortDart _setDartPort;

  late final _StartDart _startNode;

  late final _WriteStdinDart _writeStdin;

  late final _RequestShutdownDart _requestShutdown;

  late final _IsRunningDart _isRunning;

  final _pending = PendingTable();

  final _stream = StreamController<Map<String, dynamic>>.broadcast();

  final _splitter = NdjsonLineSplitter();

  Completer<void>? _readyCompleter;

  ReceivePort? _nativePort;

  StreamSubscription<dynamic>? _nativePortSubscription;

  bool _started = false;

  bool _shutdown = false;

  bool _nativeApiInitialized = false;

  @override
  Stream<Map<String, dynamic>> get events => _stream.stream;

  // ==========================================================================
  // Native library
  // ==========================================================================

  void _loadNative() {
    //
    // libncm_node_bridge.so is the code asset produced by CBuilder.
    //
    // libnode.so is a DT_NEEDED dependency of that library and therefore
    // does not need to be opened manually.
    //

    _library = DynamicLibrary.open('libncm_node_bridge.so');

    _initializeDartApi = _library
        .lookupFunction<_InitializeDartApiNative, _InitializeDartApiDart>(
          'ncm_node_initialize_dart_api',
        );

    _setDartPort = _library
        .lookupFunction<_SetDartPortNative, _SetDartPortDart>(
          'ncm_node_set_dart_port',
        );

    _startNode = _library.lookupFunction<_StartNative, _StartDart>(
      'ncm_node_start',
    );

    _writeStdin = _library.lookupFunction<_WriteStdinNative, _WriteStdinDart>(
      'ncm_node_write_stdin',
    );

    _requestShutdown = _library
        .lookupFunction<_RequestShutdownNative, _RequestShutdownDart>(
          'ncm_node_request_shutdown',
        );

    _isRunning = _library.lookupFunction<_IsRunningNative, _IsRunningDart>(
      'ncm_node_is_running',
    );
  }

  // ==========================================================================
  // Dart native port
  // ==========================================================================

  void _initializeNativePort() {
    if (_nativeApiInitialized) {
      return;
    }

    //
    // Initialize Dart API DL.
    //
    // This gives the native library access to:
    //
    //     Dart_PostCObject_DL()
    //
    // from native threads.
    //

    final result = _initializeDartApi(NativeApi.initializeApiDLData);

    if (result != 0) {
      throw BridgeError(
        'failed to initialize Dart API DL '
        '(code=$result)',
      );
    }

    _nativeApiInitialized = true;

    //
    // Create a ReceivePort belonging to the current Dart isolate.
    //

    final port = ReceivePort();

    _nativePort = port;

    _nativePortSubscription = port.listen(
      _handleNativeMessage,
      onError: (Object error, StackTrace stack) {
        _handleFatal(BridgeError('native message port error', error, stack));
      },
    );

    //
    // Give native code the SendPort's native port ID.
    //

    _setDartPort(port.sendPort.nativePort);
  }

  // ==========================================================================
  // Native message handling
  // ==========================================================================

  void _handleNativeMessage(dynamic message) {
    try {
      if (message is! List || message.length != 2) {
        _handleFatal(BridgeError('invalid native message: $message'));

        return;
      }

      final type = message[0];

      final data = message[1];

      if (type is! String || data is! String) {
        _handleFatal(BridgeError('invalid native message payload: $message'));

        return;
      }

      final nativeMessage = _NativeMessage(type, data);

      switch (nativeMessage.type) {
        case 'stdout':
          _handleStdout(nativeMessage.data);
          break;

        case 'stderr':
          _handleStderr(nativeMessage.data);
          break;

        default:
          _handleFatal(
            BridgeError(
              'unknown native message type '
              '"${nativeMessage.type}"',
            ),
          );
      }
    } catch (e, st) {
      _handleFatal(BridgeError('failed to process native message', e, st));
    }
  }

  // ==========================================================================
  // Native stdout
  // ==========================================================================

  void _handleStdout(String chunk) {
    try {
      //
      // Native currently emits complete stdout lines.
      //
      // Keep NdjsonLineSplitter here anyway so the protocol remains the same
      // as DesktopNcmBridge and does not depend on native framing forever.
      //

      final events = _splitter.feed(chunk);

      for (final event in events) {
        _dispatch(event);
      }
    } catch (e, st) {
      _handleFatal(BridgeError('failed to process native stdout', e, st));
    }
  }

  // ==========================================================================
  // Native stderr
  // ==========================================================================

  void _handleStderr(String message) {
    if (_stream.isClosed) {
      return;
    }

    _stream.add({
      'event': 'log',
      'data': {'level': 'stderr', 'message': message},
    });
  }

  // ==========================================================================
  // Start
  // ==========================================================================

  @override
  Future<void> start() async {
    if (_shutdown) {
      throw StateError('MobileNcmBridge: bridge has already been shut down');
    }

    if (_started) {
      final ready = _readyCompleter;

      if (ready == null) {
        throw StateError('MobileNcmBridge: invalid start state');
      }

      return ready.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          throw BridgeError('native bridge did not become ready within 30s');
        },
      );
    }

    _started = true;

    _readyCompleter = Completer<void>();

    try {
      //
      // This MUST happen before ncm_node_start().
      //
      // Native Node runs on its own pthread and will use
      // Dart_PostCObject_DL() from that thread.
      //

      _initializeNativePort();

      //
      // This must be a real filesystem directory because bundle.js does:
      //
      //     require.resolve("./xhr-sync-worker.js")
      //

      final bridgeRoot = await _resolveBridgeRoot();

      final bundleJs = File(
        '${bridgeRoot}${Platform.pathSeparator}'
        'dist${Platform.pathSeparator}'
        'bundle.js',
      );

      if (!await bundleJs.exists()) {
        throw BridgeError(
          'MobileNcmBridge: bundle.js not found at '
          '${bundleJs.path}',
        );
      }

      //
      // Direct Node entry:
      //
      //     node bundle.js
      //

      final arguments = <String>['node', bundleJs.path];

      final argv = calloc<Pointer<Utf8>>(arguments.length);

      final allocated = <Pointer<Utf8>>[];

      try {
        for (var i = 0; i < arguments.length; i++) {
          final ptr = arguments[i].toNativeUtf8();

          allocated.add(ptr);

          argv[i] = ptr;
        }

        final result = _startNode(arguments.length, argv);

        if (result != 0) {
          throw BridgeError(
            'native bridge start failed '
            'with code $result',
          );
        }
      } finally {
        for (final ptr in allocated) {
          calloc.free(ptr);
        }

        calloc.free(argv);
      }
    } catch (e, st) {
      _started = false;

      if (_readyCompleter != null && !_readyCompleter!.isCompleted) {
        _readyCompleter!.completeError(
          e is BridgeError ? e : BridgeError('start() failed', e, st),
        );
      }

      rethrow;
    }

    //
    // ncm_node_start() only means the native Node thread was created.
    //
    // Actual readiness comes from:
    //
    //     {"event":"ready","data":...}
    //

    return _readyCompleter!.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
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
      final directory = Directory(explicitRoot);

      if (!await directory.exists()) {
        throw BridgeError(
          'NCM_BRIDGE_ROOT does not exist: '
          '$explicitRoot',
        );
      }

      return directory.path;
    }

    //
    // bundle.js and xhr-sync-worker.js are Flutter assets.
    //
    // Node cannot execute a Flutter AssetBundle URI directly, so copy them
    // into a real filesystem tree.
    //

    final root = await Directory.systemTemp.createTemp(
      'ncm_api_enhanced_bridge_',
    );

    final dist = Directory('${root.path}${Platform.pathSeparator}dist');

    await dist.create(recursive: true);

    const prefix =
        'packages/ncm_api_enhanced/'
        'assets/bridge/dist/';

    await _extractAsset(
      '$prefix'
      'bundle.js',
      File(
        '${dist.path}${Platform.pathSeparator}'
        'bundle.js',
      ),
    );

    await _extractAsset(
      '$prefix'
      'xhr-sync-worker.js',
      File(
        '${dist.path}${Platform.pathSeparator}'
        'xhr-sync-worker.js',
      ),
    );

    return root.path;
  }

  Future<void> _extractAsset(String asset, File destination) async {
    try {
      final data = await rootBundle.load(asset);

      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );

      await destination.writeAsBytes(bytes, flush: true);
    } catch (e, st) {
      throw BridgeError(
        'failed to extract Flutter asset '
        '"$asset"',
        e,
        st,
      );
    }
  }

  // ==========================================================================
  // Protocol dispatch
  // ==========================================================================

  void _dispatch(NdjsonEvent event) {
    dispatchNdjson(
      events: [event],
      pending: _pending,
      eventsCtl: _stream,
      onFatal: (message, cause) {
        _handleFatal(BridgeError('node fatal: $message', cause));
      },
    );

    final value = event.value;

    if (value != null &&
        value['event'] == 'ready' &&
        _readyCompleter != null &&
        !_readyCompleter!.isCompleted) {
      _readyCompleter!.complete();
    }
  }

  void _handleFatal(Object error) {
    _pending.rejectAll(error);

    if (_readyCompleter != null && !_readyCompleter!.isCompleted) {
      _readyCompleter!.completeError(error);
    }
  }

  // ==========================================================================
  // Call
  // ==========================================================================

  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic>? params,
  ]) async {
    final ready = _readyCompleter;

    if (ready == null || !ready.isCompleted) {
      throw StateError('MobileNcmBridge: call() before ready');
    }

    if (_shutdown) {
      throw StateError('MobileNcmBridge: call() after shutdown');
    }

    if (_isRunning() == 0) {
      throw BridgeError('native Node process is not running');
    }

    final entry = _pending.create(method);

    final id = entry.id;

    final completer = entry.completer;

    final payload = jsonEncode({
      'id': id,
      'method': method,
      'params': params ?? <String, dynamic>{},
    });

    final bytes = utf8.encode('$payload\n');

    final buffer = calloc<Uint8>(bytes.length);

    try {
      buffer.asTypedList(bytes.length).setAll(0, bytes);

      final result = _writeStdin(buffer, bytes.length);

      if (result != 0) {
        _pending.take(id);

        final error = BridgeError(
          'native stdin write failed for '
          '"$method" '
          '(id=$id, code=$result)',
        );

        if (!completer.isCompleted) {
          completer.completeError(error);
        }

        return await completer.future;
      }
    } catch (e, st) {
      _pending.take(id);

      final error = BridgeError('native call failed', e, st);

      if (!completer.isCompleted) {
        completer.completeError(error);
      }

      return completer.future;
    } finally {
      calloc.free(buffer);
    }

    return completer.future.timeout(
      _callTimeout,
      onTimeout: () {
        _pending.take(id);

        throw TimeoutException(
          'NCM call "$method" (id=$id) exceeded '
          '${_callTimeout.inSeconds}s',
          _callTimeout,
        );
      },
    );
  }

  // ==========================================================================
  // Shutdown
  // ==========================================================================

  @override
  Future<void> shutdown() async {
    if (_shutdown) {
      return;
    }

    _shutdown = true;

    try {
      _requestShutdown();
    } catch (_) {
      // Native side may already be gone.
    }

    try {
      for (final event in _splitter.flush()) {
        _dispatch(event);
      }
    } catch (_) {
      // Ignore malformed trailing data during shutdown.
    }

    _pending.rejectAll(BridgeError('bridge shut down'));

    //
    // Stop accepting native messages before closing the Dart port.
    //

    await _nativePortSubscription?.cancel();

    _nativePortSubscription = null;

    _nativePort?.close();

    _nativePort = null;

    if (!_stream.isClosed) {
      await _stream.close();
    }

    //
    // Native shutdown is currently a no-op and Node may technically still
    // be running. Therefore do NOT unload the native library or invalidate
    // the Dart API DL state here.
    //

    _started = false;
  }
}
