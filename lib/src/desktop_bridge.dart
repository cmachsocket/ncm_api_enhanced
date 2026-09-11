// Desktop bridge implementation.
//
// Linux/macOS/Windows:
//
//   - Uses the system `node` executable.
//   - Communicates with bundle.js through NDJSON over stdin/stdout.
//
// Bridge root resolution order:
//
//   1. `bridgeRoot` constructor argument.
//   2. `NCM_BRIDGE_ROOT` environment variable.
//   3. Flutter package assets.
//
// Flutter assets cannot be used directly as a Node working directory,
// so the bridge files are extracted to a temporary filesystem directory
// before spawning Node.
//
// Package asset layout:
//
//   packages/ncm_api_enhanced/assets/bridge/dist/
//     ├── bundle.js
//     └── xhr-sync-worker.js
//
// `bundle.js` requires `./xhr-sync-worker.js`, therefore both files must
// remain in the same directory.
//
// Normal consumer usage:
//
//   NcmApi()
//
// requires neither `bridgeRoot` nor `NCM_BRIDGE_ROOT.

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
  ///   bundle.js
  ///   xhr-sync-worker.js
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

  /// Physical Flutter asset prefix.
  ///
  /// The build output is:
  ///
  ///   flutter_assets/
  ///     packages/
  ///       ncm_api_enhanced/
  ///         assets/
  ///           bridge/
  ///             dist/
  ///               bundle.js
  ///               xhr-sync-worker.js
  static const String _assetPrefix =
      'packages/ncm_api_enhanced/assets/bridge/dist/';

  static const String _bridgeAsset = '${_assetPrefix}bundle.js';

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  // ===========================================================================
  // Bridge root resolution
  // ===========================================================================

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

  // ===========================================================================
  // Asset extraction
  // ===========================================================================

  /// Extract the bridge files from Flutter's asset bundle.
  ///
  /// The resulting temporary directory contains:
  ///
  ///   bundle.js
  ///   xhr-sync-worker.js
  ///
  /// Returns null only when bundle.js is not present in the asset manifest.
  ///
  /// Throws [BridgeError] when bundle.js exists but extraction or validation
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

        stderr.writeln(
          '[DesktopNcmBridge] extracted: $assetKey -> '
          '${outputFile.path}',
        );
      }

      if (extractedFiles == 0) {
        throw BridgeError(
          'Flutter asset $_bridgeAsset exists in the manifest, '
          'but no bridge files were extracted.',
        );
      }

      _validateExtractedBridge(tmp);

      stderr.writeln('[DesktopNcmBridge] bridge extracted to: ${tmp.path}');

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
  ///
  /// `bundle.js` contains:
  ///
  ///   require.resolve("./xhr-sync-worker.js")
  ///
  /// therefore the worker must be extracted beside bundle.js.
  void _validateExtractedBridge(Directory root) {
    final bridgeJs = File(
      '${root.path}'
      '${Platform.pathSeparator}'
      'bundle.js',
    );

    final syncWorker = File(
      '${root.path}'
      '${Platform.pathSeparator}'
      'xhr-sync-worker.js',
    );

    if (!bridgeJs.existsSync()) {
      throw BridgeError(
        'Flutter bridge extraction completed, but bundle.js is missing:\n'
        '${bridgeJs.path}',
      );
    }

    if (!syncWorker.existsSync()) {
      throw BridgeError(
        'Flutter bridge extraction completed, but '
        'xhr-sync-worker.js is missing:\n'
        '${syncWorker.path}',
      );
    }
  }

  // ===========================================================================
  // Lifecycle
  // ===========================================================================

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

      final bridgeJs = File(
        '$root'
        '${Platform.pathSeparator}'
        'bundle.js',
      );

      final syncWorker = File(
        '$root'
        '${Platform.pathSeparator}'
        'xhr-sync-worker.js',
      );

      if (!bridgeJs.existsSync()) {
        throw BridgeError(
          'bundle.js not found at:\n'
          '${bridgeJs.path}',
        );
      }

      if (!syncWorker.existsSync()) {
        throw BridgeError(
          'xhr-sync-worker.js not found at:\n'
          '${syncWorker.path}',
        );
      }

      stderr.writeln('[DesktopNcmBridge] starting Node:');
      stderr.writeln('[DesktopNcmBridge] executable: $nodeExecutable');
      stderr.writeln('[DesktopNcmBridge] workingDirectory: $root');
      stderr.writeln('[DesktopNcmBridge] bundle: ${bridgeJs.path}');
      stderr.writeln('[DesktopNcmBridge] worker: ${syncWorker.path}');

      // -----------------------------------------------------------------------
      // Start Node.
      //
      // bundle.js is self-contained and contains the Netease API implementation.
      // No package.json / node_modules tree is required here.
      // -----------------------------------------------------------------------

      _proc = await Process.start(
        nodeExecutable,
        <String>[bridgeJs.path],
        workingDirectory: root,
        runInShell: false,
      );

      final proc = _proc!;

      stderr.writeln('[DesktopNcmBridge] Node process started.');

      // -----------------------------------------------------------------------
      // stdout
      // -----------------------------------------------------------------------

      proc.stdout
          .transform(utf8.decoder)
          .listen(
            _handleStdout,
            onError: (Object error, StackTrace stackTrace) {
              stderr.writeln(
                '[DesktopNcmBridge][stdout error] '
                '$error',
              );

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

      // -----------------------------------------------------------------------
      // stderr
      // -----------------------------------------------------------------------

      proc.stderr
          .transform(utf8.decoder)
          .listen(
            (String text) {
              // IMPORTANT:
              //
              // Do not only put this into bridgeEvents.
              //
              // If Node exits before Flutter receives "ready", this is often
              // the only useful diagnostic information.
              stderr.writeln('[DesktopNcmBridge][node stderr] $text');

              if (_events.isClosed) {
                return;
              }

              _events.add({
                'event': 'log',
                'data': {'level': 'stderr', 'line': text},
              });
            },
            onError: (Object error, StackTrace stackTrace) {
              stderr.writeln(
                '[DesktopNcmBridge][stderr error] '
                '$error',
              );

              if (_events.isClosed) {
                return;
              }

              _events.add({
                'event': 'log',
                'data': {'level': 'stderr_error', 'error': error.toString()},
              });
            },
          );

      // -----------------------------------------------------------------------
      // Process exit
      // -----------------------------------------------------------------------

      proc.exitCode.then((int code) {
        stderr.writeln('[DesktopNcmBridge] Node exited with code $code');

        _onNodeExit(code);
      });

      // -----------------------------------------------------------------------
      // Wait for bundle.js readiness.
      //
      // bundle.js emits:
      //
      //   {"event":"ready","data":{"pid":...,"node":"..."}}
      //
      // `_dispatch()` completes `_readyCompleter` when this frame arrives.
      // -----------------------------------------------------------------------

      await _readyCompleter!.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          throw BridgeError(
            'node bridge did not become ready within 30 seconds.',
          );
        },
      );

      stderr.writeln('[DesktopNcmBridge] Node bridge is ready.');
    } catch (_) {
      await _abortStart();
      rethrow;
    }
  }

  // ===========================================================================
  // NDJSON stdout handling
  // ===========================================================================

  void _handleStdout(String chunk) {
    // IMPORTANT:
    //
    // stdout is the actual NDJSON protocol channel.
    //
    // Log it to stderr so debugging output does not contaminate the
    // Node stdout protocol itself.
    stderr.writeln(
      '[DesktopNcmBridge][node stdout] '
      '${chunk.replaceAll('\n', '\\n')}',
    );

    if (_events.isClosed) {
      return;
    }

    for (final event in _splitter.feed(chunk)) {
      _dispatch(event);
    }
  }

  void _handleStdoutDone() {
    stderr.writeln('[DesktopNcmBridge] Node stdout closed.');

    if (_events.isClosed) {
      return;
    }

    // Process any final partial NDJSON line.
    for (final event in _splitter.flush()) {
      _dispatch(event);
    }

    // DO NOT call _onNodeExit(0) here.
    //
    // stdout closing is not authoritative.
    //
    // Process.exitCode is the authoritative process lifecycle signal.
  }

  void _dispatch(NdjsonEvent event) {
    dispatchNdjson(
      events: <NdjsonEvent>[event],
      pending: _pending,
      eventsCtl: _events,
      onFatal: (message, cause) {
        stderr.writeln(
          '[DesktopNcmBridge] protocol fatal: '
          '$message'
          '${cause == null ? '' : ' ($cause)'}',
        );

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

    stderr.writeln('[DesktopNcmBridge] received ready event: $value');

    final completer = _readyCompleter;

    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  // ===========================================================================
  // Node exit handling
  // ===========================================================================

  void _onNodeExit(int code) {
    if (_nodeExitHandled) {
      return;
    }

    _nodeExitHandled = true;

    stderr.writeln('[DesktopNcmBridge] handling Node exit: code=$code');

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

  // ===========================================================================
  // Failed startup cleanup
  // ===========================================================================

  Future<void> _abortStart() async {
    stderr.writeln('[DesktopNcmBridge] aborting Node bridge startup.');

    _started = false;

    final proc = _proc;
    _proc = null;

    if (proc != null) {
      try {
        await proc.stdin.close();
      } catch (_) {}

      try {
        proc.kill();
      } catch (_) {}
    }

    _pending.rejectAll(BridgeError('bridge failed to start'));

    final tmp = _extractedBridgeDir;
    _extractedBridgeDir = null;

    if (tmp != null) {
      stderr.writeln(
        '[DesktopNcmBridge] deleting temporary bridge: '
        '${tmp.path}',
      );

      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
  }

  // ===========================================================================
  // RPC
  // ===========================================================================

  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic>? params,
  ]) async {
    final proc = _proc;

    if (proc == null || !_started) {
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

    stderr.writeln(
      '[DesktopNcmBridge] -> Node '
      'id=$id method=$method',
    );

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

  // ===========================================================================
  // Shutdown
  // ===========================================================================

  @override
  Future<void> shutdown() async {
    stderr.writeln('[DesktopNcmBridge] shutdown requested.');

    final proc = _proc;

    _proc = null;
    _started = false;
    _nodeExitHandled = true;

    if (proc != null) {
      try {
        // Closing stdin sends EOF to the Node bridge.
        //
        // The bundle uses process.stdin as its request stream, so this gives
        // Node a chance to terminate cleanly.
        await proc.stdin.close();
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
      stderr.writeln(
        '[DesktopNcmBridge] deleting temporary bridge: '
        '${tmp.path}',
      );

      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }

    stderr.writeln('[DesktopNcmBridge] shutdown complete.');
  }
}
