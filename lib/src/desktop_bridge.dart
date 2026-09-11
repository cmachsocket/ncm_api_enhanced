// Desktop bridge implementation.
//
// Linux/macOS/Windows:
//   - Uses the system `node` executable.
//   - Communicates with bridge.js through NDJSON over stdin/stdout.
//
// Bridge root resolution order:
//
//   1. `bridgeRoot` constructor argument.
//   2. `NCM_BRIDGE_ROOT` environment variable.
//   3. Flutter package assets.
//
// Flutter assets cannot be used directly as a Node working directory,
// so the complete bridge tree is extracted to a temporary filesystem
// directory before spawning Node.
//
// Package asset layout:
//
//   packages/ncm_api_enhanced/assets/bridge/
//     ├── bridge.js
//     ├── package.json
//     └── node_modules/
//
// Normal consumer usage:
//
//   NcmApi()
//
// requires neither `bridgeRoot` nor `NCM_BRIDGE_ROOT`.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show AssetManifest, rootBundle;

import 'bridge.dart';
import 'ndjson.dart';

class DesktopNcmBridge implements NcmBridge {
  DesktopNcmBridge({
    this.bridgeRoot,
    this.nodeExecutable = 'node',
    Duration callTimeout = kDefaultCallTimeout,
  }) : _callTimeout = callTimeout;

  /// Absolute filesystem path containing:
  ///
  ///   bridge.js
  ///   node_modules/
  ///
  /// If null, the bridge is resolved from:
  ///
  ///   1. NCM_BRIDGE_ROOT
  ///   2. Flutter asset bundle
  final String? bridgeRoot;

  /// Node executable name or absolute path.
  ///
  /// Defaults to `node`.
  final String nodeExecutable;

  final Duration _callTimeout;

  Process? _proc;

  final PendingTable _pending = PendingTable();

  final StreamController<Map<String, dynamic>> _events =
      StreamController<Map<String, dynamic>>.broadcast();

  final NdjsonLineSplitter _splitter = NdjsonLineSplitter();

  Completer<void>? _readyCompleter;

  bool _started = false;
  bool _nodeExitHandled = false;

  /// Temporary directory containing an extracted bridge.
  ///
  /// Only non-null when the bridge came from Flutter assets.
  Directory? _extractedBridgeDir;

  /// Actual package asset prefix.
  ///
  /// The physical build output is:
  ///
  ///   flutter_assets/
  ///     packages/
  ///       ncm_api_enhanced/
  ///         assets/
  ///           bridge/
  static const String _assetPrefix = 'packages/ncm_api_enhanced/assets/bridge/';

  static const String _bridgeAsset = '${_assetPrefix}bridge.js';

  static const String _apiMainRelativePath =
      'node_modules/'
      '@neteasecloudmusicapienhanced/'
      'api/'
      'main.js';

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  // ---------------------------------------------------------------------------
  // Bridge root resolution
  // ---------------------------------------------------------------------------

  Future<String> _resolveBridgeRoot() async {
    // 1. Explicit constructor argument.
    final explicit = bridgeRoot;

    if (explicit != null && explicit.isNotEmpty) {
      return explicit;
    }

    // 2. Environment variable.
    final environmentRoot = Platform.environment['NCM_BRIDGE_ROOT'];

    if (environmentRoot != null && environmentRoot.isNotEmpty) {
      return environmentRoot;
    }

    // 3. Flutter asset bundle.
    final extracted = await _extractBridgeFromAssets();

    if (extracted != null) {
      _extractedBridgeDir = extracted;
      return extracted.path;
    }

    throw BridgeError(
      'DesktopNcmBridge: bridge root not found.\n'
      '\n'
      'Tried:\n'
      '  - bridgeRoot= constructor argument\n'
      '  - NCM_BRIDGE_ROOT environment variable\n'
      '  - Flutter asset bundle:\n'
      '    $_assetPrefix\n'
      '\n'
      'Make sure the package assets are included in the Flutter build.',
    );
  }

  // ---------------------------------------------------------------------------
  // Asset extraction
  // ---------------------------------------------------------------------------

  /// Extract the complete bridge tree from Flutter's asset bundle.
  ///
  /// Returns null only when the bridge asset is not present.
  ///
  /// Throws [BridgeError] when the asset exists but extraction or validation
  /// fails.
  Future<Directory?> _extractBridgeFromAssets() async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final assets = manifest.listAssets();

