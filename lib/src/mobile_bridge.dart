import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
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

typedef _SetExecutablePathNative = Void Function(Pointer<Utf8> path);

typedef _SetExecutablePathDart = void Function(Pointer<Utf8> path);

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

  late final _SetExecutablePathDart _setExecutablePath;

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

  /// Absolute path of the Node executable that was extracted from the
  /// app's code asset bundle and handed to the native bridge.
  ///
  /// Set in [start()] just before invoking the native
  /// [ncm_node_set_executable_path]. Cleared by [shutdown()].
  String? _nodeExecutablePath;

  /// Filesystem directory containing the extracted `node` binary.
  ///
  /// Tracked separately from the bridge asset dir so we can keep it
  /// alive for the entire process lifetime — the native bridge
  /// keeps a copy of the path and may reference it until
  /// [ncm_node_request_shutdown] returns.
  Directory? _nodeDir;

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

    return '${text.substring(0, maxLength)}...';
  }

  // ==========================================================================
  // Native library
  // ==========================================================================

  void _loadNative() {
    _log('loadNative: ENTER');

    _library = DynamicLibrary.open('libncm_node_bridge.so');

    _log('loadNative: library opened');

    _initializeDartApi = _library
        .lookupFunction<_InitializeDartApiNative, _InitializeDartApiDart>(
          'ncm_node_initialize_dart_api',
        );

    _log('loadNative: ncm_node_initialize_dart_api loaded');

    _setDartPort = _library
        .lookupFunction<_SetDartPortNative, _SetDartPortDart>(
          'ncm_node_set_dart_port',
        );

    _log('loadNative: ncm_node_set_dart_port loaded');

    _startNode = _library.lookupFunction<_StartNative, _StartDart>(
      'ncm_node_start',
    );

    _log('loadNative: ncm_node_start loaded');

    _writeStdin = _library.lookupFunction<_WriteStdinNative, _WriteStdinDart>(
      'ncm_node_write_stdin',
    );

    _log('loadNative: ncm_node_write_stdin loaded');

    _requestShutdown = _library
        .lookupFunction<_RequestShutdownNative, _RequestShutdownDart>(
          'ncm_node_request_shutdown',
        );

    _log('loadNative: ncm_node_request_shutdown loaded');

    _setExecutablePath = _library
        .lookupFunction<_SetExecutablePathNative, _SetExecutablePathDart>(
          'ncm_node_set_executable_path',
        );

    _log('loadNative: ncm_node_set_executable_path loaded');

    _isRunning = _library.lookupFunction<_IsRunningNative, _IsRunningDart>(
      'ncm_node_is_running',
    );

    _log('loadNative: ncm_node_is_running loaded');
    _log('loadNative: SUCCESS');
  }

  // ==========================================================================
  // Dart native port
  // ==========================================================================

  void _initializeNativePort() {
    if (_nativeApiInitialized) {
      _log('initializeNativePort: already initialized');
      return;
    }

    _log('initializeNativePort: ENTER');

    final result = _initializeDartApi(NativeApi.initializeApiDLData);

    _log('initializeNativePort: Dart_InitializeApiDL result=$result');

    if (result != 0) {
      throw BridgeError(
        'failed to initialize Dart API DL '
        '(code=$result)',
      );
    }

    _nativeApiInitialized = true;

    _log('initializeNativePort: Dart API DL initialized');

    final port = ReceivePort();

    _nativePort = port;

    _log(
      'initializeNativePort: ReceivePort created '
      'nativePort=${port.sendPort.nativePort}',
    );

    _nativePortSubscription = port.listen(
      _handleNativeMessage,
      onError: (Object error, StackTrace stack) {
        _log(
          'initializeNativePort: ReceivePort ERROR '
          'error=$error',
        );

        _handleFatal(BridgeError('native message port error', error, stack));
      },
    );

    _log('initializeNativePort: listener installed');

    final nativePort = port.sendPort.nativePort;

    _setDartPort(nativePort);

    _log(
      'initializeNativePort: native port sent '
      'port=$nativePort',
    );
  }

  // ==========================================================================
  // Native message handling
  // ==========================================================================

  void _handleNativeMessage(dynamic message) {
    _log(
      'NativePort RECEIVE '
      'type=${message.runtimeType} '
      'value=${_shorten(message)}',
    );

    try {
      if (message is! List || message.length != 2) {
        _log('NativePort INVALID message');

        _handleFatal(BridgeError('invalid native message: $message'));

        return;
      }

      final type = message[0];

      final data = message[1];

      _log(
        'NativePort decoded '
        'type=$type '
        'dataType=${data.runtimeType} '
        'dataLength=${data is String ? data.length : -1}',
      );

      if (type is! String || data is! String) {
        _log('NativePort INVALID payload');

        _handleFatal(BridgeError('invalid native message payload: $message'));

        return;
      }

      final nativeMessage = _NativeMessage(type, data);

      switch (nativeMessage.type) {
        case 'stdout':
          _log(
            'NativePort -> stdout '
            'length=${nativeMessage.data.length}',
          );

          _handleStdout(nativeMessage.data);
          break;

        case 'stderr':
          _log(
            'NativePort -> stderr '
            'length=${nativeMessage.data.length}',
          );

          _handleStderr(nativeMessage.data);
          break;

        default:
          _log(
            'NativePort UNKNOWN TYPE '
            'type=${nativeMessage.type}',
          );

          _handleFatal(
            BridgeError(
              'unknown native message type '
              '"${nativeMessage.type}"',
            ),
          );
      }
    } catch (e, st) {
      _log(
        'NativePort HANDLER EXCEPTION '
        'error=$e',
      );

      _handleFatal(BridgeError('failed to process native message', e, st));
    }
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
      _log('START: initializing NativePort');

      _initializeNativePort();

      _log('START: NativePort initialized');

      final bridgeRoot = await _resolveBridgeRoot();

      _log('START: bridgeRoot=$bridgeRoot');

      _nodeExecutablePath = await _resolveNodeExecutable();

      _log('START: nodeExecutable=$_nodeExecutablePath');

      final bundleJs = File(
        '${bridgeRoot}${Platform.pathSeparator}'
        'dist${Platform.pathSeparator}'
        'bundle.js',
      );

      _log('START: bundleJs=${bundleJs.path}');

      if (!await bundleJs.exists()) {
        _log('START ERROR: bundle.js does not exist');

        throw BridgeError(
          'MobileNcmBridge: bundle.js not found at '
          '${bundleJs.path}',
        );
      }

      final arguments = <String>[
        _nodeExecutablePath!,
        bundleJs.path,
      ];

      _log(
        'START: Node arguments='
        '${_shorten(arguments)}',
      );

      // Push the executable path into native state before
      // ncm_node_start() spawns the child.
      final executablePathPtr =
          _nodeExecutablePath!.toNativeUtf8();

      try {

        _log(
          'START: calling ncm_node_set_executable_path '
          '($_nodeExecutablePath)',
        );

        _setExecutablePath(executablePathPtr);

        _log(
          'START: ncm_node_set_executable_path returned',
        );
      } finally {

        calloc.free(executablePathPtr);
      }


      final argv = calloc<Pointer<Utf8>>(arguments.length);

      final allocated = <Pointer<Utf8>>[];

      try {
        for (var i = 0; i < arguments.length; i++) {
          final ptr = arguments[i].toNativeUtf8();

          allocated.add(ptr);

          argv[i] = ptr;

          _log('START: argv[$i]=${arguments[i]}');
        }

        _log('START: calling ncm_node_start');

        final result = _startNode(arguments.length, argv);

        _log(
          'START: ncm_node_start returned '
          'code=$result',
        );

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

        _log('START: argv memory freed');
      }
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

  /// Resolve the absolute path of the Node executable to spawn.
  ///
  /// The native bridge does not link libnode.so; instead it
  /// `fork()`+`execvp()`s an external `node` binary whose path we
  /// hand in via `ncm_node_set_executable_path()`. The Dart side is
  /// responsible for:
  ///
  ///   1. Extracting the `node` PIE from the Flutter asset bundle
  ///      (`packages/ncm_api_enhanced/assets/runtime/android-arm64/node`)
  ///      into a writable directory we own.
  ///   2. `chmod 0o755` so the OS will actually exec it.
  ///   3. Returning the absolute path of the extracted binary.
  ///
  /// Only `arm64-v8a` is shipped today; the same path is used
  /// regardless of which specific arm64 device we land on.
  Future<String> _resolveNodeExecutable() async {
    const assetPath =
        'packages/ncm_api_enhanced/'
        'assets/runtime/android-arm64/node';

    _log('resolveNodeExecutable: extracting $assetPath');

    final data = await rootBundle.load(assetPath);

    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );

    _log(
      'resolveNodeExecutable: loaded '
      'bytes=${bytes.length}',
    );

    final tmp = await Directory.systemTemp.createTemp(
      'ncm_node_',
    );

    _nodeDir = tmp;

    final nodeFile = File(
      '${tmp.path}${Platform.pathSeparator}node',
    );

    await nodeFile.writeAsBytes(bytes, flush: true);

    _log(
      'resolveNodeExecutable: wrote '
      '${nodeFile.path}',
    );

    //
    // Android chmod doesn't use the POSIX mode_t; the dart:io
    // Process.run chmod helper doesn't exist either, so we shell out
    // to /system/bin/chmod. Most Android devices ship chmod at
    // that path; if not, the subsequent execvp() will fail with
    // EACCES and surface a clear error.
    //
    final chmod = await Process.run(
      '/system/bin/chmod',
      <String>['0755', nodeFile.path],
    );

    _log(
      'resolveNodeExecutable: chmod exitCode='
      '${chmod.exitCode}',
    );

    if (chmod.exitCode != 0) {

      try {
        await tmp.delete(recursive: true);
      } catch (_) {}

      _nodeDir = null;

      throw BridgeError(
        'failed to chmod 0755 the bundled node binary '
        'at ${nodeFile.path}: '
        '${(chmod.stderr as String).trim()}',
      );
    }

    return nodeFile.path;
  }

  Future<String> _resolveBridgeRoot() async {
    const explicitRoot = String.fromEnvironment('NCM_BRIDGE_ROOT');

    if (explicitRoot.isNotEmpty) {
      _log(
        'resolveBridgeRoot: using explicit root '
        '$explicitRoot',
      );

      final directory = Directory(explicitRoot);

      if (!await directory.exists()) {
        _log('resolveBridgeRoot: explicit root DOES NOT EXIST');

        throw BridgeError(
          'NCM_BRIDGE_ROOT does not exist: '
          '$explicitRoot',
        );
      }

      return directory.path;
    }

    _log('resolveBridgeRoot: extracting Flutter assets');

    final root = await Directory.systemTemp.createTemp(
      'ncm_api_enhanced_bridge_',
    );

    _log('resolveBridgeRoot: root=$root');

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

    _log('resolveBridgeRoot: extraction COMPLETE');

    return root.path;
  }

  Future<void> _extractAsset(String asset, File destination) async {
    _log(
      'extractAsset: START '
      'asset=$asset '
      'destination=${destination.path}',
    );

    try {
      final data = await rootBundle.load(asset);

      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );

      _log(
        'extractAsset: loaded '
        'asset=$asset '
        'bytes=${bytes.length}',
      );

      await destination.writeAsBytes(bytes, flush: true);

      _log(
        'extractAsset: SUCCESS '
        'asset=$asset',
      );
    } catch (e, st) {
      _log(
        'extractAsset: ERROR '
        'asset=$asset '
        'error=$e',
      );

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
    _log(
      'DISPATCH ENTER '
      'value=${_shorten(event.value)} '
      'error=${event.error} '
      'pending=${_pending.size()}',
    );

    dispatchNdjson(
      events: [event],
      pending: _pending,
      eventsCtl: _stream,
      onFatal: (message, cause) {
        _log(
          'DISPATCH FATAL '
          'message=$message '
          'cause=$cause',
        );

        _handleFatal(BridgeError('node fatal: $message', cause));
      },
    );

    final value = event.value;

    if (value != null &&
        value['event'] == 'ready' &&
        _readyCompleter != null &&
        !_readyCompleter!.isCompleted) {
      _log('DISPATCH: READY EVENT');

      _readyCompleter!.complete();

      _log('DISPATCH: READY COMPLETER COMPLETED');
    }

    if (value != null && value.containsKey('id')) {
      _log(
        'DISPATCH: RESPONSE '
        'id=${value['id']} '
        'ok=${value['ok']} '
        'pending=${_pending.size()}',
      );
    }

    _log('DISPATCH EXIT');
  }

  void _handleFatal(Object error) {
    _log(
      'FATAL '
      'error=$error '
      'pending=${_pending.size()}',
    );

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
    _log(
      'CALL ENTER '
      'method=$method '
      'params=${_shorten(params)}',
    );

    final ready = _readyCompleter;

    if (ready == null || !ready.isCompleted) {
      _log(
        'CALL REJECTED: bridge not ready '
        'method=$method',
      );

      throw StateError('MobileNcmBridge: call() before ready');
    }

    if (_shutdown) {
      _log(
        'CALL REJECTED: bridge shutdown '
        'method=$method',
      );

      throw StateError('MobileNcmBridge: call() after shutdown');
    }

    final running = _isRunning();

    _log(
      'CALL: native running=$running '
      'method=$method',
    );

    if (running == 0) {
      _log(
        'CALL REJECTED: Node not running '
        'method=$method',
      );

      throw BridgeError('native Node process is not running');
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

    final buffer = calloc<Uint8>(bytes.length);

    try {
      buffer.asTypedList(bytes.length).setAll(0, bytes);

      _log(
        'CALL WRITE STDIN '
        'id=$id '
        'method=$method '
        'bytes=${bytes.length}',
      );

      final result = _writeStdin(buffer, bytes.length);

      _log(
        'CALL WRITE STDIN RESULT '
        'id=$id '
        'method=$method '
        'code=$result',
      );

      if (result != 0) {
        _pending.take(id);

        final error = BridgeError(
          'native stdin write failed for '
          '"$method" '
          '(id=$id, code=$result)',
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

        return await completer.future;
      }
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
    } finally {
      calloc.free(buffer);

      _log(
        'CALL: stdin buffer freed '
        'id=$id '
        'method=$method',
      );
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
      _log('SHUTDOWN: calling native request shutdown');

      _requestShutdown();

      _log('SHUTDOWN: native request returned');
    } catch (e) {
      _log(
        'SHUTDOWN: native request failed '
        'error=$e',
      );
    }

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

    _log(
      'SHUTDOWN: rejecting pending '
      'count=${_pending.size()}',
    );

    _pending.rejectAll(BridgeError('bridge shut down'));

    await _nativePortSubscription?.cancel();

    _nativePortSubscription = null;

    _nativePort?.close();

    _nativePort = null;

    //
    // Best-effort cleanup of the extracted node binary directory.
    //
    final nodeDir = _nodeDir;
    _nodeDir = null;
    _nodeExecutablePath = null;
    if (nodeDir != null) {
      try {
        await nodeDir.delete(recursive: true);
      } catch (e) {
        _log(
          'SHUTDOWN: node dir cleanup failed '
          'error=$e',
        );
      }
    }

    if (!_stream.isClosed) {
      await _stream.close();
    }

    _started = false;

    _log('SHUTDOWN EXIT');
  }
}
