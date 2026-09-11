# Mobile setup (Android / iOS)

The Dart side of the bridge (`MobileNcmBridge`) and the entire Node.js
runtime (`bridge/bridge.js` + `node_modules/`) are ready. The native
side — the code that loads `libnode.so` / `NodeMobile.xcframework` and
runs `bridge.js` — is **bundled with this repo** at the following
locations.

| Layer | Android | iOS |
|---|---|---|
| JNI wrapper | `android/app/src/main/cpp/native-lib.cpp` | — |
| CMake build | `android/app/src/main/cpp/CMakeLists.txt` | — |
| Kotlin plugin | `android/app/src/main/kotlin/com/example/ncm_api_enhanced/NcmNodeBridge.kt` | — |
| ObjC++ wrapper | — | `ios/Runner/NodeRunner.h`, `NodeRunner.mm` |
| Swift plugin | — | `ios/Runner/NcmNodePlugin.swift` |
| Plugin registration | `MainActivity.kt` | `AppDelegate.swift` |
| Asset bundle | `android/app/src/main/assets/ncm_bridge/` | `ios/Runner/ncm_bridge/` |
| libnode vendor dir | `android/app/libnode/` | (drag `NodeMobile.framework` into Runner) |

You only need to vendor the libnode binaries (one-time) and wire the
project to find them.

---

## Android

### 1. Vendor libnode.so + headers

Download `nodejs-mobile-v18.20.4-android.tar.gz` from
<https://github.com/nodejs-mobile/nodejs-mobile/releases/tag/v18.20.4>.

Extract and place:

```
android/app/libnode/
├── bin/
│   ├── arm64-v8a/libnode.so
│   ├── armeabi-v7a/libnode.so
│   └── x86_64/libnode.so
└── include/
    └── node/         # C++ headers (node.h, etc.)
```

The exact layout is referenced by `app/src/main/cpp/CMakeLists.txt`. The
`build.gradle.kts` already adds `app/libnode/bin/` to `jniLibs.srcDirs`,
so a clean `flutter build apk` packages the .so files into every ABI APK.

### 2. Copy the bridge assets

```
tool/copy_bridge.sh android
```

This populates `android/app/src/main/assets/ncm_bridge/` with `bridge.js`,
`package.json`, and the entire `node_modules/` tree (≈ 65 MB).
`NcmNodeBridge.kt` copies these to `filesDir/ncm_bridge/` at startup.

### 3. Build

```
flutter build apk --debug --target-platform=android-arm64
```

The CMake build runs as part of Gradle, producing `libncm_node_bridge.so`
that wraps `libnode.so`. `NcmNodeBridge` is registered in
`MainActivity.configureFlutterEngine`.

`INTERNET` permission is already declared in `AndroidManifest.xml`.

---

## iOS

### 1. Vendor NodeMobile.framework

Download `nodejs-mobile-v18.20.4-ios.tar.gz` from
<https://github.com/nodejs-mobile/nodejs-mobile/releases/tag/v18.20.4>.

Extract `Release-universal/NodeMobile.framework`. Two ways to add it:

**Scripted** (recommended if you have the `xcodeproj` Ruby gem):

```
gem install --user-install xcodeproj
tool/patch_ios_pbxproj.rb path/to/NodeMobile.xcframework
```

**Manual** (Xcode UI):

1. Drag `NodeMobile.framework` from Finder into `ios/Runner/`.
2. Drag it from Finder into the Xcode project's **Frameworks** group.
3. Tick **Copy items if needed**, target **Runner**.
4. Project → Build Settings → **Enable Bitcode → No** (libnode isn't
   bitcode-built).

### 2. Add the bridge assets as a folder reference

See `tool/ios_add_folder_ref.md`. In Xcode: **Add Files to "Runner"…**
→ select `ios/Runner/ncm_bridge/` → **Add as Folder Reference** (blue
folder icon, *not* "Create groups"). This ships the entire tree inside
the app bundle at `ncm_bridge/`.

```
tool/copy_bridge.sh ios   # populate ios/Runner/ncm_bridge/
```

### 3. Build

```
cd ios && pod install
flutter build ios --debug --no-codesign
```

`Podfile` sets `ENABLE_BITCODE = NO` across all Pods. `NcmNodePlugin` is
registered in `AppDelegate.didInitializeImplicitFlutterEngine`.

---

## How it works

```
Dart: MobileNcmBridge.call('album', {'id': 12345})
   ↓
Kotlin/Swift: MethodChannel("ncm_api_enhanced/bridge").invokeMethod('call', {...})
   ↓
JNI / ObjC: writeToNodeStdin('{"id":N,"method":"album","params":{...}}\n')
   ↓
[libnode.so / NodeMobile.framework] → embedded Node.js
   ↓
bridge.js: require('@neteasecloudmusicapienhanced/api').album(params)
   ↓
axios → music.163.com → Response
   ↓
bridge.js: stdout.write('{"id":N,"ok":true,"result":{...}}\n')
   ↓
[pipe reader thread] → JNI / ObjC callback → Kotlin/Swift EventChannel
   ↓
Dart: Future completes with Map<String, response
```

The pipe redirection (`dup2(STDOUT_FILENO)` / pipe-based stdin) is
required because `node::Start` / `node_start` blocks the calling thread
and inherits the host process's file descriptors. Without it, node's
stdout goes to logcat / OSLog and we can't reach it from Flutter.

## What does **not** work yet

These are platform-level caveats, not bugs in the code shipped here:

- **`NcmNodeBridge.shutdown()` on iOS/Android is advisory.** Embedded
  node has no clean exit. The Dart `MobileNcmBridge.shutdown()` will
  not actually stop the runtime — to fully tear down, the OS process
  must exit (e.g. close the Activity / kill the app).
- **Stack size matters.** iOS's `NSThread` stack is set to 2 MB in
  `NcmNodePlugin.handleStart`. Android doesn't need explicit tuning.
- **`x86` (32-bit) is dropped.** nodejs-mobile v18.20.4 only ships
  `x86_64`, `arm64-v8a`, `armeabi-v7a`. The build.gradle restricts
  `abiFilters` accordingly.

## Verification

A live integration test (Android emulator or iOS device) is required to
fully verify the IPC round-trip. In CI-restricted environments where
the libnode binaries cannot be vendored:

- `flutter analyze` is clean (0 issues).
- The desktop smoke test (`flutter test test/bridge_smoke_test.dart`)
  proves the bridge protocol works end-to-end against the same
  `bridge.js` — the only difference on mobile is the transport
  (Process vs libnode embedded in-process).