    if (!assets.contains(_bridgeAsset)) {
      return null;
    }

    final tmp = await Directory.systemTemp.createTemp('ncm_bridge_');

    try {
      var extractedFiles = 0;

      for (final assetKey in assets) {
        if (!assetKey.startsWith(_assetPrefix)) {
          continue;
        }

        final relativePath = assetKey.substring(_assetPrefix.length);

        if (relativePath.isEmpty) {
          continue;
        }

        _validateAssetPath(relativePath);

        final outputPath = relativePath.replaceAll('/', Platform.pathSeparator);

        final outputFile = File(
          '${tmp.path}'
          '${Platform.pathSeparator}'
          '$outputPath',
        );

        await outputFile.parent.create(recursive: true);

        final data = await rootBundle.load(assetKey);

        final bytes = data.buffer.asUint8List(
          data.offsetInBytes,
          data.lengthInBytes,
        );

        await outputFile.writeAsBytes(bytes, flush: false);

        extractedFiles++;
      }

      if (extractedFiles == 0) {
        throw BridgeError(
          'Flutter asset $_bridgeAsset exists in the manifest, '
          'but no bridge files were extracted.',
        );
      }

      _validateExtractedBridge(tmp);

      return tmp;
    } catch (error, stackTrace) {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}

      if (error is BridgeError) {
        rethrow;
      }

