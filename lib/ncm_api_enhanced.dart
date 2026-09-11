/// ncm_api_enhanced — Flutter bindings for @neteasecloudmusicapienhanced/api
/// (an unofficial Netease Cloud Music API).
///
/// Cross-platform:
///   * Linux / macOS / Windows: spawns the system `node` binary
///     (>=18 required) and talks NDJSON over stdin/stdout. The upstream
///     module functions are required directly — no HTTP server is started.
///   * Android / iOS: embeds libnode via nodejs-mobile v18.20.4 and runs
///     the same bridge.js through a platform channel. (Native side
///     not bundled with this package — see README.)
///
/// Concurrency:
///   Every call returns a [Future]. Issuing N calls without awaiting runs
///   them concurrently on the node side. Node's event loop dispatches them
///   in parallel; no worker pool is needed because the upstream functions
///   are async I/O (axios).
///
/// Usage:
/// ```dart
/// import 'package:ncm_api_enhanced/ncm_api_enhanced.dart';
///
/// void main() async {
///   WidgetsFlutterBinding.ensureInitialized();
///   final api = NcmApi();
///   await api.start();
///   final album = await api.album({'id': 12345});
///   print(album['body']);  // upstream NCM response
///   await api.shutdown();
/// }
/// ```
library;

export 'src/ncm_api.dart';
export 'src/bridge.dart' show NcmBridge, BridgeError, kDefaultCallTimeout;
export 'src/desktop_bridge.dart' show DesktopNcmBridge;
export 'src/mobile_bridge.dart' show MobileNcmBridge;
export 'src/platform_bridge.dart' show NcmBridgeFactory;