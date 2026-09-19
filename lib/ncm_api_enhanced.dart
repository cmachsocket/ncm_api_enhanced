/// ncm_api_enhanced — Flutter bindings for @neteasecloudmusicapienhanced/api
/// (an unofficial Netease Cloud Music API).
///
/// Cross-platform:
///   * Linux / macOS / Windows: spawns the system `node` binary
///     (>=18 required) and talks NDJSON over stdin/stdout. The upstream
///     module functions are required directly — no HTTP server is started.
///   * Android: ships a prebuilt `node` PIE binary (aarch64-android24
///     cross-compiled from upstream Node.js) as a Flutter asset and
///     fork()+execvp()s it from a native bridge. The Dart build hook
///     compiles `libncm_node_bridge.so` against the system NDK; no
///     vendoring of nodejs-mobile is required.
///   * iOS: still uses nodejs-mobile via NodeMobile.xcframework, added
///     by the consumer's Xcode project.
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