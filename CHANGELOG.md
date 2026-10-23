## 0.3.0

- Windows: the `node.exe` runtime is no longer shipped inside the package.
  `hook/build.dart` downloads the official Node.js 26.12.1 binary for the
  target architecture (SHA-256 verified, nodejs.org with an npmmirror
  fallback) and registers it as a bundled `CodeAsset`, so Flutter installs
  it next to the application executable. `DesktopNcmBridge` spawns that
  binary and falls back to `node` on `PATH` when the hook did not run.
  This removes ~186 MB of binaries from the repository and the pub
  tarball.
- Android is now **arm64-v8a only**: the hook rejects `armeabi-v7a`,
  `x86_64` and other ABIs with an `UnsupportedError` instead of producing
  an APK with a mismatched architecture.
- Node.js bumped to 26.12.1 on Android as well, so desktop and mobile
  share the same runtime version.
- All downloaded runtimes are cached in `~/.cache/ncm_api_enhanced`
  (`%LOCALAPPDATA%\ncm_api_enhanced` on Windows) and failed downloads are
  retried, so repeated builds skip the network.
- Added `crypto` as a dependency to verify the SHA-256 of the downloaded
  Windows runtime.
- Added a test suite: unit tests for the NDJSON splitter, the pending
  request table, the NDJSON dispatcher and the bridge factory, plus
  integration tests for the desktop bridge and the `NcmApi` facade.
- Added a GitHub Actions workflow with `analyze`, `test` and `hook` jobs.
  The build-hook tests are tagged in `dart_test.yaml` so they run in
  their own job.

## 0.2.2

- README: point at the upstream
  [api-enhanced](https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced)
  repository, document the arm64-v8a-only ABI coverage, and rewrite the
  iOS status section.

## 0.2.1

- Republish of 0.2.0 with corrected package metadata.

## 0.2.0

- Runtime replaced: nodejs-mobile v18.20.4 is gone in favour of Node.js
  v26.9.0, built from the [cmachsocket/node](https://github.com/cmachsocket/node)
  fork.
- Android: the JNI/Kotlin plugin bridge was replaced by a native FFI
  bridge (`native/android/node_bridge.cpp`) that the Dart build hook
  compiles with the NDK clang shipped with the Flutter SDK.
- Node side: the upstream package is now bundled by esbuild into a single
  `assets/bridge/dist/bundle.js`; a generated `generated_api.js` wrapper
  statically lists all 439 upstream module functions so the whole
  dependency graph can be bundled.
- Added a `libcpufeatures.so` stub so `dlopen(libnode.so)` resolves
  `android_getCpuFeatures` on Android.
- Windows: `node.exe` (Node 26.8.2, x64 and arm64) is shipped as a
  Flutter asset.
- Rewrote the bridge protocol layer: NDJSON framing, per-request id
  matching, `ready` / `log` / `fatal` events and structured error
  replies.
- `NcmApi.call` validates the method name against the upstream whitelist
  and throws an `ArgumentError` before any IPC happens, so typos fail
  fast.

## 0.1.0

- Initial release.
- 439 upstream NCM module functions exposed as Dart facade
  (`api.album(...)`, `api.call('loginQrKey', ...)`, etc.).
- Cross-platform:
  - Linux / macOS / Windows: spawns the system `node` binary
    (>= 18) and talks NDJSON over stdin/stdout.
  - Android: libnode.so from nodejs-mobile v18.20.4, downloaded by
    `hook/build.dart` at consumer build time, loaded via JNI.
  - iOS: NodeMobile.xcframework (added via `tool/patch_ios_pbxproj.rb`
    or manually in Xcode).
- Pinned to nodejs-mobile v18.20.4.