      throw BridgeError(
        'Failed to extract the Flutter asset bridge.',
        error,
        stackTrace,
      );
    }
  }

  /// Reject paths that could escape the temporary bridge directory.
  void _validateAssetPath(String path) {
    final normalized = path.replaceAll('\\', '/');

    if (normalized.startsWith('/') ||
        normalized == '..' ||
        normalized.startsWith('../') ||
        normalized.contains('/../')) {
      throw BridgeError('Invalid Flutter bridge asset path: $path');
    }
  }

  /// Validate the extracted bridge tree.
  void _validateExtractedBridge(Directory root) {
    final bridgeJs = File(
      '${root.path}'
      '${Platform.pathSeparator}'
      'bridge.js',
    );

    final apiMain = File(
      '${root.path}'
      '${Platform.pathSeparator}'
      '${_apiMainRelativePath.replaceAll('/', Platform.pathSeparator)}',
    );

    if (!bridgeJs.existsSync()) {
      throw BridgeError(
        'Flutter bridge extraction completed, but bridge.js is missing:\n'
        '${bridgeJs.path}',
      );
    }

    if (!apiMain.existsSync()) {
      throw BridgeError(
        'Flutter bridge extraction completed, but '
        '@neteasecloudmusicapienhanced/api/main.js is missing:\n'
        '${apiMain.path}',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  @override
  Future<void> start() async {
    if (_started) {
      return;
    }

    _started = true;
    _nodeExitHandled = false;
    _readyCompleter = Completer<void>();

    try {
      final root = await _resolveBridgeRoot();

      final bridgeJs = File('$root${Platform.pathSeparator}bridge.js');

      if (!bridgeJs.existsSync()) {
        throw BridgeError(
          'bridge.js not found at:\n'
          '${bridgeJs.path}',
        );
      }

      final apiMain = File(
        '$root'
        '${Platform.pathSeparator}'
        '${_apiMainRelativePath.replaceAll('/', Platform.pathSeparator)}',
      );

      if (!apiMain.existsSync()) {
        throw BridgeError(
          '@neteasecloudmusicapienhanced/api/main.js not found at:\n'
          '${apiMain.path}',
        );
      }

      _proc = await Process.start(
        nodeExecutable,
        <String>[bridgeJs.path],
        workingDirectory: root,
        runInShell: false,
      );

      final proc = _proc!;

      // ---------------------------------------------------------------------
      // stdout
      // ---------------------------------------------------------------------

      proc.stdout
          .transform(utf8.decoder)
          .listen(
            _handleStdout,
            onError: (Object error, StackTrace stackTrace) {
              if (_events.isClosed) {
                return;
              }

              _events.add({
                'event': 'log',
                'data': {'level': 'stdout_error', 'error': error.toString()},
              });
            },
            onDone: _handleStdoutDone,
          );

      // ---------------------------------------------------------------------
      // stderr
      // ---------------------------------------------------------------------

      proc.stderr.transform(utf8.decoder).listen((String text) {
        if (_events.isClosed) {
          return;
        }

        _events.add({
          'event': 'log',
          'data': {'level': 'stderr', 'line': text},
        });
      }, onError: (_) {});

      // ---------------------------------------------------------------------
      // Process exit
      // ---------------------------------------------------------------------

      proc.exitCode.then(_onNodeExit);

      // ---------------------------------------------------------------------
      // Wait for bridge.js readiness.
      // ---------------------------------------------------------------------

      await _readyCompleter!.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          throw BridgeError(
            'node bridge did not become ready within 30 seconds.',
          );
        },
      );
    } catch (_) {
      await _abortStart();
      rethrow;
    }
  }

  void _handleStdout(String chunk) {
    if (_events.isClosed) {
      return;
    }

    for (final event in _splitter.feed(chunk)) {
      _dispatch(event);
    }
  }

  void _handleStdoutDone() {
    if (_events.isClosed) {
      return;
    }

    // Process any final partial NDJSON line.
    for (final event in _splitter.flush()) {
      _dispatch(event);
    }

    // exitCode is normally the authoritative notification.
    //
    // Keep this as a fallback because stdout may close before the process
    // exit future is observed.
    _onNodeExit(0);
  }

  void _dispatch(NdjsonEvent event) {
    dispatchNdjson(
      events: <NdjsonEvent>[event],
      pending: _pending,
      eventsCtl: _events,
      onFatal: (message, cause) {
        _pending.rejectAll(BridgeError('node fatal: $message', cause));
      },
    );

    final value = event.value;

    if (value == null) {
      return;
    }

    if (value['event'] != 'ready') {
      return;
    }

    final completer = _readyCompleter;

    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  void _onNodeExit(int code) {
    if (_nodeExitHandled) {
      return;
    }

    _nodeExitHandled = true;

    final ready = _readyCompleter;

    if (ready != null && !ready.isCompleted) {
      ready.completeError(BridgeError('node exited before ready (code=$code)'));
    }

    _pending.rejectAll(BridgeError('node bridge exited (code=$code)'));

    if (!_events.isClosed) {
      _events.add({
        'event': 'fatal',
        'data': {'code': code},
      });

      _events.close();
    }

    _proc = null;
    _started = false;
  }

  Future<void> _abortStart() async {
    _started = false;

    final proc = _proc;
    _proc = null;

    if (proc != null) {
      try {
        proc.stdin.close();
      } catch (_) {}

      try {
        proc.kill();
      } catch (_) {}
    }

    _pending.rejectAll(BridgeError('bridge failed to start'));

    final tmp = _extractedBridgeDir;
    _extractedBridgeDir = null;

    if (tmp != null) {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
  }

  // ---------------------------------------------------------------------------
  // RPC
  // ---------------------------------------------------------------------------

  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic>? params,
  ]) async {
    final proc = _proc;

    if (proc == null) {
      throw StateError('DesktopNcmBridge: call() before start()');
    }

    final entry = _pending.create(method);

    final id = entry.id;
    final completer = entry.completer;

    final payload = jsonEncode({
      'id': id,
      'method': method,
      'params': params ?? <String, dynamic>{},
    });

    try {
      proc.stdin.writeln(payload);
    } catch (error, stackTrace) {
      _pending.take(id);

      completer.completeError(
        BridgeError('failed to write to node stdin', error, stackTrace),
      );

      return completer.future;
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

  // ---------------------------------------------------------------------------
  // Shutdown
  // ---------------------------------------------------------------------------

  @override
  Future<void> shutdown() async {
    final proc = _proc;

    _proc = null;
    _started = false;
    _nodeExitHandled = true;

    if (proc != null) {
      try {
        proc.stdin.close();
      } catch (_) {}

      try {
        await proc.exitCode.timeout(const Duration(seconds: 3));
      } catch (_) {
        try {
          proc.kill();
        } catch (_) {}
      }
    }

    _pending.rejectAll(BridgeError('bridge shut down'));

    if (!_events.isClosed) {
      await _events.close();
    }

    final tmp = _extractedBridgeDir;
    _extractedBridgeDir = null;

    if (tmp != null) {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
  }
}
