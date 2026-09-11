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